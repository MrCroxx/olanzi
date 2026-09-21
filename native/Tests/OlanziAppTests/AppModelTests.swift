import XCTest
import OlanziCore
@testable import OlanziApp

/// 只注入快照与隔离的 UserDefaults，永不 start、访问真实设备、写实际配置或展示窗口。
@MainActor
final class AppModelTests: XCTestCase {
    func testLanguagePreferenceDefaultsToSystemPersistsAndDoesNotChangeDraftOrDevice() async throws {
        let suite = "olanzi-language-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var permissionReads = 0
        let model = AppModel(demo: false, defaults: defaults, readPermissions: {
            permissionReads += 1
            return FnStatus()
        })
        XCTAssertEqual(model.language, .system)
        var state = snapshot(initialKeymap())
        state.connected = true
        state.online = true
        state.battery = DeviceBattery(millivolts: 3318, percentage: 10, isCharging: true)
        model.receive(state)
        model.selected = 2
        model.gesture = .doublePress
        model.assign(0x28)
        model.saveProfile(name: "我的中文配置")
        let draft = model.draft
        let profile = try XCTUnwrap(model.profiles.first)
        let profileData = defaults.data(forKey: "nativeHostProfiles")
        var menuUpdates = 0
        model.didChange = { menuUpdates += 1 }
        model.language = .english
        XCTAssertEqual(menuUpdates, 1)
        XCTAssertEqual(defaults.string(forKey: "nativeAppLanguage"), AppLanguage.english.rawValue)
        XCTAssertEqual(model.draft, draft)
        XCTAssertEqual(model.device.hostKeymap, state.hostKeymap)
        XCTAssertEqual(model.device.connected, true)
        XCTAssertEqual(model.device.battery, state.battery)
        XCTAssertEqual(model.selected, 2)
        XCTAssertEqual(model.gesture, .doublePress)
        XCTAssertEqual(model.profiles.first, profile)
        XCTAssertEqual(model.profiles.first?.name, "我的中文配置")
        XCTAssertEqual(defaults.data(forKey: "nativeHostProfiles"), profileData)
        XCTAssertEqual(permissionReads, 0)
        XCTAssertFalse(model.applying)
        XCTAssertEqual(model.status, model.l("Vibe Key 已连接"))
        XCTAssertNotEqual(model.status, "Vibe Key 已连接")
        XCTAssertNotEqual(model.batteryText, "10% · 充电中")
        XCTAssertNotEqual(model.notice, "配置已保存在这台 Mac。")
        XCTAssertEqual(AppModel(demo: false, defaults: defaults).language, .english)
        model.language = .english
        XCTAssertEqual(menuUpdates, 1)
        model.language = .system
        XCTAssertEqual(AppModel(demo: false, defaults: defaults).language, .system)
    }

    func testLanguageSwitchPreservesPendingSaveAndRetranslatesExistingFailure() async throws {
        let model = initializedModel()
        model.assign(0x68)
        model.apply()
        let submittedID = model.submittedID
        let draft = model.draft
        model.language = .english
        XCTAssertEqual(model.submittedID, submittedID)
        XCTAssertEqual(model.draft, draft)
        XCTAssertTrue(model.applying)
        let error = "当前不支持类型 0x03 的设备键位，只支持普通键盘类型 0x02。"
        model.receive(try completedSnapshot(initialKeymap(), model: model, error: error))
        let englishNotice = try XCTUnwrap(model.notice)
        XCTAssertFalse(englishNotice.contains("草稿"))
        XCTAssertFalse(englishNotice.contains("不支持"))
        XCTAssertTrue(englishNotice.contains("0x03"))
        model.language = .simplifiedChinese
        XCTAssertEqual(model.notice, "保存未完成，草稿已保留。" + error)
        XCTAssertEqual(model.draft, draft)
        XCTAssertFalse(model.applying)
    }

    func testDemoLanguageChangesDoNotPersistPreferences() async throws {
        let suite = "olanzi-demo-language-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(AppLanguage.simplifiedChinese.rawValue, forKey: "nativeAppLanguage")
        let model = AppModel(demo: true, defaults: defaults)
        model.language = .english
        XCTAssertEqual(defaults.string(forKey: "nativeAppLanguage"), AppLanguage.simplifiedChinese.rawValue)
        XCTAssertEqual(model.displayError("/Users/test/我的中文配置.json"), "/Users/test/我的中文配置.json")
        XCTAssertNotEqual(model.gestureTitle(.doublePress), AssignmentGesture.doublePress.rawValue)
        XCTAssertNotEqual(model.controlName(0), KeyCatalog.controlNames[0])
        XCTAssertNotEqual(model.categoryTitle("修饰键"), "修饰键")
        XCTAssertNotEqual(model.keyLabel(0xE1), "左 Shift")
    }

