import XCTest
@testable import OlanziCore

final class LayerTests: XCTestCase {
    private let base = [KeyEntry(code: 0x04)]
    private let upper = [KeyEntry(code: 0x05)]
    private let highest = [KeyEntry(code: 0x06)]

    private func map() -> HostKeymap {
        var controls = (0..<6).map { ControlActionMap(index: $0, press: base) }
        controls[0].pressAction = .momentaryLayer(1)
        return HostKeymap(controls: controls, layers: [HostLayer(id: 1, controls: [
            ControlActionMap(index: 1, press: upper),
            ControlActionMap(index: 4, press: upper)
        ])])
    }

    private func down(_ index: Int) -> VendorKeyEvent { .init(index: index, pressed: true) }
    private func up(_ index: Int) -> VendorKeyEvent { .init(index: index, pressed: false) }
    private func pulse(_ entries: [KeyEntry], _ index: Int) -> [GestureTransition] {
        [.begin(index: index, entries: entries), .end(index: index)]
    }

    func testMomentaryLayerIsImmediateAndReleaseRestoresBase() throws {
        let configuration = map()
        try configuration.validate()
        var router = GestureRouter()
        _ = router.configure(configuration)
        XCTAssertEqual(router.receive(down(0), at: 0), [])
        XCTAssertEqual(router.receive(down(1), at: 0), [.begin(index: 1, entries: upper)])
        XCTAssertEqual(router.receive(up(0), at: 0.1), [])
        XCTAssertEqual(router.receive(up(1), at: 0.2), [.end(index: 1)])
        XCTAssertEqual(router.receive(down(1), at: 0.3), [.begin(index: 1, entries: base)])
        XCTAssertEqual(router.receive(up(1), at: 0.4), [.end(index: 1)])
    }

    func testTransparentControlsAndRotationsUseActiveLayers() {
        var router = GestureRouter()
        _ = router.configure(map())
        _ = router.receive(down(0), at: 0)
        XCTAssertEqual(router.receive(down(2), at: 0.1), [.begin(index: 2, entries: base)])
        XCTAssertEqual(router.receive(down(4), at: 0.2), pulse(upper, 4))
        XCTAssertEqual(router.receive(down(5), at: 0.3), pulse(base, 5))
        _ = router.receive(up(0), at: 0.4)
        XCTAssertEqual(router.receive(down(4), at: 0.5), pulse(base, 4))
    }

    func testNestedLayerPriorityIsNumericAndReleaseUsesOriginalBinding() throws {
        var configuration = map()
        configuration.controls[3].pressAction = .momentaryLayer(2)
        configuration.layers[0].controls.append(ControlActionMap(index: 2, press: [], pressAction: .momentaryLayer(2)))
        configuration.layers.append(HostLayer(id: 2, controls: [
            ControlActionMap(index: 0, press: highest),
            ControlActionMap(index: 1, press: highest)
        ]))
        try configuration.validate()
        var router = GestureRouter()
        _ = router.configure(configuration)
        _ = router.receive(down(0), at: 0)
        _ = router.receive(down(2), at: 0.1)
        XCTAssertEqual(router.receive(down(1), at: 0.2), [.begin(index: 1, entries: highest)])
        _ = router.receive(up(1), at: 0.3)
        _ = router.receive(up(0), at: 0.4)
        XCTAssertEqual(router.receive(down(4), at: 0.5), pulse(base, 4))
        XCTAssertEqual(router.receive(down(1), at: 0.6), [.begin(index: 1, entries: highest)])
        _ = router.receive(up(1), at: 0.7)
        _ = router.receive(up(2), at: 0.8)
        // 先激活高层，再通过透明键激活低层，仍以高编号为优先。
        _ = router.receive(down(3), at: 1)
        // 高层覆盖键 0，使用另一透明切层键进入低层。
        configuration.controls[2].pressAction = .momentaryLayer(1)
        _ = router.configure(configuration)
        _ = router.receive(up(3), at: 1.1)
        _ = router.receive(down(3), at: 1.2)
        _ = router.receive(down(2), at: 1.3)
        XCTAssertEqual(router.receive(down(1), at: 1.4), [.begin(index: 1, entries: highest)])
        XCTAssertEqual(router.receive(down(4), at: 1.5), pulse(upper, 4))
    }

