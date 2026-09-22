import XCTest
import OlanziCore
@testable import OlanziApp

@MainActor
final class ActionRepeatTests: XCTestCase {
    private func model(keymap: HostKeymap = .defaultKeymap) -> AppModel {
        let model = AppModel(demo: true, language: .simplifiedChinese)
        var snapshot = DeviceSnapshot()
        snapshot.demo = true
        snapshot.hostKeymap = keymap
        model.receive(snapshot)
        return model
    }

    func testGestureModesAndCountsRemainIndependentWhenSelectionChanges() async throws {
        let model = model()
        XCTAssertTrue(model.assign([KeyEntry(code: 0x04)], gesture: .doublePress))
        XCTAssertTrue(model.assign([KeyEntry(code: 0x05)], gesture: .longPress))
        XCTAssertTrue(model.setActionBehavior(.burst, gesture: .press))
        XCTAssertTrue(model.setActionTapCount(3, gesture: .press))
        XCTAssertTrue(model.setActionBehavior(.tap, gesture: .doublePress))
        XCTAssertTrue(model.setActionTapCount(5, gesture: .doublePress))
        XCTAssertTrue(model.setActionBehavior(.hold, gesture: .longPress))
        XCTAssertTrue(model.setActionTapCount(7, gesture: .longPress))
        for (gesture, behavior, count) in [
            (AssignmentGesture.press, LongPressBehavior.burst, 3),
            (.doublePress, .tap, 5),
            (.longPress, .hold, 7),
            (.press, .burst, 3),
        ] {
            model.gesture = gesture
            XCTAssertEqual(model.actionBehavior(), behavior)
            XCTAssertEqual(model.actionTapCount(), count)
            XCTAssertEqual(model.actionBehavior(gesture: gesture), behavior)
            XCTAssertEqual(model.actionTapCount(gesture: gesture), count)
        }
        model.gesture = .press
        XCTAssertEqual(model.actionBehaviorLabel(), "连按 3 次")
        XCTAssertTrue(model.actionBehaviorHelp.contains("3"))
        XCTAssertEqual(model.availableActionBehaviors, [.hold, .tap, .burst])
        model.gesture = .doublePress
        XCTAssertEqual(model.availableActionBehaviors, [.tap, .burst])
        let beforeInvalid = model.draft
        XCTAssertFalse(model.setActionBehavior(.hold))
        XCTAssertEqual(model.draft, beforeInvalid)
        model.gesture = .longPress
        XCTAssertEqual(model.availableActionBehaviors, [.hold, .tap, .burst])
    }

    func testRepeatEditsAreIsolatedByControlAndLayer() async throws {
        let model = model()
        XCTAssertTrue(model.setActionBehavior(.burst, index: 0, gesture: .press))
        XCTAssertTrue(model.setActionTapCount(3, index: 0, gesture: .press))
        let base = try XCTUnwrap(model.control(0))
        model.selectedLayer = 2
        XCTAssertTrue(model.isInherited(0))
        XCTAssertEqual(model.actionTapCount(index: 0), 3)
        XCTAssertTrue(model.setActionTapCount(9, index: 0))
        XCTAssertFalse(model.isInherited(0))
        XCTAssertEqual(model.actionTapCount(index: 0), 9)
        XCTAssertTrue(model.setActionBehavior(.tap, index: 1))
        XCTAssertTrue(model.setActionTapCount(5, index: 1))
        XCTAssertEqual(model.actionBehavior(index: 0), .burst)
        XCTAssertEqual(model.actionTapCount(index: 0), 9)
        XCTAssertEqual(model.actionBehavior(index: 1), .tap)
        XCTAssertEqual(model.actionTapCount(index: 1), 5)
        XCTAssertEqual(model.draft?.control(index: 0, layer: 0), base)
        model.selectedLayer = 0
        XCTAssertEqual(model.actionTapCount(index: 0), 3)
        XCTAssertEqual(model.actionBehavior(index: 1), .hold)
        XCTAssertEqual(model.actionTapCount(index: 1), 2)
        model.selectedLayer = 2
        model.inheritControl()
        XCTAssertEqual(model.actionTapCount(index: 0), 3)
        XCTAssertEqual(model.actionTapCount(index: 1), 5)
        XCTAssertEqual(model.device.hostKeymap, .defaultKeymap)
    }

