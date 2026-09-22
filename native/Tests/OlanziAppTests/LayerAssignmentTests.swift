import XCTest
import OlanziCore
@testable import OlanziApp

@MainActor
final class LayerAssignmentTests: XCTestCase {
    private func model(keymap: HostKeymap = .defaultKeymap) -> AppModel {
        let model = AppModel(demo: true, language: .simplifiedChinese)
        var snapshot = DeviceSnapshot()
        snapshot.demo = true
        snapshot.hostKeymap = keymap
        model.receive(snapshot)
        return model
    }

    func testLayerEditingIsIsolatedAndRemovingOverrideRestoresInheritance() async throws {
        let model = model()
        let base = try XCTUnwrap(model.control(0))
        model.selectedLayer = 1
        XCTAssertEqual(model.selectedLayer, 1)
        XCTAssertTrue(model.isInherited(0))
        XCTAssertEqual(model.control(0), base)
        XCTAssertTrue(model.assign([KeyEntry(code: 0x04)], index: 0))
        XCTAssertFalse(model.isInherited(0))
        XCTAssertEqual(model.action(0), .keyboard([KeyEntry(code: 0x04)]))
        XCTAssertEqual(model.draft?.control(index: 0, layer: 0), base)
        model.selectedLayer = 2
        XCTAssertEqual(model.selectedLayer, 2)
        XCTAssertEqual(model.control(0), base)
        XCTAssertTrue(model.assign([KeyEntry(code: 0x05)], index: 0))
        model.selectedLayer = 1
        XCTAssertEqual(model.action(0), .keyboard([KeyEntry(code: 0x04)]))
        model.inheritControl()
        XCTAssertTrue(model.isInherited(0))
        XCTAssertEqual(model.control(0), base)
        XCTAssertNil(model.draft?.control(index: 0, layer: 1))
        XCTAssertFalse(try XCTUnwrap(model.draft).layers.contains { $0.id == 1 })
        XCTAssertEqual(model.draft?.control(index: 0, layer: 2)?.effectivePress, .keyboard([KeyEntry(code: 0x05)]))
        XCTAssertEqual(model.device.hostKeymap, .defaultKeymap)
        XCTAssertNil(model.submittedID)
    }

    func testGestureEditsAndLongPressSettingsOnlyChangeSelectedLayer() async throws {
        let model = model()
        XCTAssertTrue(model.assign([KeyEntry(code: 0x04)], gesture: .doublePress))
        XCTAssertTrue(model.assign([KeyEntry(code: 0x05)], gesture: .longPress))
        let base = try XCTUnwrap(model.control(0))
        model.selectedLayer = 1
        XCTAssertTrue(model.setLongPressBehavior(.burst))
        XCTAssertTrue(model.setLongPressTapCount(7))
        XCTAssertEqual(model.longPressBehavior(), .burst)
        XCTAssertEqual(model.longPressTapCount(), 7)
        model.gesture = .doublePress
        model.disableGesture()
        XCTAssertNil(model.assignedAction(0, gesture: .doublePress))
        XCTAssertEqual(model.assignedAction(0, gesture: .longPress), .keyboard([KeyEntry(code: 0x05)]))
        model.gesture = .longPress
        model.disableGesture()
        XCTAssertNil(model.assignedAction(0, gesture: .longPress))
        XCTAssertEqual(model.draft?.control(index: 0, layer: 0), base)
        model.selectedLayer = 0
        XCTAssertEqual(model.gesture, .press)
        XCTAssertEqual(model.control(0), base)
    }

    func testMomentaryLayerAssignmentClearsDoublePressAndPreservesExistingLongPress() async throws {
        let model = model()
        let longAction: HostAction = .macro([.keyboard([KeyEntry(code: 0x05)])])
        XCTAssertTrue(model.assign([KeyEntry(code: 0x04)], gesture: .doublePress))
        XCTAssertTrue(model.assignAction(longAction, gesture: .longPress))
        XCTAssertTrue(model.setLongPressBehavior(.burst))
        XCTAssertTrue(model.setLongPressTapCount(7))
        XCTAssertTrue(model.assignAction(.momentaryLayer(1)))
        let control = try XCTUnwrap(model.control(0))
        XCTAssertEqual(control.effectivePress, .momentaryLayer(1))
        XCTAssertTrue(control.press.isEmpty)
        XCTAssertNil(control.doublePress)
        XCTAssertNil(control.doublePressAction)
        XCTAssertNil(control.longPress)
        XCTAssertEqual(control.longPressAction, longAction)
        XCTAssertEqual(control.longPressBehavior, .burst)
        XCTAssertEqual(control.longPressTapCount, 7)
        XCTAssertTrue(model.isLayerSwitch(0))
        XCTAssertNoThrow(try model.draft?.validate())
        XCTAssertTrue(model.assignAction(.momentaryLayer(1), index: 3, gesture: .press))
    }

