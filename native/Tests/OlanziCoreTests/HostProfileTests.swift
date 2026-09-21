import XCTest
@testable import OlanziCore

final class HostProfileTests: XCTestCase {
    func testLegacyImportPreservesIdentityAndExportsOnlyV2() throws {
        let old = KeyProfile(name: "旧配置", codes: DeviceProtocol.defaultCodes)
        let migrated = try HostProfile.decode(data: JSONEncoder().encode(old))
        XCTAssertEqual(migrated.id, old.id)
        XCTAssertEqual(migrated.name, old.name)
        XCTAssertEqual(migrated.version, 2)
        XCTAssertEqual(migrated.keymap.controls.map { $0.press[0].code }, old.codes)
        XCTAssertTrue(migrated.keymap.controls.allSatisfy { $0.doublePress == nil && $0.longPress == nil })
        let bytes = try JSONEncoder().encode(migrated)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 2)
        XCTAssertNil(json["codes"])
        XCTAssertNil(json["fnEnabled"])
        XCTAssertNotNil(json["keymap"])
        XCTAssertEqual(try HostProfile.decode(data: bytes), migrated)
    }

    func testLegacyImportRejectsBadVersionKeysCountsAndName() throws {
        var old = KeyProfile(name: "Test", codes: DeviceProtocol.defaultCodes)
        old.version = 3
        XCTAssertThrowsError(try HostProfile.decode(data: JSONEncoder().encode(old)))
        old.version = 1; old.codes[0] = 0x70
        XCTAssertThrowsError(try HostProfile.decode(data: JSONEncoder().encode(old)))
        old.codes = [1]
        XCTAssertThrowsError(try HostProfile.decode(data: JSONEncoder().encode(old)))
        old.codes = DeviceProtocol.defaultCodes; old.name = " \n "
        XCTAssertThrowsError(try HostProfile.decode(data: JSONEncoder().encode(old)))
        old.name = String(repeating: "a", count: 81)
        XCTAssertThrowsError(try HostProfile.decode(data: JSONEncoder().encode(old)))
        XCTAssertThrowsError(try HostProfile.decode(data: Data(repeating: 32, count: 32769)))
    }

    func testV2KeepsComboGesturesAndTiming() throws {
        let bindings = DeviceProtocol.defaultCodes.enumerated().map {
            KeyBinding(index: $0.offset, entries: [KeyEntry(code: $0.element)])
        }
        var map = try HostKeymap.fromDeviceBindings(bindings)
        map.controls[0].press = [KeyEntry(code: 0xE3), KeyEntry(code: 0x06)]
        map.controls[0].doublePress = []
        map.controls[1].longPress = [KeyEntry(code: 1)]
        map.doublePressWindow = 0.3; map.longPressThreshold = 0.8
        var profile = HostProfile(name: "组合手势", keymap: map)
        XCTAssertEqual(try HostProfile.decode(data: JSONEncoder().encode(profile)), profile)
        profile.version = 1
        XCTAssertThrowsError(try JSONEncoder().encode(profile))
        profile.version = 2; profile.keymap.controls.removeLast()
        XCTAssertThrowsError(try JSONEncoder().encode(profile))
    }
}
