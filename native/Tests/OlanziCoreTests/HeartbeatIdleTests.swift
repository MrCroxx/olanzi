import Foundation
import XCTest
@testable import OlanziCore

private final class IdleTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 1_000
    var now: TimeInterval { lock.withLock { value } }
    func set(_ value: TimeInterval) { lock.withLock { self.value = value } }
}

private final class IdleTestEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []
    var presses: [Bool] { lock.withLock { values } }
    func append(_ pressed: Bool) { lock.withLock { values.append(pressed) } }
}

private final class IdleTestSnapshots: @unchecked Sendable {
    private let condition = NSCondition()
    private var values: [DeviceSnapshot] = []
    var count: Int { condition.lock(); defer { condition.unlock() }; return values.count }
    func append(_ value: DeviceSnapshot) {
        condition.lock(); values.append(value); condition.broadcast(); condition.unlock()
    }
    func completed(after index: Int, matching predicate: (DeviceSnapshot) -> Bool) -> DeviceSnapshot? {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: 2)
        while true {
            // 先看到本次任务的 busy，再等待结束，不能误用轮询产生的旧空闲快照。
            if let busy = values.indices.dropFirst(index).first(where: { values[$0].busy }),
               let found = values.dropFirst(busy + 1).first(where: { !$0.busy && predicate($0) }) {
                return found
            }
            guard condition.wait(until: deadline) else { return nil }
        }
    }
    func wait(after index: Int = 0, matching predicate: (DeviceSnapshot) -> Bool) -> DeviceSnapshot? {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: 2)
        while true {
            if let found = values.dropFirst(index).first(where: predicate) { return found }
            guard condition.wait(until: deadline) else { return nil }
        }
    }
}

/// 操作队列只在服务工作线程执行，测试线程不直接调用输入回调。
private final class IdleTestTransport: DeviceTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = false
    private var softwareOnline = false
    private var onlineFailure: Bool?
    private var wireOperations: [String] = []
    private var sent = 0
    private var onlineQueries = 0
    private var batteryReads = 0
    private var keyReads = 0
    private var pumps = 0
    private var online: Bool? = true
    private var operations: [() -> Void] = []
    private var lastSent: Date?
    var onKeyEvent: ((VendorKeyEvent) -> Void)?
    var onPump: (() -> Void)?
    var heartbeatEnabled: Bool {
        get { lock.withLock { allowed } }
        set { lock.withLock { allowed = newValue; if !newValue { lastSent = nil } } }
    }
    var lastHeartbeat: Date? { lock.withLock { lastSent } }
    var heartbeatCount: Int { lock.withLock { sent } }
    var requestCounts: [Int] { lock.withLock { [sent, onlineQueries, batteryReads, keyReads] } }
    var pumpCount: Int { lock.withLock { pumps } }
    var traffic: [String] { lock.withLock { wireOperations } }
    func failSoftwareOnline(_ value: Bool?) { lock.withLock { onlineFailure = value } }
    func setSoftwareOnline(_ online: Bool) throws {
        try lock.withLock {
            wireOperations.append(online ? "online" : "offline")
            if onlineFailure == online { throw DeviceProtocolError.message("测试在线模式切换失败") }
            softwareOnline = online
        }
    }
    func setOnline(_ value: Bool?) { lock.withLock { online = value } }
    func enqueue(_ operation: @escaping () -> Void) { lock.withLock { operations.append(operation) } }
    func open() throws { heartbeatEnabled = false }
    func close() {
        heartbeatEnabled = false
        lock.withLock { softwareOnline = false; wireOperations.append("close") }
    }
    func pump(for duration: TimeInterval) throws {
        let work = lock.withLock { () -> [() -> Void] in
            pumps += 1
            defer { operations.removeAll() }
            return operations
        }
        work.forEach { $0() }
        onPump?()
        lock.withLock {
            if allowed && softwareOnline {
                sent += 1; lastSent = Date(); wireOperations.append("heartbeat")
            }
        }
    }
    func queryOnline() throws -> Bool {
        lock.withLock { onlineQueries += 1 }
        guard let value = lock.withLock({ online }) else {
            throw DeviceProtocolError.message("测试在线查询超时")
        }
        return value
    }
    func readKey(index: Int) throws -> KeyBinding {
        lock.withLock { keyReads += 1 }
        return KeyBinding(index: index, entries: [KeyEntry(code: 0x28)])
    }
    func readBattery() throws -> DeviceBattery {
        lock.withLock { batteryReads += 1 }
        return DeviceBattery(millivolts: 3900, percentage: 80, isCharging: false)
    }
    func writeKey(index: Int, code: UInt8) throws { XCTFail("空闲保活设置不能写设备键位") }
}