    func testLongPressCanBeAssignedAfterPrimaryMomentaryLayer() async throws {
        let model = model()
        XCTAssertTrue(model.assignAction(.momentaryLayer(1)))
        model.gesture = .longPress
        XCTAssertTrue(model.assign([KeyEntry(code: 0x04)]))
        XCTAssertTrue(model.setLongPressBehavior(.tap))
        XCTAssertEqual(model.assignedAction(0), .momentaryLayer(1))
        XCTAssertEqual(model.assignedAction(0, gesture: .longPress), .keyboard([KeyEntry(code: 0x04)]))
        XCTAssertEqual(model.longPressBehavior(), .tap)
        XCTAssertNoThrow(try XCTUnwrap(model.draft).validate())
    }

    func testPrimaryAndLongPressMomentaryLayersCanBeAssignedInEitherOrder() async throws {
        for primaryFirst in [true, false] {
            let model = model()
            if primaryFirst {
                XCTAssertTrue(model.assignAction(.momentaryLayer(1), gesture: .press))
                XCTAssertTrue(model.assignAction(.momentaryLayer(3), gesture: .longPress))
            } else {
                XCTAssertTrue(model.assignAction(.momentaryLayer(3), gesture: .longPress))
                XCTAssertTrue(model.assignAction(.momentaryLayer(1), gesture: .press))
            }
            XCTAssertEqual(model.assignedAction(0), .momentaryLayer(1))
            XCTAssertEqual(model.assignedAction(0, gesture: .longPress), .momentaryLayer(3))
            XCTAssertNoThrow(try XCTUnwrap(model.draft).validate())
        }
    }

    func testLongPressMomentaryLayersPreserveOrdinaryPrimaryAction() async throws {
        let model = model()
        XCTAssertTrue(model.assign([KeyEntry(code: 0x04)], gesture: .press))
        let primary = try XCTUnwrap(model.control(0))
        for layer in 1...3 {
            XCTAssertTrue(model.assignAction(.momentaryLayer(layer), gesture: .longPress))
            XCTAssertEqual(model.control(0)?.press, primary.press)
            XCTAssertEqual(model.control(0)?.pressAction, primary.pressAction)
            XCTAssertEqual(model.assignedAction(0), .keyboard([KeyEntry(code: 0x04)]))
            XCTAssertEqual(model.assignedAction(0, gesture: .longPress), .momentaryLayer(layer))
            XCTAssertNoThrow(try XCTUnwrap(model.draft).validate())
        }
    }

    func testDisablingLongPressLayerSwitchRestoresOriginalPrimaryConfiguration() async throws {
        for primaryIsLayer in [false, true] {
            let model = model()
            if primaryIsLayer { XCTAssertTrue(model.assignAction(.momentaryLayer(1))) }
            let original = model.draft
            let primary = model.assignedAction(0)
            model.gesture = .longPress
            XCTAssertTrue(model.assignAction(.momentaryLayer(2)))
            model.disableGesture()
            XCTAssertNil(model.assignedAction(0, gesture: .longPress))
            XCTAssertEqual(model.assignedAction(0), primary)
            XCTAssertEqual(model.draft, original)
            XCTAssertTrue(model.assignAction(.momentaryLayer(3)))
            XCTAssertEqual(model.assignedAction(0, gesture: .longPress), .momentaryLayer(3))
            XCTAssertEqual(model.assignedAction(0), primary)
        }
    }

    func testInvalidLayerTargetsAndUnsupportedGesturesPreserveDraft() async throws {
        let model = model()
        let original = model.draft
        for target in [0, 4, 8] {
            for gesture in [AssignmentGesture.press, .longPress] {
                XCTAssertFalse(model.assignAction(.momentaryLayer(target), gesture: gesture))
                XCTAssertEqual(model.draft, original)
            }
        }
        for index in [4, 5] {
            for gesture in [AssignmentGesture.press, .longPress] {
                XCTAssertFalse(model.assignAction(.momentaryLayer(1), index: index, gesture: gesture))
                XCTAssertEqual(model.draft, original)
            }
        }
        XCTAssertFalse(model.assignAction(.momentaryLayer(1), gesture: .doublePress))
        XCTAssertEqual(model.draft, original)
        XCTAssertNotNil(model.notice)
    }

    func testFixedLayersCanBeSelectedWithoutCreatingDraftAndAcceptMomentaryLayerThree() async throws {
        let model = model()
        XCTAssertEqual(model.layerIDs, [0, 1, 2, 3])
        for layer in model.layerIDs {
            model.selectedLayer = layer
            XCTAssertTrue(model.canEdit)
            XCTAssertNil(model.draft)
            XCTAssertEqual(model.control(0), HostKeymap.defaultKeymap.control(index: 0, layer: 0))
            XCTAssertEqual(model.isInherited(0), layer != 0)
        }
        model.selectedLayer = 0
        XCTAssertTrue(model.assignAction(.momentaryLayer(3)))
        let draft = try XCTUnwrap(model.draft)
        XCTAssertTrue(draft.layers.isEmpty)
        XCTAssertEqual(model.assignedAction(0), .momentaryLayer(3))
        XCTAssertNoThrow(try draft.validate())
    }

