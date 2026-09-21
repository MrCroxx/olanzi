import CoreGraphics
import XCTest
@testable import OlanziCore

final class VendorKeyTests: XCTestCase {
    func testRapidVendorClicksWithoutDoubleActionEmitEverySingle() {
        for hasLongAction in [false, true] {
            for index in 0..<4 {
                var time = 0.0
                var outputs: [Bool] = []
                var configuration = HostKeymap.defaultKeymap
                let single = configuration.controls[index].press
                if hasLongAction { configuration.controls[index].longPress = [KeyEntry(code: 0x04)] }
                let bridge = VendorKeyBridge(permissions: { (true, true) }, now: { time },
                                             emit: { entries, down, _ in
                    XCTAssertEqual(entries, single)
                    outputs.append(down)
                })
                bridge.synchronize(configuration: configuration, connected: true, online: true)
                let transport = MacHIDTransport()
                transport.onKeyEvent = { bridge.receive($0) }
                // 从解码后的设备帧经过手势识别及按键发布，验证不会被合并或去重。
                for click in 0..<5 {
                    time = Double(click) * 0.08
                    transport.receiveDecodedFrame([0x8b, 0x10, 0, 1, UInt8(index)])
                    XCTAssertEqual(outputs.count, click * 2 + (hasLongAction ? 0 : 1))
                    time += 0.03
                    transport.receiveDecodedFrame([0x8b, 0x10, 0, 0, UInt8(index)])
                    XCTAssertEqual(outputs.count, (click + 1) * 2)
                }
                time = 2
                bridge.pump()
                XCTAssertEqual(outputs, Array(repeating: [true, false], count: 5).flatMap { $0 })
                XCTAssertNil(bridge.status.error)
            }
        }
    }

    func testFnMonitorIsPreparedBeforeInputAndFailureStopsBridgeUntilRecovery() {
        var monitorReady = false
        var time: TimeInterval = 0
        var preparations = 0
        var outputs: [Bool] = []
        let bridge = VendorKeyBridge(permissions: { (true, true) }, prepare: {
            preparations += 1
            if !monitorReady { throw DeviceProtocolError.message("Fn 监听不可用") }
        }, now: { time }, emit: { _, down, _ in
            XCTAssertTrue(monitorReady)
            XCTAssertGreaterThan(preparations, 0)
            outputs.append(down)
        })
        bridge.synchronize(configuration: .defaultKeymap, connected: true, online: true)
        XCTAssertFalse(bridge.status.active)
        XCTAssertTrue(bridge.status.error?.contains("Fn 监听不可用") == true)
        bridge.receive(.init(index: 0, pressed: true))
        bridge.receive(.init(index: 0, pressed: false))
        XCTAssertTrue(outputs.isEmpty)
        monitorReady = true
        bridge.pump()
        XCTAssertTrue(bridge.status.active)
        XCTAssertNil(bridge.status.error)
        bridge.receive(.init(index: 0, pressed: true))
        for tick in 1...5 {
            time = Double(tick * 2)
            bridge.synchronize(configuration: .defaultKeymap, connected: true, online: true)
            bridge.pump()
            XCTAssertEqual(outputs, [true])
        }
        bridge.receive(.init(index: 0, pressed: false))
        XCTAssertEqual(outputs, [true, false])
    }

