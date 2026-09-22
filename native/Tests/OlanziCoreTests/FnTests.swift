import CoreGraphics
import IOKit.hidsystem
import XCTest
@testable import OlanziCore

private struct TestFnError: LocalizedError {
    var errorDescription: String? { "测试故障" }
}

private final class FakeFnBackend: FnBackend {
    var callbackError: String?
    var inputPermission: Bool? = true
    var accessibilityPermission = true
    var onReport: ((Int, [UInt8]) -> Void)?
    var onLost: ((String) -> Void)?
    var posts: [Bool] = []
    var openCount = 0
    var closeCount = 0
    var permissionChecks = 0
    var requests = 0
    var upAttempts = 0
    var failOpen = false
    var failDown = false
    var failedUpAttempts = 0

    func permissions() -> (input: Bool?, accessibility: Bool) {
        permissionChecks += 1
        return (inputPermission, accessibilityPermission)
    }
    func requestPermissions() { requests += 1 }
    func open(onReport: @escaping (Int, [UInt8]) -> Void,
              onLost: @escaping (String) -> Void) throws {
        if failOpen { throw TestFnError() }
        openCount += 1
        self.onReport = onReport
        self.onLost = onLost
        callbackError = nil
    }
    func postFn(pressed: Bool) throws {
        if pressed && failDown { throw TestFnError() }
        if !pressed {
            upAttempts += 1
            if failedUpAttempts > 0 {
                failedUpAttempts -= 1
                throw TestFnError()
            }
        }
        posts.append(pressed)
    }
    func close() throws { closeCount += 1 }
}

final class FnTests: XCTestCase {
    private let press: [UInt8] = [0, 0, 1, 0, 0, 0, 0, 0]
    private let release = [UInt8](repeating: 0, count: 8)

    func testDeniedPreflightsDoNotBlockIndependentAccessibilityRefresh() {
        var trusted = false
        var trustChecks = 0
        let backend = NativeFnBackend(checkInput: { kIOHIDAccessTypeUnknown },
                                      checkListening: { false }, checkPosting: { false },
                                      checkAccessibility: { trustChecks += 1; return trusted },
                                      probeListening: { false })
        XCTAssertEqual(backend.permissions().input, false)
        XCTAssertFalse(backend.permissions().accessibility)
        trusted = true
        XCTAssertTrue(backend.permissions().accessibility)
        trusted = false
        XCTAssertFalse(backend.permissions().accessibility)
        XCTAssertEqual(trustChecks, 4)
    }

    func testKeyboardProbeDetectsGrantWhileBothListeningPreflightsStayDenied() {
        var probeGranted = false
        let backend = NativeFnBackend(checkInput: { kIOHIDAccessTypeDenied },
                                      checkListening: { false }, checkPosting: { false },
                                      checkAccessibility: { false },
                                      probeListening: { probeGranted })
        XCTAssertEqual(backend.permissions().input, false)
        // 实测故障：同一进程的 HID/CG 预检仍拒绝，但键盘监听已可创建。
        probeGranted = true
        XCTAssertEqual(backend.permissions().input, true)
        XCTAssertFalse(backend.permissions().accessibility)
        probeGranted = false
        XCTAssertEqual(backend.permissions().input, false)
    }

    func testGrantedListeningPreflightDoesNotCreateRedundantKeyboardProbe() {
        let backend = NativeFnBackend(checkInput: { kIOHIDAccessTypeDenied },
                                      checkListening: { true }, checkPosting: { false },
                                      checkAccessibility: { false },
                                      probeListening: { XCTFail("已通过预检时不创建监听探针"); return false })
        XCTAssertEqual(backend.permissions().input, true)
    }

    func testHIDGrantAloneDoesNotHideUnavailableKeyboardListening() {
        let backend = NativeFnBackend(checkInput: { kIOHIDAccessTypeGranted },
                                      checkListening: { false }, checkPosting: { false },
                                      checkAccessibility: { false }, probeListening: { false })
        XCTAssertEqual(backend.permissions().input, false)
    }

    func testAccessibilityChangesAreDetectedWhilePostingPreflightRemainsFalse() {
        var trusted = false
        let backend = NativeFnBackend(checkInput: { kIOHIDAccessTypeGranted }, checkListening: { true },
                                      checkPosting: { false }, checkAccessibility: { trusted },
                                      probeListening: { false })
        XCTAssertFalse(backend.permissions().accessibility)
        trusted = true
        XCTAssertTrue(backend.permissions().accessibility)
        trusted = false
        XCTAssertFalse(backend.permissions().accessibility)
    }

