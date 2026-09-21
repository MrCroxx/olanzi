import CoreGraphics
import XCTest
@testable import OlanziCore

final class MacKeyEmitterTests: XCTestCase {
    private func entries(_ codes: UInt8...) -> [KeyEntry] { codes.map { KeyEntry(code: $0) } }
    private func key(_ event: CGEvent) -> Int64 { event.getIntegerValueField(.keyboardEventKeycode) }

    func testEntireCatalogIsMappedOrExplicitlyUnsupported() throws {
        for option in KeyCatalog.options {
            if (0x70...0x73).contains(option.code) {
                XCTAssertThrowsError(try MacKeyEmitter.validate(entries: [KeyEntry(code: option.code)])) {
                    XCTAssertEqual($0 as? MacKeyEmitterError, .unsupportedCode(option.code))
                }
            } else {
                XCTAssertNoThrow(try MacKeyEmitter.validate(entries: [KeyEntry(code: option.code)]))
                if option.code != 0 { XCTAssertNotNil(MacKeyEmitter.virtualKey(for: option.code)) }
            }
        }
    }

    func testRepresentativeAppleUSBToVirtualKeyMappings() {
        let expected: [UInt8: CGKeyCode] = [1: 63, 4: 0, 0x1D: 6, 0x28: 36, 0x29: 53,
            0x2A: 51, 0x32: 42, 0x39: 57, 0x3A: 122, 0x45: 111, 0x46: 105, 0x47: 107,
            0x48: 113, 0x49: 114, 0x4F: 124, 0x50: 123, 0x58: 76, 0x63: 65, 0x65: 110,
            0x68: 105, 0x6F: 90, 0xE0: 59, 0xE3: 55, 0xE4: 62, 0xE7: 54]
        for (usage, virtualKey) in expected {
            XCTAssertEqual(MacKeyEmitter.virtualKey(for: usage), virtualKey)
        }
        XCTAssertNil(MacKeyEmitter.virtualKey(for: 0))
        XCTAssertNil(MacKeyEmitter.virtualKey(for: 0x70))
        XCTAssertNil(MacKeyEmitter.virtualKey(for: 0xFF))
    }

    func testUnassignedProducesNoEventsOrSourceAllocation() throws {
        var sourceCalls = 0
        var posts = 0
        let emitter = MacKeyEmitter(hardwareFlags: { [] }, sourceFactory: {
            sourceCalls += 1
            return nil
        }, post: { _ in posts += 1 })
        XCTAssertEqual(try emitter.emit(entries: entries(0), pressed: true), 0)
        XCTAssertEqual(try emitter.emit(entries: [], pressed: false), 0)
        XCTAssertEqual(sourceCalls, 0)
        XCTAssertEqual(posts, 0)
    }

    func testUnsupportedTailIsRejectedBeforePostingValidPrefix() {
        var posts = 0
        let emitter = MacKeyEmitter(hardwareFlags: { [] }, post: { _ in posts += 1 })
        XCTAssertThrowsError(try emitter.emit(entries: entries(0xE3, 4, 0x70), pressed: true))
        XCTAssertThrowsError(try emitter.emit(entries: [KeyEntry(code: 4), KeyEntry(type: 3, code: 5)], pressed: true)) {
            XCTAssertEqual($0 as? MacKeyEmitterError, .unsupportedType(3))
        }
        XCTAssertEqual(posts, 0)
    }

    func testTooManyEntriesRejectedBeforeAnyPost() {
        var posts = 0
        let emitter = MacKeyEmitter(hardwareFlags: { [] }, post: { _ in posts += 1 })
        XCTAssertThrowsError(try emitter.emit(entries: Array(repeating: KeyEntry(code: 4), count: 25), pressed: true)) {
            XCTAssertEqual($0 as? MacKeyEmitterError, .tooManyEntries)
        }
        XCTAssertEqual(posts, 0)
    }

    func testSourceFailureDoesNotPost() {
        var posts = 0
        let emitter = MacKeyEmitter(hardwareFlags: { [] }, sourceFactory: { nil }, post: { _ in posts += 1 })
        XCTAssertThrowsError(try emitter.emit(entries: entries(4), pressed: true)) {
            XCTAssertEqual($0 as? MacKeyEmitterError, .sourceUnavailable)
        }
        XCTAssertEqual(posts, 0)
    }

