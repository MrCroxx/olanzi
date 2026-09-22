import XCTest
import OlanziCore
@testable import OlanziApp

@MainActor
final class HeartbeatSettingsTests: XCTestCase {
    func testIdlePreferencePersistsIndependentlyOfKeymapDraft() async throws {
        let name = "olanzi.idle-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = AppModel(demo: false, defaults: defaults)
        XCTAssertEqual(model.heartbeatIdleMinutes, 0)
        var snapshot = DeviceSnapshot()
        snapshot.hostKeymap = .defaultKeymap
        model.receive(snapshot)
        XCTAssertTrue(model.assign([KeyEntry(code: 0x04)], gesture: .press))
        let draft = model.draft
        model.setHeartbeatIdleMinutes(15)
        XCTAssertEqual(model.heartbeatIdleMinutes, 15)
        XCTAssertEqual(defaults.integer(forKey: "nativeHeartbeatIdleMinutes"), 15)
        XCTAssertEqual(model.draft, draft)
        XCTAssertEqual(AppModel(demo: false, defaults: defaults).heartbeatIdleMinutes, 15)
        model.setHeartbeatIdleMinutes(0)
        XCTAssertEqual(AppModel(demo: false, defaults: defaults).heartbeatIdleMinutes, 0)
    }

    func testInvalidPreferenceFallsBackToContinuousKeepalive() async throws {
        let name = "olanzi.idle-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(-1, forKey: "nativeHeartbeatIdleMinutes")
        let model = AppModel(demo: false, defaults: defaults)
        XCTAssertEqual(model.heartbeatIdleMinutes, 0)
        model.setHeartbeatIdleMinutes(7)
        XCTAssertEqual(model.heartbeatIdleMinutes, 0)
    }

    func testDemoDoesNotReadOrOverwriteRealKeepalivePreference() async throws {
        let name = "olanzi.idle-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(30, forKey: "nativeHeartbeatIdleMinutes")
        let model = AppModel(demo: true, defaults: defaults)
        XCTAssertEqual(model.heartbeatIdleMinutes, 0)
        model.setHeartbeatIdleMinutes(5)
        XCTAssertEqual(model.heartbeatIdleMinutes, 5)
        XCTAssertEqual(defaults.integer(forKey: "nativeHeartbeatIdleMinutes"), 30)
    }
}
