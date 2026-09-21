import CoreGraphics
import XCTest
@testable import OlanziCore

final class VendorKeyTests: XCTestCase {
    func testInputDispatchDoesNotWaitForQueryRepliesOrOverflowWithReplyTraffic() {
        let transport = MacHIDTransport()
        var events: [VendorKeyEvent] = []
        transport.onKeyEvent = { events.append($0) }
        transport.receiveDecodedFrame([0x8b, 0x10, 0x6f, 1, 0])
        XCTAssertEqual(events, [.init(index: 0, pressed: true)])
        for _ in 0..<140 { transport.receiveDecodedFrame([0x81, 6, 0x50, 0x11, 0]) }
        transport.receiveDecodedFrame([0x8b, 0x10, 0x6f, 0, 0])
        XCTAssertEqual(events.last, .init(index: 0, pressed: false))
        XCTAssertTrue(transport.takeKeyEvents().isEmpty)
    }

    func testRotationReleaseFailureRetriesWhileOnlineBeforeNextTick() {
        var failures = 1
        var downs = 0
        var ups = 0
        let bridge = VendorKeyBridge(permissions: { (true, true) }, emit: { _, down, _ in
            if down { downs += 1 }
            else if failures > 0 { failures -= 1; throw DeviceProtocolError.message("暂时失败") }
            else { ups += 1 }
        })
        bridge.synchronize(bindings: bindings([1, 0x28, 0x29, 0x46, 0x4f, 0x2a]), connected: true, online: true)
        bridge.receive(.init(index: 4, pressed: true))
        XCTAssertNotNil(bridge.status.error)
        bridge.pump()
        XCTAssertNil(bridge.status.error)
        bridge.receive(.init(index: 4, pressed: true))
        XCTAssertEqual(downs, 2)
        XCTAssertEqual(ups, 2)
    }
    private func bindings(_ codes: [UInt8]) -> [KeyBinding] {
        codes.enumerated().map { KeyBinding(index: $0.offset, entries: [KeyEntry(code: $0.element)]) }
    }

    func testVendorEventUsesPhysicalIndexNotLogicalActionOrHIDCode() {
        for index in 0..<6 {
            XCTAssertEqual(VendorKeyEvent.decode([0x8b, 0x10, 0x70, 1, UInt8(index)]),
                           VendorKeyEvent(index: index, pressed: true))
            XCTAssertEqual(VendorKeyEvent.decode([0x8b, 0x10, 0x70, 0, UInt8(index)]),
                           VendorKeyEvent(index: index, pressed: false))
        }
        for frame: [UInt8] in [[0x8b, 0x10, 0x70, 1], [0x81, 0x10, 0x70, 1, 0],
                               [0x8b, 0x11, 0x70, 1, 0], [0x8b, 0x10, 0x70, 2, 0],
                               [0x8b, 0x10, 0x70, 1, 6]] {
            XCTAssertNil(VendorKeyEvent.decode(frame))
        }
    }

    func testOrdinaryKeyWorksWithoutAnyFnMappingAndDuplicateReportsAreIgnored() {
        var posts: [(UInt8, Bool)] = []
        let bridge = VendorKeyBridge(permissions: { (true, true) }, emit: { entries, down, _ in
            posts += entries.map { ($0.code, down) }
        })
        bridge.synchronize(bindings: bindings([0x28]), connected: true, online: true)
        XCTAssertTrue(bridge.status.active)
        bridge.receive(.init(index: 0, pressed: true))
        bridge.receive(.init(index: 0, pressed: true))
        bridge.receive(.init(index: 0, pressed: false))
        bridge.receive(.init(index: 0, pressed: false))
        XCTAssertEqual(posts.map(\.0), [0x28, 0x28])
        XCTAssertEqual(posts.map(\.1), [true, false])
    }

    func testConfigurationSwitchReleasesOldMappingsAndQuarantinesUntilPhysicalUp() {
        var posts: [([UInt8], Bool, CGEventFlags)] = []
        let bridge = VendorKeyBridge(permissions: { (true, true) }, emit: {
            posts.append(($0.map(\.code), $1, $2))
        })
        bridge.synchronize(bindings: bindings([1, 0x28]), connected: true, online: true)
        bridge.receive(.init(index: 0, pressed: true))
        bridge.receive(.init(index: 1, pressed: true))
        XCTAssertTrue(posts.last!.2.contains(.maskSecondaryFn))
        bridge.synchronize(bindings: bindings([1, 0x29]), connected: true, online: true)
        XCTAssertEqual(posts.suffix(2).map { $0.0 }, [[0x28], [1]])
        XCTAssertTrue(posts[2].2.contains(.maskSecondaryFn))
        XCTAssertFalse(posts[3].2.contains(.maskSecondaryFn))
        XCTAssertFalse(bridge.status.pressed)
        let count = posts.count
        bridge.receive(.init(index: 1, pressed: true))
        bridge.receive(.init(index: 0, pressed: true))
        XCTAssertEqual(posts.count, count)
        bridge.receive(.init(index: 1, pressed: false))
        bridge.receive(.init(index: 0, pressed: false))
        bridge.receive(.init(index: 1, pressed: true))
        XCTAssertEqual(posts.last!.0, [0x29])
    }

