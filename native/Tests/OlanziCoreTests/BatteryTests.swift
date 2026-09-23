import XCTest
@testable import OlanziCore

private final class BatteryServiceFixture: DeviceTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 0
    private var reads = 0
    private var posts = 0
    private var failure = false
    private var enabled = false
    var onPump: (() -> Void)?
    var onKeyEvent: ((VendorKeyEvent) -> Void)?
    var heartbeatEnabled: Bool {
        get { lock.withLock { enabled } }
        set { lock.withLock { enabled = newValue } }
    }
    var lastHeartbeat: Date? { nil }
    var clock: TimeInterval { lock.withLock { time } }
    var counts: (Int, Int) { lock.withLock { (reads, posts) } }
    func advance(to time: TimeInterval, failure: Bool) { lock.withLock { self.time = time; self.failure = failure } }
    func recordPost() { lock.withLock { posts += 1 } }
    func setSoftwareOnline(_ online: Bool) throws {}
    func open() throws {}
    func close() { heartbeatEnabled = false }
    func pump(for duration: TimeInterval) throws { onPump?() }
    func queryOnline() throws -> Bool { true }
    func readKey(index: Int) throws -> KeyBinding {
        KeyBinding(index: index, entries: [KeyEntry(code: DeviceProtocol.defaultCodes[index])])
    }
    func writeKey(index: Int, code: UInt8) throws { XCTFail("电量测试不得写设备") }
    func readBattery() throws -> DeviceBattery {
        let fail = lock.withLock { reads += 1; return failure }
        onPump?()
        if fail {
            // 查询等待仍接收厂商 Fn 上下沿，不把遥测失败当作设备离线。
            onKeyEvent?(VendorKeyEvent(index: 0, pressed: true))
            onPump?()
            onKeyEvent?(VendorKeyEvent(index: 0, pressed: false))
            throw DeviceProtocolError.message("电量超时测试")
        }
        return DeviceBattery(millivolts: 3318, percentage: 10, isCharging: true)
    }
}

private final class BatterySnapshots: @unchecked Sendable {
    private let condition = NSCondition()
    private var values: [DeviceSnapshot] = []
    func append(_ value: DeviceSnapshot) {
        condition.lock(); values.append(value); condition.broadcast(); condition.unlock()
    }
    func wait(_ predicate: (DeviceSnapshot) -> Bool) -> DeviceSnapshot? {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: 2)
        while true {
            if let value = values.last, predicate(value) { return value }
            guard condition.wait(until: deadline) else { return nil }
        }
    }
}

final class BatteryTests: XCTestCase {
    func testTelemetryFailureKeepsInputActiveAndUsesTwentySecondCadence() throws {
        let transport = BatteryServiceFixture()
        let snapshots = BatterySnapshots()
        let service = NativeDeviceService(demo: false, transportFactory: { transport },
            loadHostKeymap: { .defaultKeymap }, saveHostKeymap: { _ in XCTFail("电量读取不得保存配置") },
            bridgeFactory: {
                VendorKeyBridge(permissions: { (true, true) }, emit: { _, _, _ in transport.recordPost() })
            }, batteryClock: { transport.clock }, onChange: { snapshots.append($0) })
        service.start()
        defer {
            let stopped = expectation(description: "电量服务结束")
            service.stop { stopped.fulfill() }
            wait(for: [stopped], timeout: 2)
        }
        let initial = try XCTUnwrap(snapshots.wait { $0.battery != nil && $0.fn.active })
        XCTAssertNotNil(initial.batteryUpdatedAt)
        transport.advance(to: 19, failure: false)
        service.refresh()
        _ = try XCTUnwrap(snapshots.wait { !$0.busy && $0.lastRead != initial.lastRead })
        XCTAssertEqual(transport.counts.0, 1)
        transport.advance(to: 20, failure: true)
        service.refresh()
        let failed = try XCTUnwrap(snapshots.wait { $0.batteryError != nil && !$0.busy })
        XCTAssertNil(failed.battery)
        XCTAssertNil(failed.batteryUpdatedAt)
        XCTAssertNil(failed.error)
        XCTAssertEqual(failed.online, true)
        XCTAssertTrue(failed.fn.active)
        XCTAssertTrue(failed.heartbeatEnabled)
        XCTAssertEqual(transport.counts.0, 2)
        XCTAssertEqual(transport.counts.1, 2)
        transport.advance(to: 39, failure: false)
        service.refresh()
        _ = try XCTUnwrap(snapshots.wait { !$0.busy && $0.lastRead != failed.lastRead })
        XCTAssertEqual(transport.counts.0, 2)
        transport.advance(to: 40, failure: false)
        service.refresh()
        _ = try XCTUnwrap(snapshots.wait { $0.battery != nil && $0.batteryError == nil && !$0.busy })
        XCTAssertEqual(transport.counts.0, 3)
        service.disconnect()
        let disconnected = try XCTUnwrap(snapshots.wait { !$0.connected })
        XCTAssertNil(disconnected.battery)
        XCTAssertNil(disconnected.batteryUpdatedAt)
    }