    func testBatteryDisplayHidesPreviousReadingWhenDeviceGoesOffline() async {
        let model = AppModel(demo: true, language: .simplifiedChinese)
        var state = DeviceSnapshot()
        state.connected = true
        state.online = true
        state.battery = DeviceBattery(millivolts: 3318, percentage: 10)
        model.receive(state)
        XCTAssertEqual(model.batteryText, "10%")
        XCTAssertTrue(model.batteryLow)
        state.battery = DeviceBattery(millivolts: 3318, percentage: 10, isCharging: true)
        model.receive(state)
        XCTAssertEqual(model.batteryText, "10% · 充电中")
        // 离线快照即使误带上次读数，也不能把历史电量当作实时值显示。
        state.online = false
        model.receive(state)
        XCTAssertEqual(model.batteryText, "电量 —")
        XCTAssertFalse(model.batteryLow)
        state.online = true
        state.battery = nil
        state.batteryError = "查询超时"
        model.receive(state)
        XCTAssertEqual(model.batteryText, "电量 —")
        XCTAssertTrue(model.batteryHelp.contains("查询超时"))
    }

    func testPermissionTimerRefreshesWithoutActivationAndRejectsStaleDeviceStatus() async throws {
        let suite = "olanzi-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var granted = false
        var checks = 0
        var nextCheck: XCTestExpectation?
        let model = AppModel(demo: false, language: .simplifiedChinese, defaults: defaults, permissionPollInterval: 0.02) {
            checks += 1
            nextCheck?.fulfill()
            nextCheck = nil
            return FnStatus(inputPermission: granted, accessibilityPermission: granted)
        }
        defer { model.stopPermissionMonitoring() }
        // 仅启动权限定时器，设备线程不启动；模拟查询阻塞或应用不在前台。
        model.startPermissionMonitoring()
        XCTAssertEqual(checks, 1)
        XCTAssertTrue(model.needsPermissionSetup)
        model.startPermissionMonitoring()
        XCTAssertEqual(checks, 1)
        granted = true
        let authorized = expectation(description: "定时器自动发现新授权，无需激活窗口")
        nextCheck = authorized
        await fulfillment(of: [authorized], timeout: 1)
        XCTAssertFalse(model.needsPermissionSetup)
        var stale = DeviceSnapshot()
        stale.fn = FnStatus(inputPermission: false, accessibilityPermission: false)
        model.receive(stale)
        XCTAssertFalse(model.needsPermissionSetup)
        XCTAssertEqual(model.permissionStatus.inputPermission, true)
        model.loadDefaults()
        let draft = model.keymap
        granted = false
        let revoked = expectation(description: "定时器发现撤权并回到欢迎页")
        nextCheck = revoked
        await fulfillment(of: [revoked], timeout: 1)
        XCTAssertTrue(model.needsPermissionSetup)
        XCTAssertEqual(model.keymap, draft)
        model.stopPermissionMonitoring()
        let stopped = expectation(description: "停止后不继续检测")
        stopped.isInverted = true
        nextCheck = stopped
        await fulfillment(of: [stopped], timeout: 0.1)
    }

    func testDemoDoesNotStartPermissionPollingOrQuerySystemAccess() async {
        let model = AppModel(demo: true, language: .simplifiedChinese, permissionPollInterval: 0.01) {
            XCTFail("演示模式不能调用系统权限查询")
            return FnStatus()
        }
        model.startPermissionMonitoring()
        model.refreshPermissions()
        XCTAssertNil(model.polledPermissions)
        model.stopPermissionMonitoring()
    }

    func testPermissionSetupGatesWorkspaceUntilBothPermissionsAreGranted() async throws {
        let suite = "olanzi-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(demo: false, language: .simplifiedChinese, defaults: defaults)
        XCTAssertTrue(model.needsPermissionSetup)
        XCTAssertTrue(model.isCheckingPermissions)
        var state = DeviceSnapshot()
        state.error = "设备初始化失败"
        state.fn = FnStatus(inputPermission: false, accessibilityPermission: false)
        model.receive(state)
        XCTAssertTrue(model.needsPermissionSetup)
        XCTAssertFalse(model.isCheckingPermissions)
        XCTAssertEqual(model.permissionButtonTitle, "打开输入监控设置")
        state.fn.inputPermission = true
        model.receive(state)
        XCTAssertTrue(model.needsPermissionSetup)
        XCTAssertEqual(model.permissionButtonTitle, "打开辅助功能设置")
        state.fn.accessibilityPermission = true
        model.receive(state)
        XCTAssertFalse(model.needsPermissionSetup)
        // 设备初始化错误不应伪装成权限错误，授权完成后由工作台处理。
        XCTAssertEqual(model.device.error, "设备初始化失败")
        model.loadDefaults()
        let draft = model.keymap
        state.fn.inputPermission = false
        model.receive(state)
        XCTAssertTrue(model.needsPermissionSetup)
        XCTAssertEqual(model.keymap, draft)
        state.fn.inputPermission = true
        model.receive(state)
        XCTAssertFalse(model.needsPermissionSetup)
        XCTAssertEqual(model.keymap, draft)
    }