    func testKnobRotationSupportsTapAndBurstButRejectsHold() async throws {
        let model = model()
        for index in [4, 5] {
            model.selected = index
            XCTAssertEqual(model.gesture, .press)
            XCTAssertEqual(model.availableActionBehaviors, [.tap, .burst])
            XCTAssertEqual(model.actionBehavior(), .tap)
            XCTAssertTrue(model.setActionBehavior(.burst))
            XCTAssertTrue(model.setActionTapCount(index + 2))
            XCTAssertEqual(model.actionBehavior(), .burst)
            XCTAssertEqual(model.actionTapCount(), index + 2)
            let beforeInvalid = model.draft
            XCTAssertFalse(model.setActionBehavior(.hold))
            XCTAssertFalse(model.setActionBehavior(.hold, gesture: .longPress))
            XCTAssertEqual(model.draft, beforeInvalid)
            XCTAssertTrue(model.setActionBehavior(.tap))
            XCTAssertEqual(model.actionBehavior(), .tap)
        }
        XCTAssertEqual(model.actionTapCount(index: 4), 6)
        XCTAssertEqual(model.actionTapCount(index: 5), 7)
    }

    func testNonKeyboardActionsRejectRepeatChangesAndKeyCombinationsAllowThem() async throws {
        let model = model()
        let target = ApplicationTarget(bundleIdentifier: "com.example.editor", path: "/Applications/Editor.app", name: "Editor")
        for action in [HostAction.momentaryLayer(1), .application(target), .macro([.keyboard([KeyEntry(code: 0x04)])])] {
            for gesture in [AssignmentGesture.press, .longPress] {
                XCTAssertTrue(model.assignAction(action, gesture: gesture))
                let original = model.draft
                XCTAssertFalse(model.setActionBehavior(.burst, gesture: gesture))
                XCTAssertFalse(model.setActionTapCount(6, gesture: gesture))
                XCTAssertEqual(model.draft, original)
            }
        }
        let combination = [KeyEntry(code: 0xE1), KeyEntry(code: 0x04)]
        XCTAssertTrue(model.assign(combination, gesture: .press))
        XCTAssertTrue(model.setActionBehavior(.burst, gesture: .press))
        XCTAssertTrue(model.setActionTapCount(6, gesture: .press))
        XCTAssertEqual(model.assignedAction(0), .keyboard(combination))
        XCTAssertEqual(model.actionTapCount(gesture: .press), 6)
    }

    func testUnassignedGesturesRejectRepeatChanges() async throws {
        let model = model()
        for gesture in [AssignmentGesture.doublePress, .longPress] {
            XCTAssertFalse(model.setActionBehavior(.burst, gesture: gesture))
            XCTAssertFalse(model.setActionTapCount(6, gesture: gesture))
        }
        XCTAssertNil(model.draft)
    }

    func testCountBoundsApplyIndependentlyToEveryGesture() async throws {
        let model = model()
        XCTAssertTrue(model.assign([KeyEntry(code: 0x04)], gesture: .doublePress))
        XCTAssertTrue(model.assign([KeyEntry(code: 0x05)], gesture: .longPress))
        for gesture in AssignmentGesture.allCases {
            model.gesture = gesture
            for count in [2, 20] {
                XCTAssertTrue(model.setActionTapCount(count))
                XCTAssertEqual(model.actionTapCount(), count)
            }
            for count in [-1, 0, 1, 21] {
                let original = model.draft
                XCTAssertFalse(model.setActionTapCount(count))
                XCTAssertEqual(model.actionTapCount(), 20)
                XCTAssertEqual(model.draft, original)
            }
        }
    }

