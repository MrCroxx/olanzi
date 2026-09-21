import CoreGraphics
import Foundation
import XCTest
@testable import OlanziCore

private final class HostServiceTransport: DeviceTransport {
    let lock = NSLock()
    private var heartbeatAllowed = false
    private var heartbeatCount = 0
    var heartbeatEnabled: Bool {
        get { lock.withLock { heartbeatAllowed } }
        set { lock.withLock { heartbeatAllowed = newValue } }
    }
    var heartbeats: Int { lock.withLock { heartbeatCount } }
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
    func setEntries(_ entries: [KeyEntry], index: Int) {
        lock.withLock { keys[index] = KeyBinding(index: index, entries: entries) }
    }
    func onNextQuery(_ action: @escaping (HostServiceTransport) -> Void) { lock.withLock { queryAction = action } }
    func open() throws { heartbeatEnabled = false }
    func close() { heartbeatEnabled = false }
    func pump(for duration: TimeInterval) throws {
        onPump?()
        lock.withLock { if heartbeatAllowed { heartbeatCount += 1 } }
    }
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

private final class HostPermissions: @unchecked Sendable {
    private let lock = NSLock()
    private var granted = true
    func set(_ value: Bool) { lock.withLock { granted = value } }
    func read() -> (input: Bool?, accessibility: Bool) { lock.withLock { (granted, granted) } }
}

final class HostServiceTests: XCTestCase {
    private func map(code: UInt8 = 1) -> HostKeymap {
        HostKeymap(controls: (0..<6).map { ControlActionMap(index: $0, press: [KeyEntry(code: $0 == 0 ? code : 0x28)]) })
    }
    private func service(_ store: MemoryHostStore, transport: HostServiceTransport,
                         snapshots: HostSnapshots, demo: Bool = false,
                         actions: HostActionLog = HostActionLog(),
                         permissions: HostPermissions = HostPermissions()) -> NativeDeviceService {
        NativeDeviceService(demo: demo, transportFactory: { transport },
                            loadHostKeymap: { try store.load() }, saveHostKeymap: { try store.save($0) },
                            bridgeFactory: {
            VendorKeyBridge(permissions: { permissions.read() }, now: { actions.now }, emit: { entries, down, _ in
                actions.record(entries, down)
            })
        }, onChange: { snapshots.append($0) })
    }
    private func stop(_ service: NativeDeviceService) {
        let done = expectation(description: "工作线程退出")
        service.stop { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    func testMissingFileRequiresExplicitSaveAndRefreshReconnectNeverOverwriteHostConfiguration() throws {
        let store = MemoryHostStore()
        let transport = HostServiceTransport()
        let snapshots = HostSnapshots()
        let service = service(store, transport: transport, snapshots: snapshots)
        defer { stop(service) }
        service.start()
        let missing = try XCTUnwrap(snapshots.wait { $0.hostConfigurationMissing && $0.online == true })
        XCTAssertNil(missing.hostKeymap)
        XCTAssertNil(missing.error)
        XCTAssertFalse(missing.fn.active)
        XCTAssertFalse(missing.heartbeatEnabled)
        XCTAssertEqual(store.counts.0, 1)
        XCTAssertEqual(store.counts.1, 0)
        XCTAssertEqual(transport.heartbeats, 0)
        XCTAssertNoThrow(try HostKeymap.defaultKeymap.validate())
        let requestID = UUID()
        service.applyHostKeymap(.defaultKeymap, requestID: requestID)
        let initial = try XCTUnwrap(snapshots.wait { !$0.busy && $0.hostSaveResult?.requestID == requestID })
        XCTAssertEqual(initial.hostKeymap, .defaultKeymap)
        XCTAssertFalse(initial.hostConfigurationMissing)
        XCTAssertTrue(initial.heartbeatEnabled)
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

    func testMissingHostConfigurationCanBeSavedBeforeFirstDeviceConnection() throws {
        let store = MemoryHostStore()
        let transport = HostServiceTransport()
        let snapshots = HostSnapshots()
        let service = service(store, transport: transport, snapshots: snapshots)
        defer { stop(service) }
        service.disconnect()
        service.start()
        XCTAssertNotNil(snapshots.wait { $0.hostConfigurationMissing && !$0.connected })
        let requestID = UUID()
        service.applyHostKeymap(.defaultKeymap, requestID: requestID)
        let saved = try XCTUnwrap(snapshots.wait { !$0.busy && $0.hostSaveResult?.requestID == requestID })
        XCTAssertNil(saved.hostSaveResult?.error)
        XCTAssertEqual(saved.hostKeymap, .defaultKeymap)
        XCTAssertFalse(saved.hostConfigurationMissing)
        XCTAssertFalse(saved.connected)
        XCTAssertFalse(saved.fn.active)
        XCTAssertFalse(saved.heartbeatEnabled)
        XCTAssertEqual(store.value, .defaultKeymap)
        XCTAssertEqual(store.counts.0, 1)
        XCTAssertEqual(store.counts.1, 1)
        XCTAssertEqual(transport.heartbeats, 0)
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
        XCTAssertNotNil(snapshots.wait { $0.hostKeymap == original && !$0.hostConfigurationMissing })
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
        XCTAssertFalse(failed.hostConfigurationMissing)
        XCTAssertFalse(failed.fn.active)
        XCTAssertFalse(failed.heartbeatEnabled)
        let mark = snapshots.count
        service.refresh()
        let refreshed = try XCTUnwrap(snapshots.wait(after: mark) { !$0.busy && $0.online == true })
        XCTAssertTrue(refreshed.error?.contains("损坏配置测试") == true)
        XCTAssertEqual(store.counts.0, 1)
        XCTAssertEqual(store.counts.1, 0)
        XCTAssertEqual(transport.writes, 0)
        let requestID = UUID()
        service.applyHostKeymap(map(), requestID: requestID)
        let rejected = try XCTUnwrap(snapshots.wait { $0.hostSaveResult?.requestID == requestID })
        XCTAssertNotNil(rejected.hostSaveResult?.error)
        XCTAssertNil(rejected.hostKeymap)
        XCTAssertFalse(rejected.hostConfigurationMissing)
        XCTAssertEqual(store.counts.1, 0)
        XCTAssertEqual(transport.heartbeats, 0)
    }

    func testFailedFirstExplicitSaveDoesNotActivateOrRetryUntilRequested() throws {
        let store = MemoryHostStore()
        store.setSaveFailure(true)
        let transport = HostServiceTransport()
        let snapshots = HostSnapshots()
        let service = service(store, transport: transport, snapshots: snapshots)
        defer { stop(service) }
        service.start()
        XCTAssertNotNil(snapshots.wait { $0.online == true && $0.hostConfigurationMissing })
        XCTAssertEqual(store.counts.1, 0)
        let failedID = UUID()
        service.applyHostKeymap(.defaultKeymap, requestID: failedID)
        let failed = try XCTUnwrap(snapshots.wait { !$0.busy && $0.hostSaveResult?.requestID == failedID })
        XCTAssertTrue(failed.hostSaveResult?.error?.contains("持久化失败测试") == true)
        XCTAssertNil(failed.hostKeymap)
        XCTAssertTrue(failed.hostConfigurationMissing)
        XCTAssertFalse(failed.fn.active)
        XCTAssertFalse(failed.heartbeatEnabled)
        let mark = snapshots.count
        service.refresh()
        XCTAssertNotNil(snapshots.wait(after: mark) { !$0.busy && $0.online == true })
        XCTAssertEqual(store.counts.1, 1)
        XCTAssertNil(store.value)
        XCTAssertEqual(transport.writes, 0)
        XCTAssertEqual(transport.heartbeats, 0)
        store.setSaveFailure(false)
        let requestID = UUID()
        service.applyHostKeymap(map(), requestID: requestID)
        let saved = try XCTUnwrap(snapshots.wait { $0.hostSaveResult?.requestID == requestID && !$0.busy })
        XCTAssertNil(saved.hostSaveResult?.error)
        XCTAssertFalse(saved.hostConfigurationMissing)
        XCTAssertEqual(saved.hostKeymap, map())
        XCTAssertTrue(saved.heartbeatEnabled)
        XCTAssertEqual(store.counts.1, 2)
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
        let initial = try XCTUnwrap(snapshots.wait { $0.demo && $0.hostKeymap != nil })
        XCTAssertEqual(initial.hostKeymap, .defaultKeymap)
        XCTAssertFalse(initial.hostConfigurationMissing)
        let mark = snapshots.count
        service.applyHostKeymap(map(code: 0x69))
        XCTAssertNotNil(snapshots.wait(after: mark) { !$0.busy && $0.hostKeymap == self.map(code: 0x69) })
        XCTAssertEqual(store.counts.0, 0)
        XCTAssertEqual(store.counts.1, 0)
        XCTAssertTrue(actions.codes.isEmpty)
        XCTAssertEqual(transport.writes, 0)
    }

    func testUnsupportedDeviceBindingDoesNotBlockExplicitDefaultHostConfiguration() throws {
        let store = MemoryHostStore()
        let transport = HostServiceTransport()
        let media = [KeyEntry(type: 3, code: 4)]
        transport.setEntries(media, index: 4)
        let snapshots = HostSnapshots()
        let service = service(store, transport: transport, snapshots: snapshots)
        defer { stop(service) }
        service.start()
        let missing = try XCTUnwrap(snapshots.wait { $0.online == true && $0.hostConfigurationMissing })
        XCTAssertTrue(missing.connected)
        XCTAssertNil(missing.error)
        XCTAssertNil(missing.hostKeymap)
        XCTAssertFalse(missing.heartbeatEnabled)
        XCTAssertFalse(missing.fn.active)
        XCTAssertEqual(missing.keys[4].entries, media)
        let mark = snapshots.count
        service.refresh()
        XCTAssertNotNil(snapshots.wait(after: mark) { !$0.busy && $0.hostConfigurationMissing && $0.error == nil })
        XCTAssertEqual(transport.heartbeats, 0)
        XCTAssertEqual(store.counts.1, 0)

        let requestID = UUID()
        service.applyHostKeymap(.defaultKeymap, requestID: requestID)
        let saved = try XCTUnwrap(snapshots.wait { !$0.busy && $0.hostSaveResult?.requestID == requestID })
        XCTAssertNil(saved.hostSaveResult?.error)
        XCTAssertNil(saved.error)
        XCTAssertTrue(saved.fn.active)
        XCTAssertTrue(saved.heartbeatEnabled)
        XCTAssertEqual(saved.hostKeymap, .defaultKeymap)
        XCTAssertFalse(saved.hostConfigurationMissing)
        XCTAssertEqual(saved.keys[4].entries, media)
        XCTAssertEqual(transport.writes, 0)
    }

    func testHardwareChangesNeverInitializeMissingHostConfiguration() throws {
        let store = MemoryHostStore()
        let transport = HostServiceTransport()
        transport.setCode(0x70, index: 4)
        let snapshots = HostSnapshots()
        let service = service(store, transport: transport, snapshots: snapshots)
        defer { stop(service) }
        service.start()
        XCTAssertNotNil(snapshots.wait { $0.online == true && $0.hostConfigurationMissing && $0.error == nil })
        XCTAssertEqual(transport.heartbeats, 0)
        transport.setCode(0x4F, index: 4)
        let mark = snapshots.count
        service.refresh()
        let refreshed = try XCTUnwrap(snapshots.wait(after: mark) { !$0.busy && $0.keys[4].code == 0x4F })
        XCTAssertNil(refreshed.error)
        XCTAssertNil(refreshed.hostKeymap)
        XCTAssertTrue(refreshed.hostConfigurationMissing)
        XCTAssertFalse(refreshed.heartbeatEnabled)
        XCTAssertEqual(transport.heartbeats, 0)
        XCTAssertEqual(store.counts.1, 0)
        XCTAssertEqual(transport.writes, 0)
    }

    func testPermissionsGateHeartbeatIncludingRevocationDuringQuery() throws {
        let store = MemoryHostStore(map())
        let transport = HostServiceTransport()
        let snapshots = HostSnapshots()
        let actions = HostActionLog()
        let permissions = HostPermissions()
        permissions.set(false)
        let service = service(store, transport: transport, snapshots: snapshots,
                              actions: actions, permissions: permissions)
        defer { stop(service) }
        service.start()
        let missing = try XCTUnwrap(snapshots.wait { $0.online == true && $0.fn.error != nil })
        XCTAssertFalse(missing.heartbeatEnabled)
        XCTAssertFalse(missing.fn.active)
        XCTAssertEqual(transport.heartbeats, 0)
        permissions.set(true)
        var mark = snapshots.count
        service.checkFnPermissions()
        XCTAssertNotNil(snapshots.wait(after: mark) { !$0.busy && $0.heartbeatEnabled && $0.fn.active })

        transport.onNextQuery { device in
            XCTAssertTrue(device.heartbeatEnabled)
            device.onKeyEvent?(.init(index: 0, pressed: true))
            XCTAssertEqual(actions.presses, [true])
            permissions.set(false)
            actions.advance(3)
            let count = device.heartbeats
            try? device.pump(for: 0)
            XCTAssertFalse(device.heartbeatEnabled)
            XCTAssertEqual(device.heartbeats, count)
            XCTAssertEqual(actions.presses, [true, false])
            device.onKeyEvent?(.init(index: 0, pressed: false))
        }
        mark = snapshots.count
        service.connect()
        XCTAssertNotNil(snapshots.wait(after: mark) { !$0.busy && !$0.heartbeatEnabled && !$0.fn.active })
        XCTAssertEqual(actions.presses, [true, false])
        permissions.set(true)
        mark = snapshots.count
        service.checkFnPermissions()
        XCTAssertNotNil(snapshots.wait(after: mark) { !$0.busy && $0.heartbeatEnabled && $0.fn.active })
        XCTAssertEqual(transport.writes, 0)
    }

    func testSaveResultsIdentifyFailuresAndDoNotChangeForOtherJobs() throws {
        let store = MemoryHostStore(map())
        let transport = HostServiceTransport()
        let snapshots = HostSnapshots()
        let service = service(store, transport: transport, snapshots: snapshots)
        defer { stop(service) }
        service.start()
        XCTAssertNotNil(snapshots.wait { $0.online == true })
        store.setSaveFailure(true)
        let firstID = UUID()
        service.applyHostKeymap(map(code: 0x29), requestID: firstID)
        let failed = try XCTUnwrap(snapshots.wait { !$0.busy && $0.hostSaveResult?.requestID == firstID })
        XCTAssertTrue(failed.hostSaveResult?.error?.contains("持久化失败测试") == true)
        var mark = snapshots.count
        service.checkFnPermissions()
        let checked = try XCTUnwrap(snapshots.wait(after: mark) { !$0.busy })
        XCTAssertEqual(checked.hostSaveResult, failed.hostSaveResult)
        store.setSaveFailure(false)
        let secondID = UUID()
        mark = snapshots.count
        service.applyHostKeymap(map(code: 0x29), requestID: secondID)
        let saved = try XCTUnwrap(snapshots.wait(after: mark) { !$0.busy && $0.hostSaveResult?.requestID == secondID })
        XCTAssertNil(saved.hostSaveResult?.error)
        XCTAssertEqual(saved.hostKeymap, map(code: 0x29))
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
            XCTAssertTrue(device.heartbeatEnabled)
            device.onKeyEvent?(.init(index: 0, pressed: true))
            XCTAssertTrue(actions.codes.isEmpty)
            actions.advance(0.5)
            device.onPump?()
            XCTAssertTrue(device.heartbeatEnabled)
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
            XCTAssertFalse(device.heartbeatEnabled)
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