    func testDemoWorkspaceDoesNotRequireSystemPermissions() async {
        let model = AppModel(demo: true, language: .simplifiedChinese)
        XCTAssertFalse(model.needsPermissionSetup)
        XCTAssertFalse(model.isCheckingPermissions)
    }

    private func initialKeymap() -> HostKeymap {
        HostKeymap(controls: KeyCatalog.defaults.enumerated().map {
            ControlActionMap(index: $0.offset, press: [KeyEntry(code: $0.element)])
        })
    }

    private func snapshot(_ map: HostKeymap?, busy: Bool = false, error: String? = nil) -> DeviceSnapshot {
        var value = DeviceSnapshot()
        value.demo = true
        value.hostKeymap = map
        value.busy = busy
        value.error = error
        return value
    }

    private func completedSnapshot(_ map: HostKeymap, model: AppModel,
                                   error: String? = nil, deviceError: String? = nil) throws -> DeviceSnapshot {
        var value = snapshot(map, error: deviceError)
        value.hostSaveResult = HostSaveResult(requestID: try XCTUnwrap(model.submittedID), error: error)
        return value
    }

    private func initializedModel() -> AppModel {
        let model = AppModel(demo: true, language: .simplifiedChinese)
        model.receive(snapshot(initialKeymap()))
        return model
    }

    func testEditingWaitsForInitialHostConfiguration() async {
        let model = AppModel(demo: true, language: .simplifiedChinese)
        model.assign(0x68)
        XCTAssertFalse(model.canEdit)
        XCTAssertFalse(model.hasDraft)
        XCTAssertNil(model.keymap)
    }

    func testFirstUseProvidesEditableDefaultOfflineAndOnlyAcknowledgedSaveActivatesIt() async throws {
        let model = AppModel(demo: true, language: .simplifiedChinese)
        var missing = snapshot(nil)
        missing.hostConfigurationMissing = true
        model.receive(missing)
        XCTAssertFalse(model.online)
        XCTAssertTrue(model.canEdit)
        XCTAssertTrue(model.hasDraft)
        XCTAssertEqual(model.keymap, initialKeymap())
        XCTAssertNil(model.device.hostKeymap)
        // 默认草稿无需先修改一个键，也能直接提交；保存成功前不能当成已生效。
        model.apply()
        XCTAssertTrue(model.applying)
        XCTAssertNil(model.device.hostKeymap)
        model.receive(missing)
        XCTAssertTrue(model.applying)
        model.receive(try completedSnapshot(initialKeymap(), model: model))
        XCTAssertFalse(model.applying)
        XCTAssertFalse(model.hasDraft)
        XCTAssertEqual(model.device.hostKeymap, initialKeymap())
    }

    func testUnsupportedDeviceSnapshotDoesNotBlockFirstUseOrOverwriteDraft() async {
        let model = AppModel(demo: true, language: .simplifiedChinese)
        var missing = snapshot(nil)
        missing.hostConfigurationMissing = true
        model.receive(missing)
        model.assign(0x68)
        missing.connected = true
        missing.online = true
        missing.keys = initialKeymap().controls.map { KeyBinding(index: $0.index, entries: $0.press) }
        missing.keys[4].entries = [KeyEntry(type: 3, code: 4)]
        model.receive(missing)
        XCTAssertEqual(model.code(0), 0x68)
        XCTAssertTrue(model.canEdit)
        XCTAssertNil(model.device.hostKeymap)
        model.discard()
        XCTAssertEqual(model.keymap, initialKeymap())
        XCTAssertTrue(model.canEdit)
        XCTAssertTrue(model.hasDraft)
        XCTAssertEqual(model.device.keys, missing.keys)
    }

    func testOptionalDeviceImportPreservesDraftOnUnsupportedActionThenImportsWithoutSaving() async throws {
        let model = initializedModel()
        model.assign(0x68)
        let edited = model.keymap
        var hardware = snapshot(initialKeymap())
        hardware.connected = true
        hardware.online = true
        hardware.keys = initialKeymap().controls.map { KeyBinding(index: $0.index, entries: $0.press) }
        hardware.keys[4].entries = [KeyEntry(type: 3, code: 4)]
        model.receive(hardware)
        model.importDeviceBindings()
        XCTAssertEqual(model.keymap, edited)
        XCTAssertEqual(model.device.hostKeymap, initialKeymap())
        XCTAssertTrue(model.notice?.contains("顺时针") == true)
        XCTAssertTrue(model.notice?.contains("0x03") == true)
        hardware.keys[4].entries = [KeyEntry(code: 0x69)]
        model.receive(hardware)
        model.importDeviceBindings()
        XCTAssertEqual(model.code(4), 0x69)
        XCTAssertTrue(model.hasDraft)
        XCTAssertFalse(model.applying)
        XCTAssertEqual(model.device.hostKeymap, initialKeymap())
    }