private final class IdleTestWakeMonitor: DeviceWakeMonitoring {
    var onActivity: ((Bool) -> Void)?
    var error: String?
    var opened = false
    func open() throws { opened = true; error = nil }
    func close() { opened = false; error = nil }
}

private struct IdleTestHarness {
    let clock = IdleTestClock()
    let events = IdleTestEvents()
    let snapshots = IdleTestSnapshots()
    let transport = IdleTestTransport()
    let wakeMonitor = IdleTestWakeMonitor()
    let service: NativeDeviceService
    init(timeout: TimeInterval?) {
        let clock = clock, events = events, snapshots = snapshots, transport = transport, wakeMonitor = wakeMonitor
        let configuration = HostKeymap(controls: (0..<6).map {
            ControlActionMap(index: $0, press: [KeyEntry(code: 0x28)])
        })
        service = NativeDeviceService(demo: false, transportFactory: { transport },
                                      loadHostKeymap: { configuration }, saveHostKeymap: { _ in },
                                      bridgeFactory: {
            VendorKeyBridge(permissions: { (true, true) }, now: { clock.now },
                            emit: { _, pressed, _ in events.append(pressed) })
        }, batteryClock: { clock.now }, heartbeatIdleTimeout: timeout, idleClock: { clock.now }, wakeMonitorFactory: { wakeMonitor },
                                      onChange: { snapshots.append($0) })
    }
}

final class HeartbeatIdleTests: XCTestCase {
    private func start(timeout: TimeInterval? = 10) throws -> IdleTestHarness {
        let harness = IdleTestHarness(timeout: timeout)
        harness.service.start()
        _ = try XCTUnwrap(harness.snapshots.wait { $0.online == true && $0.heartbeatEnabled && $0.fn.active })
        return harness
    }

    private func stop(_ harness: IdleTestHarness) {
        let completion = expectation(description: "停止空闲保活测试服务")
        harness.service.stop { completion.fulfill() }
        wait(for: [completion], timeout: 2)
    }

    private func perform(_ harness: IdleTestHarness, _ operation: @escaping () -> Void) {
        let completion = expectation(description: "工作线程处理测试操作")
        harness.transport.enqueue { operation(); completion.fulfill() }
        wait(for: [completion], timeout: 2)
    }

    private func advance(_ harness: IdleTestHarness, to time: TimeInterval) {
        perform(harness) {
            harness.clock.set(time)
            harness.transport.onPump?()
        }
    }

    private func event(_ harness: IdleTestHarness, index: Int = 0, pressed: Bool, at time: TimeInterval) {
        perform(harness) {
            harness.clock.set(time)
            harness.transport.onKeyEvent?(.init(index: index, pressed: pressed))
        }
    }

    private func pause(_ harness: IdleTestHarness, at time: TimeInterval = 1_010) throws {
        let mark = harness.snapshots.count
        advance(harness, to: time)
        _ = try XCTUnwrap(harness.snapshots.wait(after: mark) {
            $0.heartbeatPausedForInactivity && !$0.heartbeatEnabled && !$0.fn.active
        })
    }

