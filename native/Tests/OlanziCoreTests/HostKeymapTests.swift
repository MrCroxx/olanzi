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
        map.version = 2
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
}
