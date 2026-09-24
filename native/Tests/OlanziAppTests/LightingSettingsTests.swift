import XCTest
import OlanziCore
@testable import OlanziApp

@MainActor
final class LightingSettingsTests: XCTestCase {
    private func snapshot() -> DeviceSnapshot {
        var result = DeviceSnapshot()
        result.connected = true
        result.online = true
        result.hostKeymap = .defaultKeymap
        result.lighting = DeviceLighting(mode: 2, brightness: 2, lights: (0..<4).map {
            IndicatorLight(type: 1, workTime: UInt8(11 + $0), breatheLevel: 12,
                           breatheBrightness: 13, alwaysOnBrightness: 14)
        })
        return result
    }

    func testEditsPreserveUnexposedFieldsAndKeymapDraftAcrossSnapshots() async throws {
        let model = AppModel(demo: true)
        let state = snapshot()
        model.receive(state)
        model.assign(0x04)
        let keymapDraft = model.draft
        model.editLighting { $0.lights[0].type = 2 }
        let edited = try XCTUnwrap(model.lightingDraft)
        model.receive(state)
        XCTAssertEqual(model.lighting, edited)
        XCTAssertEqual(model.draft, keymapDraft)
        XCTAssertEqual(edited.lights[0].workTime, 11)
        XCTAssertEqual(edited.lights[0].breatheLevel, 12)
        XCTAssertEqual(edited.lights[0].breatheBrightness, 13)
        XCTAssertEqual(edited.lights[0].alwaysOnBrightness, 14)
        model.editLighting { $0.lights[0].type = 1 }
        XCTAssertNil(model.lightingDraft)
    }

    func testApplyMatchesRequestAndPreservesDraftOnFailure() async throws {
        let model = AppModel(demo: true, language: .english)
        var state = snapshot()
        model.receive(state)
        model.editLighting { $0.brightness = 1 }
        model.applyLighting()
        let request = try XCTUnwrap(model.lightingSubmittedID)
        state.lightingResult = HostSaveResult(requestID: UUID())
        model.receive(state)
        XCTAssertEqual(model.lightingSubmittedID, request)
        state.lightingResult = HostSaveResult(requestID: request, error: "设备灯效已变化，请重新读取后再应用。")
        model.receive(state)
        XCTAssertNil(model.lightingSubmittedID)
        XCTAssertEqual(model.lightingDraft?.brightness, 1)
        XCTAssertNil(model.notice)
        model.applyLighting()
        let second = try XCTUnwrap(model.lightingSubmittedID)
        state.lighting = model.lightingDraft
        state.lightingResult = HostSaveResult(requestID: second)
        model.receive(state)
        XCTAssertNil(model.lightingDraft)
        XCTAssertNil(model.notice)
    }

    func testEnteringLightingWaitsForBusyThenReadsOnlyOnceAfterFailure() async throws {
        let model = AppModel(demo: true)
        var state = snapshot()
        state.busy = true
        state.lighting = nil
        model.receive(state)
        model.page = 2
        XCTAssertFalse(model.lightingReading)
        state.busy = false
        model.receive(state)
        XCTAssertTrue(model.lightingReading)
        state.busy = true
        model.receive(state)
        state.busy = false
        state.lightingError = "无法读取设备。"
        model.receive(state)
        XCTAssertFalse(model.lightingReading)
        model.receive(state)
        XCTAssertFalse(model.lightingReading)
        model.page = 1
        model.page = 2
        XCTAssertTrue(model.lightingReading)
    }

    func testEnteringOfflineReadsOnConnectionAndReturningPreservesDraft() async throws {
        let model = AppModel(demo: true)
        model.page = 2
        XCTAssertFalse(model.lightingReading)
        var state = snapshot()
        model.receive(state)
        XCTAssertTrue(model.lightingReading)
        state.busy = true
        model.receive(state)
        state.busy = false
        model.receive(state)
        model.editLighting { $0.brightness = 9 }
        let draft = model.lightingDraft
        model.page = 0
        model.page = 2
        XCTAssertFalse(model.lightingReading)
        XCTAssertEqual(model.lightingDraft, draft)
    }

