import CoreGraphics
import XCTest
@testable import OlanziCore

final class MacroRecordingSessionTests: XCTestCase {
    private func keyboard(_ codes: UInt8...) -> MacroStep { .keyboard(codes.map { KeyEntry(code: $0) }) }

    func testSequentialPressesBecomeSeparateStepsAndOverlapBecomesOneChord() {
        var session = MacroRecordingSession(recordDelays: false)
        session.receiveKeyDown(keyCode: 0, flags: 0, at: 1)
        session.receiveKeyUp(keyCode: 0, flags: 0, at: 1.1)
        session.receiveKeyDown(keyCode: 11, flags: 0, at: 2)
        session.receiveKeyUp(keyCode: 11, flags: 0, at: 2.1)
        session.receiveKeyDown(keyCode: 8, flags: 0, at: 3)
        session.receiveKeyDown(keyCode: 2, flags: 0, at: 3.01)
        session.receiveKeyUp(keyCode: 8, flags: 0, at: 3.1)
        XCTAssertEqual(session.steps, [keyboard(0x04), keyboard(0x05)])
        XCTAssertTrue(session.hasPendingChord)
        session.receiveKeyUp(keyCode: 2, flags: 0, at: 3.2)
        XCTAssertEqual(session.steps, [keyboard(0x04), keyboard(0x05), keyboard(0x06, 0x07)])
        XCTAssertTrue(session.isRecording)
        XCTAssertNil(session.error)
    }

    func testIntervalsMeasurePreviousReleaseToNextPressAndRoundToMilliseconds() throws {
        var session = MacroRecordingSession(recordDelays: true)
        session.receiveKeyDown(keyCode: 0, flags: 0, at: 100)
        session.receiveKeyUp(keyCode: 0, flags: 0, at: 101)
        session.receiveKeyDown(keyCode: 11, flags: 0, at: 101.1254)
        session.receiveKeyUp(keyCode: 11, flags: 0, at: 102)
        XCTAssertEqual(session.steps, [keyboard(0x04), .delay(0.125), keyboard(0x05)])
        // 本机录制和 QMK 代码模式保持可往返，不把浮点事件时间导出为非法小数毫秒。
        XCTAssertEqual(try QMKMacroCodec.decode(QMKMacroCodec.encode(session.steps)), session.steps)
    }

    func testShortIntervalsAreOmittedAndDisabledDelaysPermitLongPauses() {
        var session = MacroRecordingSession(recordDelays: true)
        session.receiveKeyDown(keyCode: 0, flags: 0, at: 0)
        session.receiveKeyUp(keyCode: 0, flags: 0, at: 0.1)
        session.receiveKeyDown(keyCode: 11, flags: 0, at: 0.14)
        session.receiveKeyUp(keyCode: 11, flags: 0, at: 0.2)
        XCTAssertEqual(session.steps, [keyboard(0x04), keyboard(0x05)])
        var withoutDelay = MacroRecordingSession(recordDelays: false)
        withoutDelay.receiveKeyDown(keyCode: 0, flags: 0, at: 0)
        withoutDelay.receiveKeyUp(keyCode: 0, flags: 0, at: 0.1)
        withoutDelay.receiveKeyDown(keyCode: 11, flags: 0, at: 100)
        withoutDelay.receiveKeyUp(keyCode: 11, flags: 0, at: 100.1)
        XCTAssertEqual(withoutDelay.steps, [keyboard(0x04), keyboard(0x05)])
        XCTAssertTrue(withoutDelay.isRecording)
    }

    func testLongRecordedIntervalStopsWithoutTruncationOrPartialStep() {
        var session = MacroRecordingSession(recordDelays: true)
        session.receiveKeyDown(keyCode: 0, flags: 0, at: 0)
        session.receiveKeyUp(keyCode: 0, flags: 0, at: 1)
        session.receiveKeyDown(keyCode: 11, flags: 0, at: 11.01)
        session.receiveKeyUp(keyCode: 11, flags: 0, at: 12)
        XCTAssertEqual(session.steps, [keyboard(0x04)])
        XCTAssertFalse(session.isRecording)
        XCTAssertFalse(session.hasPendingChord)
        XCTAssertTrue(session.error?.contains("10 秒") == true)
    }

    func testIntervalIncludesModifierPressButNotTimeHeldInChord() {
        var session = MacroRecordingSession(recordDelays: true)
        let command = CGEventFlags.maskCommand.rawValue
        session.receiveKeyDown(keyCode: 0, flags: 0, at: 0)
        session.receiveKeyUp(keyCode: 0, flags: 0, at: 1)
        session.receiveFlagsChanged(keyCode: 55, flags: command, at: 1.2)
        session.receiveKeyDown(keyCode: 11, flags: command, at: 1.5)
        session.receiveKeyUp(keyCode: 11, flags: command, at: 2)
        XCTAssertEqual(session.steps, [keyboard(0x04)])
        session.receiveFlagsChanged(keyCode: 0, flags: 0, at: 2.2)
        XCTAssertEqual(session.steps, [keyboard(0x04), .delay(0.2), keyboard(0xE3, 0x05)])
    }

    func testRepeatsAndUnmatchedReleasesCannotCreateStepsOrChangeInterval() {
        var session = MacroRecordingSession(recordDelays: true)
        session.receiveKeyUp(keyCode: 0, flags: 0, at: 0)
        session.receiveFlagsChanged(keyCode: 55, flags: 0, at: 0.1)
        session.receiveKeyDown(keyCode: 0, flags: 0, isRepeat: true, at: 0.2)
        XCTAssertTrue(session.steps.isEmpty)
        XCTAssertFalse(session.hasPendingChord)
        session.receiveKeyDown(keyCode: 0, flags: 0, at: 1)
        session.receiveKeyDown(keyCode: 0, flags: 0, isRepeat: true, at: 2)
        session.receiveKeyUp(keyCode: 0, flags: 0, at: 3)
        session.receiveKeyDown(keyCode: 11, flags: 0, isRepeat: true, at: 3.1)
        session.receiveKeyUp(keyCode: 11, flags: 0, at: 3.2)
        session.receiveKeyDown(keyCode: 11, flags: 0, at: 3.5)
        session.receiveKeyUp(keyCode: 11, flags: 0, at: 3.6)
        XCTAssertEqual(session.steps, [keyboard(0x04), .delay(0.5), keyboard(0x05)])
    }