    func testPostingAccessDoesNotClaimKeyboardListeningAccess() {
        let backend = NativeFnBackend(checkInput: { kIOHIDAccessTypeDenied }, checkListening: { false },
                                      checkPosting: { true }, checkAccessibility: { true },
                                      probeListening: { false })
        let permissions = backend.permissions()
        XCTAssertEqual(permissions.input, false)
        XCTAssertTrue(permissions.accessibility)
    }

    func testPermissionNavigationTargetsOnlyMissingPermissions() {
        XCTAssertEqual(FnStatus().missingPermissions, [.inputMonitoring, .accessibility])
        XCTAssertEqual(FnStatus(inputPermission: true, accessibilityPermission: false).missingPermissions, [.accessibility])
        XCTAssertEqual(FnStatus(inputPermission: false, accessibilityPermission: true).missingPermissions, [.inputMonitoring])
        XCTAssertTrue(FnStatus(inputPermission: true, accessibilityPermission: true).missingPermissions.isEmpty)
        XCTAssertTrue(InputPermission.inputMonitoring.settingsURL.absoluteString.hasSuffix("Privacy_ListenEvent"))
        XCTAssertTrue(InputPermission.accessibility.settingsURL.absoluteString.hasSuffix("Privacy_Accessibility"))
    }

    func testMissingPermissionErrorDoesNotReportGrantedPermission() {
        let backend = FakeFnBackend()
        backend.inputPermission = true
        backend.accessibilityPermission = false
        let bridge = MacFnBridge(backend: backend)
        bridge.synchronize(enabled: true, connected: true, online: true)
        XCTAssertTrue(bridge.status.error?.contains("辅助功能") == true)
        XCTAssertFalse(bridge.status.error?.contains("输入监控") == true)
        XCTAssertEqual(backend.requests, 0)
        backend.accessibilityPermission = true
        bridge.requestPermissions()
        XCTAssertTrue(bridge.status.active)
        XCTAssertNil(bridge.status.error)
        bridge.close()
    }

    func testPermissionRefreshAfterReturningFromSettingsWorksWhileOffline() {
        let backend = FakeFnBackend()
        backend.accessibilityPermission = false
        let bridge = MacFnBridge(backend: backend)
        bridge.synchronize(enabled: true, connected: true, online: true)
        XCTAssertNotNil(bridge.status.error)
        bridge.synchronize(enabled: true, connected: true, online: false)
        backend.accessibilityPermission = true
        bridge.refreshPermissions()
        XCTAssertEqual(bridge.status.accessibilityPermission, true)
        XCTAssertNil(bridge.status.error)
        XCTAssertFalse(bridge.status.active)
        XCTAssertEqual(backend.requests, 0)
        XCTAssertEqual(backend.openCount, 0)
        bridge.close()
    }

    func testDecodeExactKeyboardReports() {
        XCTAssertEqual(FnReport.decode(reportID: 3, data: press), true)
        XCTAssertEqual(FnReport.decode(reportID: 3, data: [3] + press), true)
        XCTAssertEqual(FnReport.decode(reportID: 3, data: release), false)
        XCTAssertEqual(FnReport.decode(reportID: 3, data: [3] + release), false)
        XCTAssertNil(FnReport.decode(reportID: 1, data: press))
        XCTAssertNil(FnReport.decode(reportID: 0x55, data: press))
        XCTAssertNil(FnReport.decode(reportID: 3, data: [2] + press))
        XCTAssertNil(FnReport.decode(reportID: 3, data: [0, 0, 1]))
        XCTAssertNil(FnReport.decode(reportID: 3, data: [0, 1, 1, 0, 0, 0, 0, 0]))
    }

    func testRolloverAndErrorSlotsDoNotTriggerFn() {
        XCTAssertEqual(FnReport.decode(reportID: 3, data: [0, 0, 1, 1, 1, 1, 1, 1]), false)
        XCTAssertEqual(FnReport.decode(reportID: 3, data: [0, 0, 1, 1, 0, 0, 0, 0]), false)
        XCTAssertEqual(FnReport.decode(reportID: 3, data: [0, 0, 1, 2, 0, 0, 0, 0]), false)
        XCTAssertEqual(FnReport.decode(reportID: 3, data: [0, 0, 1, 3, 0, 0, 0, 0]), false)
        // 其他正常键与一个自定义键可以共存。
        XCTAssertEqual(FnReport.decode(reportID: 3, data: [2, 0, 1, 4, 0, 0, 0, 0]), true)
    }

    func testModifierMergePreservesPhysicalFnAndOtherModifiers() {
        for hardware: CGEventFlags in [[], [.maskCommand, .maskShift],
                                        [.maskSecondaryFn, .maskAlternate, .maskControl]] {
            XCTAssertEqual(FnReport.flags(hardware: hardware, pressed: true), hardware.union(.maskSecondaryFn))
            XCTAssertEqual(FnReport.flags(hardware: hardware, pressed: false), hardware)
        }
    }

