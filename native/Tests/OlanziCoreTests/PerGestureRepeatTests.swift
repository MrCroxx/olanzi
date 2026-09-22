import XCTest
@testable import OlanziCore

final class PerGestureRepeatTests: XCTestCase {
    private let primary = [KeyEntry(code: 0xE3), KeyEntry(code: 0x04)]
    private let double = [KeyEntry(code: 0x05)]
    private let long = [KeyEntry(code: 0x06)]
    private func down(_ index: Int = 0) -> VendorKeyEvent { .init(index: index, pressed: true) }
    private func up(_ index: Int = 0) -> VendorKeyEvent { .init(index: index, pressed: false) }
    private func pairs(_ entries: [KeyEntry], count: Int, index: Int = 0) -> [GestureTransition] {
        (0..<count).flatMap { _ in [.begin(index: index, entries: entries), .end(index: index)] }
    }
    private func map() -> HostKeymap {
        var configuration = HostKeymap.defaultKeymap
        configuration.controls[0].press = primary
        return configuration
    }
    private func drain(_ router: inout GestureRouter, from start: Double, steps: Int = 200) -> [GestureTransition] {
        (1...steps).flatMap { router.advance(to: start + Double($0) * 0.1) }
    }

    func testEachGestureUsesIndependentRepeatCountAndNeverFiresPrimaryEarly() throws {
        var configuration = map()
        configuration.controls[0].doublePress = double
        configuration.controls[0].longPress = long
        configuration.controls[0].pressBehavior = .burst
        configuration.controls[0].pressTapCount = 2
        configuration.controls[0].doublePressBehavior = .burst
        configuration.controls[0].doublePressTapCount = 3
        configuration.controls[0].longPressBehavior = .burst
        configuration.controls[0].longPressTapCount = 4
        try configuration.validate()
        for gesture in 0..<3 {
            var router = GestureRouter()
            _ = router.configure(configuration)
            XCTAssertEqual(router.receive(down(), at: 0), [])
            var output: [GestureTransition] = []
            if gesture < 2 {
                XCTAssertEqual(router.receive(up(), at: 0.1), [])
                if gesture == 1 {
                    XCTAssertEqual(router.receive(down(), at: 0.2), [])
                    output += router.receive(up(), at: 0.3)
                }
            } else {
                output += router.receive(up(), at: 0.5)
            }
            output += drain(&router, from: 0.5)
            XCTAssertEqual(output, pairs(gesture == 0 ? primary : gesture == 1 ? double : long,
                                         count: gesture + 2))
        }
    }

    func testPrimaryTapRunsOnceWhileHoldStillWaitsForPhysicalRelease() {
        for behavior in [LongPressBehavior.hold, .tap] {
            var configuration = map()
            configuration.controls[0].pressBehavior = behavior
            var router = GestureRouter()
            _ = router.configure(configuration)
            let output = router.receive(down(), at: 0)
            XCTAssertEqual(output, behavior == .hold ? [.begin(index: 0, entries: primary)] : pairs(primary, count: 1))
            XCTAssertEqual(router.advance(to: 1), [])
            XCTAssertEqual(router.receive(up(), at: 2), behavior == .hold ? [.end(index: 0)] : [])
        }
    }

    func testRapidClicksAndRotationsQueueCompleteGroupsWithCapturedActions() {
        for index in [0, 4] {
            var configuration = map()
            configuration.controls[index].press = primary
            configuration.controls[index].pressBehavior = .burst
            configuration.controls[index].pressTapCount = 3
            var router = GestureRouter()
            _ = router.configure(configuration)
            var output: [GestureTransition] = []
            for click in 0..<5 {
                output += router.receive(down(index), at: Double(click) * 0.002)
                if index == 0 { output += router.receive(up(index), at: Double(click) * 0.002 + 0.001) }
            }
            output += drain(&router, from: 0.01)
            XCTAssertEqual(output, pairs(primary, count: 15, index: index))
        }
    }