    func testSameCodeAcrossControlsOnlyReleasesAfterLastControl() {
        var posts: [(UInt8, Bool)] = []
        let bridge = VendorKeyBridge(permissions: { (true, true) }, emit: { entries, down, _ in
            posts += entries.map { ($0.code, down) }
        })
        bridge.synchronize(bindings: bindings([1, 1]), connected: true, online: true)
        bridge.receive(.init(index: 0, pressed: true))
        bridge.receive(.init(index: 1, pressed: true))
        bridge.receive(.init(index: 0, pressed: false))
        XCTAssertTrue(bridge.status.pressed)
        XCTAssertEqual(posts.count, 1)
        bridge.receive(.init(index: 1, pressed: false))
        XCTAssertEqual(posts.map(\.1), [true, false])
        XCTAssertFalse(bridge.status.pressed)
    }

    func testOfflineAndPermissionRevocationReleaseAllKeys() {
        var granted = true
        var now = 0.0
        var posts: [(UInt8, Bool)] = []
        let bridge = VendorKeyBridge(permissions: { (true, granted) }, now: { now }, emit: { entries, down, _ in
            posts += entries.map { ($0.code, down) }
        })
        bridge.synchronize(bindings: bindings([1, 0x28]), connected: true, online: true)
        bridge.receive(.init(index: 0, pressed: true))
        bridge.receive(.init(index: 1, pressed: true))
        granted = false
        now = 3
        bridge.pump()
        XCTAssertFalse(bridge.status.active)
        XCTAssertFalse(bridge.status.pressed)
        XCTAssertEqual(posts.filter { !$0.1 }.map(\.0).sorted(), [1, 0x28])
        XCTAssertTrue(bridge.status.error?.contains("辅助功能") == true)
        granted = true
        bridge.refreshPermissions()
        bridge.receive(.init(index: 0, pressed: true))
        bridge.synchronize(bindings: bindings([1, 0x28]), connected: true, online: nil)
        XCTAssertFalse(bridge.status.pressed)
        XCTAssertFalse(posts.last!.1)
    }

    func testFailedReleaseIsRetriedDuringClose() {
        var failed = false
        var releases = 0
        let bridge = VendorKeyBridge(permissions: { (true, true) }, emit: { _, down, _ in
            if !down {
                releases += 1
                if !failed { failed = true; throw DeviceProtocolError.message("暂时不能释放") }
            }
        })
        bridge.synchronize(bindings: bindings([1]), connected: true, online: true)
        bridge.receive(.init(index: 0, pressed: true))
        bridge.receive(.init(index: 0, pressed: false))
        XCTAssertTrue(bridge.status.pressed)
        XCTAssertNotNil(bridge.status.error)
        bridge.close()
        XCTAssertEqual(releases, 2)
        XCTAssertFalse(bridge.status.pressed)
    }

    func testKnobTicksWithoutReleaseEmitIndependentPulses() {
        var posts: [(UInt8, Bool)] = []
        let bridge = VendorKeyBridge(permissions: { (true, true) }, emit: { entries, down, _ in
            posts += entries.map { ($0.code, down) }
        })
        bridge.synchronize(bindings: bindings([1, 0x28, 0x29, 0x46, 0x4f, 0x2a]), connected: true, online: true)
        bridge.receive(.init(index: 4, pressed: true))
        bridge.receive(.init(index: 4, pressed: true))
        bridge.receive(.init(index: 5, pressed: true))
        XCTAssertEqual(posts.map(\.0), [0x4f, 0x4f, 0x4f, 0x4f, 0x2a, 0x2a])
        XCTAssertEqual(posts.map(\.1), [true, false, true, false, true, false])
        bridge.close()
        XCTAssertEqual(posts.count, 6)
    }

    func testMacAliasesShareHoldAndUnsupportedMappingStaysVisible() {
        var posts: [(UInt8, Bool)] = []
        let bridge = VendorKeyBridge(permissions: { (true, true) }, emit: { entries, down, _ in
            posts += entries.map { ($0.code, down) }
        })
        bridge.synchronize(bindings: bindings([0x46, 0x68, 0x70]), connected: true, online: true)
        bridge.receive(.init(index: 0, pressed: true))
        bridge.receive(.init(index: 1, pressed: true))
        bridge.receive(.init(index: 0, pressed: false))
        XCTAssertEqual(posts.count, 1)
        bridge.receive(.init(index: 1, pressed: false))
        XCTAssertEqual(posts.map(\.1), [true, false])
        bridge.receive(.init(index: 2, pressed: true))
        bridge.receive(.init(index: 2, pressed: false))
        XCTAssertNotNil(bridge.status.error)
        XCTAssertEqual(posts.count, 2)
    }
}