    func testTwoOwnersAndDuplicateEventsCannotDropOrStickLayer() {
        var configuration = map()
        configuration.controls[2].pressAction = .momentaryLayer(1)
        var router = GestureRouter()
        _ = router.configure(configuration)
        _ = router.receive(down(0), at: 0)
        _ = router.receive(down(0), at: 0.1)
        _ = router.receive(down(2), at: 0.2)
        _ = router.receive(up(0), at: 0.3)
        _ = router.receive(up(0), at: 0.4)
        XCTAssertEqual(router.receive(down(4), at: 0.5), pulse(upper, 4))
        _ = router.receive(up(2), at: 0.6)
        XCTAssertEqual(router.receive(down(4), at: 0.7), pulse(base, 4))
    }

    func testDelayedSingleAndDoubleKeepFirstDownSnapshot() {
        for completeDouble in [false, true] {
            var configuration = map()
            configuration.layers[0].controls[0].doublePress = highest
            var router = GestureRouter()
            _ = router.configure(configuration)
            _ = router.receive(down(0), at: 0)
            _ = router.receive(down(1), at: 0.01)
            _ = router.receive(up(1), at: 0.1)
            _ = router.receive(up(0), at: 0.15)
            if completeDouble {
                XCTAssertEqual(router.receive(down(1), at: 0.2), [])
                XCTAssertEqual(router.receive(up(1), at: 0.25), pulse(highest, 1))
            } else {
                XCTAssertEqual(router.advance(to: 0.35), pulse(upper, 1))
            }
            XCTAssertEqual(router.advance(to: 1), [])
        }
    }

    func testLayerEntryDoesNotChangeAnExistingBaseGesture() {
        var configuration = map()
        configuration.controls[1].longPress = highest
        var router = GestureRouter()
        _ = router.configure(configuration)
        _ = router.receive(down(1), at: 0)
        _ = router.receive(down(0), at: 0.1)
        XCTAssertEqual(router.advance(to: 0.5), [.begin(index: 1, entries: highest)])
        XCTAssertEqual(router.receive(up(1), at: 0.6), [.end(index: 1)])
    }

    func testLayerExitDoesNotChangeLongPressOrBurstQueue() {
        for behavior in [LongPressBehavior.hold, .tap, .burst] {
            var configuration = map()
            configuration.layers[0].controls[0].longPress = highest
            configuration.layers[0].controls[0].longPressBehavior = behavior
            var router = GestureRouter()
            _ = router.configure(configuration)
            _ = router.receive(down(0), at: 0)
            _ = router.receive(down(1), at: 0.1)
            _ = router.receive(up(0), at: 0.2)
            let first: [GestureTransition] = behavior == .tap ? pulse(highest, 1) : [.begin(index: 1, entries: highest)]
            XCTAssertEqual(router.advance(to: 0.6), first)
            if behavior == .burst {
                XCTAssertEqual(router.receive(up(1), at: 0.61), [])
                XCTAssertEqual(router.advance(to: 0.65), [.end(index: 1)])
                XCTAssertEqual(router.advance(to: 0.74), [.begin(index: 1, entries: highest)])
                XCTAssertEqual(router.advance(to: 0.79), [.end(index: 1)])
            } else {
                XCTAssertEqual(router.receive(up(1), at: 0.7), behavior == .hold ? [.end(index: 1)] : [])
            }
            XCTAssertEqual(router.advance(to: 2), [])
        }
    }

    func testCancellationClearsLayersAndQuarantinesHeldSelectors() {
        for reconfigure in [false, true] {
            var router = GestureRouter()
            let configuration = map()
            _ = router.configure(configuration)
            _ = router.receive(down(0), at: 0)
            _ = router.receive(down(1), at: 0.1)
            if reconfigure {
                var updated = configuration
                updated.doublePressWindow = 0.3
                XCTAssertEqual(router.configure(updated), [.end(index: 1)])
            } else {
                XCTAssertEqual(router.cancel(), [.end(index: 1)])
            }
            XCTAssertEqual(router.receive(down(0), at: 0.2), [])
            XCTAssertEqual(router.receive(down(4), at: 0.3), pulse(base, 4))
            _ = router.receive(up(0), at: 0.4)
            _ = router.receive(down(0), at: 0.5)
            XCTAssertEqual(router.receive(down(4), at: 0.6), pulse(upper, 4))
        }
    }

    func testLibraryActionsResolveWithinLayer() throws {
        var configuration = map()
        let item = NamedHostAction(name: "宏", slot: 0, action: .macro([.keyboard(highest)]))
        configuration.actionLibrary = [item]
        configuration.layers[0].controls[0].pressAction = .library(item.id)
        try configuration.validate()
        var router = GestureRouter()
        _ = router.configure(configuration)
        _ = router.receive(down(0), at: 0)
        XCTAssertEqual(router.receive(down(1), at: 0.1), [.execute(index: 1, action: item.action)])
    }

