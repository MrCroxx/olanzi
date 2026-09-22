import XCTest
import OlanziCore
@testable import OlanziApp

@MainActor
final class ActionLibraryTests: XCTestCase {
    private let target = ApplicationTarget(bundleIdentifier: "com.example.editor", path: "/Applications/Editor.app", name: "Editor")
    private var macro: HostAction { .macro([.keyboard([KeyEntry(code: 0x04)])]) }

    private func model() -> AppModel {
        let model = AppModel(demo: true, language: .simplifiedChinese)
        var snapshot = DeviceSnapshot()
        snapshot.demo = true
        snapshot.hostKeymap = .defaultKeymap
        model.receive(snapshot)
        return model
    }

    func testUnboundLibraryEditsAreDraftOnlyAndUndoRestoresSavedLibrary() async throws {
        let model = model()
        let id = try XCTUnwrap(model.saveLibraryAction(id: nil, name: "  My macro  ", action: macro))
        XCTAssertTrue(model.hasDraft)
        XCTAssertEqual(model.libraryItems.map(\.id), [id])
        XCTAssertEqual(model.libraryItems[0].name, "My macro")
        XCTAssertEqual(model.libraryItems[0].slot, 0)
        XCTAssertEqual(model.dirtyCount, 0)
        XCTAssertEqual(model.device.hostKeymap, .defaultKeymap)
        XCTAssertNil(model.submittedID)
        XCTAssertFalse(model.applying)
        model.discard()
        XCTAssertTrue(model.libraryItems.isEmpty)
        XCTAssertFalse(model.hasDraft)
    }

    func testEditingLibraryUpdatesEveryReferenceAndMarksBoundControlsDirty() async throws {
        let model = model()
        let id = try XCTUnwrap(model.saveLibraryAction(id: nil, name: "Original", action: macro))
        model.selected = 0
        XCTAssertTrue(model.assignLibraryAction(id))
        model.selected = 1
        model.gesture = .doublePress
        XCTAssertTrue(model.assignLibraryAction(id))
        var saved = model.device
        saved.hostKeymap = try XCTUnwrap(model.draft)
        model.receive(saved)
        model.discard()
        XCTAssertEqual(model.usageCount(id), 2)
        XCTAssertEqual(model.assignedAction(0), .library(id))
        XCTAssertEqual(model.assignedAction(1, gesture: .doublePress), .library(id))
        XCTAssertEqual(model.action(0), macro)
        let edited: HostAction = .macro([.application(target), .delay(0.2)])
        XCTAssertEqual(model.saveLibraryAction(id: id, name: "Updated", action: edited), id)
        XCTAssertEqual(model.action(0), edited)
        XCTAssertEqual(model.action(1, gesture: .doublePress), edited)
        XCTAssertEqual(model.label(0), "M0 · Updated")
        XCTAssertEqual(model.label(1, gesture: .doublePress), "M0 · Updated")
        XCTAssertTrue(model.isDirty(0))
        XCTAssertTrue(model.isDirty(1))
        XCTAssertEqual(model.device.hostKeymap?.actionLibrary[0].name, "Original")
        model.discard()
        XCTAssertEqual(model.action(0), macro)
        XCTAssertEqual(model.label(0), "M0 · Original")
    }

    func testReferencedLibraryCannotBeDeletedUntilAllBindingsAreRemoved() async throws {
        let model = model()
        let id = try XCTUnwrap(model.saveLibraryAction(id: nil, name: "Focus", action: .application(target)))
        model.selected = 0
        XCTAssertTrue(model.assignLibraryAction(id))
        model.selected = 1
        model.gesture = .longPress
        XCTAssertTrue(model.assignLibraryAction(id))
        let original = model.draft
        XCTAssertFalse(model.canRemoveLibraryAction(id))
        XCTAssertFalse(model.removeLibraryAction(id))
        XCTAssertEqual(model.draft, original)
        XCTAssertNotNil(model.notice)
        model.disableGesture()
        XCTAssertEqual(model.usageCount(id), 1)
        XCTAssertTrue(model.assign([KeyEntry(code: 0x01)], index: 0, gesture: .press))
        XCTAssertTrue(model.canRemoveLibraryAction(id))
        XCTAssertTrue(model.removeLibraryAction(id))
        XCTAssertEqual(model.libraryItems, [])
        XCTAssertNil(model.draft)
    }

