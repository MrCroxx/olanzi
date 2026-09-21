import CoreGraphics
import XCTest
@testable import OlanziCore

final class PhysicalFnMonitorTests: XCTestCase {
    func testObservedPhysicalFnRemainsHeldAcrossUnrelatedModifierChanges() {
        var state = PhysicalFnState()
        state.receive(type: .flagsChanged, sourcePID: 0, keyCode: 63, flags: .maskSecondaryFn)
        XCTAssertTrue(state.pressed)
        XCTAssertFalse(state.receive(type: .flagsChanged, sourcePID: 0, keyCode: 56, flags: []))
        XCTAssertTrue(state.pressed)
        state.receive(type: .flagsChanged, sourcePID: 0, keyCode: 63, flags: [])
        XCTAssertFalse(state.pressed)
    }

    func testPostedFnEventsCannotChangePhysicalState() {
        var state = PhysicalFnState()
        state.receive(type: .flagsChanged, sourcePID: 123, keyCode: 63, flags: .maskSecondaryFn)
        XCTAssertFalse(state.pressed)
        state.receive(type: .flagsChanged, sourcePID: 0, keyCode: 63, flags: .maskSecondaryFn)
        XCTAssertTrue(state.pressed)
        state.receive(type: .flagsChanged, sourcePID: 123, keyCode: 63, flags: [])
        XCTAssertTrue(state.pressed)
        state.receive(type: .flagsChanged, sourcePID: 0, keyCode: 63, flags: [])
        XCTAssertFalse(state.pressed)
    }

    func testOtherEventTypesAndKeysCannotChangeFn() {
        var state = PhysicalFnState()
        state.receive(type: .keyDown, sourcePID: 0, keyCode: 63, flags: .maskSecondaryFn)
        state.receive(type: .flagsChanged, sourcePID: 0, keyCode: 55, flags: .maskSecondaryFn)
        XCTAssertFalse(state.pressed)
        state.receive(type: .flagsChanged, sourcePID: 0, keyCode: 63, flags: [.maskSecondaryFn, .maskShift])
        state.receive(type: .keyUp, sourcePID: 0, keyCode: 63, flags: [])
        state.receive(type: .flagsChanged, sourcePID: 0, keyCode: 55, flags: [])
        XCTAssertTrue(state.pressed)
    }

    func testDisabledNotificationsClearUntrustedCacheAndRequestReenable() {
        for initiallyPressed in [false, true] {
            var state = PhysicalFnState(pressed: initiallyPressed)
            for type in [CGEventType.tapDisabledByTimeout, .tapDisabledByUserInput] {
                XCTAssertTrue(state.receive(type: type, sourcePID: 0, keyCode: 63,
                                            flags: initiallyPressed ? [] : .maskSecondaryFn))
                XCTAssertFalse(state.pressed)
                XCTAssertEqual(state.flags, [])
            }
        }
    }

    func testEveryPhysicalSideUsesItsOwnBitAndRebuildsFamily() {
        let sides: [(Int64, CGEventFlags, UInt64)] = [
            (59, .maskControl, 0x0001), (62, .maskControl, 0x2000),
            (56, .maskShift, 0x0002), (60, .maskShift, 0x0004),
            (58, .maskAlternate, 0x0020), (61, .maskAlternate, 0x0040),
            (55, .maskCommand, 0x0008), (54, .maskCommand, 0x0010)
        ]
        for (key, family, side) in sides {
            var state = PhysicalModifierState()
            let down = family.union(CGEventFlags(rawValue: side))
            state.receive(type: .flagsChanged, sourcePID: 0, keyCode: key, flags: down)
            XCTAssertEqual(state.flags, down)
            // 即便全局家族位仍被合成事件保持，当前真实侧键的位清除即表示该侧已松开。
            state.receive(type: .flagsChanged, sourcePID: 0, keyCode: key, flags: family)
            XCTAssertEqual(state.flags, [])
        }
    }

    func testLeftAndRightPhysicalModifiersHaveIndependentOwnership() {
        var state = PhysicalModifierState()
        state.receive(type: .flagsChanged, sourcePID: 0, keyCode: 55,
                      flags: [.maskCommand, CGEventFlags(rawValue: 0x0008)])
        state.receive(type: .flagsChanged, sourcePID: 0, keyCode: 54,
                      flags: [.maskCommand, CGEventFlags(rawValue: 0x0018)])
        state.receive(type: .flagsChanged, sourcePID: 0, keyCode: 55,
                      flags: [.maskCommand, CGEventFlags(rawValue: 0x0010)])
        XCTAssertEqual(state.flags, [.maskCommand, CGEventFlags(rawValue: 0x0010)])
        state.receive(type: .flagsChanged, sourcePID: 0, keyCode: 54, flags: [])
        XCTAssertEqual(state.flags, [])
    }

    func testPostedAndUnrelatedPhysicalEventsCannotImportSyntheticModifiers() {
        var state = PhysicalModifierState()
        state.receive(type: .flagsChanged, sourcePID: 999, keyCode: 55,
                      flags: [.maskCommand, CGEventFlags(rawValue: 0x0008)])
        XCTAssertEqual(state.flags, [])
        state.receive(type: .flagsChanged, sourcePID: 0, keyCode: 56,
                      flags: [.maskShift, .maskCommand, .maskSecondaryFn, CGEventFlags(rawValue: 0x000A)])
        XCTAssertEqual(state.flags, [.maskShift, CGEventFlags(rawValue: 0x0002)])
        state.receive(type: .keyDown, sourcePID: 0, keyCode: 105, flags: .maskSecondaryFn)
        XCTAssertFalse(state.pressed)
    }

    func testInterruptionClearsAllSidesAndNextPhysicalEventCanReestablishState() {
        var state = PhysicalModifierState()
        state.receive(type: .flagsChanged, sourcePID: 0, keyCode: 55,
                      flags: [.maskCommand, CGEventFlags(rawValue: 0x0008)])
        state.receive(type: .flagsChanged, sourcePID: 0, keyCode: 63, flags: .maskSecondaryFn)
        XCTAssertTrue(state.receive(type: .tapDisabledByTimeout, sourcePID: 0, keyCode: 0, flags: []))
        XCTAssertEqual(state.flags, [])
        state.receive(type: .flagsChanged, sourcePID: 0, keyCode: 60,
                      flags: [.maskShift, CGEventFlags(rawValue: 0x0004)])
        XCTAssertEqual(state.flags, [.maskShift, CGEventFlags(rawValue: 0x0004)])
    }
}