    func testFailureCreatingSecondEventDoesNotPostFirst() {
        var created = 0
        var posts = 0
        let emitter = MacKeyEmitter(hardwareFlags: { [] }, eventFactory: { source, code, down in
            created += 1
            return created == 2 ? nil : CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
        }, post: { _ in posts += 1 })
        XCTAssertThrowsError(try emitter.emit(entries: entries(0xE3, 4), pressed: true)) {
            XCTAssertEqual($0 as? MacKeyEmitterError, .eventUnavailable(4))
        }
        XCTAssertEqual(posts, 0)
    }

    func testOrdinaryKeyDownUpPreservesHardwareModifiers() throws {
        var events: [CGEvent] = []
        let emitter = MacKeyEmitter(hardwareFlags: { [.maskShift, .maskControl] }, post: { events.append($0) })
        try emitter.emit(entries: entries(4), pressed: true)
        try emitter.emit(entries: entries(4), pressed: false)
        XCTAssertEqual(events.map(\.type), [.keyDown, .keyUp])
        XCTAssertEqual(events.map { key($0) }, [0, 0])
        XCTAssertTrue(events.allSatisfy { $0.flags == [.maskShift, .maskControl] })
        XCTAssertTrue(events.allSatisfy { $0.getIntegerValueField(.keyboardEventAutorepeat) == 0 })
    }

    func testFnUsesFlagsChangedAndBalancedFnFlags() throws {
        var events: [CGEvent] = []
        let emitter = MacKeyEmitter(hardwareFlags: { [.maskCommand] }, post: { events.append($0) })
        try emitter.emit(entries: entries(1), pressed: true)
        try emitter.emit(entries: entries(1), pressed: false)
        XCTAssertEqual(events.map(\.type), [.flagsChanged, .flagsChanged])
        XCTAssertEqual(events.map { key($0) }, [63, 63])
        XCTAssertEqual(events[0].flags, [.maskCommand, .maskSecondaryFn])
        XCTAssertEqual(events[1].flags, [.maskCommand])
    }

    func testFunctionKeysCarryIntrinsicFunctionFlagWithoutPhysicalFn() throws {
        // Print Screen / Scroll Lock / Pause 在 macOS 上也映射为 F13–F15。
        let usages = Array(UInt8(0x3A)...UInt8(0x48)) + Array(UInt8(0x68)...UInt8(0x6F))
        for usage in usages {
            var events: [CGEvent] = []
            let emitter = MacKeyEmitter(hardwareFlags: { .maskShift }, physicalFn: { false },
                                        post: { events.append($0) })
            try emitter.emit(entries: entries(usage), pressed: true)
            try emitter.emit(entries: entries(usage), pressed: false)
            XCTAssertEqual(events.map(\.type), [.keyDown, .keyUp])
            XCTAssertTrue(events.allSatisfy { $0.flags == [.maskShift, .maskSecondaryFn] },
                          "功能键 usage \(usage) 的按下和松开均应携带 function 标志")
        }
    }

    func testF13FunctionFlagDoesNotLatchFnOrLeakIntoNextOrdinaryKey() throws {
        var systemFlags: CGEventFlags = []
        var events: [CGEvent] = []
        let emitter = MacKeyEmitter(hardwareFlags: { systemFlags }, physicalFn: { false }, post: {
            events.append($0)
            systemFlags = $0.flags
        })
        for code: UInt8 in [0x68, 1, 4] {
            try emitter.emit(entries: entries(code), pressed: true)
            try emitter.emit(entries: entries(code), pressed: false)
        }
        XCTAssertEqual(events.map { key($0) }, [105, 105, 63, 63, 0, 0])
        XCTAssertEqual(events.map { $0.flags.contains(.maskSecondaryFn) },
                       [true, true, true, false, false, false])
    }

    func testFnReleasePreservesPhysicalFn() throws {
        var events: [CGEvent] = []
        let emitter = MacKeyEmitter(hardwareFlags: { [.maskSecondaryFn, .maskShift] }, post: { events.append($0) })
        try emitter.emit(entries: entries(1), pressed: false)
        XCTAssertEqual(events[0].flags, [.maskSecondaryFn, .maskShift])
    }