    func testInitializedConfigurationCanBeEditedAndSavedOffline() async throws {
        let model = initializedModel()
        XCTAssertFalse(model.online)
        XCTAssertTrue(model.canEdit)
        model.assign(0x68)
        let pending = try XCTUnwrap(model.keymap)
        model.apply()
        XCTAssertTrue(model.applying)
        model.receive(snapshot(initialKeymap(), busy: true))
        model.receive(try completedSnapshot(pending, model: model))
        XCTAssertFalse(model.applying)
        XCTAssertFalse(model.hasDraft)
        XCTAssertEqual(model.code(0), 0x68)
    }

    func testCombinationsEditEveryPressGestureAndOnlyActivateAfterAcknowledgedSave() async throws {
        let model = initializedModel()
        let action = [KeyEntry(code: 0xE0), KeyEntry(code: 0xE2), KeyEntry(code: 0xE3), KeyEntry(code: 0x0C)]
        var expected = initialKeymap()
        for index in 0..<4 {
            for gesture in AssignmentGesture.allCases {
                XCTAssertTrue(model.assign(action, index: index, gesture: gesture))
                switch gesture {
                case .press: expected.controls[index].press = action
                case .doublePress: expected.controls[index].doublePress = action
                case .longPress: expected.controls[index].longPress = action
                }
                XCTAssertEqual(model.keymap, expected)
                XCTAssertEqual(model.entries(index, gesture: gesture), action)
                XCTAssertEqual(model.label(index, gesture: gesture), "⌃⌥⌘ I")
                XCTAssertEqual(model.device.hostKeymap, initialKeymap())
                XCTAssertFalse(model.applying)
                XCTAssertNil(model.submittedID)
            }
        }
        model.saveProfile(name: "组合键配置")
        let encoded = try JSONEncoder().encode(XCTUnwrap(model.profiles.first))
        XCTAssertEqual(try HostProfile.decode(data: encoded).keymap, expected)
        model.apply()
        XCTAssertTrue(model.applying)
        XCTAssertEqual(model.device.hostKeymap, initialKeymap())
        model.receive(try completedSnapshot(expected, model: model))
        XCTAssertFalse(model.hasDraft)
        XCTAssertEqual(model.device.hostKeymap, expected)
    }

    func testRecordedCombinationUsesCapturedTargetEvenAfterSelectionChanges() async {
        let model = initializedModel()
        model.selected = 3
        model.gesture = .longPress
        let capturedIndex = model.selected
        let capturedGesture = model.gesture
        model.selected = 1
        model.gesture = .doublePress
        let action = [KeyEntry(code: 0xE3), KeyEntry(code: 0x06)]
        XCTAssertTrue(model.assign(action, index: capturedIndex, gesture: capturedGesture))
        XCTAssertEqual(model.entries(3, gesture: .longPress), action)
        XCTAssertNil(model.entries(1, gesture: .doublePress))
        XCTAssertEqual(model.selected, 1)
        XCTAssertEqual(model.gesture, .doublePress)
        XCTAssertEqual(model.code(3), initialKeymap().controls[3].press[0].code)
        // 即使外部传入长按，旋转目标也只能写主要动作。
        for index in [4, 5] {
            XCTAssertTrue(model.assign(action, index: index, gesture: .longPress))
            XCTAssertEqual(model.entries(index), action)
            XCTAssertNil(model.entries(index, gesture: .doublePress))
            XCTAssertNil(model.entries(index, gesture: .longPress))
        }
        XCTAssertFalse(model.applying)
    }

    func testInvalidCombinationsPreserveExistingDraftAndPendingSave() async {
        let model = initializedModel()
        model.assign(0x68)
        let edited = model.draft
        model.apply()
        let requestID = model.submittedID
        let invalid: [[KeyEntry]] = [
            [], [KeyEntry(code: 0xE3), KeyEntry(type: 3, code: 4)],
            [KeyEntry(code: 0xE3), KeyEntry(code: 0x70)],
            Array(repeating: KeyEntry(code: 0x04), count: 25)
        ]
        for action in invalid {
            XCTAssertFalse(model.assign(action, index: 2, gesture: .doublePress))
            XCTAssertEqual(model.draft, edited)
            XCTAssertEqual(model.device.hostKeymap, initialKeymap())
            XCTAssertEqual(model.submittedID, requestID)
            XCTAssertNotNil(model.notice)
            XCTAssertTrue(model.applying)
        }
        XCTAssertFalse(model.assign([KeyEntry(code: 0x28)], index: 99, gesture: .press))
        XCTAssertEqual(model.draft, edited)
        // 显式不执行动作仍有一项，不能与空录制混淆。
        XCTAssertTrue(model.assign([KeyEntry(code: 0)], index: 2, gesture: .doublePress))
        XCTAssertEqual(model.entries(2, gesture: .doublePress), [KeyEntry(code: 0)])
    }

