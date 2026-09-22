import CoreGraphics
import XCTest
@testable import OlanziCore

final class ShortcutCaptureTests: XCTestCase {
    private func capture(_ key: UInt16, _ flags: CGEventFlags = []) throws -> [KeyEntry] {
        try ShortcutCapture.entries(keyCode: key, flags: flags.rawValue)
    }

    func testFourModifiersUseCanonicalOrderAndLeftSideOnly() throws {
        let flags: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate,
                                  CGEventFlags(rawValue: 0x2014)]
        let entries = try capture(0, flags)
        XCTAssertEqual(entries.map(\.code), [0xE0, 0xE2, 0xE1, 0xE3, 0x04])
        XCTAssertTrue(entries.allSatisfy { $0.type == 2 })
        XCTAssertEqual(Set(entries.map(\.code)).count, entries.count)
    }

    func testEveryModifierCombinationHasExactlyOnePrimaryKey() throws {
        let modifiers: [CGEventFlags] = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
        for bits in 0..<16 {
            let flags = modifiers.enumerated().reduce(into: CGEventFlags()) { result, item in
                if bits & (1 << item.offset) != 0 { result.formUnion(item.element) }
            }
            let entries = try capture(36, flags)
            XCTAssertEqual(entries.count, bits.nonzeroBitCount + 1)
            XCTAssertEqual(entries.last, KeyEntry(code: 0x28))
            XCTAssertNoThrow(try MacKeyEmitter.validate(entries: entries))
        }
    }

    func testFunctionKeysPreferFNamesAndDoNotCaptureIntrinsicFn() throws {
        let virtualKeys: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
                                     105, 107, 113, 106, 64, 79, 80, 90]
        for (index, key) in virtualKeys.enumerated() {
            let usage = UInt8(index < 12 ? 0x3A + index : 0x68 + index - 12)
            XCTAssertEqual(try capture(key, [.maskSecondaryFn, .maskNonCoalesced]), [KeyEntry(code: usage)])
        }
    }

    func testSpecialKeysAndBackslashRoundTripToTheirVirtualKeys() throws {
        let mappings: [(UInt16, UInt8)] = [(53, 0x29), (48, 0x2B), (36, 0x28), (51, 0x2A),
            (117, 0x4C), (124, 0x4F), (123, 0x50), (125, 0x51), (126, 0x52),
            (115, 0x4A), (119, 0x4D), (116, 0x4B), (121, 0x4E), (42, 0x31), (76, 0x58)]
        for (key, usage) in mappings {
            let entries = try capture(key, [.maskSecondaryFn, .maskNumericPad, .maskAlphaShift])
            XCTAssertEqual(entries, [KeyEntry(code: usage)])
            XCTAssertEqual(MacKeyEmitter.virtualKey(for: usage), key)
        }
    }

    func testUnsupportedAndModifierOnlyEventsAreRejected() {
        for key: UInt16 in [54, 55, 56, 57, 58, 59, 60, 61, 62, 63] {
            XCTAssertThrowsError(try capture(key, [.maskCommand, .maskSecondaryFn])) {
                XCTAssertEqual($0 as? ShortcutCaptureError, .modifierOnly)
            }
        }
        // 这些音量键及未知虚拟键没有现有普通键盘映射，不猜测媒体 usage。
        for key: UInt16 in [72, 73, 74, 0xFF, 0xFFFF] {
            XCTAssertThrowsError(try capture(key)) {
                XCTAssertEqual($0 as? ShortcutCaptureError, .unsupportedKey(key))
            }
        }
    }

    func testCapturedCombinationPersistsAndEmitterUsesItsCanonicalKeys() throws {
        let entries = try capture(105, [.maskCommand, .maskControl, .maskSecondaryFn])
        var map = HostKeymap.defaultKeymap
        map.controls[3].press = entries
        let data = try JSONEncoder().encode(map)
        let restored = try HostKeymap.decode(data: data)
        XCTAssertEqual(restored.controls[3].press, [KeyEntry(code: 0xE0), KeyEntry(code: 0xE3), KeyEntry(code: 0x68)])
        var events: [CGEvent] = []
        let emitter = MacKeyEmitter(hardwareFlags: { [] }, post: { events.append($0) })
        try emitter.emit(entries: restored.controls[3].press, pressed: true)
        try emitter.emit(entries: restored.controls[3].press, pressed: false)
        XCTAssertEqual(events.map { $0.getIntegerValueField(.keyboardEventKeycode) }, [59, 55, 105, 105, 55, 59])
        XCTAssertEqual(events.map(\.type), [.flagsChanged, .flagsChanged, .keyDown, .keyUp, .flagsChanged, .flagsChanged])
        XCTAssertTrue(events[2].flags.contains([.maskControl, .maskCommand, .maskSecondaryFn]))
        XCTAssertEqual(events.last?.flags, [])
    }

    func testOverlappingOrdinaryKeysCompleteOnlyAfterLastRelease() throws {
        var session = ShortcutRecordingSession()
        try session.receiveKeyDown(keyCode: 0, flags: 0)
        try session.receiveKeyDown(keyCode: 11, flags: 0)
        try session.receiveKeyUp(keyCode: 0, flags: 0)
        XCTAssertFalse(session.isComplete)
        XCTAssertEqual(session.candidate.map(\.code), [0x04, 0x05])
        try session.receiveKeyUp(keyCode: 11, flags: 0)
        XCTAssertTrue(session.isComplete)
        // 完成后的下一个字符不得串入已录制组合。
        try session.receiveKeyDown(keyCode: 8, flags: 0)
        XCTAssertEqual(session.candidate.map(\.code), [0x04, 0x05])
    }

    func testSequentialTextDoesNotBecomeAMacroAndRepeatsAreIgnored() throws {
        var session = ShortcutRecordingSession()
        try session.receiveKeyDown(keyCode: 0, flags: 0, isRepeat: true)
        XCTAssertTrue(session.candidate.isEmpty)
        try session.receiveKeyDown(keyCode: 0, flags: 0)
        try session.receiveKeyDown(keyCode: 0, flags: 0)
        try session.receiveKeyDown(keyCode: 0, flags: 0, isRepeat: true)
        XCTAssertEqual(session.candidate, [KeyEntry(code: 0x04)])
        try session.receiveKeyUp(keyCode: 0, flags: 0)
        try session.receiveKeyDown(keyCode: 11, flags: 0)
        XCTAssertTrue(session.isComplete)
        XCTAssertEqual(session.candidate, [KeyEntry(code: 0x04)])
    }

    func testModifiersAndOrdinaryKeysAccumulateInCanonicalOrder() throws {
        var session = ShortcutRecordingSession()
        let control = CGEventFlags.maskControl.rawValue
        try session.receiveFlagsChanged(keyCode: 59, flags: control)
        try session.receiveKeyDown(keyCode: 11, flags: control)
        try session.receiveKeyDown(keyCode: 0, flags: control)
        // 修饰键先释放，仍有普通键按住，录制不能提前结束。
        try session.receiveFlagsChanged(keyCode: 59, flags: 0)
        try session.receiveKeyUp(keyCode: 11, flags: 0)
        XCTAssertFalse(session.isComplete)
        try session.receiveKeyUp(keyCode: 0, flags: 0)
        XCTAssertTrue(session.isComplete)
        XCTAssertEqual(session.candidate.map(\.code), [0xE0, 0x05, 0x04])
    }

    func testPureModifierCombinationWaitsForAllModifiersAndNormalizesSides() throws {
        var session = ShortcutRecordingSession()
        let command = CGEventFlags.maskCommand.rawValue
        let both = command | CGEventFlags.maskShift.rawValue
        try session.receiveFlagsChanged(keyCode: 54, flags: command)
        try session.receiveFlagsChanged(keyCode: 60, flags: both)
        try session.receiveFlagsChanged(keyCode: 54, flags: CGEventFlags.maskShift.rawValue)
        XCTAssertFalse(session.isComplete)
        try session.receiveFlagsChanged(keyCode: 60, flags: 0)
        XCTAssertTrue(session.isComplete)
        XCTAssertEqual(session.candidate.map(\.code), [0xE1, 0xE3])
    }

    func testFlagsChangedWithUnspecifiedKeyCodeUsesModifierMetadata() throws {
        var session = ShortcutRecordingSession()
        let control = CGEventFlags.maskControl.rawValue
        let all = control | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskCommand.rawValue
        try session.receiveFlagsChanged(keyCode: 0, flags: control)
        try session.receiveFlagsChanged(keyCode: 0, flags: all | CGEventFlags.maskSecondaryFn.rawValue)
        try session.receiveKeyDown(keyCode: 34, flags: all)
        try session.receiveKeyUp(keyCode: 34, flags: all)
        XCTAssertFalse(session.isComplete)
        try session.receiveFlagsChanged(keyCode: 0, flags: control)
        XCTAssertFalse(session.isComplete)
        try session.receiveFlagsChanged(keyCode: 0, flags: 0)
        XCTAssertTrue(session.isComplete)
        XCTAssertEqual(session.candidate.map(\.code), [0xE0, 0xE2, 0xE3, 0x0C])
    }

    func testFnRequiresExplicitModifierEventAndF13DoesNotInventFn() throws {
        let function = CGEventFlags.maskSecondaryFn.rawValue
        var functionKey = ShortcutRecordingSession()
        try functionKey.receiveKeyDown(keyCode: 105, flags: function)
        try functionKey.receiveKeyUp(keyCode: 105, flags: function)
        XCTAssertTrue(functionKey.isComplete)
        XCTAssertEqual(functionKey.candidate, [KeyEntry(code: 0x68)])

        var physicalFn = ShortcutRecordingSession()
        try physicalFn.receiveFlagsChanged(keyCode: 63, flags: function)
        try physicalFn.receiveKeyDown(keyCode: 105, flags: function)
        try physicalFn.receiveKeyUp(keyCode: 105, flags: function)
        XCTAssertFalse(physicalFn.isComplete)
        try physicalFn.receiveFlagsChanged(keyCode: 63, flags: 0)
        XCTAssertTrue(physicalFn.isComplete)
        XCTAssertEqual(physicalFn.candidate.map(\.code), [1, 0x68])

        var fnOnly = ShortcutRecordingSession()
        try fnOnly.receiveFlagsChanged(keyCode: 63, flags: function)
        try fnOnly.receiveFlagsChanged(keyCode: 63, flags: 0)
        XCTAssertTrue(fnOnly.isComplete)
        XCTAssertEqual(fnOnly.candidate, [KeyEntry(code: 1)])
    }

    func testUnsupportedEventsPreserveCandidateAndUnmatchedReleasesDoNotStart() throws {
        var session = ShortcutRecordingSession()
        try session.receiveKeyUp(keyCode: 0, flags: 0)
        try session.receiveFlagsChanged(keyCode: 55, flags: 0)
        XCTAssertTrue(session.candidate.isEmpty)
        XCTAssertFalse(session.isComplete)
        XCTAssertThrowsError(try session.receiveKeyDown(keyCode: 0xFFFF, flags: 0))
        XCTAssertTrue(session.candidate.isEmpty)
        try session.receiveKeyDown(keyCode: 0, flags: 0)
        XCTAssertThrowsError(try session.receiveFlagsChanged(keyCode: 57, flags: CGEventFlags.maskAlphaShift.rawValue)) {
            XCTAssertEqual($0 as? ShortcutCaptureError, .capsLockUnsupported)
        }
        XCTAssertThrowsError(try session.receiveKeyDown(keyCode: 72, flags: 0))
        XCTAssertEqual(session.candidate, [KeyEntry(code: 0x04)])
        try session.receiveKeyUp(keyCode: 0, flags: 0)
        XCTAssertTrue(session.isComplete)
    }

    func testTwentyFourEntryLimitIncludesModifiersAndRejectsAtomically() throws {
        var session = ShortcutRecordingSession()
        let command = CGEventFlags.maskCommand.rawValue
        try session.receiveFlagsChanged(keyCode: 55, flags: command)
        let keys = try (0x04...0x1B).map { try XCTUnwrap(MacKeyEmitter.virtualKey(for: UInt8($0))) }
        for key in keys.prefix(23) { try session.receiveKeyDown(keyCode: key, flags: command) }
        XCTAssertEqual(session.candidate.count, 24)
        let previous = session.candidate
        XCTAssertThrowsError(try session.receiveKeyDown(keyCode: keys[23], flags: command)) {
            XCTAssertEqual($0 as? MacKeyEmitterError, .tooManyEntries)
        }
        XCTAssertEqual(session.candidate, previous)
        for key in keys.prefix(23) { try session.receiveKeyUp(keyCode: key, flags: command) }
        XCTAssertFalse(session.isComplete)
        try session.receiveFlagsChanged(keyCode: 55, flags: 0)
        XCTAssertTrue(session.isComplete)
    }

    func testMultiKeyRecordingPersistsAndEmitsAsOneHeldCombination() throws {
        var session = ShortcutRecordingSession()
        let command = CGEventFlags.maskCommand.rawValue
        try session.receiveKeyDown(keyCode: 0, flags: command)
        try session.receiveKeyDown(keyCode: 11, flags: command)
        try session.receiveKeyUp(keyCode: 0, flags: command)
        try session.receiveKeyUp(keyCode: 11, flags: command)
        try session.receiveFlagsChanged(keyCode: 55, flags: 0)
        XCTAssertTrue(session.isComplete)
        var map = HostKeymap.defaultKeymap
        map.controls[0].press = session.candidate
        let restored = try HostKeymap.decode(data: JSONEncoder().encode(map))
        var events: [CGEvent] = []
        let emitter = MacKeyEmitter(hardwareFlags: { [] }, post: { events.append($0) })
        try emitter.emit(entries: restored.controls[0].press, pressed: true)
        XCTAssertEqual(events.map { $0.getIntegerValueField(.keyboardEventKeycode) }, [55, 0, 11])
        try emitter.emit(entries: restored.controls[0].press, pressed: false)
        XCTAssertEqual(events.map { $0.getIntegerValueField(.keyboardEventKeycode) }, [55, 0, 11, 11, 0, 55])
        XCTAssertTrue(events[1...4].allSatisfy { $0.flags.contains(.maskCommand) })
        XCTAssertEqual(events.last?.flags, [])
    }
}
