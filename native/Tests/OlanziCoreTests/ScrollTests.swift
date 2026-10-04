import CoreGraphics
import XCTest
@testable import OlanziCore

final class ScrollTests: XCTestCase {
    private func scrollMap() -> HostKeymap {
        var map = HostKeymap.defaultKeymap
        map.controls[4].pressAction = .scroll(vertical: -60)
        map.controls[5].pressAction = .scroll(vertical: 60)
        return map
    }

    func testValidationRejectsZeroOverflowAndExtremeIntegersBeforeAllocating() throws {
        var allocations = 0
        var posted = 0
        let emitter = MacScrollEmitter(sourceFactory: { allocations += 1; return nil }, post: { _ in posted += 1 })
        for amount in [0, 601, -601, Int.min, Int.max] {
            XCTAssertThrowsError(try HostAction.scroll(vertical: amount).validate()) {
                XCTAssertEqual($0 as? MacScrollEmitterError, .invalidAmount)
            }
            XCTAssertThrowsError(try emitter.emit(vertical: amount))
        }
        for amount in [-600, -1, 1, 600] { XCTAssertNoThrow(try HostAction.scroll(vertical: amount).validate()) }
        XCTAssertEqual(allocations, 0)
        XCTAssertEqual(posted, 0)
    }

    func testNativeEventsHaveExactSignedPixelAmountAndNoHorizontalAxisOrModifiers() throws {
        var events: [CGEvent] = []
        let emitter = MacScrollEmitter(post: { events.append($0) })
        for amount in [60, -60, 1, -600] { try emitter.emit(vertical: amount) }
        XCTAssertEqual(events.map(\.type), Array(repeating: .scrollWheel, count: 4))
        XCTAssertEqual(events.map { $0.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) }, [60, -60, 1, -600])
        XCTAssertTrue(events.allSatisfy { $0.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == 0 })
        XCTAssertTrue(events.allSatisfy { $0.getIntegerValueField(.scrollWheelEventPointDeltaAxis3) == 0 })
        XCTAssertTrue(events.allSatisfy { $0.getIntegerValueField(.scrollWheelEventIsContinuous) == 1 })
        XCTAssertTrue(events.allSatisfy { $0.flags.isEmpty })
    }

    func testFactoryFlagsAreClearedAndSourceReusedWithoutSendingKeyboardUps() throws {
        var allocations = 0
        var amounts: [Int32] = []
        var events: [CGEvent] = []
        let emitter = MacScrollEmitter(sourceFactory: {
            allocations += 1
            return CGEventSource(stateID: .privateState)
        }, eventFactory: { source, amount in
            amounts.append(amount)
            let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1,
                                wheel1: amount, wheel2: 0, wheel3: 0)
            event?.flags = [.maskControl, .maskAlternate, .maskShift, .maskCommand, .maskSecondaryFn]
            return event
        }, post: { events.append($0) })
        try emitter.emit(vertical: 60)
        try emitter.emit(vertical: -60)
        XCTAssertEqual(allocations, 1)
        XCTAssertEqual(amounts, [60, -60])
        XCTAssertTrue(events.allSatisfy { $0.type == .scrollWheel && $0.flags.isEmpty })
    }

    func testEmitterFailuresPropagateAndNextNotchCanRecover() throws {
        var posted = 0
        let missingSource = MacScrollEmitter(sourceFactory: { nil }, post: { _ in posted += 1 })
        XCTAssertThrowsError(try missingSource.emit(vertical: 60)) {
            XCTAssertEqual($0 as? MacScrollEmitterError, .sourceUnavailable)
        }
        let missingEvent = MacScrollEmitter(eventFactory: { _, _ in nil }, post: { _ in posted += 1 })
        XCTAssertThrowsError(try missingEvent.emit(vertical: 60)) {
            XCTAssertEqual($0 as? MacScrollEmitterError, .eventUnavailable)
        }
        XCTAssertEqual(posted, 0)
        var fail = true
        let emitter = MacScrollEmitter(post: { _ in
            if fail { throw DeviceProtocolError.message("滚动发布测试失败") }
            posted += 1
        })
        XCTAssertThrowsError(try emitter.emit(vertical: 60))
        fail = false
        XCTAssertNoThrow(try emitter.emit(vertical: 60))
        XCTAssertEqual(posted, 1)
    }

    func testScrollRoundTripUsesInnerVersionSixAndKeepsOuterProfileTwo() throws {
        let map = scrollMap()
        XCTAssertEqual(map.version, 6)
        let encoded = try JSONEncoder().encode(map)
        XCTAssertEqual(try HostKeymap.decode(data: encoded), map)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let controls = try XCTUnwrap(object["controls"] as? [[String: Any]])
        let scroll = try XCTUnwrap(controls[4]["pressAction"] as? [String: Any])
        XCTAssertEqual((scroll["scroll"] as? [String: Int])?["vertical"], -60)
        let profile = HostProfile(name: "Scroll", keymap: map)
        XCTAssertEqual(profile.version, 2)
        XCTAssertEqual(try HostProfile.decode(data: JSONEncoder().encode(profile)), profile)
        for version in 1...5 {
            var old = object
            old["version"] = version
            XCTAssertThrowsError(try HostKeymap.decode(data: JSONSerialization.data(withJSONObject: old))) {
                XCTAssertEqual($0 as? HostKeymapError, .unsupportedVersion)
            }
        }
        var invalid = map
        invalid.controls[4].pressAction = .scroll(vertical: 0)
        XCTAssertThrowsError(try JSONEncoder().encode(invalid))
    }

    func testLegacyVersionsOneThroughFiveRetainExistingRequiredSchemas() throws {
        var maps = [HostKeymap.defaultKeymap]
        let target = ApplicationTarget(bundleIdentifier: "com.example.editor", path: "", name: "Editor")
        var v2 = maps[0]
        v2.controls[0].pressAction = .application(target)
        maps.append(v2)
        let item = NamedHostAction(name: "Editor", slot: 0, action: .application(target))
        var v3 = v2
        v3.actionLibrary = [item]
        v3.controls[0].pressAction = .library(item.id)
        maps.append(v3)
        var v4 = v3
        v4.layers = [HostLayer(id: 1)]
        maps.append(v4)
        var v5 = v4
        v5.controls[1].pressBehavior = .tap
        maps.append(v5)
        XCTAssertEqual(maps.map(\.version), [1, 2, 3, 4, 5])
        for map in maps { XCTAssertEqual(try HostKeymap.decode(data: JSONEncoder().encode(map)), map) }
    }

    func testLayerScrollRequiresSixAndRemovingScrollRestoresPreviousSchema() throws {
        var map = HostKeymap.defaultKeymap
        map.layers = [HostLayer(id: 1, controls: [ControlActionMap(index: 4, press: [], pressAction: .scroll(vertical: -60))])]
        XCTAssertEqual(map.version, 6)
        XCTAssertEqual(try HostKeymap.decode(data: JSONEncoder().encode(map)), map)
        map.layers[0].controls[0].pressAction = nil
        XCTAssertEqual(map.version, 4)
        map.layers = []
        XCTAssertEqual(map.version, 1)
        map.controls[0].doublePressAction = .scroll(vertical: 60)
        XCTAssertEqual(map.version, 6)
        map.controls[0].doublePressAction = nil
        map.controls[0].longPressAction = .scroll(vertical: 60)
        XCTAssertEqual(map.version, 6)
    }

    func testScrollCannotEnterLibraryOrMacroRunnerEvenWhenQueueIsBusy() throws {
        XCTAssertThrowsError(try NamedHostAction(name: "Scroll", slot: 0, action: .scroll(vertical: 60)).validate())
        let runner = HostActionRunner()
        try runner.enqueue(index: 4, action: .macro([.delay(1)]))
        XCTAssertThrowsError(try runner.enqueue(index: 4, action: .scroll(vertical: 60))) {
            XCTAssertEqual($0 as? HostActionError, .unsupportedMacroAction)
        }
    }

    func testRapidPulsesEmitEveryNotchImmediatelyWhileDictationIsHeld() throws {
        var map = scrollMap()
        let speech = [UInt8(0xE0), 0xE2, 0xE1, 0x19].map { KeyEntry(code: $0) }
        map.controls[0].press = speech
        var keys: [([KeyEntry], Bool)] = []
        var scrolling: [Int] = []
        let bridge = VendorKeyBridge(permissions: { (true, true) }, now: { 0 },
                                     scroll: { scrolling.append($0) }, emit: { entries, pressed, _ in keys.append((entries, pressed)) })
        bridge.synchronize(configuration: map, connected: true, online: true)
        bridge.receive(.init(index: 0, pressed: true))
        let indices = Array(repeating: [4, 4, 5, 4, 5, 5], count: 40).flatMap { $0 }
        for index in indices {
            bridge.receive(.init(index: index, pressed: true))
            bridge.receive(.init(index: index, pressed: false))
        }
        XCTAssertEqual(scrolling, indices.map { $0 == 4 ? -60 : 60 })
        XCTAssertEqual(keys.count, 1)
        XCTAssertEqual(keys.first?.0, speech)
        XCTAssertEqual(keys.first?.1, true)
        XCTAssertEqual(bridge.status.events, indices.count + 1)
        bridge.receive(.init(index: 0, pressed: false))
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(keys.last?.0, speech)
        XCTAssertEqual(keys.last?.1, false)
        XCTAssertNil(bridge.status.error)
    }

    func testScrollFailureCannotReleaseDictationAndNextPulseRecovers() {
        var map = scrollMap()
        map.controls[0].press = [0xE0, 0xE2, 0xE1, 0x19].map { KeyEntry(code: $0) }
        var keys: [Bool] = []
        var fail = true
        var scrolling: [Int] = []
        let bridge = VendorKeyBridge(permissions: { (true, true) }, now: { 0 }, scroll: {
            if fail { throw MacScrollEmitterError.eventUnavailable }
            scrolling.append($0)
        }, emit: { _, down, _ in keys.append(down) })
        bridge.synchronize(configuration: map, connected: true, online: true)
        bridge.receive(.init(index: 0, pressed: true))
        bridge.receive(.init(index: 4, pressed: true))
        XCTAssertNotNil(bridge.status.error)
        XCTAssertEqual(keys, [true])
        fail = false
        bridge.receive(.init(index: 4, pressed: true))
        XCTAssertEqual(scrolling, [-60])
        XCTAssertNil(bridge.status.error)
        XCTAssertEqual(keys, [true])
        bridge.receive(.init(index: 0, pressed: false))
        XCTAssertEqual(keys, [true, false])
    }

    func testScrollingBypassesUnrelatedMacroWaitAndPermissionLossStopsIt() {
        var map = scrollMap()
        map.controls[1].pressAction = .macro([.delay(10)])
        var granted = true
        var scrolling: [Int] = []
        let bridge = VendorKeyBridge(permissions: { (granted, granted) }, now: { 0 },
                                     scroll: { scrolling.append($0) }, emit: { _, _, _ in XCTFail("Unexpected keyboard event") })
        bridge.synchronize(configuration: map, connected: true, online: true)
        bridge.receive(.init(index: 1, pressed: true))
        for _ in 0..<50 { bridge.receive(.init(index: 4, pressed: true)) }
        XCTAssertEqual(scrolling.count, 50)
        granted = false
        bridge.refreshPermissions()
        bridge.receive(.init(index: 4, pressed: true))
        XCTAssertEqual(scrolling.count, 50)
        XCTAssertFalse(bridge.status.active)
    }
}
