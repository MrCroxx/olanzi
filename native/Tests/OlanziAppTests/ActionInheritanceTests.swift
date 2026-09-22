import XCTest
import OlanziCore
@testable import OlanziApp

@MainActor
final class ActionInheritanceTests: XCTestCase {
    private func model() -> AppModel {
        let model = AppModel(demo: true, language: .simplifiedChinese)
        var map = HostKeymap.defaultKeymap
        map.controls[0] = ControlActionMap(
            index: 0, press: [KeyEntry(code: 0x04)], doublePress: [KeyEntry(code: 0x05)],
            longPress: [KeyEntry(code: 0x06)], longPressBehavior: .burst, longPressTapCount: 7,
            pressBehavior: .burst, pressTapCount: 3, doublePressBehavior: .burst, doublePressTapCount: 5)
        var snapshot = DeviceSnapshot()
        snapshot.demo = true
        snapshot.hostKeymap = map
        model.receive(snapshot)
        return model
    }

    func testInheritingOneGesturePreservesOtherOverridesOnSameControl() async throws {
        let model = model()
        model.selectedLayer = 1
        XCTAssertTrue(model.assign([KeyEntry(code: 0x07)], gesture: .press))
        XCTAssertTrue(model.assign([KeyEntry(code: 0x08)], gesture: .doublePress))
        XCTAssertTrue(model.assign([KeyEntry(code: 0x09)], gesture: .longPress))
        model.gesture = .longPress
        model.inheritAction()
        XCTAssertFalse(model.isInherited(0, gesture: .press))
        XCTAssertFalse(model.isInherited(0, gesture: .doublePress))
        XCTAssertTrue(model.isInherited(0, gesture: .longPress))
        XCTAssertEqual(model.assignedAction(0), .keyboard([KeyEntry(code: 0x07)]))
        XCTAssertEqual(model.assignedAction(0, gesture: .doublePress), .keyboard([KeyEntry(code: 0x08)]))
        XCTAssertEqual(model.assignedAction(0, gesture: .longPress), .keyboard([KeyEntry(code: 0x06)]))
        XCTAssertEqual(model.actionBehavior(), .burst)
        XCTAssertEqual(model.actionTapCount(), 7)
        XCTAssertEqual(model.draft?.control(index: 0, layer: 1)?.inheritedGestures, [.longPress])
    }

    func testInheritedActionAndRepeatSettingsFollowBaseEdits() async throws {
        let model = model()
        model.selectedLayer = 1
        XCTAssertTrue(model.assign([KeyEntry(code: 0x07)], gesture: .press))
        XCTAssertTrue(model.isInherited(0, gesture: .doublePress))
        XCTAssertTrue(model.isInherited(0, gesture: .longPress))
        model.selectedLayer = 0
        XCTAssertTrue(model.assign([KeyEntry(code: 0x08)], gesture: .doublePress))
        XCTAssertTrue(model.setActionBehavior(.tap, gesture: .doublePress))
        XCTAssertTrue(model.setActionTapCount(9, gesture: .doublePress))
        XCTAssertTrue(model.assign([KeyEntry(code: 0x09)], gesture: .longPress))
        XCTAssertTrue(model.setActionBehavior(.tap, gesture: .longPress))
        XCTAssertTrue(model.setActionTapCount(11, gesture: .longPress))
        model.selectedLayer = 1
        XCTAssertEqual(model.assignedAction(0), .keyboard([KeyEntry(code: 0x07)]))
        XCTAssertEqual(model.assignedAction(0, gesture: .doublePress), .keyboard([KeyEntry(code: 0x08)]))
        XCTAssertEqual(model.actionBehavior(gesture: .doublePress), .tap)
        XCTAssertEqual(model.actionTapCount(gesture: .doublePress), 9)
        XCTAssertEqual(model.assignedAction(0, gesture: .longPress), .keyboard([KeyEntry(code: 0x09)]))
        XCTAssertEqual(model.actionBehavior(gesture: .longPress), .tap)
        XCTAssertEqual(model.actionTapCount(gesture: .longPress), 11)
    }

    func testEmptyRectangleCreatesExplicitPrimaryOverrideInsteadOfInheritance() async throws {
        let model = model()
        model.selectedLayer = 2
        model.clearAction()
        XCTAssertFalse(model.isInherited(0))
        XCTAssertTrue(model.isEmptyAction(0))
        XCTAssertEqual(model.assignedAction(0), .keyboard([KeyEntry(code: 0)]))
        XCTAssertTrue(model.isInherited(0, gesture: .doublePress))
        XCTAssertTrue(model.isInherited(0, gesture: .longPress))
        XCTAssertEqual(model.assignedAction(0, gesture: .doublePress), .keyboard([KeyEntry(code: 0x05)]))
        model.selectedLayer = 0
        XCTAssertTrue(model.assign([KeyEntry(code: 0x09)], gesture: .press))
        model.selectedLayer = 2
        XCTAssertTrue(model.isEmptyAction(0))
        XCTAssertEqual(model.assignedAction(0), .keyboard([KeyEntry(code: 0)]))
        model.inheritAction()
        XCTAssertTrue(model.isInherited(0))
        XCTAssertFalse(model.isEmptyAction(0))
        XCTAssertEqual(model.assignedAction(0), .keyboard([KeyEntry(code: 0x09)]))
    }