    func testRotationQueueIsBoundedAndDropsNewestWholeActions() {
        var configuration = map()
        configuration.controls[4].press = primary
        configuration.controls[4].pressBehavior = .burst
        configuration.controls[4].pressTapCount = 2
        var router = GestureRouter()
        _ = router.configure(configuration)
        var output: [GestureTransition] = []
        for _ in 0..<100 { output += router.receive(down(4), at: 0) }
        output += drain(&router, from: 0, steps: 200)
        XCTAssertEqual(output, pairs(primary, count: 2 * (1 + GestureRouter.maximumQueuedActions), index: 4))
        XCTAssertEqual(router.advance(to: 100), [])
    }

    func testQueuedRotationSnapshotsSurviveLayerExitAndTransparentFallback() throws {
        var configuration = map()
        configuration.controls[0].pressAction = .momentaryLayer(1)
        configuration.controls[4].press = primary
        configuration.controls[4].pressBehavior = .burst
        configuration.layers = [HostLayer(id: 1, controls: [
            ControlActionMap(index: 4, press: double, pressBehavior: .burst, pressTapCount: 3)
        ])]
        try configuration.validate()
        var router = GestureRouter()
        _ = router.configure(configuration)
        _ = router.receive(down(), at: 0)
        var output = router.receive(down(4), at: 0.001)
        output += router.receive(down(4), at: 0.002)
        _ = router.receive(up(), at: 0.003)
        output += router.receive(down(4), at: 0.004)
        output += drain(&router, from: 0.01)
        XCTAssertEqual(output, pairs(double, count: 6, index: 4) + pairs(primary, count: 2, index: 4))
    }

    func testCancellationAndReconfigurationReleaseCurrentAndDiscardEveryQueuedGroup() {
        for inGap in [false, true] {
            for reconfigure in [false, true] {
                var configuration = map()
                configuration.controls[0].pressBehavior = .burst
                var router = GestureRouter()
                _ = router.configure(configuration)
                _ = router.receive(down(), at: 0)
                _ = router.receive(up(), at: 0.001)
                _ = router.receive(down(), at: 0.002)
                if inGap { _ = router.advance(to: 0.05) }
                configuration.controls[0].pressTapCount = 3
                XCTAssertEqual(reconfigure ? router.configure(configuration) : router.cancel(),
                               inGap ? [] : [.end(index: 0)])
                XCTAssertEqual(router.advance(to: 100), [])
                XCTAssertEqual(router.receive(down(), at: 101), [])
                XCTAssertEqual(router.receive(up(), at: 102), [])
            }
        }
    }

    func testConcurrentControlsHaveIndependentQueuesAndOwners() {
        var configuration = map()
        for index in [0, 1] {
            configuration.controls[index].press = index == 0 ? primary : double
            configuration.controls[index].pressBehavior = .burst
            configuration.controls[index].pressTapCount = index + 2
        }
        var router = GestureRouter()
        _ = router.configure(configuration)
        var output = router.receive(down(0), at: 0)
        output += router.receive(down(1), at: 0)
        output += router.receive(up(0), at: 0.01)
        output += router.receive(up(1), at: 0.01)
        output += drain(&router, from: 0.01)
        for index in [0, 1] {
            let selected = output.filter { transition in
                switch transition {
                case .begin(let owner, _), .end(let owner), .execute(let owner, _): return owner == index
                }
            }
            XCTAssertEqual(selected, pairs(index == 0 ? primary : double, count: index + 2, index: index))
        }
    }

    func testLongHoldQueuedBehindDoubleBurstCannotReleaseBurstOrStartAfterPhysicalUp() {
        var configuration = map()
        configuration.controls[0].doublePress = double
        configuration.controls[0].doublePressBehavior = .burst
        configuration.controls[0].doublePressTapCount = 20
        configuration.controls[0].longPress = long
        var router = GestureRouter()
        _ = router.configure(configuration)
        _ = router.receive(down(), at: 0)
        _ = router.receive(up(), at: 0.05)
        _ = router.receive(down(), at: 0.1)
        var output = router.receive(up(), at: 0.15)
        output += router.receive(down(), at: 0.2)
        output += router.advance(to: 0.7)
        output += router.receive(up(), at: 0.71)
        output += drain(&router, from: 0.71)
        XCTAssertEqual(output, pairs(double, count: 20))
    }