    func testVersionFourRoundTripProfileAndExactLookup() throws {
        let configuration = map()
        XCTAssertEqual(configuration.version, 4)
        XCTAssertEqual(try HostKeymap.decode(data: JSONEncoder().encode(configuration)), configuration)
        let profile = HostProfile(name: "Layer", keymap: configuration)
        XCTAssertEqual(try HostProfile.decode(data: JSONEncoder().encode(profile)), profile)
        XCTAssertNil(configuration.control(index: 2, layer: 1))
        XCTAssertEqual(configuration.control(index: 2, layer: 0)?.press, base)
        XCTAssertEqual(configuration.control(index: 1, layer: 1)?.press, upper)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: Any])
        object["version"] = 3
        XCTAssertThrowsError(try HostKeymap.decode(data: JSONSerialization.data(withJSONObject: object)))
        var legacy = HostKeymap.defaultKeymap
        XCTAssertEqual(try HostKeymap.decode(data: JSONEncoder().encode(legacy)).layers, [])
        legacy.layers = [HostLayer(id: 1)]
        XCTAssertEqual(legacy.version, 4)
        legacy.layers = []
        XCTAssertEqual(legacy.version, 1)
    }

    func testFixedLayersNeedNoStoredOverridesAndInheritBase() throws {
        for target in 1...3 {
            var configuration = HostKeymap.defaultKeymap
            configuration.controls[0].pressAction = .momentaryLayer(target)
            try configuration.validate()
            XCTAssertTrue(configuration.layers.isEmpty)
            XCTAssertEqual(try HostKeymap.decode(data: JSONEncoder().encode(configuration)), configuration)
            var router = GestureRouter()
            _ = router.configure(configuration)
            XCTAssertEqual(router.receive(down(0), at: 0), [])
            XCTAssertEqual(router.receive(down(1), at: 0.1), [.begin(index: 1, entries: configuration.controls[1].press)])
            XCTAssertEqual(router.receive(up(0), at: 0.2), [])
            XCTAssertEqual(router.receive(up(1), at: 0.3), [.end(index: 1)])
        }
    }

    func testInvalidLayerShapesAndBindingsAreRejected() throws {
        for layers in [[HostLayer(id: 0)], [HostLayer(id: 4)], [HostLayer(id: 8)], [HostLayer(id: 1), HostLayer(id: 1)],
                       [HostLayer(id: 1, controls: [ControlActionMap(index: -1, press: [])])],
                       [HostLayer(id: 1, controls: [ControlActionMap(index: 6, press: [])])],
                       [HostLayer(id: 1, controls: [ControlActionMap(index: 1, press: []), ControlActionMap(index: 1, press: [])])]] {
            var invalid = map()
            invalid.layers = layers
            XCTAssertThrowsError(try invalid.validate()) { XCTAssertEqual($0 as? HostKeymapError, .invalidLayer) }
        }
        for index in 0..<6 {
            var invalid = map()
            invalid.controls[index].doublePressAction = .momentaryLayer(1)
            XCTAssertThrowsError(try invalid.validate())
            invalid = map()
            invalid.controls[index].longPressAction = .momentaryLayer(1)
            if index < 4 { XCTAssertNoThrow(try invalid.validate()) }
            else { XCTAssertThrowsError(try invalid.validate()) }
        }
        for index in [4, 5] {
            var invalid = map()
            invalid.controls[index].pressAction = .momentaryLayer(1)
            XCTAssertThrowsError(try invalid.validate())
        }
        for target in [0, 4, 8] {
            var invalid = map()
            invalid.controls[0].pressAction = .momentaryLayer(target)
            XCTAssertThrowsError(try invalid.validate())
            invalid = map()
            invalid.controls[1].longPressAction = .momentaryLayer(target)
            XCTAssertThrowsError(try invalid.validate())
        }
        var invalid = map()
        invalid.controls[0].doublePress = []
        XCTAssertThrowsError(try invalid.validate())
        invalid = map()
        invalid.controls[0].longPress = []
        XCTAssertNoThrow(try invalid.validate())
        invalid = map()
        invalid.layers[0].controls[0].press = [KeyEntry(code: 0xFF)]
        XCTAssertThrowsError(try invalid.validate())
        XCTAssertThrowsError(try NamedHostAction(name: "Layer", slot: 0, action: .momentaryLayer(1)).validate())
        XCTAssertThrowsError(try HostActionRunner().enqueue(index: 0, action: .momentaryLayer(1)))
    }

    func testPrimaryLayerSupportsAllKeyboardLongModesWithoutDelayingLayer() throws {
        for behavior in LongPressBehavior.allCases {
            var configuration = map()
            configuration.controls[0].longPress = highest
            configuration.controls[0].longPressBehavior = behavior
            try configuration.validate()
            var router = GestureRouter()
            _ = router.configure(configuration)
            XCTAssertEqual(router.receive(down(0), at: 0), [])
            XCTAssertEqual(router.receive(down(4), at: 0.1), pulse(upper, 4))
            let expected: [GestureTransition] = behavior == .tap
                ? pulse(highest, 0) : [.begin(index: 0, entries: highest)]
            XCTAssertEqual(router.advance(to: 0.5), expected)
            XCTAssertEqual(router.receive(down(0), at: 0.51), [])
            XCTAssertEqual(router.receive(down(4), at: 0.52), pulse(upper, 4))
            XCTAssertEqual(router.receive(up(0), at: 0.53), behavior == .hold ? [.end(index: 0)] : [])
            if behavior == .burst {
                XCTAssertEqual(router.advance(to: 0.55), [.end(index: 0)])
                XCTAssertEqual(router.receive(down(4), at: 0.56), pulse(base, 4))
                XCTAssertEqual(router.advance(to: 0.64), [.begin(index: 0, entries: highest)])
                XCTAssertEqual(router.advance(to: 0.69), [.end(index: 0)])
            }
            XCTAssertEqual(router.receive(down(4), at: 0.8), pulse(base, 4))
            XCTAssertEqual(router.advance(to: 2), [])
        }
    }

    func testPrimaryLayerShortReleaseSuppressesFallbackAndLongAction() {
        var configuration = map()
        configuration.controls[0].longPress = highest
        var router = GestureRouter()
        _ = router.configure(configuration)
        _ = router.receive(down(0), at: 0)
        XCTAssertEqual(router.receive(down(4), at: 0.1), pulse(upper, 4))
        XCTAssertEqual(router.receive(up(0), at: 0.2), [])
        XCTAssertEqual(router.receive(down(4), at: 0.3), pulse(base, 4))
        XCTAssertEqual(router.advance(to: 2), [])
    }

    func testPrimaryLayerCanRunApplicationOrMacroLongActionOnce() throws {
        let target = ApplicationTarget(bundleIdentifier: "com.example.editor", path: "", name: "Editor")
        for action: HostAction in [.application(target), .macro([.keyboard(highest)])] {
            var configuration = map()
            configuration.controls[0].longPressAction = action
            try configuration.validate()
            var router = GestureRouter()
            _ = router.configure(configuration)
            _ = router.receive(down(0), at: 0)
            XCTAssertEqual(router.advance(to: 0.5), [.execute(index: 0, action: action)])
            XCTAssertEqual(router.receive(down(4), at: 0.6), pulse(upper, 4))
            XCTAssertEqual(router.advance(to: 1), [])
            XCTAssertEqual(router.receive(up(0), at: 1.1), [])
            XCTAssertEqual(router.receive(down(4), at: 1.2), pulse(base, 4))
        }
    }

    func testTapHoldLayerRunsPrimaryOnlyForShortPressAndNeverExecutesLayer() throws {
        for behavior in LongPressBehavior.allCases {
            var configuration = map()
            configuration.controls[0].pressAction = nil
            configuration.controls[0].longPressAction = .momentaryLayer(1)
            configuration.controls[0].longPressBehavior = behavior
            try configuration.validate()
            XCTAssertEqual(try HostKeymap.decode(data: JSONEncoder().encode(configuration)), configuration)
            var router = GestureRouter()
            _ = router.configure(configuration)
            XCTAssertEqual(router.receive(down(0), at: 0), [])
            XCTAssertEqual(router.receive(down(4), at: 0.1), pulse(base, 4))
            XCTAssertEqual(router.receive(up(0), at: 0.2), pulse(base, 0))
            XCTAssertEqual(router.receive(down(0), at: 1), [])
            XCTAssertEqual(router.advance(to: 1.5), [])
            XCTAssertEqual(router.receive(down(4), at: 1.6), pulse(upper, 4))
            XCTAssertEqual(router.receive(up(0), at: 1.7), [])
            XCTAssertEqual(router.receive(down(4), at: 1.8), pulse(base, 4))
            XCTAssertEqual(router.advance(to: 2), [])
            XCTAssertEqual(router.receive(down(0), at: 3), [])
            XCTAssertEqual(router.receive(up(0), at: 3.5), [])
            XCTAssertEqual(router.receive(down(4), at: 3.6), pulse(base, 4))
        }
    }

    func testPrimaryAndLongLayersReplaceOwnerAndPreserveOtherHeldKeys() throws {
        var configuration = map()
        configuration.controls[0].longPressAction = .momentaryLayer(2)
        configuration.layers.append(HostLayer(id: 2, controls: [ControlActionMap(index: 4, press: highest)]))
        try configuration.validate()
        var router = GestureRouter()
        _ = router.configure(configuration)
        _ = router.receive(down(0), at: 0)
        XCTAssertEqual(router.receive(down(1), at: 0.1), [.begin(index: 1, entries: upper)])
        XCTAssertEqual(router.receive(down(4), at: 0.2), pulse(upper, 4))
        XCTAssertEqual(router.advance(to: 0.5), [])
        XCTAssertEqual(router.receive(down(4), at: 0.6), pulse(highest, 4))
        XCTAssertEqual(router.receive(up(0), at: 0.7), [])
        XCTAssertEqual(router.receive(down(4), at: 0.8), pulse(base, 4))
        XCTAssertEqual(router.receive(up(1), at: 0.9), [.end(index: 1)])
    }

    func testCancellationClearsLayersBeforeAndAfterLongThreshold() {
        for longAction: HostAction in [.keyboard(highest), .momentaryLayer(2)] {
            for fired in [false, true] {
                var configuration = map()
                configuration.controls[0].longPressAction = longAction
                var router = GestureRouter()
                _ = router.configure(configuration)
                _ = router.receive(down(0), at: 0)
                if fired { _ = router.advance(to: 0.5) }
                let expected: [GestureTransition] = fired && longAction == .keyboard(highest) ? [.end(index: 0)] : []
                XCTAssertEqual(router.cancel(), expected)
                XCTAssertEqual(router.receive(down(4), at: 0.6), pulse(base, 4))
                XCTAssertEqual(router.receive(down(0), at: 0.7), [])
                XCTAssertEqual(router.receive(down(4), at: 0.8), pulse(base, 4))
                XCTAssertEqual(router.receive(up(0), at: 0.9), [])
                XCTAssertEqual(router.advance(to: 2), [])
            }
        }
    }

    func testLayerPrimaryRepressDuringBurstReactivatesOnlyWhilePhysicallyHeld() {
        var configuration = map()
        configuration.controls[0].longPress = highest
        configuration.controls[0].longPressBehavior = .burst
        var router = GestureRouter()
        _ = router.configure(configuration)
        _ = router.receive(down(0), at: 0)
        _ = router.advance(to: 0.5)
        _ = router.receive(up(0), at: 0.51)
        _ = router.advance(to: 0.55)
        XCTAssertEqual(router.receive(down(4), at: 0.56), pulse(base, 4))
        XCTAssertEqual(router.receive(down(0), at: 0.57), [])
        XCTAssertEqual(router.receive(down(4), at: 0.58), pulse(upper, 4))
        XCTAssertEqual(router.advance(to: 0.64), [.begin(index: 0, entries: highest)])
        XCTAssertEqual(router.advance(to: 0.69), [.end(index: 0)])
        XCTAssertEqual(router.receive(down(4), at: 0.7), pulse(upper, 4))
        XCTAssertEqual(router.receive(up(0), at: 0.8), [])
        XCTAssertEqual(router.receive(down(4), at: 0.9), pulse(base, 4))
        XCTAssertEqual(router.advance(to: 2), [])
    }

    func testBridgePermissionPauseAndDisconnectClearActiveLayers() {
        for interruption in 0..<3 {
            var allowed = true
            var time = 0.0
            var emitted: [UInt8] = []
            let bridge = VendorKeyBridge(permissions: { (true, allowed) }, now: { time }, emit: { entries, pressed, _ in
                if pressed { emitted += entries.map(\.code) }
            })
            let configuration = map()
            bridge.synchronize(configuration: configuration, connected: true, online: true)
            bridge.receive(down(0))
            bridge.receive(down(4))
            XCTAssertEqual(emitted, [0x05])
            switch interruption {
            case 0: allowed = false; bridge.refreshPermissions()
            case 1: bridge.synchronize(configuration: nil, connected: true, online: true)
            default: bridge.synchronize(configuration: configuration, connected: false, online: false)
            }
            time = 3
            allowed = true
            bridge.refreshPermissions()
            bridge.synchronize(configuration: configuration, connected: true, online: true)
            bridge.receive(down(4))
            XCTAssertEqual(emitted, [0x05, 0x04])
            bridge.receive(up(0))
            bridge.receive(down(0))
            bridge.receive(down(4))
            XCTAssertEqual(emitted, [0x05, 0x04, 0x05])
            XCTAssertNil(bridge.status.error)
            bridge.close()
        }
    }
}