    func testPartialFailureUsesReadbackAsNextEditBaselineWithoutToast() async throws {
        let model = AppModel(demo: true, language: .english)
        var state = snapshot()
        model.receive(state)
        model.editLighting { $0.mode = 1; $0.brightness = 9 }
        model.applyLighting()
        let request = try XCTUnwrap(model.lightingSubmittedID)
        state.lighting?.mode = 1
        state.lightingFailureFields = ["全亮亮度"]
        state.lightingResult = HostSaveResult(requestID: request, error: "部分灯效未生效。")
        model.receive(state)
        XCTAssertNil(model.notice)
        XCTAssertEqual(model.lightingFailureText, "Not applied: All On Brightness")
        XCTAssertNotNil(model.lightingDraft)
        model.editLighting { $0.brightness = 2 }
        XCTAssertNil(model.lightingDraft)
        XCTAssertNil(model.lightingFailureText)
    }

    func testMissingFailureReadbackKeepsBaselineForExplicitRetry() async throws {
        let model = AppModel(demo: true)
        var state = snapshot()
        model.receive(state)
        model.editLighting { $0.brightness = 9 }
        model.applyLighting()
        let request = try XCTUnwrap(model.lightingSubmittedID)
        state.lighting = nil
        state.lightingError = "无法读取设备。"
        state.lightingResult = HostSaveResult(requestID: request, error: state.lightingError)
        model.receive(state)
        XCTAssertNotNil(model.lightingErrorText)
        XCTAssertTrue(model.canApplyLighting)
        model.applyLighting()
        XCTAssertNotNil(model.lightingSubmittedID)
        XCTAssertNil(model.lightingErrorText)
    }

    func testUnknownKnobBrightnessCanExplicitlyWriteTheRawPlaceholder() async throws {
        let model = AppModel(demo: true)
        var state = snapshot()
        state.lighting?.lights[3].alwaysOnBrightness = 2
        model.receive(state)
        XCTAssertFalse(model.lightingKnobBrightnessKnown)
        model.editKnobBrightness(2)
        XCTAssertTrue(model.lightingKnobBrightnessEdited)
        XCTAssertNotNil(model.lightingDraft)
        XCTAssertTrue(model.canApplyLighting)
        model.applyLighting()
        XCTAssertNotNil(model.lightingSubmittedID)
    }

    func testKnobConfirmationCompletesSaveAndSurvivesReadWhileRawValueStaysOld() async throws {
        let model = AppModel(demo: true)
        var state = snapshot()
        state.lighting?.lights[3].alwaysOnBrightness = 2
        model.receive(state)
        model.editKnobBrightness(5)
        model.applyLighting()
        let request = try XCTUnwrap(model.lightingSubmittedID)
        state.lightingKnobBrightnessConfirmation = 5
        state.lightingResult = HostSaveResult(requestID: request)
        model.receive(state)
        XCTAssertNil(model.lightingDraft)
        XCTAssertFalse(model.lightingKnobBrightnessEdited)
        XCTAssertTrue(model.lightingKnobBrightnessKnown)
        XCTAssertEqual(model.lighting?.lights[3].alwaysOnBrightness, 5)
        XCTAssertEqual(model.device.lighting?.lights[3].alwaysOnBrightness, 2)
        model.readLighting()
        state.busy = true
        model.receive(state)
        state.busy = false
        model.receive(state)
        XCTAssertEqual(model.lighting?.lights[3].alwaysOnBrightness, 5)
        model.editKnobBrightness(7)
        state.connected = false
        state.online = false
        state.lightingKnobBrightnessConfirmation = nil
        model.receive(state)
        XCTAssertNil(model.lightingDraft)
        XCTAssertFalse(model.lightingKnobBrightnessEdited)
        XCTAssertFalse(model.lightingKnobBrightnessKnown)
    }

    func testBusyAndOfflinePreventEditingAndReadingCompletesAfterBusy() async throws {
        let model = AppModel(demo: true)
        var state = snapshot()
        model.receive(state)
        model.readLighting()
        XCTAssertTrue(model.lightingReading)
        model.editLighting { $0.mode = 0 }
        XCTAssertNil(model.lightingDraft)
        state.busy = true
        model.receive(state)
        state.busy = false
        model.receive(state)
        XCTAssertFalse(model.lightingReading)
        model.editLighting { $0.mode = 0 }
        XCTAssertNotNil(model.lightingDraft)
        state.online = false
        model.receive(state)
        XCTAssertNil(model.lightingDraft)
        XCTAssertFalse(model.canEditLighting)
        model.readLighting()
        XCTAssertFalse(model.lightingReading)
    }
}