    func testIdleHandoffSendsOfflineOnceAndDoesNotWriteFromInputCallbacks() throws {
        let harness = try start()
        defer { stop(harness) }
        XCTAssertEqual(harness.transport.traffic.filter { $0 == "online" }.count, 1)
        perform(harness) {
            let before = harness.transport.traffic.count
            harness.clock.set(1_010)
            harness.transport.onPump?()
            XCTAssertFalse(harness.transport.heartbeatEnabled)
            XCTAssertEqual(harness.transport.traffic.count, before)
        }
        _ = try XCTUnwrap(harness.snapshots.wait { $0.heartbeatPausedForInactivity })
        perform(harness) {}
        let traffic = harness.transport.traffic
        XCTAssertEqual(traffic.filter { $0 == "offline" }.count, 1)
        advance(harness, to: 1_100)
        perform(harness) {}
        XCTAssertEqual(harness.transport.traffic, traffic)
    }

    func testNativeReleaseReentersOnlineModeBeforeFirstResumedHeartbeat() throws {
        let harness = try start()
        defer { stop(harness) }
        try pause(harness)
        perform(harness) {}
        let pausedTraffic = harness.transport.traffic
        perform(harness) { harness.wakeMonitor.onActivity?(true) }
        advance(harness, to: 1_020)
        XCTAssertEqual(harness.transport.traffic, pausedTraffic)
        perform(harness) {
            let before = harness.transport.traffic.count
            harness.wakeMonitor.onActivity?(false)
            XCTAssertEqual(harness.transport.traffic.count, before)
        }
        let mark = harness.snapshots.count
        advance(harness, to: 1_020.2)
        _ = try XCTUnwrap(harness.snapshots.wait(after: mark) { $0.heartbeatEnabled && $0.lastHeartbeat != nil })
        let resumedTraffic = Array(harness.transport.traffic.dropFirst(pausedTraffic.count))
        XCTAssertEqual(resumedTraffic.first, "online")
        XCTAssertTrue(resumedTraffic.contains("heartbeat"))
        XCTAssertEqual(resumedTraffic.filter { $0 == "online" }.count, 1)
        XCTAssertTrue(harness.events.presses.isEmpty)
    }

    func testDisconnectAndSystemSleepReleaseOnlineModeBeforeClosingTransport() throws {
        let harness = try start()
        defer { stop(harness) }
        var mark = harness.snapshots.count
        harness.service.disconnect()
        _ = try XCTUnwrap(harness.snapshots.completed(after: mark) { !$0.connected })
        XCTAssertEqual(Array(harness.transport.traffic.suffix(2)), ["offline", "close"])
        mark = harness.snapshots.count
        harness.service.connect()
        _ = try XCTUnwrap(harness.snapshots.completed(after: mark) { $0.heartbeatEnabled })
        mark = harness.snapshots.count
        harness.service.suspendForSystemSleep()
        _ = try XCTUnwrap(harness.snapshots.completed(after: mark) { !$0.connected })
        XCTAssertEqual(Array(harness.transport.traffic.suffix(2)), ["offline", "close"])
    }

    func testStopReleasesOnlineModeBeforeClosingTransport() throws {
        let harness = try start()
        stop(harness)
        XCTAssertEqual(Array(harness.transport.traffic.suffix(2)), ["offline", "close"])
    }

    func testOfflineHandoffFailureSurfacesAndNeverRestartsHeartbeatAutomatically() throws {
        let harness = try start()
        defer { stop(harness) }
        harness.transport.failSoftwareOnline(false)
        let mark = harness.snapshots.count
        try pause(harness)
        _ = try XCTUnwrap(harness.snapshots.wait(after: mark) {
            $0.error?.contains("测试在线模式切换失败") == true && !$0.heartbeatEnabled
        })
        let counts = harness.transport.requestCounts
        advance(harness, to: 1_100)
        perform(harness) {}
        XCTAssertFalse(harness.transport.heartbeatEnabled)
        XCTAssertEqual(harness.transport.requestCounts, counts)
        XCTAssertEqual(harness.transport.traffic.filter { $0 == "offline" }.count, 1)
    }

