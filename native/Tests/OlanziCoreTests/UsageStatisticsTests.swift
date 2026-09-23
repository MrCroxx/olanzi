import Foundation
import XCTest
@testable import OlanziCore

final class UsageStatisticsTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private let start = Date(timeIntervalSince1970: 1_700_006_400)

    func testPhysicalPressDeduplicatesButKnobPulsesDoNotRequireRelease() {
        var usage = UsageStatistics(calendar: calendar)
        usage.receive(.init(index: 0, pressed: true), at: start)
        usage.receive(.init(index: 0, pressed: true), at: start.addingTimeInterval(1))
        usage.receive(.init(index: 0, pressed: false), at: start.addingTimeInterval(2))
        usage.receive(.init(index: 0, pressed: true), at: start.addingTimeInterval(3))
        usage.receive(.init(index: 4, pressed: true), at: start.addingTimeInterval(4))
        usage.receive(.init(index: 4, pressed: true), at: start.addingTimeInterval(5))
        usage.receive(.init(index: 9, pressed: true), at: start.addingTimeInterval(6))
        XCTAssertEqual(usage.days[0].keyPresses, 2)
        XCTAssertEqual(usage.days[0].knobTurns, 2)
    }

    func testActiveWindowsMergeAndNeverCountFutureOrIdleTime() {
        var usage = UsageStatistics(calendar: calendar)
        usage.receive(.init(index: 4, pressed: true), at: start)
        XCTAssertEqual(usage.days[0].activeSeconds, 0)
        usage.receive(.init(index: 4, pressed: true), at: start.addingTimeInterval(20))
        XCTAssertEqual(usage.days[0].activeSeconds, 20)
        usage.advance(to: start.addingTimeInterval(500))
        XCTAssertEqual(usage.days[0].activeSeconds, 50)
        usage.receive(.init(index: 4, pressed: true), at: start.addingTimeInterval(600))
        usage.advance(to: start.addingTimeInterval(610))
        XCTAssertEqual(usage.days[0].activeSeconds, 60)
    }

    func testDisconnectAndRestartDoNotChargeClosedTimeAndClearHeldKeys() {
        var usage = UsageStatistics(calendar: calendar)
        usage.receive(.init(index: 0, pressed: true), at: start)
        usage.suspend(at: start.addingTimeInterval(5))
        usage.advance(to: start.addingTimeInterval(100))
        XCTAssertEqual(usage.days[0].activeSeconds, 5)
        usage.receive(.init(index: 0, pressed: true), at: start.addingTimeInterval(100))
        XCTAssertEqual(usage.days[0].keyPresses, 2)
        var restarted = UsageStatistics(days: usage.days, calendar: calendar)
        restarted.advance(to: start.addingTimeInterval(200))
        XCTAssertEqual(restarted.days[0].activeSeconds, 5)
    }

    func testWindowSplitsAtMidnightAndRetentionIsBounded() {
        let midnight = calendar.startOfDay(for: start)
        var usage = UsageStatistics(calendar: calendar)
        usage.receive(.init(index: 4, pressed: true), at: midnight.addingTimeInterval(-10))
        usage.advance(to: midnight.addingTimeInterval(10))
        XCTAssertEqual(usage.days.map(\.activeSeconds), [10, 10])
        usage.advance(to: calendar.date(byAdding: .day, value: 29, to: midnight)!)
        XCTAssertEqual(usage.days.count, 1)
        XCTAssertEqual(usage.days[0].date, midnight)
        XCTAssertEqual(usage.days[0].activeSeconds, 20)
    }

    func testStoreRoundTripsAndRejectsCorruptionWithoutOverwriting() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsageStatisticsStore(url: directory.appendingPathComponent("usage.json"))
        XCTAssertEqual(try store.load(), [])
        let days = [UsageDay(date: calendar.startOfDay(for: start), keyPresses: 2, knobTurns: 3, activeSeconds: 12)]
        try store.save(days)
        XCTAssertEqual(try store.load(), days)
        let corrupt = Data("bad json".utf8)
        try corrupt.write(to: store.url)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: store.url), corrupt)
    }
}

private final class UsageTestTransport: DeviceTransport {
    var heartbeatEnabled = false
    var lastHeartbeat: Date? { nil }
    var onKeyEvent: ((VendorKeyEvent) -> Void)?
    var onPump: (() -> Void)?
    private var pumps = 0
    func setSoftwareOnline(_ online: Bool) throws {}
    func open() throws {}
    func close() {}
    func pump(for duration: TimeInterval) throws {
        pumps += 1
        if pumps == 3 {
            onKeyEvent?(.init(index: 1, pressed: true))
            onKeyEvent?(.init(index: 1, pressed: false))
        }
        onPump?()
    }
    func queryOnline() throws -> Bool { true }
    func readKey(index: Int) throws -> KeyBinding {
        return KeyBinding(index: index, entries: [KeyEntry(code: 0x28)])
    }
    func writeKey(index: Int, code: UInt8) throws { XCTFail("统计不能写设备") }
}

extension UsageStatisticsTests {
    func testDemoNeverReadsOrWritesSuppliedStore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsageStatisticsStore(url: directory.appendingPathComponent("usage.json"))
        let bytes = Data("invalid".utf8)
        try bytes.write(to: store.url)
        let ready = expectation(description: "演示七天统计")
        ready.assertForOverFulfill = false
        let service = NativeDeviceService(demo: true, transportFactory: { DemoHIDTransport() },
            usageStore: store) { snapshot in
                if snapshot.connected && snapshot.usageDays.count == 7 && snapshot.usageError == nil { ready.fulfill() }
            }
        service.start()
        wait(for: [ready], timeout: 3)
        let stopped = expectation(description: "停止")
        service.stop { stopped.fulfill() }
        wait(for: [stopped], timeout: 3)
        XCTAssertEqual(try Data(contentsOf: store.url), bytes)
    }

    func testSaveFailureIsVisibleAndDoesNotDisableForwarding() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsageStatisticsStore(url: directory.appendingPathComponent("usage.json"))
        let forwarded = expectation(description: "存储失败仍转发")
        forwarded.assertForOverFulfill = false
        let ready = expectation(description: "已统计输入")
        ready.assertForOverFulfill = false
        let failed = expectation(description: "保存失败可见")
        failed.assertForOverFulfill = false
        let service = NativeDeviceService(demo: false, transportFactory: { UsageTestTransport() },
            loadHostKeymap: { .defaultKeymap }, bridgeFactory: {
                VendorKeyBridge(permissions: { (true, true) }, emit: { _, pressed, _ in
                    if pressed { forwarded.fulfill() }
                })
            }, usageStore: store) { snapshot in
                if snapshot.usageDays.reduce(0, { $0 + $1.keyPresses }) == 1 { ready.fulfill() }
                if snapshot.usageError != nil { failed.fulfill() }
            }
        service.start()
        wait(for: [ready, forwarded], timeout: 3)
        let stopped = expectation(description: "停止并落盘")
        service.stop { stopped.fulfill() }
        wait(for: [stopped, failed], timeout: 3)
    }
}
