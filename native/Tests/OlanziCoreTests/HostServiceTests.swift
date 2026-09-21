import CoreGraphics
import Foundation
import XCTest
@testable import OlanziCore

private final class HostServiceTransport: DeviceTransport {
    let lock = NSLock()
    var onKeyEvent: ((VendorKeyEvent) -> Void)?
    var onPump: (() -> Void)?
    var lastHeartbeat: Date? = Date()
    private var keys = DeviceProtocol.defaultCodes.enumerated().map {
        KeyBinding(index: $0.offset, entries: [KeyEntry(code: $0.element)])
    }
    private var writeCount = 0
    private var queryAction: ((HostServiceTransport) -> Void)?
    var writes: Int { lock.withLock { writeCount } }
    func setCode(_ code: UInt8, index: Int) { lock.withLock { keys[index] = KeyBinding(index: index, entries: [KeyEntry(code: code)]) } }
    func onNextQuery(_ action: @escaping (HostServiceTransport) -> Void) { lock.withLock { queryAction = action } }
    func open() throws {}
    func close() {}
    func pump(for duration: TimeInterval) throws { onPump?() }
    func queryOnline() throws -> Bool {
        let action = lock.withLock { () -> ((HostServiceTransport) -> Void)? in
            defer { queryAction = nil }
            return queryAction
        }
        action?(self)
        return true
    }
    func readKey(index: Int) throws -> KeyBinding { lock.withLock { keys[index] } }
    func writeKey(index: Int, code: UInt8) throws {
        lock.withLock { writeCount += 1; keys[index] = KeyBinding(index: index, entries: [KeyEntry(code: code)]) }
    }
}

private final class MemoryHostStore: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: HostKeymap?
    private var loadCount = 0
    private var saveCount = 0
    private var badLoad = false
    private var badSave = false
    init(_ value: HostKeymap? = nil) { stored = value }
    func setLoadFailure() { lock.withLock { badLoad = true } }
    func setSaveFailure(_ failed: Bool) { lock.withLock { badSave = failed } }
    func load() throws -> HostKeymap? {
        try lock.withLock {
            loadCount += 1
            if badLoad { throw DeviceProtocolError.message("损坏配置测试") }
            return stored
        }
    }
    func save(_ value: HostKeymap) throws {
        try lock.withLock {
            saveCount += 1
            if badSave { throw DeviceProtocolError.message("持久化失败测试") }
            stored = value
        }
    }
    var counts: (Int, Int) { lock.withLock { (loadCount, saveCount) } }
    var value: HostKeymap? { lock.withLock { stored } }
}

private final class HostSnapshots: @unchecked Sendable {
    private let condition = NSCondition()
    private var values: [DeviceSnapshot] = []
    func append(_ value: DeviceSnapshot) {
        condition.lock(); values.append(value); condition.broadcast(); condition.unlock()
    }
    var count: Int { condition.lock(); defer { condition.unlock() }; return values.count }
    func wait(after index: Int = 0, _ predicate: (DeviceSnapshot) -> Bool) -> DeviceSnapshot? {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: 2)
        while true {
            if let value = values.dropFirst(index).first(where: predicate) { return value }
            guard condition.wait(until: deadline) else { return nil }
        }
    }
}

private final class HostActionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 0
    private var records: [(UInt8, Bool)] = []
    var now: TimeInterval { lock.withLock { time } }
    func advance(_ value: TimeInterval) { lock.withLock { time = value } }
    func record(_ entries: [KeyEntry], _ pressed: Bool) { lock.withLock { records += entries.map { ($0.code, pressed) } } }
    var codes: [UInt8] { lock.withLock { records.map(\.0) } }
    var presses: [Bool] { lock.withLock { records.map(\.1) } }
}