    func testResumeOnlineFailureKeepsHeartbeatDisabledAndReportsError() throws {
        let harness = try start()
        defer { stop(harness) }
        try pause(harness)
        perform(harness) {}
        harness.transport.failSoftwareOnline(true)
        let count = harness.transport.heartbeatCount
        let mark = harness.snapshots.count
        harness.service.resumeHeartbeat()
        _ = try XCTUnwrap(harness.snapshots.wait(after: mark) {
            $0.error?.contains("测试在线模式切换失败") == true && !$0.heartbeatEnabled
        })
        perform(harness) {}
        XCTAssertFalse(harness.transport.heartbeatEnabled)
        XCTAssertEqual(harness.transport.heartbeatCount, count)
        let attempts = harness.transport.traffic.filter { $0 == "online" }.count
        perform(harness) {}
        XCTAssertEqual(harness.transport.traffic.filter { $0 == "online" }.count, attempts)
        harness.transport.failSoftwareOnline(nil)
        let retryMark = harness.snapshots.count
        harness.service.resumeHeartbeat()
        _ = try XCTUnwrap(harness.snapshots.wait(after: retryMark) {
            $0.error == nil && $0.heartbeatEnabled && $0.lastHeartbeat != nil
        })
        XCTAssertEqual(harness.transport.traffic.filter { $0 == "online" }.count, attempts + 1)
    }

    func testTimerDefaultsToNeverAndRejectsInvalidTimeouts() {
        var timer = HeartbeatIdleTimer()
        XCTAssertFalse(timer.expired(at: 1_000_000))
        for timeout in [nil, 0, -1, TimeInterval.infinity, TimeInterval.nan] as [TimeInterval?] {
            timer.configure(timeout: timeout, at: 10)
            XCTAssertNil(timer.timeout)
            XCTAssertFalse(timer.expired(at: 1_000_000))
        }
    }

    func testTimerExpiresAtDeadlineAndResetsOnPhysicalActivity() {
        var timer = HeartbeatIdleTimer()
        timer.configure(timeout: 10, at: 100)
        XCTAssertFalse(timer.expired(at: 109.99))
        XCTAssertTrue(timer.expired(at: 110))
        timer.receive(.init(index: 4, pressed: true), at: 109)
        XCTAssertFalse(timer.expired(at: 118.99))
        XCTAssertTrue(timer.expired(at: 119))
    }

    func testHeldKeysDelayExpiryUntilFullTimeoutAfterLastRelease() {
        var timer = HeartbeatIdleTimer()
        timer.configure(timeout: 10, at: 100)
        timer.receive(.init(index: 0, pressed: true), at: 101)
        timer.receive(.init(index: 3, pressed: true), at: 102)
        XCTAssertFalse(timer.expired(at: 1_000))
        timer.receive(.init(index: 0, pressed: false), at: 1_000)
        XCTAssertFalse(timer.expired(at: 2_000))
        timer.receive(.init(index: 3, pressed: false), at: 2_000)
        XCTAssertFalse(timer.expired(at: 2_009.99))
        XCTAssertTrue(timer.expired(at: 2_010))
    }

    func testRotaryReleaseAndUnknownReleaseDoNotExtendDeadline() {
        var timer = HeartbeatIdleTimer()
        timer.configure(timeout: 10, at: 100)
        timer.receive(.init(index: 5, pressed: true), at: 101)
        timer.receive(.init(index: 5, pressed: false), at: 109)
        timer.receive(.init(index: 2, pressed: false), at: 110)
        timer.receive(.init(index: 9, pressed: true), at: 110)
        XCTAssertTrue(timer.expired(at: 111))
    }