    func testConfirmedReadCommandAndCapturedChargingReply() throws {
        XCTAssertEqual(DeviceProtocol.batteryRequest, [1, 1, 2, 1])
        let frame: [UInt8] = [0x81, 1, 2, 0x11, 0xF6, 0x0C, 0x0A, 0, 0xC8, 1, 1, 0]
        XCTAssertEqual(try DeviceProtocol.parseBattery(frame),
                       DeviceBattery(millivolts: 3318, percentage: 10, isCharging: true))
        let report = try DeviceProtocol.encodeReport(frame)
        let decoded = try XCTUnwrap(DeviceProtocol.decodeReport(reportID: 0x55, bytes: report))
        XCTAssertEqual(try DeviceProtocol.parseBattery(decoded).percentage, 10)
    }

    func testHistoricalPayloadAndMissingChargingRemainSeparate() throws {
        let frame: [UInt8] = [0x81, 1, 2, 0x11, 0xDD, 0x0D, 0x1E, 0, 0xF1, 1]
        let battery = try DeviceProtocol.parseBattery(frame)
        XCTAssertEqual(battery.millivolts, 3549)
        XCTAssertEqual(battery.percentage, 30)
        XCTAssertNil(battery.isCharging)
    }

    func testBatteryBoundsDoNotClampUnknownValuesOrReadOnlyLowByte() throws {
        for level in [0, 100, 101, 256, 0xFFFF] {
            let frame: [UInt8] = [0x81, 1, 2, 0x11, 0xDD, 0x0D,
                                  UInt8(truncatingIfNeeded: level), UInt8(level >> 8), 0, 0, 2]
            let battery = try DeviceProtocol.parseBattery(frame)
            XCTAssertEqual(battery.percentage, level <= 100 ? level : nil)
            XCTAssertNil(battery.isCharging)
        }
        XCTAssertFalse(try XCTUnwrap(DeviceProtocol.parseBattery([0x81, 1, 2, 0x11, 1, 14, 50, 0, 0, 0, 0]).isCharging))
    }

    func testBatteryRejectsWrongReplyTruncationAndInvalidVoltage() {
        let valid: [UInt8] = [0x81, 1, 2, 0x11, 0xDD, 0x0D, 30, 0]
        for length in 0..<8 {
            XCTAssertThrowsError(try DeviceProtocol.parseBattery(Array(valid.prefix(length))))
        }
        for index in 0..<4 {
            var frame = valid
            frame[index] = 0
            XCTAssertFalse(DeviceProtocol.matchesBatteryReply(frame))
            XCTAssertThrowsError(try DeviceProtocol.parseBattery(frame))
        }
        XCTAssertThrowsError(try DeviceProtocol.parseBattery([0x81, 1, 2, 0x11, 255, 255, 30, 0]))
    }

    func testDemoBatteryRequiresOpenAndUsesOnlyMemory() throws {
        let transport = DemoHIDTransport()
        XCTAssertThrowsError(try transport.readBattery())
        try transport.open()
        XCTAssertEqual(try transport.readBattery(), DeviceBattery(millivolts: 3900, percentage: 80, isCharging: false))
        transport.close()
        XCTAssertThrowsError(try transport.readBattery())
    }
}