    func testClearingOptionalActionsImmediatelyRemovesTheirEffectiveGestures() async throws {
        let model = model()
        model.selectedLayer = 1
        let primary = model.assignedAction(0)
        for gesture in [AssignmentGesture.doublePress, .longPress] {
            model.gesture = gesture
            XCTAssertNotNil(model.assignedAction(0, gesture: gesture))
            model.clearAction()
            XCTAssertFalse(model.isInherited(0, gesture: gesture))
            XCTAssertTrue(model.isEmptyAction(0, gesture: gesture))
            XCTAssertNil(model.assignedAction(0, gesture: gesture))
        }
        XCTAssertNil(model.control(0)?.effectiveDoublePress)
        XCTAssertNil(model.control(0)?.effectiveLongPress)
        XCTAssertEqual(model.assignedAction(0), primary)
        XCTAssertTrue(model.isInherited(0))
        model.gesture = .doublePress
        model.inheritAction()
        XCTAssertNotNil(model.control(0)?.effectiveDoublePress)
        XCTAssertNil(model.control(0)?.effectiveLongPress)
        XCTAssertFalse(model.isInherited(0, gesture: .longPress))
    }

    func testBaseLayerInheritanceDoesNothing() async throws {
        let model = model()
        XCTAssertTrue(model.assign([KeyEntry(code: 0x09)], gesture: .press))
        let original = model.draft
        for gesture in AssignmentGesture.allCases {
            model.gesture = gesture
            model.inheritAction()
            XCTAssertEqual(model.draft, original)
            XCTAssertFalse(model.isInherited(0, gesture: gesture))
        }
    }

    func testInheritingLastOverrideRemovesSparseRecordsAndRestoresOriginalDraft() async throws {
        let model = model()
        model.selectedLayer = 3
        XCTAssertTrue(model.assign([KeyEntry(code: 0x09)], gesture: .longPress))
        let stored = try XCTUnwrap(model.draft?.control(index: 0, layer: 3))
        XCTAssertEqual(stored.inheritedGestures, [.press, .doublePress])
        model.gesture = .longPress
        model.inheritAction()
        XCTAssertNil(model.draft)
        XCTAssertTrue(model.isInherited(0, gesture: .longPress))
        XCTAssertEqual(model.selectedLayer, 3)
        XCTAssertEqual(model.control(0), model.device.hostKeymap?.control(index: 0, layer: 0))
    }

    func testProfileRoundTripRetainsIndependentInheritanceFlagsAndEmptyOverrides() async throws {
        let model = model()
        model.selectedLayer = 1
        XCTAssertTrue(model.assign([KeyEntry(code: 0x09)], gesture: .doublePress))
        model.selectedLayer = 2
        model.clearAction()
        model.saveProfile(name: "Independent inheritance")
        let profile = try XCTUnwrap(model.profiles.first)
        let restored = try HostProfile.decode(data: JSONEncoder().encode(profile))
        XCTAssertEqual(restored.keymap.version, 5)
        XCTAssertEqual(restored.keymap, model.draft)
        XCTAssertEqual(restored.keymap.control(index: 0, layer: 1)?.inheritedGestures, [.press, .longPress])
        XCTAssertEqual(restored.keymap.control(index: 0, layer: 2)?.inheritedGestures, [.doublePress, .longPress])
        model.discard()
        model.loadProfile(restored)
        model.selectedLayer = 1
        XCTAssertTrue(model.isInherited(0))
        XCTAssertFalse(model.isInherited(0, gesture: .doublePress))
        XCTAssertEqual(model.assignedAction(0, gesture: .doublePress), .keyboard([KeyEntry(code: 0x09)]))
        model.selectedLayer = 2
        XCTAssertTrue(model.isEmptyAction(0))
        XCTAssertFalse(model.isInherited(0))
    }