    func testSyntheticFnFeedbackCannotKeepReleasePressedAcrossRepeatedHolds() throws {
        var systemFlags: CGEventFlags = .maskShift
        var events: [CGEvent] = []
        let emitter = MacKeyEmitter(hardwareFlags: { systemFlags }, physicalFn: { false }, post: {
            events.append($0)
            // 模拟实测：HID 汇总状态被刚发布的合成 Fn 改写。
            systemFlags = $0.flags
        })
        for _ in 0..<3 {
            try emitter.emit(entries: entries(1), pressed: true)
            try emitter.emit(entries: entries(1), pressed: false)
        }
        XCTAssertEqual(events.map { $0.flags.contains(.maskSecondaryFn) }, [true, false, true, false, true, false])
        XCTAssertTrue(events.allSatisfy { $0.type == .flagsChanged && key($0) == 63 })
        XCTAssertTrue(events.allSatisfy { $0.flags.contains(.maskShift) })
    }

    func testSyntheticCommandEnterFeedbackDoesNotLeakIntoFollowingFn() throws {
        var systemFlags: CGEventFlags = []
        var events: [CGEvent] = []
        let emitter = MacKeyEmitter(hardwareFlags: { systemFlags }, physicalModifiers: { [] }, post: {
            events.append($0)
            // 模拟已知的全局状态反馈路径：发布的修饰键随后出现在 HID 汇总 flags 中。
            // 本场景没有按住真实键盘修饰键，Cmd 松开后必须清除自己的合成状态。
            systemFlags = $0.flags
        })
        try emitter.emit(entries: entries(0xE3, 0x28), pressed: true)
        try emitter.emit(entries: entries(0xE3, 0x28), pressed: false)
        try emitter.emit(entries: entries(1), pressed: true)
        try emitter.emit(entries: entries(1), pressed: false)

        XCTAssertEqual(events.map { key($0) }, [55, 36, 36, 55, 63, 63])
        XCTAssertTrue(events[0...2].allSatisfy { $0.flags.contains(.maskCommand) })
        XCTAssertFalse(events[3].flags.contains(.maskCommand), "合成 Cmd 松开不得保留自己的全局反馈")
        XCTAssertEqual(events[3].flags.rawValue & 0x0008, 0, "左 Command 的设备位也必须释放")
        XCTAssertFalse(events[4].flags.contains(.maskCommand), "后续纯 Fn 不得变成 Cmd+Fn")
        XCTAssertFalse(events[5].flags.contains(.maskCommand))
        XCTAssertEqual(events[4].flags, .maskSecondaryFn)
        XCTAssertEqual(events[5].flags, [])
    }

    func testEverySyntheticModifierReleasesDespiteGlobalFeedback() throws {
        for usage in UInt8(0xE0)...UInt8(0xE7) {
            var global: CGEventFlags = .maskNonCoalesced
            var events: [CGEvent] = []
            let emitter = MacKeyEmitter(hardwareFlags: { global }, physicalModifiers: { [] }, post: {
                events.append($0); global = $0.flags
            })
            try emitter.emit(entries: entries(usage, 0x28), pressed: true)
            try emitter.emit(entries: entries(usage, 0x28), pressed: false)
            try emitter.emit(entries: entries(1), pressed: true)
            try emitter.emit(entries: entries(1), pressed: false)
            XCTAssertEqual(events[3].flags, .maskNonCoalesced, "修饰键 usage \(usage) 必须释放")
            XCTAssertEqual(events[4].flags, [.maskNonCoalesced, .maskSecondaryFn])
            XCTAssertEqual(events[5].flags, .maskNonCoalesced)
        }
    }

    func testPhysicalRightCommandSurvivesSyntheticLeftCommandAndCanReleaseIndependently() throws {
        var global: CGEventFlags = []
        var real: CGEventFlags = [.maskCommand, CGEventFlags(rawValue: 0x0010)]
        var events: [CGEvent] = []
        let emitter = MacKeyEmitter(hardwareFlags: { global }, physicalModifiers: { real }, post: {
            events.append($0); global = $0.flags
        })
        try emitter.emit(entries: entries(0xE3, 0x28), pressed: true)
        try emitter.emit(entries: entries(0xE3, 0x28), pressed: false)
        XCTAssertEqual(events.last?.flags, real)
        XCTAssertEqual(events.last!.flags.rawValue & 0x0008, 0)
        // 在第二轮 AU05 按住期间释放真实右 Cmd 并按住真实左 Shift。
        try emitter.emit(entries: entries(0xE3, 0x28), pressed: true)
        real = [.maskShift, CGEventFlags(rawValue: 0x0002)]
        try emitter.emit(entries: entries(0xE3, 0x28), pressed: false)
        XCTAssertEqual(events.last?.flags, real)
        XCTAssertFalse(events.last!.flags.contains(.maskCommand))
    }