    func testCombinationPreviewCompactsLeftModifiersButPreservesRightModifierMeaning() async {
        let model = initializedModel()
        let left = [KeyEntry(code: 0xE0), KeyEntry(code: 0xE2), KeyEntry(code: 0xE3), KeyEntry(code: 0x0C)]
        XCTAssertEqual(model.actionLabel(entries: left), "⌃⌥⌘ I")
        XCTAssertEqual(AppModel.actionLabel(left), "左 Control + 左 Option + 左 Command + I")
        XCTAssertEqual(model.actionLabel(entries: [KeyEntry(code: 0xE3)]), "左 Command")
        XCTAssertEqual(model.actionLabel(entries: [KeyEntry(code: 0xE7), KeyEntry(code: 0x0C)]), "右 Command + I")
        XCTAssertEqual(model.actionLabel(entries: [KeyEntry(code: 0xE1), KeyEntry(code: 0xE7), KeyEntry(code: 0x0C)]), "⇧ 右 Command + I")
        XCTAssertEqual(model.actionLabel(entries: [KeyEntry(code: 0xE0), KeyEntry(code: 0xE3)]), "⌃⌘")
        XCTAssertEqual(model.actionLabel(entries: nil), "关闭")
        XCTAssertEqual(model.actionLabel(entries: [KeyEntry(code: 0)]), "不执行动作")
        model.language = .english
        XCTAssertEqual(model.actionLabel(entries: left), "⌃⌥⌘ I")
        XCTAssertEqual(model.actionLabel(entries: [KeyEntry(code: 0xE7), KeyEntry(code: 0x0C)]), model.keyLabel(0xE7) + " + I")
        XCTAssertFalse(model.actionLabel(entries: [KeyEntry(code: 0xE7), KeyEntry(code: 0x0C)]).contains("右"))
    }

    func testDisabledGestureDiffersFromEnabledNoOp() async {
        let model = initializedModel()
        for gesture in [AssignmentGesture.doublePress, .longPress] {
            model.gesture = gesture
            XCTAssertNil(model.entries(0, gesture: gesture))
            XCTAssertEqual(model.label(0, gesture: gesture), "关闭")
            model.assign(0)
            XCTAssertEqual(model.entries(0, gesture: gesture), [KeyEntry(code: 0)])
            XCTAssertEqual(model.label(0, gesture: gesture), "不执行动作")
            XCTAssertTrue(model.hasDraft)
            model.disableGesture()
            XCTAssertNil(model.entries(0, gesture: gesture))
            XCTAssertFalse(model.hasDraft)
        }
    }

    func testRotationSelectsOnlyItsPressAction() async {
        let model = initializedModel()
        for index in [4, 5] {
            model.gesture = .longPress
            model.selected = index
            XCTAssertEqual(model.gesture, .press)
            model.assign(0x68)
            XCTAssertEqual(model.code(index), 0x68)
            XCTAssertNil(model.entries(index, gesture: .doublePress))
            XCTAssertNil(model.entries(index, gesture: .longPress))
        }
    }

    func testUnsupportedMacKeyCannotEnterDraft() async {
        let model = initializedModel()
        for code: UInt8 in 0x70...0x73 {
            XCTAssertFalse(model.isSupported(code))
            model.assign(code)
            XCTAssertFalse(model.hasDraft)
            XCTAssertNotNil(model.notice)
        }
        XCTAssertEqual(model.code(0), 1)
    }

    func testHardwareRefreshDoesNotReplaceHostDraft() async throws {
        let model = initializedModel()
        model.gesture = .doublePress
        model.assign(0x68)
        let edited = try XCTUnwrap(model.keymap)
        var refreshed = snapshot(initialKeymap())
        refreshed.keys = (0..<6).map { KeyBinding(index: $0, entries: [KeyEntry(code: 0x29)]) }
        refreshed.connected = true
        refreshed.online = true
        model.receive(refreshed)
        XCTAssertEqual(model.keymap, edited)
        XCTAssertEqual(model.entries(0, gesture: .doublePress), [KeyEntry(code: 0x68)])
        XCTAssertEqual(model.code(0), 1)
    }

    func testNewEditsSurviveCompletionOfEarlierSave() async throws {
        let model = initializedModel()
        model.assign(0x68)
        let saving = try XCTUnwrap(model.keymap)
        model.apply()
        model.receive(snapshot(initialKeymap(), busy: true))
        model.assign(0x69)
        model.receive(try completedSnapshot(saving, model: model))
        XCTAssertFalse(model.applying)
        XCTAssertTrue(model.hasDraft)
        XCTAssertEqual(model.code(0), 0x69)
        XCTAssertEqual(model.device.hostKeymap, saving)
    }