    func testEditingInheritedRepeatMaterializesOnlyCurrentGestureUsingLatestBaseAction() async throws {
        let model = model()
        model.selectedLayer = 1
        XCTAssertTrue(model.assign([KeyEntry(code: 0x09)], gesture: .press))
        model.selectedLayer = 0
        XCTAssertTrue(model.assign([KeyEntry(code: 0x08)], gesture: .longPress))
        XCTAssertTrue(model.setActionBehavior(.tap, gesture: .longPress))
        XCTAssertTrue(model.setActionTapCount(11, gesture: .longPress))
        model.selectedLayer = 1
        model.gesture = .longPress
        XCTAssertTrue(model.setActionTapCount(13))
        XCTAssertFalse(model.isInherited(0, gesture: .longPress))
        XCTAssertTrue(model.isInherited(0, gesture: .doublePress))
        XCTAssertEqual(model.assignedAction(0), .keyboard([KeyEntry(code: 0x09)]))
        XCTAssertEqual(model.assignedAction(0, gesture: .longPress), .keyboard([KeyEntry(code: 0x08)]))
        XCTAssertEqual(model.actionBehavior(), .tap)
        XCTAssertEqual(model.actionTapCount(), 13)
        let stored = try XCTUnwrap(model.draft?.control(index: 0, layer: 1))
        XCTAssertEqual(stored.inheritedGestures, [.doublePress])
        XCTAssertEqual(stored.effectiveLongPress, .keyboard([KeyEntry(code: 0x08)]))
        XCTAssertEqual(stored.longPressBehavior, .tap)
        model.selectedLayer = 0
        XCTAssertEqual(model.actionTapCount(gesture: .longPress), 11)
        XCTAssertTrue(model.assign([KeyEntry(code: 0x07)], gesture: .longPress))
        model.selectedLayer = 1
        XCTAssertEqual(model.assignedAction(0, gesture: .longPress), .keyboard([KeyEntry(code: 0x08)]))
    }

    func testKnobEmptyOverrideCanReturnToInheritedRotation() async throws {
        let model = model()
        model.selectedLayer = 1
        model.selected = 4
        let original = model.assignedAction(4)
        model.clearAction()
        XCTAssertTrue(model.isEmptyAction(4))
        XCTAssertFalse(model.isInherited(4))
        model.inheritAction()
        XCTAssertTrue(model.isInherited(4))
        XCTAssertEqual(model.assignedAction(4), original)
        XCTAssertNil(model.draft)
    }

    func testInheritedLibraryReferencesAreNotCopiedCountedOrLeftBehind() async throws {
        let model = model()
        let id = try XCTUnwrap(model.saveLibraryAction(
            id: nil, name: "Shared", action: .macro([.keyboard([KeyEntry(code: 0x09)])])))
        XCTAssertTrue(model.assignAction(.library(id), gesture: .press))
        XCTAssertTrue(model.assignAction(.library(id), gesture: .longPress))
        XCTAssertEqual(model.usageCount(id), 2)
        model.selectedLayer = 1
        XCTAssertTrue(model.assign([KeyEntry(code: 0x08)], gesture: .doublePress))
        let stored = try XCTUnwrap(model.draft?.control(index: 0, layer: 1))
        XCTAssertEqual(stored.inheritedGestures, [.press, .longPress])
        XCTAssertNil(stored.pressAction)
        XCTAssertNil(stored.longPressAction)
        XCTAssertEqual(model.usageCount(id), 2)
        XCTAssertEqual(model.assignedAction(0), .library(id))
        XCTAssertEqual(model.assignedAction(0, gesture: .longPress), .library(id))
        model.selectedLayer = 0
        XCTAssertTrue(model.assign([KeyEntry(code: 0x04)], gesture: .press))
        model.gesture = .longPress
        model.clearAction()
        XCTAssertEqual(model.usageCount(id), 0)
        XCTAssertTrue(model.removeLibraryAction(id))
        XCTAssertNoThrow(try XCTUnwrap(model.draft).validate())
        model.selectedLayer = 1
        XCTAssertEqual(model.assignedAction(0), .keyboard([KeyEntry(code: 0x04)]))
        XCTAssertNil(model.assignedAction(0, gesture: .longPress))
    }

    func testLibraryEditDoesNotMarkAnInheritedOnlyReferenceAsExplicitLayerChange() async throws {
        let model = model()
        let id = try XCTUnwrap(model.saveLibraryAction(
            id: nil, name: "Original", action: .macro([.keyboard([KeyEntry(code: 0x09)])])))
        XCTAssertTrue(model.assignAction(.library(id), gesture: .press))
        model.selectedLayer = 1
        XCTAssertTrue(model.assign([KeyEntry(code: 0x08)], gesture: .doublePress))
        var saved = model.device
        saved.hostKeymap = try XCTUnwrap(model.draft)
        model.receive(saved)
        model.discard()
        XCTAssertEqual(model.saveLibraryAction(
            id: id, name: "Updated", action: .macro([.keyboard([KeyEntry(code: 0x07)])])), id)
        XCTAssertTrue(model.isDirty(0))
        model.selectedLayer = 1
        XCTAssertFalse(model.isDirty(0))
        XCTAssertTrue(model.isInherited(0))
        XCTAssertEqual(model.action(0), .macro([.keyboard([KeyEntry(code: 0x07)])]))
        XCTAssertEqual(model.usageCount(id), 1)
    }
}
