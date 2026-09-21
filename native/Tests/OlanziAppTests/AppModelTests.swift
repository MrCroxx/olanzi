import XCTest
import OlanziCore
@testable import OlanziApp

/// 只创建演示模型并注入快照，永不 start、访问真实设备、写本机配置或展示窗口。
@MainActor
final class AppModelTests: XCTestCase {
    private func initialKeymap() -> HostKeymap {
        HostKeymap(controls: KeyCatalog.defaults.enumerated().map {
            ControlActionMap(index: $0.offset, press: [KeyEntry(code: $0.element)])
        })
    }

    private func snapshot(_ map: HostKeymap, busy: Bool = false, error: String? = nil) -> DeviceSnapshot {
        var value = DeviceSnapshot()
        value.demo = true
        value.hostKeymap = map
        value.busy = busy
        value.error = error
        return value
    }

    private func initializedModel() -> AppModel {
        let model = AppModel(demo: true)
        model.receive(snapshot(initialKeymap()))
        return model
    }

    func testEditingWaitsForInitialHostConfiguration() async {
        let model = AppModel(demo: true)
        model.assign(0x68)
        XCTAssertFalse(model.canEdit)
        XCTAssertFalse(model.hasDraft)
        XCTAssertNil(model.keymap)
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
        model.receive(snapshot(pending))
        XCTAssertFalse(model.applying)
        XCTAssertFalse(model.hasDraft)
        XCTAssertEqual(model.code(0), 0x68)
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
        model.receive(snapshot(saving))
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
        model.receive(snapshot(saving))
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
        model.receive(snapshot(saving, error: "接收器离线"))
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
        model.receive(snapshot(initialKeymap(), error: "磁盘写入失败"))
        XCTAssertFalse(model.applying)
        XCTAssertTrue(model.hasDraft)
        XCTAssertEqual(model.keymap, edited)
        XCTAssertEqual(model.device.hostKeymap, initialKeymap())
        XCTAssertTrue(model.notice?.contains("草稿已保留") == true)
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
}
