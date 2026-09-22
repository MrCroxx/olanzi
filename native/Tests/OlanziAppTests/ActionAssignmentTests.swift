import XCTest
import OlanziCore
@testable import OlanziApp

/// 只操作演示模型与快照，不启动设备服务或切换真实应用。
@MainActor
final class ActionAssignmentTests: XCTestCase {
    private let target = ApplicationTarget(bundleIdentifier: "com.openai.codex",
                                           path: "/Applications/Codex.app", name: "Codex")

    private var actions: [HostAction] {
        [.application(target), .macro([
            .application(target), .delay(0.2),
            .keyboard([KeyEntry(code: 0xE0), KeyEntry(code: 0xE2),
                       KeyEntry(code: 0xE3), KeyEntry(code: 0x0C)])
        ])]
    }

    private func initializedModel() -> AppModel {
        let model = AppModel(demo: true, language: .simplifiedChinese)
        var snapshot = DeviceSnapshot()
        snapshot.demo = true
        snapshot.hostKeymap = .defaultKeymap
        model.receive(snapshot)
        return model
    }

    func testApplicationAndMacroAssignmentsOnlyChangeDraftForEveryGestureAndRotation() async throws {
        for action in actions {
            for index in 0..<6 {
                for gesture in AssignmentGesture.allCases {
                    let model = initializedModel()
                    XCTAssertTrue(model.assignAction(action, index: index, gesture: gesture))
                    let expectedGesture: AssignmentGesture = index >= 4 ? .press : gesture
                    XCTAssertEqual(model.action(index, gesture: expectedGesture), action)
                    XCTAssertNil(model.entries(index, gesture: expectedGesture))
                    XCTAssertTrue(model.isDirty(index))
                    XCTAssertNotNil(model.draft)
                    XCTAssertEqual(model.device.hostKeymap, .defaultKeymap)
                    XCTAssertFalse(model.applying)
                    XCTAssertNil(model.submittedID)
                    try XCTUnwrap(model.draft).validate()
                    for other in (0..<6).filter({ $0 != index }) {
                        XCTAssertFalse(model.isDirty(other))
                    }
                    if index >= 4 {
                        XCTAssertNil(model.action(index, gesture: .doublePress))
                        XCTAssertNil(model.action(index, gesture: .longPress))
                    }
                }
            }
        }
    }

    func testDisableOptionalApplicationOrMacroClearsOverrideAndRestoresOriginalDraft() async throws {
        for action in actions {
            for gesture in [AssignmentGesture.doublePress, .longPress] {
                let model = initializedModel()
                model.selected = 2
                model.gesture = gesture
                XCTAssertTrue(model.assignAction(action))
                XCTAssertNotNil(model.extendedLabel(2))
                model.disableGesture()
                let control = try XCTUnwrap(model.control(2))
                XCTAssertNil(control.doublePress)
                XCTAssertNil(control.longPress)
                XCTAssertNil(control.doublePressAction)
                XCTAssertNil(control.longPressAction)
                XCTAssertNil(model.action(2, gesture: gesture))
                XCTAssertNil(model.extendedLabel(2))
                XCTAssertNil(model.draft)
                XCTAssertEqual(model.device.hostKeymap, .defaultKeymap)
            }
        }
    }

    func testKeyboardAssignmentReplacesApplicationAndMacroOverrides() async throws {
        let keys = [KeyEntry(code: 0xE3), KeyEntry(code: 0x06)]
        for action in actions {
            for gesture in AssignmentGesture.allCases {
                let model = initializedModel()
                XCTAssertTrue(model.assignAction(action, index: 1, gesture: gesture))
                XCTAssertTrue(model.assign(keys, index: 1, gesture: gesture))
                let control = try XCTUnwrap(model.control(1))
                XCTAssertNil(control.pressAction)
                XCTAssertNil(control.doublePressAction)
                XCTAssertNil(control.longPressAction)
                XCTAssertEqual(model.action(1, gesture: gesture), .keyboard(keys))
                XCTAssertEqual(model.entries(1, gesture: gesture), keys)
                XCTAssertEqual(model.device.hostKeymap, .defaultKeymap)
            }
        }
    }

