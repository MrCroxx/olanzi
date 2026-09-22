import XCTest
@testable import OlanziCore

final class ProfileTests: XCTestCase {
    func testCatalogContainsExactlySupportedCodes() {
        XCTAssertEqual(Set(KeyCatalog.options.map(\.code)), Set((UInt8.min...UInt8.max).filter { DeviceProtocol.isAllowedKey($0) }))
        XCTAssertEqual(Set(KeyCatalog.options.map(\.code)).count, KeyCatalog.options.count)
    }
    func testImportRejectsUnknownVersionCodesAndMissingControls() {
        var profile = KeyProfile(name: "Test", codes: KeyCatalog.defaults)
        XCTAssertNoThrow(try profile.validate())
        profile.version = 2
        XCTAssertThrowsError(try profile.validate())
        profile.version = 1; profile.codes[0] = 2
        XCTAssertThrowsError(try profile.validate())
        profile.codes = [1]
        XCTAssertThrowsError(try profile.validate())
        profile.codes = KeyCatalog.defaults; profile.name = " "
        XCTAssertThrowsError(try profile.validate())
    }
    func testProfileRoundtripContainsKeysButNotFnSetting() throws {
        let profile = KeyProfile(name: "Test", codes: KeyCatalog.defaults)
        let bytes = try JSONEncoder().encode(profile)
        XCTAssertEqual(try JSONDecoder().decode(KeyProfile.self, from: bytes), profile)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertNil(object["fnEnabled"])
    }
}
