import XCTest
@testable import OlanziCore

final class GestureRouterTests: XCTestCase {
    private let single = [KeyEntry(code: 1)]
    private let double = [KeyEntry(code: 0x28)]
    private let long = [KeyEntry(code: 0x29)]

    private func map(double: Bool = false, long: Bool = false) -> HostKeymap {
        HostKeymap(controls: (0..<6).map {
            ControlActionMap(index: $0, press: single,
                             doublePress: $0 < 4 && double ? self.double : nil,
                             longPress: $0 < 4 && long ? self.long : nil)
        })
    }
    private func down(_ index: Int = 0) -> VendorKeyEvent { .init(index: index, pressed: true) }
    private func up(_ index: Int = 0) -> VendorKeyEvent { .init(index: index, pressed: false) }
    private func pulse(_ action: [KeyEntry], _ index: Int = 0) -> [GestureTransition] {
        [.begin(index: index, entries: action), .end(index: index)]
    }

    func testDefaultFnBeginsImmediatelyAndStaysHeldWithoutTimeout() {
        var router = GestureRouter()
        _ = router.configure(map())
        XCTAssertEqual(router.receive(down(), at: 0), [.begin(index: 0, entries: single)])
        XCTAssertEqual(router.advance(to: 100), [])
        XCTAssertEqual(router.receive(up(), at: 101), [.end(index: 0)])
    }

    func testDuplicateDownAndUpAreIgnored() {
        var router = GestureRouter()
        _ = router.configure(map())
        _ = router.receive(down(), at: 0)
        XCTAssertEqual(router.receive(down(), at: 0.1), [])
        XCTAssertEqual(router.receive(up(), at: 0.2), [.end(index: 0)])
        XCTAssertEqual(router.receive(up(), at: 0.3), [])
    }

    func testSingleWaitsFromFirstReleaseAndFiresAtExactDeadline() {
        var router = GestureRouter()
        _ = router.configure(map(double: true))
        XCTAssertEqual(router.receive(down(), at: 0), [])
        XCTAssertEqual(router.receive(up(), at: 0.1), [])
        XCTAssertEqual(router.advance(to: 0.349), [])
        XCTAssertEqual(router.advance(to: 0.35), pulse(single))
        XCTAssertEqual(router.advance(to: 10), [])
    }

    func testDoubleOnlyFiresOnSecondReleaseAndSuppressesSingle() {
        var router = GestureRouter()
        _ = router.configure(map(double: true))
        _ = router.receive(down(), at: 0)
        _ = router.receive(up(), at: 0.1)
        XCTAssertEqual(router.receive(down(), at: 0.2), [])
        XCTAssertEqual(router.advance(to: 2), [])
        XCTAssertEqual(router.receive(up(), at: 3), pulse(double))
        XCTAssertEqual(router.advance(to: 4), [])
    }

    func testSecondDownAtDeadlineStartsNewSequenceAfterFirstSingle() {
        var router = GestureRouter()
        _ = router.configure(map(double: true))
        _ = router.receive(down(), at: 0)
        _ = router.receive(up(), at: 0.25)
        XCTAssertEqual(router.receive(down(), at: 0.5), pulse(single))
        XCTAssertEqual(router.receive(up(), at: 0.75), [])
        XCTAssertEqual(router.advance(to: 1), pulse(single))
    }

    func testLongBeginsAtThresholdAndStaysHeldUntilRelease() {
        var router = GestureRouter()
        _ = router.configure(map(double: true, long: true))
        _ = router.receive(down(), at: 0)
        XCTAssertEqual(router.advance(to: 0.499), [])
        XCTAssertEqual(router.advance(to: 0.5), [.begin(index: 0, entries: long)])
        XCTAssertEqual(router.advance(to: 10), [])
        XCTAssertEqual(router.receive(up(), at: 11), [.end(index: 0)])
        XCTAssertEqual(router.advance(to: 12), [])
    }

    func testReleaseExactlyAtLongThresholdIsLongPulse() {
        var router = GestureRouter()
        _ = router.configure(map(long: true))
        _ = router.receive(down(), at: 0)
        XCTAssertEqual(router.receive(up(), at: 0.5), pulse(long))
    }

    func testShortPressWithOnlyLongAlternativeFiresSingleAtRelease() {
        var router = GestureRouter()
        _ = router.configure(map(long: true))
        _ = router.receive(down(), at: 0)
        XCTAssertEqual(router.receive(up(), at: 0.499), pulse(single))
        XCTAssertEqual(router.advance(to: 2), [])
    }

    func testSecondLongWinsAndCancelsFirstSingleAndDouble() {
        var router = GestureRouter()
        _ = router.configure(map(double: true, long: true))
        _ = router.receive(down(), at: 0)
        _ = router.receive(up(), at: 0.125)
        _ = router.receive(down(), at: 0.25)
        XCTAssertEqual(router.advance(to: 0.75), [.begin(index: 0, entries: long)])
        XCTAssertEqual(router.receive(up(), at: 0.8), [.end(index: 0)])
        XCTAssertEqual(router.advance(to: 2), [])
    }