    func testFocusLossPreservesCompletedStepsAndDiscardsIncompleteChordAndDelay() {
        var session = MacroRecordingSession(recordDelays: true)
        session.receiveKeyDown(keyCode: 0, flags: 0, at: 0)
        session.receiveKeyUp(keyCode: 0, flags: 0, at: 0.1)
        session.receiveKeyDown(keyCode: 11, flags: 0, at: 1)
        session.interrupt()
        XCTAssertEqual(session.steps, [keyboard(0x04)])
        XCTAssertFalse(session.isRecording)
        XCTAssertFalse(session.hasPendingChord)
        XCTAssertTrue(session.error?.contains("失去焦点") == true)
        session.receiveKeyUp(keyCode: 11, flags: 0, at: 1.1)
        session.receiveKeyDown(keyCode: 8, flags: 0, at: 2)
        XCTAssertEqual(session.steps, [keyboard(0x04)])
    }

    func testManualStopPreservesCompletedStepsWithoutAddingEscapeOrIncompleteStep() {
        var session = MacroRecordingSession(recordDelays: false)
        // Esc 是可录制的真实动作，不是停止录制的隐式快捷键。
        session.receiveKeyDown(keyCode: 53, flags: 0, at: 0)
        session.receiveKeyUp(keyCode: 53, flags: 0, at: 0.1)
        session.receiveKeyDown(keyCode: 0, flags: 0, at: 1)
        session.stop()
        XCTAssertEqual(session.steps, [keyboard(0x29)])
        XCTAssertFalse(session.isRecording)
        XCTAssertFalse(session.hasPendingChord)
        XCTAssertNil(session.error)
    }

    func testCapacityStopsAtThirtyTwoCompletedSteps() {
        var session = MacroRecordingSession(recordDelays: false)
        for index in 0..<33 {
            session.receiveKeyDown(keyCode: 0, flags: 0, at: Double(index))
            session.receiveKeyUp(keyCode: 0, flags: 0, at: Double(index) + 0.1)
        }
        XCTAssertEqual(session.steps, Array(repeating: keyboard(0x04), count: 32))
        XCTAssertFalse(session.isRecording)
        XCTAssertTrue(session.error?.contains("32") == true)
    }

    func testCapacityReservesDelayAndKeyboardAtomically() {
        var session = MacroRecordingSession(recordDelays: true)
        for index in 0..<16 {
            session.receiveKeyDown(keyCode: 0, flags: 0, at: Double(index))
            session.receiveKeyUp(keyCode: 0, flags: 0, at: Double(index) + 0.1)
        }
        XCTAssertEqual(session.steps.count, 31)
        let completed = session.steps
        session.receiveKeyDown(keyCode: 11, flags: 0, at: 16)
        session.receiveKeyUp(keyCode: 11, flags: 0, at: 16.1)
        XCTAssertEqual(session.steps, completed)
        XCTAssertFalse(session.isRecording)
        XCTAssertNotNil(session.error)
        XCTAssertFalse(session.hasPendingChord)
    }

    func testFnRequiresExplicitFlagsAndCommandCombinationsWaitForRelease() {
        var session = MacroRecordingSession(recordDelays: false)
        let command = CGEventFlags.maskCommand.rawValue
        let function = CGEventFlags.maskSecondaryFn.rawValue
        session.receiveKeyDown(keyCode: 34, flags: command, at: 0)
        session.receiveKeyUp(keyCode: 34, flags: command, at: 0.1)
        XCTAssertTrue(session.steps.isEmpty)
        session.receiveFlagsChanged(keyCode: 0, flags: 0, at: 0.2)
        session.receiveKeyDown(keyCode: 105, flags: function, at: 1)
        session.receiveKeyUp(keyCode: 105, flags: function, at: 1.1)
        session.receiveFlagsChanged(keyCode: 63, flags: function, at: 2)
        session.receiveKeyDown(keyCode: 105, flags: function, at: 2.1)
        session.receiveKeyUp(keyCode: 105, flags: function, at: 2.2)
        session.receiveFlagsChanged(keyCode: 0, flags: 0, at: 2.3)
        XCTAssertEqual(session.steps, [keyboard(0xE3, 0x0C), keyboard(0x68)])
        session.receiveFlagsChanged(keyCode: 63, flags: 0, at: 2.4)
        XCTAssertEqual(session.steps, [keyboard(0xE3, 0x0C), keyboard(0x68), keyboard(1, 0x68)])
    }

    func testUnsupportedEventStopsAndKeepsOnlyCompletedSteps() {
        var session = MacroRecordingSession(recordDelays: true)
        session.receiveKeyDown(keyCode: 0, flags: 0, at: 0)
        session.receiveKeyUp(keyCode: 0, flags: 0, at: 0.1)
        session.receiveKeyDown(keyCode: 11, flags: 0, at: 1)
        session.receiveKeyDown(keyCode: 72, flags: 0, at: 1.1)
        XCTAssertEqual(session.steps, [keyboard(0x04)])
        XCTAssertFalse(session.isRecording)
        XCTAssertFalse(session.hasPendingChord)
        XCTAssertNotNil(session.error)
    }
}