    func testRevertingToOldValueDuringSaveRemainsAnUnsavedEdit() async throws {
        let model = initializedModel()
        model.assign(0x68)
        let saving = try XCTUnwrap(model.keymap)
        model.apply()
        // 此时回到旧快照的值仍是新意图，不能被刚提交的新值覆盖。
        model.assign(1)
        XCTAssertTrue(model.hasDraft)
        model.receive(snapshot(initialKeymap(), busy: true))
        model.receive(try completedSnapshot(saving, model: model))
        XCTAssertTrue(model.hasDraft)
        XCTAssertEqual(model.code(0), 1)
        XCTAssertEqual(model.device.hostKeymap, saving)
    }

    func testSuccessfulHostSaveIsNotRejectedByUnrelatedDeviceError() async throws {
        let model = initializedModel()
        model.assign(0x68)
        let saving = try XCTUnwrap(model.keymap)
        model.apply()
        model.receive(snapshot(initialKeymap(), busy: true))
        model.receive(try completedSnapshot(saving, model: model, deviceError: "接收器离线"))
        XCTAssertFalse(model.applying)
        XCTAssertFalse(model.hasDraft)
        XCTAssertEqual(model.notice, "键位已保存到本机。")
        XCTAssertEqual(model.device.error, "接收器离线")
    }

    func testFailedHostSaveRetainsDraftAndPreviousConfiguration() async throws {
        let model = initializedModel()
        model.assign(0x68)
        let edited = try XCTUnwrap(model.keymap)
        model.apply()
        model.receive(snapshot(initialKeymap(), busy: true))
        model.receive(try completedSnapshot(initialKeymap(), model: model, error: "磁盘写入失败", deviceError: "接收器离线"))
        XCTAssertFalse(model.applying)
        XCTAssertTrue(model.hasDraft)
        XCTAssertEqual(model.keymap, edited)
        XCTAssertEqual(model.device.hostKeymap, initialKeymap())
        XCTAssertTrue(model.notice?.contains("草稿已保留") == true)
        XCTAssertTrue(model.notice?.contains("磁盘写入失败") == true)
        XCTAssertFalse(model.notice?.contains("接收器离线") == true)
    }

    func testPeriodicSnapshotBeforeBusyDoesNotCompletePendingSave() async {
        let model = initializedModel()
        model.assign(0x68)
        model.apply()
        model.receive(snapshot(initialKeymap()))
        XCTAssertTrue(model.applying)
        XCTAssertTrue(model.hasDraft)
    }

    func testGestureProfilePreservesTimingsAndActionsOffline() async throws {
        let model = initializedModel()
        var configuration = initialKeymap()
        configuration.doublePressWindow = 0.3
        configuration.longPressThreshold = 0.8
        configuration.controls[0].doublePress = [KeyEntry(code: 0x28)]
        configuration.controls[0].longPress = [KeyEntry(code: 0)]
        model.loadProfile(HostProfile(name: "导入", keymap: configuration))
        model.saveProfile(name: "保存")
        let profile = try XCTUnwrap(model.profiles.first)
        let decoded = try HostProfile.decode(data: JSONEncoder().encode(profile))
        XCTAssertEqual(decoded.keymap, configuration)
        XCTAssertEqual(decoded.id, profile.id)
        XCTAssertEqual(decoded.version, 2)
        XCTAssertFalse(model.online)
    }

    func testUnrelatedJobsAndStaleSaveResultsDoNotCompletePendingSave() async throws {
        let model = initializedModel()
        model.assign(0x68)
        let saving = try XCTUnwrap(model.keymap)
        model.apply()
        let firstID = try XCTUnwrap(model.submittedID)
        // 刷新或权限复查比保存先完成时，不能消费当前提交。
        model.receive(snapshot(initialKeymap(), busy: true))
        model.receive(snapshot(initialKeymap()))
        XCTAssertTrue(model.applying)
        XCTAssertNil(model.notice)
        var unrelated = snapshot(initialKeymap())
        unrelated.hostSaveResult = HostSaveResult(requestID: UUID(), error: "旧保存失败")
        model.receive(unrelated)
        XCTAssertTrue(model.applying)
        // 对应结果足以完成保存，无须猜测 busy 快照是否已送达。
        let completed = try completedSnapshot(saving, model: model)
        model.receive(completed)
        XCTAssertFalse(model.applying)
        XCTAssertFalse(model.hasDraft)
        model.assign(0x69)
        model.apply()
        XCTAssertNotEqual(model.submittedID, firstID)
        model.receive(completed)
        XCTAssertTrue(model.applying)
        XCTAssertEqual(model.code(0), 0x69)
    }