    func testIndependentPhysicalModifiersPreserveAnotherAU05ControlOwnership() throws {
        var events: [CGEvent] = []
        let real: CGEventFlags = [.maskShift, CGEventFlags(rawValue: 0x0004)]
        let held = MacKeyEmitter.modifierFlags(for: entries(0xE6, 1))
        let emitter = MacKeyEmitter(hardwareFlags: { PhysicalModifierState.managedMask },
                                    physicalModifiers: { real }, post: { events.append($0) })
        try emitter.emit(entries: entries(0xE3), pressed: false, heldModifiers: held)
        XCTAssertEqual(events.last?.flags, real.union(held))
    }

    func testPhysicalModifierReadFailureCannotEmitPartialAction() {
        var posted = 0
        let emitter = MacKeyEmitter(hardwareFlags: { .maskCommand }, physicalModifiers: {
            throw DeviceProtocolError.message("监听失败测试")
        }, post: { _ in posted += 1 })
        XCTAssertThrowsError(try emitter.emit(entries: entries(0xE3, 0x28), pressed: true))
        XCTAssertEqual(posted, 0)
    }

    func testPhysicalFnOverlapIsIndependentOfSyntheticFeedback() throws {
        var systemFlags: CGEventFlags = []
        var realFn = false
        var events: [CGEvent] = []
        let emitter = MacKeyEmitter(hardwareFlags: { systemFlags }, physicalFn: { realFn }, post: {
            events.append($0); systemFlags = $0.flags
        })
        try emitter.emit(entries: entries(1), pressed: true)
        realFn = true
        try emitter.emit(entries: entries(1), pressed: false)
        XCTAssertTrue(try XCTUnwrap(events.last).flags.contains(.maskSecondaryFn))
        // 真实 Fn 在下一次 AU05 按住期间松开，最终释放必须清除污染的汇总位。
        try emitter.emit(entries: entries(1), pressed: true)
        realFn = false
        try emitter.emit(entries: entries(1), pressed: false)
        XCTAssertFalse(try XCTUnwrap(events.last).flags.contains(.maskSecondaryFn))
    }

    func testOtherHeldFnControlSurvivesReleaseWithIndependentPhysicalState() throws {
        var events: [CGEvent] = []
        let emitter = MacKeyEmitter(hardwareFlags: { .maskSecondaryFn }, physicalFn: { false },
                                    post: { events.append($0) })
        try emitter.emit(entries: entries(0xE3), pressed: false, heldModifiers: .maskSecondaryFn)
        XCTAssertTrue(try XCTUnwrap(events.last).flags.contains(.maskSecondaryFn))
        try emitter.emit(entries: entries(1), pressed: false)
        XCTAssertFalse(try XCTUnwrap(events.last).flags.contains(.maskSecondaryFn))
    }

    func testCombinationPressesModifiersFirstAndReleasesThemLast() throws {
        var events: [CGEvent] = []
        let emitter = MacKeyEmitter(hardwareFlags: { [] }, post: { events.append($0) })
        let combination = entries(4, 0xE3, 0xE1)
        try emitter.emit(entries: combination, pressed: true)
        try emitter.emit(entries: combination, pressed: false)
        XCTAssertEqual(events.map { key($0) }, [55, 56, 0, 0, 56, 55])
        XCTAssertEqual(events.map(\.type), [.flagsChanged, .flagsChanged, .keyDown, .keyUp, .flagsChanged, .flagsChanged])
        XCTAssertTrue(events[0].flags.contains(.maskCommand))
        XCTAssertFalse(events[0].flags.contains(.maskShift))
        XCTAssertTrue(events[2].flags.contains([.maskCommand, .maskShift]))
        XCTAssertTrue(events[3].flags.contains([.maskCommand, .maskShift]))
        XCTAssertFalse(events[4].flags.contains(.maskShift))
        XCTAssertTrue(events[4].flags.contains(.maskCommand))
        XCTAssertEqual(events[5].flags, [])
    }