    func testDefaultServiceKeepsHeartbeatAndForwardingAfterLongIdle() throws {
        let harness = try start(timeout: nil)
        defer { stop(harness) }
        advance(harness, to: 1_000_000)
        XCTAssertTrue(harness.transport.heartbeatEnabled)
        event(harness, pressed: true, at: 1_000_001)
        event(harness, pressed: false, at: 1_000_002)
        XCTAssertEqual(harness.events.presses, [true, false])
    }

    func testVendorWakeWaitsForReleaseAndDoesNotReplayFirstGesture() throws {
        let harness = try start()
        defer { stop(harness) }
        try pause(harness)
        let count = harness.transport.heartbeatCount
        event(harness, pressed: true, at: 1_011)
        advance(harness, to: 1_020)
        XCTAssertFalse(harness.transport.heartbeatEnabled)
        XCTAssertEqual(harness.transport.heartbeatCount, count)
        event(harness, pressed: false, at: 1_021)
        advance(harness, to: 1_021.05)
        XCTAssertFalse(harness.transport.heartbeatEnabled)
        let mark = harness.snapshots.count
        advance(harness, to: 1_021.2)
        _ = try XCTUnwrap(harness.snapshots.wait(after: mark) { $0.heartbeatEnabled && !$0.heartbeatPausedForInactivity })
        XCTAssertTrue(harness.events.presses.isEmpty)
        event(harness, pressed: true, at: 1_022)
        event(harness, pressed: false, at: 1_023)
        XCTAssertEqual(harness.events.presses, [true, false])
    }

    func testRotaryWakeResumesWithoutWaitingForMissingRelease() throws {
        let harness = try start()
        defer { stop(harness) }
        try pause(harness)
        event(harness, index: 4, pressed: true, at: 1_011)
        let mark = harness.snapshots.count
        advance(harness, to: 1_011.2)
        _ = try XCTUnwrap(harness.snapshots.wait(after: mark) { $0.heartbeatEnabled })
        XCTAssertTrue(harness.events.presses.isEmpty)
    }

    func testStandardHIDWakeWaitsForReleaseAndKeepsAllRequestsSilentUntilThen() throws {
        let harness = try start()
        defer { stop(harness) }
        try pause(harness)
        let counts = harness.transport.requestCounts
        perform(harness) {
            XCTAssertTrue(harness.wakeMonitor.opened)
            harness.wakeMonitor.onActivity?(true)
        }
        advance(harness, to: 1_030)
        XCTAssertEqual(harness.transport.requestCounts, counts)
        perform(harness) { harness.wakeMonitor.onActivity?(false) }
        advance(harness, to: 1_030.05)
        XCTAssertFalse(harness.transport.heartbeatEnabled)
        let mark = harness.snapshots.count
        advance(harness, to: 1_030.2)
        _ = try XCTUnwrap(harness.snapshots.wait(after: mark) { $0.heartbeatEnabled && !$0.heartbeatPausedForInactivity })
        perform(harness) { XCTAssertFalse(harness.wakeMonitor.opened) }
        XCTAssertTrue(harness.events.presses.isEmpty)
        event(harness, pressed: true, at: 1_031)
        event(harness, pressed: false, at: 1_032)
        XCTAssertEqual(harness.events.presses, [true, false])
    }

    func testBothWakeInterfacesMustReleaseBeforeResuming() throws {
        let harness = try start()
        defer { stop(harness) }
        try pause(harness)
        event(harness, pressed: true, at: 1_011)
        perform(harness) { harness.wakeMonitor.onActivity?(true) }
        event(harness, pressed: false, at: 1_012)
        advance(harness, to: 1_020)
        XCTAssertFalse(harness.transport.heartbeatEnabled)
        perform(harness) { harness.wakeMonitor.onActivity?(false) }
        let mark = harness.snapshots.count
        advance(harness, to: 1_020.2)
        _ = try XCTUnwrap(harness.snapshots.wait(after: mark) { $0.heartbeatEnabled })
        XCTAssertTrue(harness.events.presses.isEmpty)
    }