    func testSlotsArePerCategoryReuseHolesAndEditingRetainsIdentity() async throws {
        let model = model()
        let macro0 = try XCTUnwrap(model.saveLibraryAction(id: nil, name: "Macro zero", action: macro))
        let macro1 = try XCTUnwrap(model.saveLibraryAction(id: nil, name: "Macro one", action: macro))
        let app0 = try XCTUnwrap(model.saveLibraryAction(id: nil, name: "App zero", action: .application(target)))
        XCTAssertEqual(model.libraryItems.first { $0.id == app0 }?.slot, 0)
        XCTAssertEqual(model.libraryItems.first { $0.id == macro1 }?.slot, 1)
        XCTAssertTrue(model.removeLibraryAction(macro0))
        let reused = try XCTUnwrap(model.saveLibraryAction(id: nil, name: "Reused", action: macro))
        XCTAssertEqual(model.libraryItems.first { $0.id == reused }?.slot, 0)
        XCTAssertEqual(model.saveLibraryAction(id: macro1, name: "Now an app", action: .application(target)), macro1)
        XCTAssertEqual(model.libraryItems.first { $0.id == macro1 }?.slot, 1)
        XCTAssertEqual(model.libraryItems.first { $0.id == macro1 }?.isMacro, false)
    }

    func testInvalidLibraryEditsAndMissingReferencesPreserveDraft() async throws {
        let model = model()
        let id = try XCTUnwrap(model.saveLibraryAction(id: nil, name: "Original", action: macro))
        let original = model.draft
        XCTAssertNil(model.saveLibraryAction(id: id, name: "", action: macro))
        XCTAssertNil(model.saveLibraryAction(id: id, name: "Nested", action: .library(id)))
        XCTAssertNil(model.saveLibraryAction(id: UUID(), name: "Missing", action: macro))
        XCTAssertNil(model.saveLibraryAction(id: id, name: "Keyboard", action: .keyboard([KeyEntry(code: 0x04)])))
        XCTAssertFalse(model.assignLibraryAction(UUID()))
        XCTAssertEqual(model.draft, original)
    }

    func testSixteenSlotsPerCategoryAreEnforcedWithoutChangingExistingDraft() async throws {
        let model = model()
        for slot in 0..<16 {
            let id = try XCTUnwrap(model.saveLibraryAction(id: nil, name: "Macro \(slot)", action: macro))
            XCTAssertEqual(model.libraryItems.first { $0.id == id }?.slot, slot)
        }
        let original = model.draft
        XCTAssertNil(model.saveLibraryAction(id: nil, name: "Overflow", action: macro))
        XCTAssertEqual(model.draft, original)
        XCTAssertNotNil(model.saveLibraryAction(id: nil, name: "App", action: .application(target)))
    }

    func testProfilesPreserveUnboundItemsAndReferencesAndSummaryUsesProfileLibrary() async throws {
        let model = model()
        let id = try XCTUnwrap(model.saveLibraryAction(id: nil, name: "Saved macro", action: macro))
        XCTAssertNotNil(model.saveLibraryAction(id: nil, name: "Unbound app", action: .application(target)))
        XCTAssertTrue(model.assignLibraryAction(id))
        model.saveProfile(name: "With library")
        let profile = try XCTUnwrap(model.profiles.first)
        let restored = try HostProfile.decode(data: JSONEncoder().encode(profile))
        model.discard()
        XCTAssertTrue(model.libraryItems.isEmpty)
        XCTAssertTrue(model.profileSummary(restored).contains("M0 · Saved macro"))
        model.loadProfile(restored)
        XCTAssertEqual(model.libraryItems.count, 2)
        XCTAssertEqual(model.assignedAction(0), .library(id))
        XCTAssertEqual(model.action(0), macro)
        XCTAssertEqual(model.draft, restored.keymap)
        XCTAssertEqual(model.device.hostKeymap, .defaultKeymap)
    }
}
