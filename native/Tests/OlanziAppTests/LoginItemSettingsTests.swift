import XCTest
import ServiceManagement
@testable import OlanziApp

@MainActor
final class LoginItemSettingsTests: XCTestCase {
    func testRegistrationApprovalAndCancellationFollowSystemState() async {
        var status = SMAppService.Status.notRegistered
        let settings = LoginItemSettings(readStatus: { status },
            register: { status = .requiresApproval }, unregister: { status = .notRegistered })
        XCTAssertFalse(settings.isRegistered)
        settings.setEnabled(true)
        XCTAssertEqual(settings.status, .requiresApproval)
        XCTAssertTrue(settings.isRegistered)
        settings.setEnabled(false)
        XCTAssertEqual(settings.status, .notRegistered)
        status = .enabled
        settings.refresh()
        XCTAssertTrue(settings.isRegistered)
        status = .notRegistered
        settings.refresh()
        XCTAssertFalse(settings.isRegistered)
    }

    func testFailuresDoNotOptimisticallyChangeStateAndRetryClearsError() async {
        var status = SMAppService.Status.enabled
        var shouldFail = true
        let settings = LoginItemSettings(readStatus: { status }, register: {}, unregister: {
            if shouldFail { throw NSError(domain: "LoginItemTest", code: 1) }
            status = .notRegistered
        })
        settings.setEnabled(false)
        XCTAssertTrue(settings.isRegistered)
        XCTAssertNotNil(settings.error)
        shouldFail = false
        settings.setEnabled(false)
        XCTAssertFalse(settings.isRegistered)
        XCTAssertNil(settings.error)
    }
}