    func testMissingPermissionsRemainVisibleBeforeConfigurationAndWhileDisconnected() {
        var input: Bool? = nil
        var accessibility = false
        let bridge = VendorKeyBridge(permissions: { (input, accessibility) }, emit: { _, _, _ in
            XCTFail("权限和配置就绪前不得注入按键")
        })
        for connected in [false, true] {
            bridge.synchronize(configuration: nil, connected: connected, online: connected)
            XCTAssertFalse(bridge.status.enabled)
            XCTAssertFalse(bridge.status.active)
            XCTAssertTrue(bridge.status.error?.contains("输入监控与辅助功能") == true)
            XCTAssertEqual(bridge.status.missingPermissions, [.inputMonitoring, .accessibility])
        }
        input = true
        bridge.refreshPermissions()
        XCTAssertEqual(bridge.status.missingPermissions, [.accessibility])
        XCTAssertTrue(bridge.status.error?.contains("辅助功能") == true)
        XCTAssertFalse(bridge.status.error?.contains("输入监控") == true)
        accessibility = true
        bridge.refreshPermissions()
        XCTAssertTrue(bridge.status.missingPermissions.isEmpty)
        XCTAssertNil(bridge.status.error)
        XCTAssertFalse(bridge.status.active)
    }

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
    func testTapLongCombinationKeepsAnotherControlsModifierHeldUntilItsOwnRelease() {
        let modifiers: [(UInt8, CGEventFlags)] = [(1, .maskSecondaryFn), (0xE3, .maskCommand)]
        for (modifier, flag) in modifiers {
            var time = 0.0
            var posts: [([UInt8], Bool, CGEventFlags)] = []
            var configuration = HostKeymap.defaultKeymap
            configuration.controls[0].press = [KeyEntry(code: modifier)]
            configuration.controls[1].longPress = [KeyEntry(code: modifier), KeyEntry(code: 0x0C)]
            configuration.controls[1].longPressBehavior = .tap
            let bridge = VendorKeyBridge(permissions: { (true, true) }, now: { time }, emit: {
                posts.append(($0.map(\.code), $1, $2))
            })
            bridge.synchronize(configuration: configuration, connected: true, online: true)
            bridge.receive(.init(index: 0, pressed: true))
            bridge.receive(.init(index: 1, pressed: true))
            time = 0.5
            bridge.pump()
            XCTAssertEqual(posts.map { $0.0 }, [[modifier], [0x0C], [0x0C]])
            XCTAssertEqual(posts.map { $0.1 }, [true, true, false])
            XCTAssertTrue(posts[1].2.contains(flag))
            XCTAssertTrue(posts[2].2.contains(flag))
            time = 10
            bridge.receive(.init(index: 1, pressed: true))
            bridge.receive(.init(index: 1, pressed: false))
            XCTAssertEqual(posts.count, 3)
            bridge.receive(.init(index: 0, pressed: false))
            XCTAssertEqual(posts.last?.0, [modifier])
            XCTAssertEqual(posts.last?.1, false)
            XCTAssertFalse(posts.last!.2.contains(flag))
            XCTAssertNil(bridge.status.error)
            XCTAssertFalse(bridge.status.pressed)
        }
    }

    func testFailedTapCombinationRetriesItsKeyUpWithoutReleasingSharedFnOrRepeatingPulse() {
        var time = 0.0
        var failDown = true
        var releaseFailures = 2
        var attempts: [([UInt8], Bool, CGEventFlags)] = []
        var configuration = HostKeymap.defaultKeymap
        configuration.controls[1].longPress = [KeyEntry(code: 1), KeyEntry(code: 0x0C)]
        configuration.controls[1].longPressBehavior = .tap
        let bridge = VendorKeyBridge(permissions: { (true, true) }, now: { time }, emit: { entries, down, flags in
            attempts.append((entries.map(\.code), down, flags))
            if entries.contains(where: { $0.code == 0x0C }) {
                if down && failDown {
                    failDown = false
                    throw DeviceProtocolError.message("组合键部分发布失败")
                }
                if !down && releaseFailures > 0 {
                    releaseFailures -= 1
                    throw DeviceProtocolError.message("组合键释放暂时失败")
                }
            }
        })
        bridge.synchronize(configuration: configuration, connected: true, online: true)
        bridge.receive(.init(index: 0, pressed: true))
        bridge.receive(.init(index: 1, pressed: true))
        time = 0.5
        bridge.pump()
        // 部分 down 失败后的补 up 与同一 pulse 的 end 都可能失败，下一次 pump 继续释放。
        XCTAssertNotNil(bridge.status.error)
        XCTAssertTrue(bridge.status.pressed)
        bridge.pump()
        XCTAssertNil(bridge.status.error)
        XCTAssertTrue(bridge.status.pressed)
        XCTAssertEqual(attempts.map { $0.0 }, [[1], [0x0C], [0x0C], [0x0C], [0x0C]])
        XCTAssertEqual(attempts.map { $0.1 }, [true, true, false, false, false])
        XCTAssertTrue(attempts.dropFirst().allSatisfy { $0.2.contains(.maskSecondaryFn) })
        time = 2
        bridge.receive(.init(index: 1, pressed: true))
        bridge.receive(.init(index: 1, pressed: false))
        XCTAssertEqual(attempts.count, 5)
        bridge.receive(.init(index: 0, pressed: false))
        XCTAssertEqual(attempts.last?.0, [1])
        XCTAssertEqual(attempts.last?.1, false)
        XCTAssertFalse(attempts.last!.2.contains(.maskSecondaryFn))
        XCTAssertFalse(bridge.status.pressed)
    }

}