    func testLegacyLongPressConfigurationIsPreservedByGenericAccessors() async throws {
        var map = HostKeymap.defaultKeymap
        map.controls[0].longPress = [KeyEntry(code: 0x04)]
        map.controls[0].longPressBehavior = .burst
        map.controls[0].longPressTapCount = 8
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(map)) as? [String: Any])
        var controls = try XCTUnwrap(json["controls"] as? [[String: Any]])
        for index in controls.indices {
            for field in ["pressBehavior", "pressTapCount", "doublePressBehavior", "doublePressTapCount"] {
                controls[index].removeValue(forKey: field)
            }
        }
        json["controls"] = controls
        let legacy = try HostKeymap.decode(data: JSONSerialization.data(withJSONObject: json))
        let model = model(keymap: legacy)
        model.gesture = .longPress
        XCTAssertEqual(model.actionBehavior(), .burst)
        XCTAssertEqual(model.actionTapCount(), 8)
        XCTAssertEqual(model.actionBehavior(), model.longPressBehavior())
        XCTAssertEqual(model.actionTapCount(), model.longPressTapCount())
        XCTAssertEqual(model.actionBehavior(gesture: .press), .hold)
        XCTAssertEqual(model.actionTapCount(gesture: .press), 2)
        XCTAssertEqual(model.actionBehavior(gesture: .doublePress), .tap)
        XCTAssertEqual(model.actionTapCount(gesture: .doublePress), 2)
        XCTAssertNil(model.draft)
        XCTAssertTrue(model.setActionTapCount(9))
        XCTAssertEqual(model.longPressTapCount(), 9)
        XCTAssertTrue(model.setLongPressBehavior(.tap))
        XCTAssertEqual(model.actionBehavior(), .tap)
        XCTAssertEqual(model.device.hostKeymap, legacy)
    }

    func testProfileV5RoundTripPreservesRepeatSettingsWithoutChangingSavedDeviceMap() async throws {
        let model = model()
        XCTAssertTrue(model.setActionBehavior(.burst))
        XCTAssertTrue(model.setActionTapCount(4))
        model.selectedLayer = 1
        XCTAssertTrue(model.assign([KeyEntry(code: 0x04)], gesture: .doublePress))
        XCTAssertTrue(model.setActionBehavior(.burst, gesture: .doublePress))
        XCTAssertTrue(model.setActionTapCount(6, gesture: .doublePress))
        XCTAssertTrue(model.assign([KeyEntry(code: 0x05)], gesture: .longPress))
        XCTAssertTrue(model.setActionBehavior(.tap, gesture: .longPress))
        XCTAssertTrue(model.setActionTapCount(8, gesture: .longPress))
        model.saveProfile(name: "Independent repeat")
        let profile = try XCTUnwrap(model.profiles.first)
        let restored = try HostProfile.decode(data: JSONEncoder().encode(profile))
        XCTAssertEqual(restored.keymap.version, 5)
        XCTAssertEqual(restored.keymap, model.draft)
        XCTAssertEqual(model.device.hostKeymap, .defaultKeymap)
        XCTAssertNil(model.submittedID)
        model.discard()
        XCTAssertNil(model.draft)
        model.loadProfile(restored)
        model.selectedLayer = 1
        XCTAssertEqual(model.actionBehavior(gesture: .press), .burst)
        XCTAssertEqual(model.actionTapCount(gesture: .press), 4)
        XCTAssertEqual(model.actionBehavior(gesture: .doublePress), .burst)
        XCTAssertEqual(model.actionTapCount(gesture: .doublePress), 6)
        XCTAssertEqual(model.actionBehavior(gesture: .longPress), .tap)
        XCTAssertEqual(model.actionTapCount(gesture: .longPress), 8)
        XCTAssertEqual(model.device.hostKeymap, .defaultKeymap)
    }
}