    func testDuplicateSecondDownDoesNotRestartLongClock() {
        var router = GestureRouter()
        _ = router.configure(map(double: true, long: true))
        _ = router.receive(down(), at: 0)
        _ = router.receive(up(), at: 0.125)
        _ = router.receive(down(), at: 0.25)
        XCTAssertEqual(router.receive(down(), at: 0.7), [])
        XCTAssertEqual(router.advance(to: 0.75), [.begin(index: 0, entries: long)])
    }

    func testRotationAlwaysPulsesAndDoesNotWaitForUp() {
        var router = GestureRouter()
        _ = router.configure(map(double: true, long: true))
        XCTAssertEqual(router.receive(down(4), at: 0), pulse(single, 4))
        XCTAssertEqual(router.receive(down(4), at: 0.001), pulse(single, 4))
        XCTAssertEqual(router.receive(up(4), at: 0.002), [])
        XCTAssertEqual(router.receive(down(5), at: 0.003), pulse(single, 5))
    }

    func testCancellationNeverFlushesExpiredSingleOrStartsPendingLong() {
        var router = GestureRouter()
        _ = router.configure(map(double: true, long: true))
        _ = router.receive(down(), at: 0)
        _ = router.receive(up(), at: 0.1)
        _ = router.receive(down(1), at: 0.1)
        XCTAssertEqual(router.cancel(), [])
        XCTAssertEqual(router.advance(to: 100), [])
    }

    func testConfigurationChangeReleasesHeldAndQuarantinesUntilUp() {
        var router = GestureRouter()
        _ = router.configure(map())
        _ = router.receive(down(), at: 0)
        var updated = map()
        updated.controls[0].press = double
        XCTAssertEqual(router.configure(updated), [.end(index: 0)])
        XCTAssertEqual(router.receive(down(), at: 1), [])
        XCTAssertEqual(router.receive(up(), at: 2), [])
        XCTAssertEqual(router.receive(down(), at: 3), [.begin(index: 0, entries: double)])
    }

    func testSuspendedPhysicalDownRequiresUpBeforeReactivation() {
        var router = GestureRouter()
        _ = router.configure(map())
        router.observeWhileSuspended(down())
        XCTAssertEqual(router.receive(down(), at: 1), [])
        XCTAssertEqual(router.receive(up(), at: 2), [])
        XCTAssertEqual(router.receive(down(), at: 3), [.begin(index: 0, entries: single)])
    }

    func testDisconnectResetsOldPhysicalGenerationAndRotationsAreNeverQuarantined() {
        var router = GestureRouter()
        _ = router.configure(map())
        _ = router.receive(down(), at: 0)
        _ = router.cancel(quarantine: false)
        XCTAssertEqual(router.receive(down(), at: 1), [.begin(index: 0, entries: single)])
        _ = router.cancel()
        XCTAssertEqual(router.receive(down(4), at: 2), pulse(single, 4))
    }

    func testControlsHaveIndependentTimersAndClockNeverReopensWindow() {
        var router = GestureRouter()
        _ = router.configure(map(double: true))
        _ = router.receive(down(), at: 0)
        _ = router.receive(up(), at: 0.1)
        _ = router.receive(down(1), at: 0.2)
        _ = router.receive(up(1), at: 0.3)
        XCTAssertEqual(router.advance(to: 0.35), pulse(single))
        XCTAssertEqual(router.advance(to: 0.2), [])
        XCTAssertEqual(router.advance(to: 0.55), pulse(single, 1))
    }

    func testTransportPumpAdvancesTimersWithoutAnotherKeyOrQueryReply() throws {
        var time = 0.0
        var actions: [(UInt8, Bool)] = []
        let bridge = VendorKeyBridge(permissions: { (true, true) }, now: { time }, emit: { entries, down, _ in
            actions += entries.map { ($0.code, down) }
        })
        bridge.synchronize(configuration: map(long: true), connected: true, online: true)
        let transport = MacHIDTransport()
        transport.onKeyEvent = { bridge.receive($0) }
        transport.onPump = { bridge.pump() }
        transport.receiveDecodedFrame([0x8b, 0x10, 0, 1, 0])
        XCTAssertTrue(actions.isEmpty)
        time = 0.5
        try transport.pump(for: 0)
        XCTAssertEqual(actions.map(\.0), [0x29])
        XCTAssertEqual(actions.map(\.1), [true])
        transport.receiveDecodedFrame([0x8b, 0x10, 0, 0, 0])
        XCTAssertEqual(actions.map(\.1), [true, false])
    }
}
