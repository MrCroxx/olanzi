import XCTest
@testable import OlanziCore

final class HostKeymapTests: XCTestCase {
    private func keymap() throws -> HostKeymap {
        try HostKeymap.fromDeviceBindings(DeviceProtocol.defaultCodes.enumerated().map {
            KeyBinding(index: $0.offset, entries: [KeyEntry(code: $0.element)])
        })
    }

    func testDeviceMigrationPreservesCombosAndSortsControls() throws {
        var bindings = DeviceProtocol.defaultCodes.enumerated().map {
            KeyBinding(index: $0.offset, entries: [KeyEntry(code: $0.element)])
        }
        bindings[1].entries = [KeyEntry(code: 0xE3), KeyEntry(code: 0x06)]
        let map = try HostKeymap.fromDeviceBindings(bindings.reversed())
        XCTAssertEqual(map.controls.map(\.index), Array(0..<6))
        XCTAssertEqual(map.controls[1].press, bindings[1].entries)
        XCTAssertTrue(map.controls.allSatisfy { $0.doublePress == nil && $0.longPress == nil })
        XCTAssertEqual(map.doublePressWindow, 0.25)
        XCTAssertEqual(map.longPressThreshold, 0.5)
    }

    func testEveryControlMustOccurExactlyOnce() throws {
        for indices in [[0,1,2,3,4], [0,1,2,3,4,4], [0,1,2,3,4,6], [-1,1,2,3,4,5], Array(0...6)] {
            let map = HostKeymap(controls: indices.map { ControlActionMap(index: $0, press: []) })
            XCTAssertThrowsError(try map.validate())
        }
        var map = try keymap()
        map.version = 99
        XCTAssertThrowsError(try map.validate())
    }

    func testTimingRejectsNonfiniteOutOfRangeAndInvertedWindows() throws {
        for (double, long) in [(0.14,0.5), (0.51,1), (0.2,0.29), (0.2,2.01), (0.4,0.4),
                               (Double.nan,0.5), (0.25,Double.infinity)] {
            var map = try keymap()
            map.doublePressWindow = double
            map.longPressThreshold = long
            XCTAssertThrowsError(try map.validate())
        }
        for (double, long) in [(0.15,0.3), (0.5,2)] {
            var map = try keymap()
            map.doublePressWindow = double
            map.longPressThreshold = long
            XCTAssertNoThrow(try map.validate())
        }
    }

    func testAllActionsUseEmitterValidationAndWheelHasNoGestures() throws {
        for entries in [[KeyEntry(type: 3, code: 0x28)], [KeyEntry(code: 0x70)],
                        [KeyEntry(code: 0xFF)], Array(repeating: KeyEntry(code: 4), count: 25)] {
            var map = try keymap()
            map.controls[0].press = entries
            XCTAssertThrowsError(try map.validate())
            map = try keymap(); map.controls[0].doublePress = entries
            XCTAssertThrowsError(try map.validate())
            map = try keymap(); map.controls[0].longPress = entries
            XCTAssertThrowsError(try map.validate())
        }
        for index in [4,5] {
            var map = try keymap()
            map.controls[index].doublePress = []
            XCTAssertThrowsError(try map.validate())
            map.controls[index].doublePress = nil
            map.controls[index].longPress = []
            XCTAssertThrowsError(try map.validate())
        }
        var map = try keymap()
        map.controls[0].press = []
        map.controls[1].doublePress = [KeyEntry(code: 1)]
        map.controls[3].longPress = []
        XCTAssertNoThrow(try map.validate())
    }

    func testDecodeValidatesAndPreservesOptionalEmptyAction() throws {
        var map = try keymap()
        map.controls[1].doublePress = []
        map.controls[2].longPress = [KeyEntry(code: 0x28)]
        XCTAssertEqual(try HostKeymap.decode(data: JSONEncoder().encode(map)), map)
        map.controls[5].doublePress = []
        XCTAssertThrowsError(try HostKeymap.decode(data: JSONEncoder().encode(map)))
        XCTAssertThrowsError(try HostKeymap.decode(data: Data(repeating: 32, count: 32769)))
    }
    func testLegacyControlWithoutLongPressBehaviorDefaultsToHold() throws {
        var map = try keymap()
        map.controls[0].longPress = [KeyEntry(code: 1)]
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(map)) as? [String: Any])
        var controls = try XCTUnwrap(object["controls"] as? [[String: Any]])
        for index in controls.indices { controls[index].removeValue(forKey: "longPressBehavior") }
        object["controls"] = controls
        let decoded = try HostKeymap.decode(data: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded, map)
        XCTAssertTrue(decoded.controls.allSatisfy { $0.longPressBehavior == .hold })
    }

    func testLongPressBehaviorSurvivesHostAndProfileRoundTrips() throws {
        var map = try keymap()
        map.controls[0].longPress = [KeyEntry(code: 0xE3), KeyEntry(code: 0x06)]
        map.controls[0].longPressBehavior = .tap
        map.controls[1].longPress = [KeyEntry(code: 1)]
        XCTAssertEqual(try HostKeymap.decode(data: JSONEncoder().encode(map)), map)
        let profile = HostProfile(name: "长按短按一次", keymap: map)
        XCTAssertEqual(try HostProfile.decode(data: JSONEncoder().encode(profile)), profile)
        XCTAssertEqual(profile.keymap.controls[1].longPressBehavior, .hold)
    }

    func testUnknownBehaviorAndRotaryTapModeAreRejected() throws {
        let map = try keymap()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(map)) as? [String: Any])
        var controls = try XCTUnwrap(object["controls"] as? [[String: Any]])
        controls[0]["longPressBehavior"] = "repeat"
        object["controls"] = controls
        XCTAssertThrowsError(try HostKeymap.decode(data: JSONSerialization.data(withJSONObject: object)))
        for index in [4, 5] {
            var invalid = map
            invalid.controls[index].longPressBehavior = .tap
            XCTAssertThrowsError(try invalid.validate()) { XCTAssertEqual($0 as? HostKeymapError, .unsupportedGesture) }
        }
    }

}
