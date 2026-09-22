import CoreGraphics
import XCTest
@testable import OlanziCore

final class LongPressBurstTests: XCTestCase {
    private let action = [KeyEntry(code: 0xE3), KeyEntry(code: 0x28)]
    private func map(count: Int = 2) -> HostKeymap {
        var map = HostKeymap.defaultKeymap
        map.controls[1].longPress = action
        map.controls[1].longPressBehavior = .burst
        map.controls[1].longPressTapCount = count
        return map
    }
    private func down(_ index: Int = 1) -> VendorKeyEvent { .init(index: index, pressed: true) }
    private func up(_ index: Int = 1) -> VendorKeyEvent { .init(index: index, pressed: false) }
    private var begin: GestureTransition { .begin(index: 1, entries: action) }
    private var end: GestureTransition { .end(index: 1) }

    func testLegacyMissingCountDefaultsToTwoAndProfileRoundTripKeepsBurstCount() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(map(count: 7))) as? [String: Any])
        var controls = try XCTUnwrap(object["controls"] as? [[String: Any]])
        for index in controls.indices { controls[index].removeValue(forKey: "longPressTapCount") }
        object["controls"] = controls
        let old = try HostKeymap.decode(data: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(old.controls.allSatisfy { $0.longPressTapCount == 2 })
        let profile = HostProfile(name: "连按七次", keymap: map(count: 7))
        XCTAssertEqual(try HostProfile.decode(data: JSONEncoder().encode(profile)), profile)
        XCTAssertEqual(try HostKeymap.decode(data: JSONEncoder().encode(profile.keymap)), profile.keymap)
    }

    func testCountValidationAppliesToEveryModeAndRotationStillRejectsBurst() throws {
        for behavior in LongPressBehavior.allCases {
            for count in [-1, 0, 1, 21, Int.max] {
                var invalid = map(count: count)
                invalid.controls[1].longPressBehavior = behavior
                XCTAssertThrowsError(try invalid.validate()) {
                    XCTAssertEqual($0 as? HostKeymapError, .invalidLongPressTapCount)
                }
                XCTAssertThrowsError(try HostKeymap.decode(data: JSONEncoder().encode(invalid)))
            }
        }
        for count in [2, 20] { XCTAssertNoThrow(try map(count: count).validate()) }
        for index in [4, 5] {
            var invalid = map()
            invalid.controls[index].longPressBehavior = .burst
            XCTAssertThrowsError(try invalid.validate()) {
                XCTAssertEqual($0 as? HostKeymapError, .unsupportedGesture)
            }
        }
    }

    func testBurstStartsAtThresholdHoldsFortyMillisecondsAndWaitsEightyAfterUp() {
        var router = GestureRouter()
        _ = router.configure(map())
        XCTAssertEqual(router.receive(down(), at: 0), [])
        XCTAssertEqual(router.advance(to: 0.499), [])
        XCTAssertEqual(router.advance(to: 0.5), [begin])
        XCTAssertEqual(router.advance(to: 0.539), [])
        XCTAssertEqual(router.advance(to: 0.541), [end])
        XCTAssertEqual(router.advance(to: 0.620), [])
        XCTAssertEqual(router.advance(to: 0.622), [begin])
        XCTAssertEqual(router.advance(to: 0.661), [])
        XCTAssertEqual(router.advance(to: 0.663), [end])
        XCTAssertEqual(router.advance(to: 100), [])
        XCTAssertEqual(router.receive(down(), at: 101), [])
        XCTAssertEqual(router.receive(up(), at: 102), [])
    }

    func testPhysicalReleaseAtThresholdStillCompletesWholeBurst() {
        var router = GestureRouter()
        _ = router.configure(map(count: 3))
        _ = router.receive(down(), at: 0)
        XCTAssertEqual(router.receive(up(), at: 0.5), [begin])
        for (time, expected) in [(0.55, end), (0.64, begin), (0.69, end), (0.78, begin), (0.83, end)] {
            XCTAssertEqual(router.advance(to: time), [expected])
        }
        XCTAssertEqual(router.advance(to: 10), [])
        _ = router.receive(down(), at: 11)
        XCTAssertEqual(router.advance(to: 11.5), [begin])
    }

    func testNewPhysicalPressDuringBurstCannotStartAnotherGroupEvenIfHeldPastCompletion() {
        var router = GestureRouter()
        _ = router.configure(map())
        _ = router.receive(down(), at: 0)
        _ = router.receive(up(), at: 0.5)
        XCTAssertEqual(router.receive(down(), at: 0.51), [])
        XCTAssertEqual(router.advance(to: 0.55), [end])
        XCTAssertEqual(router.advance(to: 0.64), [begin])
        XCTAssertEqual(router.advance(to: 0.69), [end])
        XCTAssertEqual(router.advance(to: 5), [])
        XCTAssertEqual(router.receive(up(), at: 6), [])
        _ = router.receive(down(), at: 7)
        XCTAssertEqual(router.advance(to: 7.5), [begin])
    }

    func testDelayedPumpAndClockRollbackNeverCatchUpInOneAdvance() {
        var router = GestureRouter()
        _ = router.configure(map(count: 20))
        _ = router.receive(down(), at: 0)
        XCTAssertEqual(router.advance(to: 10), [begin])
        XCTAssertEqual(router.advance(to: 10), [])
        XCTAssertEqual(router.advance(to: 100), [end])
        XCTAssertEqual(router.advance(to: 100), [])
        XCTAssertEqual(router.advance(to: 1), [])
        XCTAssertEqual(router.advance(to: 100.079), [])
        XCTAssertEqual(router.advance(to: 100.081), [begin])
        XCTAssertEqual(router.advance(to: 100.081), [])
    }

    func testUpperBoundProducesExactlyTwentyPairsWithoutRepeatingWhileHeld() {
        var router = GestureRouter()
        _ = router.configure(map(count: 20))
        _ = router.receive(down(), at: 0)
        var time = 0.5
        var output = router.advance(to: time)
        for pulse in 0..<20 {
            time += 0.05
            output += router.advance(to: time)
            if pulse < 19 {
                time += 0.09
                output += router.advance(to: time)
            }
        }
        XCTAssertEqual(output, (0..<20).flatMap { _ in [begin, end] })
        XCTAssertEqual(router.advance(to: 100), [])
    }

    func testCancelAndConfigurationChangeDiscardBothHeldAndWaitingBurstPhases() {
        for inGap in [false, true] {
            for reconfigure in [false, true] {
                var router = GestureRouter()
                _ = router.configure(map())
                _ = router.receive(down(), at: 0)
                _ = router.advance(to: 0.5)
                if inGap { _ = router.advance(to: 0.55) }
                let releases = reconfigure ? router.configure(map(count: 3)) : router.cancel()
                XCTAssertEqual(releases, inGap ? [] : [end])
                XCTAssertEqual(router.advance(to: 10), [])
                XCTAssertEqual(router.receive(down(), at: 11), [])
                XCTAssertEqual(router.receive(up(), at: 12), [])
                _ = router.receive(down(), at: 13)
                XCTAssertEqual(router.advance(to: 13.5), [begin])
            }
        }
    }

    func testSecondPressBurstSuppressesPendingSingleAndDouble() {
        var config = map()
        config.controls[1].doublePress = [KeyEntry(code: 4)]
        var router = GestureRouter()
        _ = router.configure(config)
        _ = router.receive(down(), at: 0)
        _ = router.receive(up(), at: 0.1)
        _ = router.receive(down(), at: 0.2)
        XCTAssertEqual(router.receive(up(), at: 0.71), [begin])
        XCTAssertEqual(router.advance(to: 0.76), [end])
        XCTAssertEqual(router.advance(to: 0.85), [begin])
        XCTAssertEqual(router.advance(to: 0.90), [end])
        XCTAssertEqual(router.advance(to: 5), [])
    }

    func testBridgeBurstKeepsSharedFnOwnedByAnotherPhysicalControl() {
        var config = map()
        config.controls[1].longPress = [KeyEntry(code: 1), KeyEntry(code: 0x28)]
        var time = 0.0
        var posts: [([UInt8], Bool, CGEventFlags)] = []
        let bridge = VendorKeyBridge(permissions: { (true, true) }, now: { time }, emit: {
            posts.append(($0.map(\.code), $1, $2))
        })
        bridge.synchronize(configuration: config, connected: true, online: true)
        bridge.receive(down(0))
        bridge.receive(down())
        for next in [0.5, 0.55, 0.64, 0.69] { time = next; bridge.pump() }
        XCTAssertEqual(posts.map(\.0), [[1], [0x28], [0x28], [0x28], [0x28]])
        XCTAssertEqual(posts.map(\.1), [true, true, false, true, false])
        XCTAssertTrue(posts.dropFirst().allSatisfy { $0.2.contains(.maskSecondaryFn) })
        XCTAssertTrue(bridge.status.pressed)
        bridge.receive(up(0))
        XCTAssertEqual(posts.last?.0, [1])
        XCTAssertFalse(bridge.status.pressed)
    }

    func testBridgeFailureCancelsRemainingBurstAndRetriesUpWithoutLosingOtherOwner() {
        for failDown in [false, true] {
            var config = map()
            config.controls[1].longPress = [KeyEntry(code: 1), KeyEntry(code: 0x28)]
            var time = 0.0
            var downAttempts = 0
            var upFailures = 1
            var posts: [([UInt8], Bool)] = []
            let bridge = VendorKeyBridge(permissions: { (true, true) }, now: { time }, emit: { entries, pressed, _ in
                posts.append((entries.map(\.code), pressed))
                if entries.contains(where: { $0.code == 0x28 }) {
                    if pressed {
                        downAttempts += 1
                        if failDown { throw DeviceProtocolError.message("模拟部分按下失败") }
                    } else if upFailures > 0 {
                        upFailures -= 1
                        throw DeviceProtocolError.message("模拟释放失败")
                    }
                }
            })
            bridge.synchronize(configuration: config, connected: true, online: true)
            bridge.receive(down(0)); bridge.receive(down())
            for next in [0.5, 0.55, 0.64, 0.69, 1, 5] { time = next; bridge.pump() }
            XCTAssertEqual(downAttempts, 1)
            XCTAssertEqual(posts.filter { $0.0 == [0x28] && !$0.1 }.count, 2)
            XCTAssertTrue(bridge.status.pressed)
            XCTAssertNil(bridge.status.error)
            bridge.receive(up()); bridge.receive(up(0))
            XCTAssertFalse(bridge.status.pressed)
        }
    }

    func testBridgeDisconnectOrPermissionLossReleasesAndCancelsBurst() {
        for disconnect in [false, true] {
            var time = 0.0
            var granted = true
            var posts: [Bool] = []
            let bridge = VendorKeyBridge(permissions: { (granted, granted) }, now: { time }, emit: { _, down, _ in
                posts.append(down)
            })
            bridge.synchronize(configuration: map(), connected: true, online: true)
            bridge.receive(down())
            time = 0.5; bridge.pump()
            if disconnect { bridge.synchronize(configuration: map(), connected: false, online: false) }
            else { granted = false; bridge.refreshPermissions() }
            XCTAssertEqual(posts, [true, false])
            time = 10; bridge.pump()
            XCTAssertEqual(posts, [true, false])
        }
    }
}