    func testDefaultsCreateEditableDraftWithoutInitializingOrChangingDevice() async throws {
        let model = AppModel(demo: true, language: .simplifiedChinese)
        var original = snapshot(nil, error: "设备包含不支持的多媒体键位")
        original.keys = [KeyBinding(index: 0, entries: [KeyEntry(type: 3, code: 0xE9)])]
        model.receive(original)
        model.loadDefaults()
        XCTAssertTrue(model.canEdit)
        XCTAssertTrue(model.hasDraft)
        XCTAssertNil(model.device.hostKeymap)
        XCTAssertEqual(model.device.keys, original.keys)
        model.assign(0x68)
        let saving = try XCTUnwrap(model.keymap)
        model.apply()
        XCTAssertTrue(model.applying)
        var completed = try completedSnapshot(saving, model: model)
        completed.keys = original.keys
        model.receive(completed)
        XCTAssertFalse(model.hasDraft)
        XCTAssertEqual(model.device.keys, original.keys)
        XCTAssertEqual(model.code(0), 0x68)
    }

    func testImportedProfileCreatesDraftBeforeInitializationAndCanBeDiscarded() async throws {
        let model = AppModel(demo: true, language: .simplifiedChinese)
        var map = initialKeymap()
        map.controls[0].longPress = [KeyEntry(code: 0x68)]
        let profile = try HostProfile.decode(data: JSONEncoder().encode(HostProfile(name: "恢复", keymap: map)))
        model.loadProfile(profile)
        XCTAssertEqual(model.keymap, map)
        XCTAssertTrue(model.canEdit)
        XCTAssertNil(model.device.hostKeymap)
        model.discard()
        XCTAssertFalse(model.canEdit)
        XCTAssertNil(model.keymap)
    }

    func testProfileMigrationKeepsValidEntriesAndBacksUpFailuresAcrossLaterSaves() async throws {
        for sourceKey in ["nativeProfiles", "nativeHostProfiles"] {
            let suite = "olanzi-tests-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let valid = KeyProfile(name: "可用", codes: KeyCatalog.defaults)
            var unsupported = KeyProfile(name: "F21", codes: KeyCatalog.defaults)
            unsupported.codes[0] = 0x70
            try valid.validate(); try unsupported.validate()
            let source = try JSONEncoder().encode([valid, unsupported])
            defaults.set(source, forKey: sourceKey)
            let model = AppModel(demo: false, language: .simplifiedChinese, defaults: defaults)
            XCTAssertEqual(model.profiles.map(\.id), [valid.id])
            XCTAssertTrue(model.notice?.contains("原始列表已备份保留") == true)
            XCTAssertEqual(defaults.array(forKey: "nativeHostProfilesRecoveryBackups") as? [Data], [source])
            model.loadDefaults()
            model.saveProfile(name: "新配置")
            let saved = try XCTUnwrap(defaults.data(forKey: "nativeHostProfiles"))
            XCTAssertEqual(try JSONDecoder().decode([HostProfile].self, from: saved).count, 2)
            XCTAssertEqual(defaults.array(forKey: "nativeHostProfilesRecoveryBackups") as? [Data], [source])
            let reloaded = AppModel(demo: false, language: .simplifiedChinese, defaults: defaults)
            XCTAssertEqual(reloaded.profiles.count, 2)
            reloaded.removeProfile(valid.id)
            XCTAssertEqual(defaults.array(forKey: "nativeHostProfilesRecoveryBackups") as? [Data], [source])
            if sourceKey == "nativeProfiles" { XCTAssertEqual(defaults.data(forKey: sourceKey), source) }
        }
    }

