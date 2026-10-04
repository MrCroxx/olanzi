import XCTest
import OlanziCore
@testable import OlanziApp

/// 演示模型测试，不访问设备或生成真实滚动事件。
@MainActor
final class ScrollAssignmentTests: XCTestCase {
    private func model(keymap: HostKeymap = .defaultKeymap) -> AppModel {
        let model = AppModel(demo: true, language: .simplifiedChinese)
        var snapshot = DeviceSnapshot()
        snapshot.demo = true
        snapshot.hostKeymap = keymap
        model.receive(snapshot)
        return model
    }

    func testDefaultScrollAssignmentReplacesOnlyRotationAndPreservesDictation() async throws {
        var keymap = HostKeymap.defaultKeymap
        let dictation = [KeyEntry(code: 0xE0), KeyEntry(code: 0xE2), KeyEntry(code: 0xE1), KeyEntry(code: 0x19)]
        keymap.controls[0].press = dictation
        let model = model(keymap: keymap)
        for (index, upward) in [(5, true), (4, false)] {
            model.selected = index
            XCTAssertTrue(model.assignScroll(upward: upward))
            let control = try XCTUnwrap(model.control(index))
            XCTAssertEqual(control.press, [])
            XCTAssertEqual(control.pressAction, .scroll(vertical: upward ? 60 : -60))
            XCTAssertNil(model.entries(index))
            XCTAssertNil(model.code(index))
            XCTAssertTrue(model.isDirty(index))
        }
        XCTAssertEqual(model.control(0), keymap.controls[0])
        XCTAssertEqual(model.entries(0), dictation)
        for index in 0..<4 { XCTAssertFalse(model.isDirty(index)) }
        XCTAssertEqual(model.device.hostKeymap, keymap)
        XCTAssertFalse(model.applying)
        XCTAssertNil(model.submittedID)
        try XCTUnwrap(model.draft).validate()
    }

    func testScrollSupportsGesturesAndLayersWithoutKeyboardRepeatOptions() async throws {
        let model = model()
        for gesture in AssignmentGesture.allCases {
            model.gesture = gesture
            XCTAssertTrue(model.assignScroll(upward: true, pixels: 80))
            XCTAssertEqual(model.action(0, gesture: gesture), .scroll(vertical: 80))
            XCTAssertNil(model.entries(0, gesture: gesture))
            let draft = model.draft
            XCTAssertFalse(model.setActionBehavior(.burst))
            XCTAssertFalse(model.setActionTapCount(5))
            XCTAssertEqual(model.draft, draft)
        }
        model.selected = 5
        XCTAssertTrue(model.assignScroll(upward: true))
        model.selectedLayer = 2
        XCTAssertTrue(model.isInherited(5))
        XCTAssertTrue(model.assignScroll(upward: false, pixels: 120))
        XCTAssertFalse(model.isInherited(5))
        XCTAssertEqual(model.action(5), .scroll(vertical: -120))
        model.inheritAction()
        XCTAssertTrue(model.isInherited(5))
        XCTAssertEqual(model.action(5), .scroll(vertical: 60))
    }

    func testScrollLabelsAndLibraryExclusionInBothLanguages() async {
        let model = model()
        XCTAssertEqual(model.actionLabel(.scroll(vertical: 60)), "向上滚动 · 60 像素")
        XCTAssertEqual(model.actionLabel(.scroll(vertical: -100)), "向下滚动 · 100 像素")
        model.language = .english
        XCTAssertEqual(model.actionLabel(.scroll(vertical: 60)), "Scroll Up · 60 px")
        XCTAssertEqual(model.actionLabel(.scroll(vertical: -100)), "Scroll Down · 100 px")
        XCTAssertEqual(model.l("滚动"), "Scroll")
        XCTAssertFalse(LibraryActionKind.application.includes(.scroll(vertical: 60)))
        XCTAssertFalse(LibraryActionKind.macro.includes(.scroll(vertical: 60)))
        XCTAssertNil(model.saveLibraryAction(id: nil, name: "Scroll", action: .scroll(vertical: 60)))
        XCTAssertTrue(model.libraryItems.isEmpty)
        XCTAssertNil(model.draft)
    }

    func testScrollProfileRoundTripAndDiscardPreserveSavedConfiguration() async throws {
        let model = model()
        model.selected = 5
        XCTAssertTrue(model.assignScroll(upward: true, pixels: 120))
        model.selected = 4
        XCTAssertTrue(model.assignScroll(upward: false, pixels: 120))
        let draft = try XCTUnwrap(model.draft)
        model.saveProfile(name: "阅读")
        let decoded = try HostProfile.decode(data: JSONEncoder().encode(XCTUnwrap(model.profiles.first)))
        XCTAssertEqual(decoded.keymap, draft)
        XCTAssertTrue(model.profileSummary(decoded).contains("向上滚动 · 120 像素"))
        model.discard()
        XCTAssertNil(model.draft)
        XCTAssertEqual(model.device.hostKeymap, .defaultKeymap)
        model.loadProfile(decoded)
        XCTAssertEqual(model.draft, draft)
    }

    func testInvalidScrollMagnitudeDoesNotMutateDraft() async throws {
        let model = model()
        model.selected = 5
        XCTAssertTrue(model.assignScroll(upward: true))
        let draft = try XCTUnwrap(model.draft)
        for pixels in [Int.min, -20, 0, 601, Int.max] {
            XCTAssertFalse(model.assignScroll(upward: true, pixels: pixels))
            XCTAssertFalse(model.assignScroll(upward: false, pixels: pixels))
            XCTAssertEqual(model.draft, draft)
        }
    }

    func testScrollSaveAcknowledgementKeepsLaterStepEditsAsDraft() async throws {
        let model = model()
        model.selected = 5
        XCTAssertTrue(model.assignScroll(upward: true))
        let submitted = try XCTUnwrap(model.draft)
        model.apply()
        let requestID = try XCTUnwrap(model.submittedID)
        XCTAssertTrue(model.applying)
        XCTAssertEqual(model.device.hostKeymap, .defaultKeymap)
        XCTAssertTrue(model.assignScroll(upward: true, pixels: 80))
        let laterDraft = try XCTUnwrap(model.draft)
        var snapshot = DeviceSnapshot()
        snapshot.demo = true
        snapshot.hostKeymap = submitted
        snapshot.hostSaveResult = HostSaveResult(requestID: requestID)
        model.receive(snapshot)
        XCTAssertFalse(model.applying)
        XCTAssertNil(model.submittedID)
        XCTAssertEqual(model.device.hostKeymap, submitted)
        XCTAssertEqual(model.draft, laterDraft)
        XCTAssertEqual(model.action(5), .scroll(vertical: 80))
        model.discard()
        XCTAssertEqual(model.action(5), .scroll(vertical: 60))
    }
}