    func testReleasingOneControlPreservesOtherHeldModifiers() throws {
        var events: [CGEvent] = []
        let emitter = MacKeyEmitter(hardwareFlags: { [] }, post: { events.append($0) })
        let held = MacKeyEmitter.modifierFlags(for: entries(1, 0xE7))
        try emitter.emit(entries: entries(0xE3), pressed: false, heldModifiers: held)
        XCTAssertEqual(events[0].flags, held)
        XCTAssertTrue(events[0].flags.contains([.maskCommand, .maskSecondaryFn]))
        XCTAssertEqual(events[0].flags.rawValue & 0x18, 0x10)
    }

    func testBothSidesOfSameModifierRetainFamilyFlagUntilLastRelease() throws {
        var events: [CGEvent] = []
        let emitter = MacKeyEmitter(hardwareFlags: { [] }, post: { events.append($0) })
        try emitter.emit(entries: entries(0xE1, 0xE5), pressed: false)
        XCTAssertEqual(events.map { key($0) }, [60, 56])
        XCTAssertTrue(events[0].flags.contains(.maskShift))
        XCTAssertEqual(events[0].flags.rawValue & 6, 2)
        XCTAssertFalse(events[1].flags.contains(.maskShift))
        XCTAssertEqual(events[1].flags.rawValue & 6, 0)
    }

    func testModifierFlagsAreUnionOfValidModifierEntries() {
        let flags = MacKeyEmitter.modifierFlags(for: entries(1, 0xE0, 0xE1, 0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 4, 0x39))
        XCTAssertTrue(flags.contains([.maskSecondaryFn, .maskControl, .maskShift, .maskAlternate, .maskCommand]))
        XCTAssertEqual(flags.rawValue & 0x207F, 0x207F)
        XCTAssertFalse(flags.contains(.maskAlphaShift))
        XCTAssertEqual(MacKeyEmitter.modifierFlags(for: [KeyEntry(type: 3, code: 1)]), [])
    }

    func testDuplicateAndUnassignedEntriesDoNotDuplicateEvents() throws {
        var events: [CGEvent] = []
        let emitter = MacKeyEmitter(hardwareFlags: { [] }, post: { events.append($0) })
        XCTAssertEqual(try emitter.emit(entries: entries(0, 4, 4, 0xE3, 0xE3), pressed: true), 2)
        XCTAssertEqual(events.map { key($0) }, [55, 0])
    }

    func testCapsLockTogglesOnPressAndPersistsAfterRelease() throws {
        var events: [CGEvent] = []
        let emitter = MacKeyEmitter(hardwareFlags: { [] }, post: { events.append($0) })
        try emitter.emit(entries: entries(0x39), pressed: true)
        try emitter.emit(entries: entries(0x39), pressed: false)
        try emitter.emit(entries: entries(4), pressed: true)
        try emitter.emit(entries: entries(4), pressed: false)
        try emitter.emit(entries: entries(0x39), pressed: true)
        try emitter.emit(entries: entries(0x39), pressed: false)
        XCTAssertEqual(events.map { $0.flags.contains(.maskAlphaShift) }, [true, true, true, true, false, false])
        XCTAssertEqual(events[0].type, .flagsChanged)
        XCTAssertEqual(events[1].type, .flagsChanged)
    }

    func testChangedPhysicalCapsStateIsRespected() throws {
        var physical: CGEventFlags = []
        var events: [CGEvent] = []
        let emitter = MacKeyEmitter(hardwareFlags: { physical }, post: { events.append($0) })
        try emitter.emit(entries: entries(4), pressed: true)
        physical = .maskAlphaShift
        try emitter.emit(entries: entries(4), pressed: false)
        XCTAssertFalse(events[0].flags.contains(.maskAlphaShift))
        XCTAssertTrue(events[1].flags.contains(.maskAlphaShift))
    }

    func testFailedPostingPropagatesAndReleaseCanBeRetried() throws {
        var shouldFail = true
        var events: [CGEvent] = []
        let emitter = MacKeyEmitter(hardwareFlags: { [] }, post: { event in
            if shouldFail { throw MacKeyEmitterError.sourceUnavailable }
            events.append(event)
        })
        XCTAssertThrowsError(try emitter.emit(entries: entries(1), pressed: false))
        shouldFail = false
        XCTAssertEqual(try emitter.emit(entries: entries(1), pressed: false), 1)
        XCTAssertEqual(events[0].type, .flagsChanged)
        XCTAssertFalse(events[0].flags.contains(.maskSecondaryFn))
    }
}