    func testWakeMonitorFailureDoesNotTreatLostReleaseAsPermissionToResume() throws {
        let harness = try start()
        defer { stop(harness) }
        try pause(harness)
        perform(harness) { harness.wakeMonitor.onActivity?(true) }
        let mark = harness.snapshots.count
        perform(harness) { harness.wakeMonitor.error = "测试监听中断" }
        _ = try XCTUnwrap(harness.snapshots.wait(after: mark) {
            $0.error?.contains("测试监听中断") == true && $0.heartbeatPausedForInactivity
        })
        advance(harness, to: 1_050)
        perform(harness) {}
        XCTAssertFalse(harness.transport.heartbeatEnabled)
        XCTAssertTrue(harness.events.presses.isEmpty)
    }

    func testVendorWakeStillTracksHeldControlsWhenOnlineStateIsUnknown() throws {
        let harness = try start()
        defer { stop(harness) }
        try pause(harness)
        harness.transport.setOnline(nil)
        var mark = harness.snapshots.count
        harness.service.connect()
        _ = try XCTUnwrap(harness.snapshots.completed(after: mark) { $0.online == nil })
        event(harness, pressed: true, at: 1_011)
        let counts = harness.transport.requestCounts
        advance(harness, to: 1_030)
        XCTAssertEqual(harness.transport.requestCounts, counts)
        harness.transport.setOnline(true)
        event(harness, pressed: false, at: 1_031)
        mark = harness.snapshots.count
        advance(harness, to: 1_031.2)
        _ = try XCTUnwrap(harness.snapshots.wait(after: mark) { $0.heartbeatEnabled })
        XCTAssertTrue(harness.events.presses.isEmpty)
    }

    func testIdlePauseStopsAllBackgroundRequestsButKeepsPumpingAndResumeRestartsPolling() throws {
        let harness = try start()
        defer { stop(harness) }
        try pause(harness)
        let counts = harness.transport.requestCounts
        let pumps = harness.transport.pumpCount
        XCTAssertGreaterThan(counts[1], 0)
        XCTAssertGreaterThan(counts[2], 0)
        XCTAssertEqual(counts[3], 6)
        // 电量查询已经到期；同时跨过真实的两秒在线轮询周期。
        advance(harness, to: 1_100)
        let pollingWindow = expectation(description: "跨过后台在线查询周期")
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.3) { pollingWindow.fulfill() }
        wait(for: [pollingWindow], timeout: 3)
        var mark = harness.snapshots.count
        harness.service.checkFnPermissions()
        _ = try XCTUnwrap(harness.snapshots.completed(after: mark) { $0.heartbeatPausedForInactivity })
        XCTAssertEqual(harness.transport.requestCounts, counts)
        XCTAssertGreaterThan(harness.transport.pumpCount, pumps)