    func testOnlyAU05StandardInputInterfaceMatches() {
        XCTAssertTrue(NativeFnBackend.matches(vendor: 0xFFF1, product: 0xDD, usagePage: 12, usage: 1))
        XCTAssertTrue(NativeFnBackend.matches(vendor: 0xFFF1, product: 0xDD, usagePage: 1, usage: 6))
        XCTAssertFalse(NativeFnBackend.matches(vendor: 0xFFF1, product: 0xDD, usagePage: 0xFFFC, usage: 1))
        XCTAssertFalse(NativeFnBackend.matches(vendor: 0x05AC, product: 0xDD, usagePage: 1, usage: 6))
        XCTAssertFalse(NativeFnBackend.matches(vendor: 0xFFF1, product: 0xDE, usagePage: 12, usage: 1))
    }

    func testDefaultStatusDisabled() {
        let bridge = MacFnBridge()
        XCTAssertEqual(bridge.status, FnStatus())
        bridge.synchronize(enabled: false, connected: true, online: true)
        XCTAssertEqual(bridge.status, FnStatus())
    }

    func testHoldDuplicateAndRelease() {
        let backend = FakeFnBackend()
        let bridge = MacFnBridge(backend: backend)
        bridge.synchronize(enabled: true, connected: true, online: true)
        backend.onReport?(3, press)
        backend.onReport?(3, press)
        XCTAssertTrue(bridge.status.pressed)
        backend.onReport?(3, release)
        backend.onReport?(3, release)
        XCTAssertEqual(backend.posts, [true, false])
        XCTAssertEqual(bridge.status.events, 2)
        XCTAssertFalse(bridge.status.pressed)
    }

    func testNonKeyboardOrMalformedReportsCannotReleaseHeldFn() {
        let backend = FakeFnBackend()
        let bridge = MacFnBridge(backend: backend)
        bridge.synchronize(enabled: true, connected: true, online: true)
        backend.onReport?(3, press)
        backend.onReport?(1, release)
        backend.onReport?(3, [0, 0])
        backend.onReport?(3, [2] + release)
        XCTAssertEqual(backend.posts, [true])
        backend.onReport?(3, [3] + release)
        XCTAssertEqual(backend.posts, [true, false])
    }

    func testRolloverReleasesPriorHoldWithoutCreatingOne() {
        let backend = FakeFnBackend()
        let bridge = MacFnBridge(backend: backend)
        let rollover: [UInt8] = [0, 0, 1, 1, 1, 1, 1, 1]
        bridge.synchronize(enabled: true, connected: true, online: true)
        backend.onReport?(3, rollover)
        XCTAssertEqual(backend.posts, [])
        backend.onReport?(3, press)
        backend.onReport?(3, rollover)
        XCTAssertEqual(backend.posts, [true, false])
    }

    func testDisableOfflineUnknownDisconnectAndCloseRelease() {
        let endings: [(MacFnBridge) -> Void] = [
            { $0.synchronize(enabled: false, connected: true, online: true) },
            { $0.synchronize(enabled: true, connected: true, online: false) },
            { $0.synchronize(enabled: true, connected: true, online: nil) },
            { $0.synchronize(enabled: true, connected: false, online: nil) },
            { $0.close() },
        ]
        for end in endings {
            let backend = FakeFnBackend()
            let bridge = MacFnBridge(backend: backend)
            bridge.synchronize(enabled: true, connected: true, online: true)
            backend.onReport?(3, press)
            end(bridge)
            XCTAssertEqual(backend.posts, [true, false])
            XCTAssertFalse(bridge.status.active)
            XCTAssertFalse(bridge.status.pressed)
            XCTAssertEqual(backend.closeCount, 1)
        }
    }

    func testRemovalImmediatelyReleasesAndIgnoresFurtherReports() {
        let backend = FakeFnBackend()
        let bridge = MacFnBridge(backend: backend)
        bridge.synchronize(enabled: true, connected: true, online: true)
        backend.onReport?(3, press)
        backend.onLost?("设备已拔出")
        backend.onReport?(3, press)
        XCTAssertEqual(backend.posts, [true, false])
        XCTAssertFalse(bridge.status.active)
        bridge.pump()
        XCTAssertEqual(backend.closeCount, 1)
        XCTAssertEqual(bridge.status.error, "设备已拔出")
    }