    func testActionLabelsExtendedLabelsAndProfileSummaryIncludeNewActions() async throws {
        let model = initializedModel()
        XCTAssertTrue(model.assignAction(actions[0], index: 0, gesture: .press))
        XCTAssertTrue(model.assignAction(actions[1], index: 1, gesture: .press))
        XCTAssertTrue(model.assignAction(actions[0], index: 2, gesture: .doublePress))
        XCTAssertTrue(model.assignAction(actions[1], index: 2, gesture: .longPress))
        XCTAssertEqual(model.label(0), "切换到 Codex")
        XCTAssertEqual(model.label(1), "宏 · 3 步")
        XCTAssertEqual(model.extendedLabel(2), "双击 切换到 Codex · 长按 宏 · 3 步")
        let summary = model.profileSummary(HostProfile(name: "测试", keymap: try XCTUnwrap(model.keymap)))
        XCTAssertTrue(summary.contains("切换到 Codex"))
        XCTAssertTrue(summary.contains("宏 · 3 步"))
        XCTAssertTrue(summary.contains("双击"))
        XCTAssertTrue(summary.contains("长按"))
        XCTAssertFalse(summary.contains("关闭"))
        XCTAssertNil(model.code(0))
        XCTAssertNil(model.code(1))
        XCTAssertNil(model.fnBehaviorHint)
    }

    func testSavedProfileJSONPreservesApplicationsMacrosAndGestureTargets() async throws {
        let model = initializedModel()
        XCTAssertTrue(model.assignAction(actions[0], index: 0, gesture: .press))
        XCTAssertTrue(model.assignAction(actions[1], index: 0, gesture: .doublePress))
        XCTAssertTrue(model.assignAction(actions[0], index: 1, gesture: .longPress))
        XCTAssertTrue(model.assignAction(actions[1], index: 5, gesture: .press))
        let draft = try XCTUnwrap(model.draft)
        model.saveProfile(name: "Codex 工作流")
        let profile = try XCTUnwrap(model.profiles.first)
        let decoded = try HostProfile.decode(data: JSONEncoder().encode(profile))
        XCTAssertEqual(decoded.id, profile.id)
        XCTAssertEqual(decoded.name, "Codex 工作流")
        XCTAssertEqual(decoded.keymap.version, 2)
        XCTAssertEqual(decoded.keymap.controls, draft.controls)
        XCTAssertEqual(decoded.keymap.doublePressWindow, draft.doublePressWindow)
        XCTAssertEqual(decoded.keymap.longPressThreshold, draft.longPressThreshold)
        XCTAssertEqual(try HostProfile.decode(data: JSONEncoder().encode(decoded)), decoded)
        model.discard()
        model.loadProfile(decoded)
        XCTAssertEqual(model.draft, decoded.keymap)
        XCTAssertEqual(model.device.hostKeymap, .defaultKeymap)
        XCTAssertFalse(model.applying)
    }

    func testInvalidMacroDelayAndStepsPreserveExistingDraft() async throws {
        let model = initializedModel()
        XCTAssertTrue(model.assignAction(actions[0], index: 0))
        let draft = try XCTUnwrap(model.draft)
        let invalid: [HostAction] = [
            .macro([]), .macro(Array(repeating: .delay(0.1), count: 33)),
            .macro([.delay(0)]), .macro([.delay(10.1)]),
            .macro([.delay(.nan)]), .macro([.delay(.infinity)]),
            .macro([.application(ApplicationTarget(bundleIdentifier: "", path: "", name: ""))]),
            .macro([.keyboard([KeyEntry(type: 3, code: 0x28)])])
        ]
        for action in invalid {
            XCTAssertFalse(model.assignAction(action, index: 1, gesture: .longPress))
            XCTAssertEqual(model.draft, draft)
            XCTAssertEqual(model.device.hostKeymap, .defaultKeymap)
            XCTAssertNotNil(model.notice)
            XCTAssertFalse(model.applying)
            XCTAssertNil(model.submittedID)
        }
    }

    func testApplicationAndMacroUseCapturedTargetAfterSelectionChanges() async {
        for action in actions {
            let model = initializedModel()
            model.selected = 3
            model.gesture = .longPress
            let capturedIndex = model.selected
            let capturedGesture = model.gesture
            model.selected = 1
            model.gesture = .doublePress
            XCTAssertTrue(model.assignAction(action, index: capturedIndex, gesture: capturedGesture))
            XCTAssertEqual(model.action(3, gesture: .longPress), action)
            XCTAssertNil(model.action(1, gesture: .doublePress))
            XCTAssertFalse(model.isDirty(1))
            XCTAssertEqual(model.selected, 1)
            XCTAssertEqual(model.gesture, .doublePress)
            XCTAssertEqual(model.device.hostKeymap, .defaultKeymap)
        }
    }
}