        mark = harness.snapshots.count
        harness.service.resumeHeartbeat()
        _ = try XCTUnwrap(harness.snapshots.wait(after: mark) {
            !$0.heartbeatPausedForInactivity && $0.heartbeatEnabled && $0.lastHeartbeat != nil
                && $0.batteryUpdatedAt != nil
        })
        // 在下次泵送前，上一次 tick 的查询和电量读取已经完成。
        perform(harness) {}
        let resumed = harness.transport.requestCounts
        XCTAssertGreaterThan(resumed[0], counts[0])
        XCTAssertGreaterThan(resumed[1], counts[1])
        XCTAssertGreaterThan(resumed[2], counts[2])
        XCTAssertEqual(resumed[3], counts[3])
    }

    func testExplicitRefreshWhilePausedReadsKeysWithoutRestartingBackgroundTraffic() throws {
        let harness = try start()
        defer { stop(harness) }
        try pause(harness)
        let counts = harness.transport.requestCounts
        advance(harness, to: 1_100)
        let mark = harness.snapshots.count
        harness.service.refresh()
        _ = try XCTUnwrap(harness.snapshots.completed(after: mark) { $0.heartbeatPausedForInactivity })
        perform(harness) {}
        XCTAssertEqual(harness.transport.requestCounts, [counts[0], counts[1], counts[2], counts[3] + 6])
    }

    func testServiceKeepsHeldActionAcrossIdleDeadlineAndCountsFromRelease() throws {
        let harness = try start()
        defer { stop(harness) }
        event(harness, pressed: true, at: 1_009)
        advance(harness, to: 2_000)
        XCTAssertTrue(harness.transport.heartbeatEnabled)
        XCTAssertEqual(harness.events.presses, [true])
        event(harness, pressed: false, at: 2_000)
        advance(harness, to: 2_009)
        XCTAssertTrue(harness.transport.heartbeatEnabled)
        XCTAssertEqual(harness.events.presses, [true, false])
        try pause(harness, at: 2_010)
    }

    func testPollingAndRefreshDoNotClearPausedLatch() throws {
        let harness = try start()
        defer { stop(harness) }
        try pause(harness)
        var mark = harness.snapshots.count
        harness.service.connect()
        _ = try XCTUnwrap(harness.snapshots.completed(after: mark) { !$0.busy && $0.online == true })
        XCTAssertFalse(harness.transport.heartbeatEnabled)
        mark = harness.snapshots.count
        harness.service.refresh()
        let refreshed = try XCTUnwrap(harness.snapshots.completed(after: mark) { !$0.busy && $0.online == true })
        XCTAssertTrue(refreshed.heartbeatPausedForInactivity)
        XCTAssertFalse(refreshed.heartbeatEnabled)
    }

    func testExplicitResumeStartsNewIdlePeriodWithoutReplayingPausedEvents() throws {
        let harness = try start()
        defer { stop(harness) }
        try pause(harness)
        event(harness, pressed: true, at: 1_020)
        event(harness, pressed: false, at: 1_021)
        let mark = harness.snapshots.count
        harness.service.resumeHeartbeat()
        _ = try XCTUnwrap(harness.snapshots.completed(after: mark) { !$0.busy && $0.heartbeatEnabled && !$0.heartbeatPausedForInactivity })
        XCTAssertTrue(harness.events.presses.isEmpty)
        advance(harness, to: 1_030)
        XCTAssertTrue(harness.transport.heartbeatEnabled)
        try pause(harness, at: 1_031)
    }

    func testManualResumeWaitsForPausedPhysicalHoldToReleaseWithoutReplayingIt() throws {
        let harness = try start()
        defer { stop(harness) }
        try pause(harness)
        event(harness, pressed: true, at: 1_020)
        var mark = harness.snapshots.count
        harness.service.resumeHeartbeat()
        let waiting = try XCTUnwrap(harness.snapshots.completed(after: mark) { !$0.busy })
        XCTAssertTrue(waiting.heartbeatPausedForInactivity)
        XCTAssertFalse(waiting.heartbeatEnabled)
        XCTAssertTrue(harness.events.presses.isEmpty)
        mark = harness.snapshots.count
        event(harness, pressed: false, at: 1_030)
        _ = try XCTUnwrap(harness.snapshots.wait(after: mark) {
            $0.heartbeatEnabled && !$0.heartbeatPausedForInactivity
        })
        XCTAssertTrue(harness.events.presses.isEmpty)
        event(harness, pressed: true, at: 1_031)
        event(harness, pressed: false, at: 1_032)
        XCTAssertEqual(harness.events.presses, [true, false])
    }

    func testChangingTimeoutToNeverResumesAndDisablesExpiry() throws {
        let harness = try start()
        defer { stop(harness) }
        try pause(harness)
        let mark = harness.snapshots.count
        harness.service.setHeartbeatIdleTimeout(nil)
        _ = try XCTUnwrap(harness.snapshots.completed(after: mark) { !$0.busy && $0.heartbeatEnabled && !$0.heartbeatPausedForInactivity })
        advance(harness, to: 1_000_000)
        XCTAssertTrue(harness.transport.heartbeatEnabled)
    }

    func testUnknownOnlineRecoveryPreservesLatchButConfirmedOfflineRecoveryResumes() throws {
        let harness = try start()
        defer { stop(harness) }
        try pause(harness)
        harness.transport.setOnline(nil)
        var mark = harness.snapshots.count
        harness.service.connect()
        _ = try XCTUnwrap(harness.snapshots.completed(after: mark) { !$0.busy && $0.connected && $0.online == nil })
        harness.transport.setOnline(true)
        mark = harness.snapshots.count
        harness.service.connect()
        let recovered = try XCTUnwrap(harness.snapshots.completed(after: mark) { !$0.busy && $0.online == true })
        XCTAssertTrue(recovered.heartbeatPausedForInactivity)
        XCTAssertFalse(recovered.heartbeatEnabled)
        harness.transport.setOnline(false)
        mark = harness.snapshots.count
        harness.service.connect()
        _ = try XCTUnwrap(harness.snapshots.completed(after: mark) { !$0.busy && $0.online == false })
        // 已确认的离线不能被中间一次查询失败抹掉。
        harness.transport.setOnline(nil)
        mark = harness.snapshots.count
        harness.service.connect()
        _ = try XCTUnwrap(harness.snapshots.completed(after: mark) { !$0.busy && $0.online == nil })
        harness.transport.setOnline(true)
        mark = harness.snapshots.count
        harness.service.connect()
        _ = try XCTUnwrap(harness.snapshots.completed(after: mark) { !$0.busy && $0.online == true && $0.heartbeatEnabled && !$0.heartbeatPausedForInactivity })
    }

    func testReleaseDuringUnknownOnlineStateDoesNotLeaveIdleTimerHeld() throws {
        let harness = try start()
        defer { stop(harness) }
        event(harness, pressed: true, at: 1_001)
        harness.transport.setOnline(nil)
        var mark = harness.snapshots.count
        harness.service.connect()
        _ = try XCTUnwrap(harness.snapshots.completed(after: mark) {
            !$0.busy && $0.connected && $0.online == nil && !$0.fn.active
        })
        // 查询失败已释放主机动作；此时物理松开仍必须清除空闲计时器的按住状态。
        XCTAssertEqual(harness.events.presses, [true, false])
        event(harness, pressed: false, at: 1_003)
        harness.transport.setOnline(true)
        mark = harness.snapshots.count
        harness.service.connect()
        _ = try XCTUnwrap(harness.snapshots.completed(after: mark) {
            !$0.busy && $0.online == true && $0.heartbeatEnabled && $0.fn.active
        })
        XCTAssertEqual(harness.events.presses, [true, false])
        advance(harness, to: 1_012)
        XCTAssertTrue(harness.transport.heartbeatEnabled)
        try pause(harness, at: 1_013)
    }

    func testDisconnectReconnectAndSystemWakeStartNewIdlePeriods() throws {
        let harness = try start()
        defer { stop(harness) }
        try pause(harness)
        var mark = harness.snapshots.count
        harness.service.disconnect()
        _ = try XCTUnwrap(harness.snapshots.completed(after: mark) { !$0.busy && !$0.connected })
        mark = harness.snapshots.count
        harness.service.connect()
        _ = try XCTUnwrap(harness.snapshots.completed(after: mark) { !$0.busy && $0.heartbeatEnabled && !$0.heartbeatPausedForInactivity })
        try pause(harness, at: 1_020)
        mark = harness.snapshots.count
        harness.service.suspendForSystemSleep()
        _ = try XCTUnwrap(harness.snapshots.completed(after: mark) { !$0.busy && !$0.connected })
        mark = harness.snapshots.count
        harness.service.resumeAfterSystemWake()
        _ = try XCTUnwrap(harness.snapshots.wait(after: mark) { $0.connected && $0.heartbeatEnabled && !$0.heartbeatPausedForInactivity })
    }
}