final class HostServiceTests: XCTestCase {
    private func map(code: UInt8 = 1) -> HostKeymap {
        HostKeymap(controls: (0..<6).map { ControlActionMap(index: $0, press: [KeyEntry(code: $0 == 0 ? code : 0x28)]) })
    }
    private func service(_ store: MemoryHostStore, transport: HostServiceTransport,
                         snapshots: HostSnapshots, demo: Bool = false,
                         actions: HostActionLog = HostActionLog()) -> NativeDeviceService {
        NativeDeviceService(demo: demo, transportFactory: { transport },
                            loadHostKeymap: { try store.load() }, saveHostKeymap: { try store.save($0) },
                            bridgeFactory: {
            VendorKeyBridge(permissions: { (true, true) }, now: { actions.now }, emit: { entries, down, _ in
                actions.record(entries, down)
            })
        }, onChange: { snapshots.append($0) })
    }
    private func stop(_ service: NativeDeviceService) {
        let done = expectation(description: "工作线程退出")
        service.stop { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    func testMissingFileSeedsOnceAndRefreshReconnectNeverOverwriteHostConfiguration() throws {
        let store = MemoryHostStore()
        let transport = HostServiceTransport()
        let snapshots = HostSnapshots()
        let service = service(store, transport: transport, snapshots: snapshots)
        defer { stop(service) }
        service.start()
        let initial = try XCTUnwrap(snapshots.wait { $0.hostKeymap != nil && $0.online == true })
        XCTAssertEqual(initial.hostKeymap?.controls[0].press.first?.code, 1)
        XCTAssertEqual(store.counts.0, 1)
        XCTAssertEqual(store.counts.1, 1)
        transport.setCode(0x69, index: 0)
        var mark = snapshots.count
        service.refresh()
        let refreshed = try XCTUnwrap(snapshots.wait(after: mark) { !$0.busy && $0.keys.first?.code == 0x69 })
        XCTAssertEqual(refreshed.hostKeymap, initial.hostKeymap)
        mark = snapshots.count
        service.disconnect()
        XCTAssertNotNil(snapshots.wait(after: mark) { !$0.connected })
        mark = snapshots.count
        service.connect()
        let reconnected = try XCTUnwrap(snapshots.wait(after: mark) { $0.connected && $0.online == true && !$0.busy })
        XCTAssertEqual(reconnected.hostKeymap, initial.hostKeymap)
        XCTAssertEqual(store.counts.0, 1)
        XCTAssertEqual(store.counts.1, 1)
        XCTAssertEqual(transport.writes, 0)
    }

    func testExistingHostConfigurationSurvivesDifferentDeviceBindingsAndOfflineSave() throws {
        let original = map(code: 0x68)
        let store = MemoryHostStore(original)
        let transport = HostServiceTransport()
        let snapshots = HostSnapshots()
        let service = service(store, transport: transport, snapshots: snapshots)
        defer { stop(service) }
        service.start()
        XCTAssertNotNil(snapshots.wait { $0.online == true && $0.hostKeymap == original })
        var mark = snapshots.count
        service.disconnect()
        XCTAssertNotNil(snapshots.wait(after: mark) { !$0.connected && !$0.busy })
        let changed = map(code: 0x69)
        mark = snapshots.count
        service.applyHostKeymap(changed)
        let saved = try XCTUnwrap(snapshots.wait(after: mark) { !$0.busy && $0.hostKeymap == changed })
        XCTAssertFalse(saved.connected)
        XCTAssertEqual(store.value, changed)
        XCTAssertEqual(store.counts.0, 1)
        XCTAssertEqual(store.counts.1, 1)
        XCTAssertEqual(transport.writes, 0)
    }

    func testFailedSaveRetainsPersistedAndActiveConfigurationAndErrorSurvivesRefresh() throws {
        let original = map(code: 0x68)
        let store = MemoryHostStore(original)
        let transport = HostServiceTransport()
        let snapshots = HostSnapshots()
        let actions = HostActionLog()
        let service = service(store, transport: transport, snapshots: snapshots, actions: actions)
        defer { stop(service) }
        service.start()
        XCTAssertNotNil(snapshots.wait { $0.online == true && $0.hostKeymap == original })
        store.setSaveFailure(true)
        var mark = snapshots.count
        service.applyHostKeymap(map(code: 0x69))
        let failed = try XCTUnwrap(snapshots.wait(after: mark) { !$0.busy && $0.error?.contains("持久化失败测试") == true })
        XCTAssertEqual(failed.hostKeymap, original)
        XCTAssertEqual(store.value, original)
        transport.onNextQuery { device in
            device.onKeyEvent?(.init(index: 0, pressed: true))
            device.onKeyEvent?(.init(index: 0, pressed: false))
        }
        mark = snapshots.count
        service.connect()
        let checked = try XCTUnwrap(snapshots.wait(after: mark) { !$0.busy && $0.online == true })
        XCTAssertTrue(checked.error?.contains("持久化失败测试") == true)
        XCTAssertEqual(actions.codes, [0x68, 0x68])
        mark = snapshots.count
        service.refresh()
        let refreshed = try XCTUnwrap(snapshots.wait(after: mark) { !$0.busy && $0.online == true })
        XCTAssertTrue(refreshed.error?.contains("持久化失败测试") == true)
        XCTAssertEqual(transport.writes, 0)
        store.setSaveFailure(false)
        mark = snapshots.count
        service.applyHostKeymap(map(code: 0x69))
        XCTAssertNotNil(snapshots.wait(after: mark) { !$0.busy && $0.error == nil && $0.hostKeymap == self.map(code: 0x69) })
    }

    func testCorruptLoadDoesNotSeedOverwriteOrActivateFallback() throws {
        let store = MemoryHostStore()
        store.setLoadFailure()
        let transport = HostServiceTransport()
        let snapshots = HostSnapshots()
        let service = service(store, transport: transport, snapshots: snapshots)
        defer { stop(service) }
        service.start()
        let failed = try XCTUnwrap(snapshots.wait { $0.online == true && $0.error?.contains("损坏配置测试") == true })
        XCTAssertNil(failed.hostKeymap)
        XCTAssertFalse(failed.fn.active)
        let mark = snapshots.count
        service.refresh()
        let refreshed = try XCTUnwrap(snapshots.wait(after: mark) { !$0.busy && $0.online == true })
        XCTAssertTrue(refreshed.error?.contains("损坏配置测试") == true)
        XCTAssertEqual(store.counts.0, 1)
        XCTAssertEqual(store.counts.1, 0)
        XCTAssertEqual(transport.writes, 0)
    }

    func testFailedFirstSeedDoesNotActivateOrRepeatedlyRewrite() throws {
        let store = MemoryHostStore()
        store.setSaveFailure(true)
        let transport = HostServiceTransport()
        let snapshots = HostSnapshots()
        let service = service(store, transport: transport, snapshots: snapshots)
        defer { stop(service) }
        service.start()
        let failed = try XCTUnwrap(snapshots.wait { $0.online == true && $0.error?.contains("无法从设备初始化") == true })
        XCTAssertNil(failed.hostKeymap)
        XCTAssertFalse(failed.fn.active)
        let mark = snapshots.count
        service.refresh()
        XCTAssertNotNil(snapshots.wait(after: mark) { !$0.busy && $0.online == true })
        XCTAssertEqual(store.counts.1, 1)
        XCTAssertNil(store.value)
        XCTAssertEqual(transport.writes, 0)
    }

    func testDemoNeverLoadsSavesOrInjectsRealActions() throws {
        let store = MemoryHostStore(map(code: 0x70))
        store.setLoadFailure()
        store.setSaveFailure(true)
        let transport = HostServiceTransport()
        let snapshots = HostSnapshots()
        let actions = HostActionLog()
        let service = service(store, transport: transport, snapshots: snapshots, demo: true, actions: actions)
        defer { stop(service) }
        service.start()
        XCTAssertNotNil(snapshots.wait { $0.demo && $0.hostKeymap != nil })
        let mark = snapshots.count
        service.applyHostKeymap(map(code: 0x69))
        XCTAssertNotNil(snapshots.wait(after: mark) { !$0.busy && $0.hostKeymap == self.map(code: 0x69) })
        XCTAssertEqual(store.counts.0, 0)
        XCTAssertEqual(store.counts.1, 0)
        XCTAssertTrue(actions.codes.isEmpty)
        XCTAssertEqual(transport.writes, 0)
    }

    func testLongDeadlineProgressesInsideBusyQueryWithoutAnotherReport() throws {
        var configuration = map()
        configuration.controls[0].longPress = [KeyEntry(code: 0x29)]
        let store = MemoryHostStore(configuration)
        let transport = HostServiceTransport()
        let snapshots = HostSnapshots()
        let actions = HostActionLog()
        let service = service(store, transport: transport, snapshots: snapshots, actions: actions)
        defer { stop(service) }
        service.start()
        XCTAssertNotNil(snapshots.wait { $0.online == true && $0.fn.active })
        transport.onNextQuery { device in
            device.onKeyEvent?(.init(index: 0, pressed: true))
            XCTAssertTrue(actions.codes.isEmpty)
            actions.advance(0.5)
            device.onPump?()
            XCTAssertEqual(actions.codes, [0x29])
            XCTAssertEqual(actions.presses, [true])
            device.onKeyEvent?(.init(index: 0, pressed: false))
        }
        let mark = snapshots.count
        service.connect()
        XCTAssertNotNil(snapshots.wait(after: mark) { !$0.busy && $0.fn.events >= 2 })
        XCTAssertEqual(actions.codes, [0x29, 0x29])
        XCTAssertEqual(actions.presses, [true, false])
    }

    func testSleepCancelsPendingTimersEvenWhenWakeIsQueuedBeforeWorkerFinishesQuery() throws {
        var configuration = map()
        configuration.controls[0].doublePress = [KeyEntry(code: 0x29)]
        configuration.controls[1].longPress = [KeyEntry(code: 0x29)]
        let store = MemoryHostStore(configuration)
        let transport = HostServiceTransport()
        let snapshots = HostSnapshots()
        let actions = HostActionLog()
        let service = service(store, transport: transport, snapshots: snapshots, actions: actions)
        defer { stop(service) }
        service.start()
        XCTAssertNotNil(snapshots.wait { $0.online == true && $0.fn.active })
        transport.onNextQuery { device in
            device.onKeyEvent?(.init(index: 0, pressed: true))
            device.onKeyEvent?(.init(index: 0, pressed: false))
            device.onKeyEvent?(.init(index: 1, pressed: true))
            // 权限检查先入队，再收到 sleep/wake，旧任务也必须看到暂停标记。
            service.checkFnPermissions()
            service.suspendForSystemSleep()
            service.resumeAfterSystemWake()
            actions.advance(20)
            device.onPump?()
            XCTAssertTrue(actions.codes.isEmpty)
        }
        var mark = snapshots.count
        service.connect()
        XCTAssertNotNil(snapshots.wait(after: mark) { !$0.connected && !$0.busy })
        mark = snapshots.count
        // 等待工作线程恢复；若恢复快于读取 mark，追加一次连接保证后续快照。
        service.connect()
        XCTAssertNotNil(snapshots.wait(after: mark) { $0.online == true && !$0.busy && $0.fn.active })
        XCTAssertTrue(actions.codes.isEmpty)
        XCTAssertEqual(store.value, configuration)
        XCTAssertEqual(store.counts.0, 1)
        XCTAssertEqual(store.counts.1, 0)
        XCTAssertEqual(transport.writes, 0)
    }

    func testSleepReleasesHeldFnAndStaleWakeCannotReenableLatestSleep() throws {
        let store = MemoryHostStore(map())
        let transport = HostServiceTransport()
        let snapshots = HostSnapshots()
        let actions = HostActionLog()
        let service = service(store, transport: transport, snapshots: snapshots, actions: actions)
        defer { stop(service) }
        service.start()
        XCTAssertNotNil(snapshots.wait { $0.online == true && $0.fn.active })
        transport.onNextQuery { device in
            device.onKeyEvent?(.init(index: 0, pressed: true))
            XCTAssertEqual(actions.presses, [true])
            service.suspendForSystemSleep()
            service.resumeAfterSystemWake()
            service.suspendForSystemSleep()
            device.onPump?()
            device.onKeyEvent?(.init(index: 0, pressed: true))
            XCTAssertEqual(actions.presses, [true, false])
        }
        var mark = snapshots.count
        service.connect()
        XCTAssertNotNil(snapshots.wait(after: mark) { !$0.connected && !$0.busy })
        mark = snapshots.count
        service.checkFnPermissions()
        XCTAssertNotNil(snapshots.wait(after: mark) { !$0.connected && !$0.busy && !$0.fn.active })
        XCTAssertEqual(actions.codes, [1, 1])
        mark = snapshots.count
        service.resumeAfterSystemWake()
        XCTAssertNotNil(snapshots.wait(after: mark) { $0.online == true && $0.fn.active })
        transport.onNextQuery { device in
            device.onKeyEvent?(.init(index: 0, pressed: true))
            device.onKeyEvent?(.init(index: 0, pressed: false))
        }
        mark = snapshots.count
        service.connect()
        XCTAssertNotNil(snapshots.wait(after: mark) { !$0.busy && $0.fn.events >= 4 })
        XCTAssertEqual(actions.presses, [true, false, true, false])
    }

    func testWakePreservesManualDisconnectPreference() throws {
        let store = MemoryHostStore(map())
        let transport = HostServiceTransport()
        let snapshots = HostSnapshots()
        let service = service(store, transport: transport, snapshots: snapshots)
        defer { stop(service) }
        service.start()
        XCTAssertNotNil(snapshots.wait { $0.online == true })
        var mark = snapshots.count
        service.disconnect()
        XCTAssertNotNil(snapshots.wait(after: mark) { !$0.connected && !$0.busy })
        service.suspendForSystemSleep()
        service.resumeAfterSystemWake()
        mark = snapshots.count
        service.applyHostKeymap(map(code: 0x29))
        let saved = try XCTUnwrap(snapshots.wait(after: mark) { !$0.busy && $0.hostKeymap == self.map(code: 0x29) })
        XCTAssertFalse(saved.connected)
        XCTAssertFalse(saved.fn.active)
    }

}