    func testSparseLayerRecordsAreCreatedOnEditAndDiscardRestoresBaseSelection() async throws {
        let model = model()
        model.selectedLayer = 3
        XCTAssertTrue(model.assign([KeyEntry(code: 0x04)], index: 1))
        XCTAssertEqual(model.draft?.layers.map(\.id), [3])
        XCTAssertEqual(model.draft?.layers.first?.controls.map(\.index), [1])
        model.selected = 1
        model.inheritControl()
        XCTAssertNil(model.draft)
        XCTAssertEqual(model.selectedLayer, 3)
        XCTAssertTrue(model.assign([KeyEntry(code: 0x05)], index: 2))
        model.discard()
        XCTAssertNil(model.draft)
        XCTAssertEqual(model.selectedLayer, 0)
        XCTAssertEqual(model.layerIDs, [0, 1, 2, 3])
    }

    func testLibraryUsageCountsExplicitBindingsAcrossAllLayers() async throws {
        let model = model()
        let macro: HostAction = .macro([.keyboard([KeyEntry(code: 0x04)])])
        let id = try XCTUnwrap(model.saveLibraryAction(id: nil, name: "Shared", action: macro))
        XCTAssertTrue(model.assignLibraryAction(id))
        model.selectedLayer = 1
        XCTAssertEqual(model.usageCount(id), 1)
        XCTAssertEqual(model.action(0), macro)
        model.selected = 1
        XCTAssertTrue(model.assignLibraryAction(id))
        model.selectedLayer = 2
        model.selected = 2
        model.gesture = .doublePress
        XCTAssertTrue(model.assignLibraryAction(id))
        XCTAssertEqual(model.usageCount(id), 3)
        XCTAssertFalse(model.canRemoveLibraryAction(id))
        model.inheritControl()
        XCTAssertEqual(model.usageCount(id), 2)
        model.selectedLayer = 1
        model.selected = 1
        model.inheritControl()
        XCTAssertEqual(model.usageCount(id), 1)
        model.selectedLayer = 0
        XCTAssertTrue(model.assign([KeyEntry(code: 0x01)], index: 0))
        XCTAssertEqual(model.usageCount(id), 0)
        XCTAssertTrue(model.canRemoveLibraryAction(id))
    }

    func testProfileRoundTripPreservesSparseLayerOverridesAndMomentaryActions() async throws {
        let model = model()
        model.selectedLayer = 1
        XCTAssertTrue(model.assign([KeyEntry(code: 0x04)], index: 1))
        model.selectedLayer = 0
        XCTAssertTrue(model.assignAction(.momentaryLayer(1)))
        model.saveProfile(name: "Layered")
        let profile = try XCTUnwrap(model.profiles.first)
        let restored = try HostProfile.decode(data: JSONEncoder().encode(profile))
        XCTAssertEqual(restored.keymap, model.draft)
        XCTAssertEqual(restored.keymap.version, 5)
        model.selectedLayer = 2
        model.loadProfile(restored)
        XCTAssertEqual(model.layerIDs, [0, 1, 2, 3])
        XCTAssertEqual(model.draft?.layers.map(\.id), [1])
        model.selectedLayer = 0
        XCTAssertEqual(model.assignedAction(0), .momentaryLayer(1))
        model.selectedLayer = 1
        XCTAssertEqual(model.action(1), .keyboard([KeyEntry(code: 0x04)]))
        XCTAssertTrue(model.isInherited(0))
        model.loadDefaults()
        XCTAssertNil(model.draft)
        XCTAssertEqual(model.layerIDs, [0, 1, 2, 3])
    }

    func testReceivingLegacyKeymapKeepsFixedLayersAvailableWithoutStartingService() async throws {
        var map = HostKeymap.defaultKeymap
        map.layers = [HostLayer(id: 1)]
        let model = model(keymap: map)
        model.selectedLayer = 1
        var snapshot = model.device
        snapshot.hostKeymap = .defaultKeymap
        model.receive(snapshot)
        XCTAssertEqual(model.layerIDs, [0, 1, 2, 3])
        model.selectedLayer = 3
        XCTAssertTrue(model.isInherited(0))
        XCTAssertEqual(model.control(0), HostKeymap.defaultKeymap.control(index: 0, layer: 0))
        XCTAssertNil(model.draft)
        XCTAssertNil(model.submittedID)
    }
}