    func testMalformedProfileListIsBackedUpBeforeNewListIsSaved() async throws {
        let suite = "olanzi-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = Data("{broken".utf8)
        defaults.set(source, forKey: "nativeHostProfiles")
        let model = AppModel(demo: false, language: .simplifiedChinese, defaults: defaults)
        XCTAssertTrue(model.profiles.isEmpty)
        XCTAssertNotNil(model.notice)
        XCTAssertEqual(defaults.data(forKey: "nativeHostProfiles"), source)
        model.loadDefaults()
        model.saveProfile(name: "恢复后")
        XCTAssertEqual(defaults.array(forKey: "nativeHostProfilesRecoveryBackups") as? [Data], [source])
        XCTAssertEqual(AppModel(demo: false, language: .simplifiedChinese, defaults: defaults).profiles.count, 1)
    }
    func testLongPressBehaviorEditsOnlyCapturedDraftAndPersistsThroughProfileAndSave() async throws {
        let model = initializedModel()
        XCTAssertEqual(model.longPressBehavior(), .hold)
        model.assign([KeyEntry(code: 1)], index: 3, gesture: .longPress)
        model.selected = 0
        XCTAssertTrue(model.setLongPressBehavior(.tap, index: 3))
        XCTAssertEqual(model.longPressBehavior(index: 3), .tap)
        XCTAssertEqual(model.longPressBehavior(), .hold)
        XCTAssertEqual(model.device.hostKeymap, initialKeymap())
        XCTAssertTrue(model.isDirty(3))
        XCTAssertFalse(model.applying)
        model.saveProfile(name: "长按触发方式")
        let profile = try XCTUnwrap(model.profiles.first)
        XCTAssertEqual(try HostProfile.decode(data: JSONEncoder().encode(profile)).keymap, model.keymap)
        let draft = try XCTUnwrap(model.draft)
        for index in [-1, 4, 5, 99] {
            XCTAssertFalse(model.setLongPressBehavior(.tap, index: index))
            XCTAssertEqual(model.draft, draft)
        }
        model.apply()
        XCTAssertTrue(model.applying)
        model.receive(try completedSnapshot(draft, model: model))
        XCTAssertFalse(model.hasDraft)
        XCTAssertEqual(model.device.hostKeymap?.controls[3].longPressBehavior, .tap)
        XCTAssertTrue(model.setLongPressBehavior(.hold, index: 3))
        XCTAssertTrue(model.hasDraft)
        model.discard()
        XCTAssertEqual(model.longPressBehavior(index: 3), .tap)
    }

    func testLongPressFnHintReflectsTapVersusHoldAndSwitchCanRevertDraft() async {
        let model = initializedModel()
        model.selected = 0
        model.gesture = .longPress
        model.assign(1)
        XCTAssertTrue(model.fnBehaviorHint?.contains("按住 Fn") == true)
        let holdDraft = model.draft
        XCTAssertTrue(model.setLongPressBehavior(.tap))
        XCTAssertTrue(model.fnBehaviorHint?.contains("短按一次 Fn") == true)
        XCTAssertFalse(model.fnBehaviorHint?.contains("松开时释放") == true)
        XCTAssertTrue(model.setLongPressBehavior(.hold))
        XCTAssertEqual(model.draft, holdDraft)
        model.discard()
        XCTAssertTrue(model.setLongPressBehavior(.tap))
        XCTAssertTrue(model.hasDraft)
        XCTAssertTrue(model.setLongPressBehavior(.hold))
        XCTAssertFalse(model.hasDraft)
    }

    func testLongPressRepeatCountValidatesWithoutChangingSavedMapAndSurvivesSave() async throws {
        let model = initializedModel()
        model.selected = 3
        model.gesture = .longPress
        model.assign(1)
        XCTAssertTrue(model.setLongPressBehavior(.burst))
        XCTAssertEqual(model.longPressTapCount(), 2)
        XCTAssertTrue(model.setLongPressTapCount(5))
        XCTAssertEqual(model.longPressBehaviorLabel(), "连按 5 次")
        XCTAssertTrue(model.fnBehaviorHint?.contains("Fn 5 次") == true)
        XCTAssertTrue(model.longPressBehaviorHelp.contains("松开后仍完成"))
        XCTAssertEqual(model.device.hostKeymap, initialKeymap())
        let draft = try XCTUnwrap(model.draft)
        for count in [Int.min, 0, 1, 21, Int.max] {
            XCTAssertFalse(model.setLongPressTapCount(count))
            XCTAssertEqual(model.draft, draft)
        }
        for index in [-1, 4, 5, 99] {
            XCTAssertFalse(model.setLongPressTapCount(7, index: index))
            XCTAssertEqual(model.draft, draft)
        }
        model.selected = 0
        XCTAssertTrue(model.setLongPressTapCount(20, index: 3))
        XCTAssertEqual(model.longPressTapCount(), 2)
        XCTAssertEqual(model.longPressTapCount(index: 3), 20)
        XCTAssertTrue(model.setLongPressBehavior(.hold, index: 3))
        XCTAssertTrue(model.setLongPressBehavior(.burst, index: 3))
        XCTAssertEqual(model.longPressTapCount(index: 3), 20)
        model.saveProfile(name: "连按")
        let profile = try XCTUnwrap(model.profiles.first)
        XCTAssertEqual(try HostProfile.decode(data: JSONEncoder().encode(profile)).keymap, model.keymap)
        let submitted = try XCTUnwrap(model.draft)
        model.apply()
        model.receive(try completedSnapshot(submitted, model: model))
        XCTAssertFalse(model.hasDraft)
        XCTAssertTrue(model.setLongPressTapCount(2, index: 3))
        model.discard()
        XCTAssertEqual(model.longPressTapCount(index: 3), 20)
        model.language = .english
        XCTAssertEqual(model.longPressBehaviorLabel(index: 3), "Tap 20 times")
    }

}