    func testVersionFiveAndLegacyDefaultsRoundTripWithoutChangingLongOnlyVersions() throws {
        var configuration = map()
        configuration.controls[0].longPress = long
        configuration.controls[0].longPressBehavior = .burst
        configuration.controls[0].longPressTapCount = 7
        XCTAssertEqual(configuration.version, 1)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: Any])
        var controls = try XCTUnwrap(legacy["controls"] as? [[String: Any]])
        for index in controls.indices {
            for field in ["pressBehavior", "pressTapCount", "doublePressBehavior", "doublePressTapCount", "inheritedGestures"] {
                controls[index].removeValue(forKey: field)
            }
        }
        legacy["controls"] = controls
        XCTAssertEqual(try HostKeymap.decode(data: JSONSerialization.data(withJSONObject: legacy)), configuration)
        configuration.controls[0].pressBehavior = .burst
        configuration.controls[0].pressTapCount = 4
        configuration.controls[0].doublePressBehavior = .burst
        configuration.controls[0].doublePressTapCount = 8
        XCTAssertEqual(configuration.version, 5)
        XCTAssertEqual(try HostKeymap.decode(data: JSONEncoder().encode(configuration)), configuration)
        let profile = HostProfile(name: "Repeat", keymap: configuration)
        XCTAssertEqual(try HostProfile.decode(data: JSONEncoder().encode(profile)), profile)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: Any])
        object["version"] = 4
        XCTAssertThrowsError(try HostKeymap.decode(data: JSONSerialization.data(withJSONObject: object)))
    }

    func testRepeatValidationCoversBothFieldsAndRotationCounts() throws {
        for count in [Int.min, -1, 0, 1, 21, Int.max] {
            for index in [0, 4] {
                var configuration = map()
                configuration.controls[index].pressTapCount = count
                XCTAssertThrowsError(try configuration.validate()) { XCTAssertEqual($0 as? HostKeymapError, .invalidPressTapCount) }
                configuration = map()
                configuration.controls[index].doublePressTapCount = count
                XCTAssertThrowsError(try configuration.validate()) { XCTAssertEqual($0 as? HostKeymapError, .invalidPressTapCount) }
            }
        }
        for count in [2, 20] {
            var configuration = map()
            configuration.controls[4].pressBehavior = .burst
            configuration.controls[4].pressTapCount = count
            XCTAssertNoThrow(try configuration.validate())
        }
        var configuration = map()
        configuration.controls[0].doublePressBehavior = .hold
        XCTAssertThrowsError(try configuration.validate()) { XCTAssertEqual($0 as? HostKeymapError, .invalidDoublePressBehavior) }
    }

    func testNonKeyboardActionsIgnoreRepeatSettings() throws {
        let action = HostAction.macro([.keyboard(primary)])
        var configuration = map()
        configuration.controls[0].pressAction = action
        configuration.controls[0].pressBehavior = .burst
        configuration.controls[0].pressTapCount = 20
        configuration.controls[1].pressAction = .momentaryLayer(1)
        configuration.controls[1].pressBehavior = .burst
        try configuration.validate()
        var router = GestureRouter()
        _ = router.configure(configuration)
        XCTAssertEqual(router.receive(down(), at: 0), [.execute(index: 0, action: action)])
        XCTAssertEqual(router.receive(down(1), at: 0.1), [])
        XCTAssertEqual(router.advance(to: 10), [])
        XCTAssertEqual(router.receive(up(), at: 11), [])
        XCTAssertEqual(router.receive(up(1), at: 12), [])
    }
    func testPerGestureTransparencyOverlaysActionAndRepeatSettingsIndependently() throws {
        var configuration = map()
        configuration.controls[0].doublePress = double
        configuration.controls[0].doublePressBehavior = .burst
        configuration.controls[0].doublePressTapCount = 3
        configuration.controls[0].longPress = long
        configuration.controls[0].longPressBehavior = .burst
        configuration.controls[0].longPressTapCount = 4
        configuration.layers = [
            HostLayer(id: 1, controls: [ControlActionMap(index: 0, press: double,
                pressBehavior: .burst, pressTapCount: 5, inheritedGestures: [.doublePress, .longPress])]),
            HostLayer(id: 2, controls: [ControlActionMap(index: 0, press: [], doublePress: long,
                doublePressBehavior: .burst, doublePressTapCount: 6, inheritedGestures: [.press, .longPress])]),
            HostLayer(id: 3, controls: [ControlActionMap(index: 0, press: [], inheritedGestures: [.press, .doublePress])])
        ]
        try configuration.validate()
        let resolved = try XCTUnwrap(configuration.resolvedControl(index: 0, activeLayers: [3, 1, 2, 2]))
        XCTAssertEqual(resolved.effectivePress, .keyboard(double))
        XCTAssertEqual(resolved.pressTapCount, 5)
        XCTAssertEqual(resolved.effectiveDoublePress, .keyboard(long))
        XCTAssertEqual(resolved.doublePressTapCount, 6)
        XCTAssertNil(resolved.effectiveLongPress)
        XCTAssertEqual(resolved.inheritedGestures, [])
        let lower = try XCTUnwrap(configuration.resolvedControl(index: 0, activeLayers: [1, 2]))
        XCTAssertEqual(lower.effectiveLongPress, .keyboard(long))
        XCTAssertEqual(lower.longPressTapCount, 4)
        XCTAssertEqual(configuration.version, 5)
        XCTAssertEqual(try HostKeymap.decode(data: JSONEncoder().encode(configuration)), configuration)
    }

    func testTransparentLongRetainsPrimaryOverrideInRouter() throws {
        var configuration = map()
        configuration.controls[0].longPress = long
        configuration.controls[1].pressAction = .momentaryLayer(1)
        configuration.layers = [HostLayer(id: 1, controls: [ControlActionMap(index: 0, press: double,
            pressBehavior: .burst, pressTapCount: 2, inheritedGestures: [.longPress])])]
        try configuration.validate()
        var router = GestureRouter()
        _ = router.configure(configuration)
        _ = router.receive(down(1), at: 0)
        XCTAssertEqual(router.receive(down(), at: 0.1), [])
        var output = router.receive(up(), at: 0.2)
        output += drain(&router, from: 0.2)
        XCTAssertEqual(output, pairs(double, count: 2))
        XCTAssertEqual(router.receive(down(), at: 21), [])
        XCTAssertEqual(router.advance(to: 21.5), [.begin(index: 0, entries: long)])
        XCTAssertEqual(router.receive(up(), at: 22), [.end(index: 0)])
    }

    func testTransparencyValidationRejectsBaseFlagsAndCrossLayerMomentaryDoubleConflict() throws {
        var configuration = map()
        configuration.controls[0].inheritedGestures = [.press]
        XCTAssertThrowsError(try configuration.validate()) {
            XCTAssertEqual($0 as? HostKeymapError, .invalidInheritedGestures)
        }
        configuration = map()
        configuration.layers = [
            HostLayer(id: 1, controls: [ControlActionMap(index: 0, press: [], pressAction: .momentaryLayer(1))]),
            HostLayer(id: 2, controls: [ControlActionMap(index: 0, press: primary, doublePress: double,
                                                       inheritedGestures: [.press])])
        ]
        XCTAssertThrowsError(try configuration.validate()) {
            XCTAssertEqual($0 as? HostKeymapError, .invalidLayerAction)
        }
        configuration.layers[1].controls[0].inheritedGestures = []
        XCTAssertNoThrow(try configuration.validate())
    }

    func testExplicitEmptyOverridesInheritedGestureInsteadOfFallingThrough() throws {
        var configuration = map()
        configuration.controls[0].doublePress = double
        configuration.controls[0].longPress = long
        configuration.layers = [HostLayer(id: 1, controls: [ControlActionMap(index: 0,
            press: [KeyEntry(code: 0)], inheritedGestures: [])])]
        try configuration.validate()
        let result = try XCTUnwrap(configuration.resolvedControl(index: 0, activeLayers: [1]))
        XCTAssertEqual(result.effectivePress, .keyboard([KeyEntry(code: 0)]))
        XCTAssertNil(result.effectiveDoublePress)
        XCTAssertNil(result.effectiveLongPress)
    }

}