    func testPermissionRetryDoesNotPromptAndEventuallyOpens() {
        var time: TimeInterval = 0
        let backend = FakeFnBackend()
        backend.inputPermission = false
        let bridge = MacFnBridge(backend: backend, now: { time })
        bridge.synchronize(enabled: true, connected: true, online: true)
        XCTAssertFalse(bridge.status.active)
        XCTAssertEqual(bridge.status.inputPermission, false)
        XCTAssertEqual(backend.requests, 0)
        XCTAssertEqual(backend.openCount, 0)
        backend.inputPermission = true
        time = 1
        bridge.pump()
        XCTAssertEqual(backend.openCount, 0)
        time = 2
        bridge.pump()
        XCTAssertTrue(bridge.status.active)
        XCTAssertEqual(backend.openCount, 1)
        bridge.requestPermissions()
        XCTAssertEqual(backend.requests, 1)
    }

    func testRevokingPermissionReleasesHeldFn() {
        var time: TimeInterval = 0
        let backend = FakeFnBackend()
        let bridge = MacFnBridge(backend: backend, now: { time })
        bridge.synchronize(enabled: true, connected: true, online: true)
        backend.onReport?(3, press)
        backend.accessibilityPermission = false
        time = 2
        bridge.pump()
        XCTAssertEqual(backend.posts, [true, false])
        XCTAssertFalse(bridge.status.active)
        XCTAssertEqual(bridge.status.accessibilityPermission, false)
        XCTAssertEqual(backend.closeCount, 1)
    }

    func testFailedReleaseRetainsSourceUntilRetrySucceeds() {
        let backend = FakeFnBackend()
        let bridge = MacFnBridge(backend: backend)
        bridge.synchronize(enabled: true, connected: true, online: true)
        backend.onReport?(3, press)
        backend.failedUpAttempts = 100
        bridge.synchronize(enabled: false, connected: true, online: true)
        XCTAssertTrue(bridge.status.pressed)
        XCTAssertEqual(backend.closeCount, 0)
        XCTAssertTrue(bridge.status.error?.contains("松开") == true)
        backend.failedUpAttempts = 0
        bridge.pump()
        XCTAssertFalse(bridge.status.pressed)
        XCTAssertEqual(backend.closeCount, 1)
        XCTAssertEqual(backend.posts, [true, false])
    }

    func testCloseRetriesTransientReleaseBeforeWorkerExit() {
        let backend = FakeFnBackend()
        let bridge = MacFnBridge(backend: backend)
        bridge.synchronize(enabled: true, connected: true, online: true)
        backend.onReport?(3, press)
        backend.failedUpAttempts = 1
        bridge.close()
        XCTAssertEqual(backend.upAttempts, 2)
        XCTAssertFalse(bridge.status.pressed)
        XCTAssertEqual(backend.posts, [true, false])
        XCTAssertEqual(backend.closeCount, 1)
    }

    func testFailedPressStillAttemptsReleaseAndReportsError() {
        let backend = FakeFnBackend()
        let bridge = MacFnBridge(backend: backend)
        bridge.synchronize(enabled: true, connected: true, online: true)
        backend.failDown = true
        backend.onReport?(3, press)
        XCTAssertEqual(backend.posts, [false])
        XCTAssertFalse(bridge.status.active)
        XCTAssertFalse(bridge.status.pressed)
        XCTAssertTrue(bridge.status.error?.contains("报文处理失败") == true)
    }

    func testLongHoldDoesNotUseArbitraryTimeout() {
        var time: TimeInterval = 0
        let backend = FakeFnBackend()
        let bridge = MacFnBridge(backend: backend, now: { time })
        bridge.synchronize(enabled: true, connected: true, online: true)
        backend.onReport?(3, press)
        time = 86_400
        bridge.pump()
        XCTAssertTrue(bridge.status.pressed)
        XCTAssertEqual(backend.posts, [true])
    }

    func testDemoNeverTouchesNativeBackend() {
        let backend = FakeFnBackend()
        let bridge = MacFnBridge(demo: true, backend: backend)
        bridge.synchronize(enabled: true, connected: true, online: true)
        bridge.requestPermissions()
        bridge.pump()
        bridge.close()
        XCTAssertTrue(bridge.status.enabled)
        XCTAssertFalse(bridge.status.active)
        XCTAssertEqual(bridge.status.events, 0)
        XCTAssertNil(bridge.status.inputPermission)
        XCTAssertEqual(backend.permissionChecks, 0)
        XCTAssertEqual(backend.openCount, 0)
        XCTAssertEqual(backend.requests, 0)
    }

    func testOpenFailureDoesNotActivateAndCanRetry() {
        var time: TimeInterval = 0
        let backend = FakeFnBackend()
        backend.failOpen = true
        let bridge = MacFnBridge(backend: backend, now: { time })
        bridge.synchronize(enabled: true, connected: true, online: true)
        XCTAssertFalse(bridge.status.active)
        XCTAssertNotNil(bridge.status.error)
        backend.failOpen = false
        time = 2
        bridge.pump()
        XCTAssertTrue(bridge.status.active)
        XCTAssertNil(bridge.status.error)
    }
}
