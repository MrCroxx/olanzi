import XCTest
@testable import OlanziCore

final class HostActionTests: XCTestCase {
    private let target = ApplicationTarget(bundleIdentifier: "com.example.editor", path: "/Applications/Editor.app", name: "Editor")
    private let key = [KeyEntry(code: 0x04)]

    func testExtendedActionsRoundTripAndLegacyFallback() throws {
        var map = HostKeymap.defaultKeymap
        XCTAssertEqual(map.controls[0].effectivePress, .keyboard(map.controls[0].press))
        map.controls[0].pressAction = .application(target)
        map.controls[1].doublePressAction = .macro([.application(target), .delay(0.2), .keyboard(key)])
        map.controls[2].longPressAction = .keyboard(key)
        XCTAssertEqual(map.version, 2)
        let encoded = try JSONEncoder().encode(map)
        XCTAssertEqual(try HostKeymap.decode(data: encoded), map)
        let profile = HostProfile(name: "Macro", keymap: map)
        XCTAssertEqual(try HostProfile.decode(data: JSONEncoder().encode(profile)), profile)
        XCTAssertEqual(map.controls[0].effectivePress, .application(target))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["version"] = 1
        XCTAssertThrowsError(try HostKeymap.decode(data: JSONSerialization.data(withJSONObject: object)))
        map.controls[0].pressAction = nil
        map.controls[1].doublePressAction = nil
        map.controls[2].longPressAction = nil
        XCTAssertEqual(map, HostKeymap.defaultKeymap)
    }

    func testInvalidActionsAndRotationGesturesAreRejected() throws {
        for steps: [MacroStep] in [[], Array(repeating: .keyboard(key), count: 33), [.delay(0)],
                                   [.delay(10.01)], [.delay(.nan)], [.keyboard([KeyEntry(code: 0xFF)])]] {
            XCTAssertThrowsError(try HostAction.macro(steps).validate())
        }
        XCTAssertNoThrow(try HostAction.macro([.delay(0.05), .delay(10)]).validate())
        XCTAssertThrowsError(try HostAction.application(.init(bundleIdentifier: "", path: "", name: "")).validate())
        var map = HostKeymap.defaultKeymap
        map.controls[4].doublePressAction = .application(target)
        XCTAssertThrowsError(try map.validate())
    }

    func testApplicationAndMacroGesturesExecuteOnceIncludingBurstLongPress() {
        for behavior in LongPressBehavior.allCases {
            var map = HostKeymap.defaultKeymap
            map.controls[0].pressAction = .application(target)
            map.controls[1].longPressAction = .macro([.keyboard(key)])
            map.controls[1].longPressBehavior = behavior
            var router = GestureRouter()
            _ = router.configure(map)
            XCTAssertEqual(router.receive(.init(index: 0, pressed: true), at: 0), [.execute(index: 0, action: .application(target))])
            XCTAssertEqual(router.receive(.init(index: 0, pressed: true), at: 0.1), [])
            XCTAssertEqual(router.receive(.init(index: 0, pressed: false), at: 0.2), [])
            _ = router.receive(.init(index: 1, pressed: true), at: 1)
            XCTAssertEqual(router.advance(to: 1.5), [.execute(index: 1, action: .macro([.keyboard(key)]))])
            XCTAssertEqual(router.advance(to: 5), [])
            XCTAssertEqual(router.receive(.init(index: 1, pressed: false), at: 6), [])
        }
    }

    func testMacroWaitsForActivationThenDelayAndPulsesInOrder() throws {
        let activation = ApplicationActivation()
        var frontmost = false
        var events: [String] = []
        let runner = HostActionRunner(launcher: .init(launch: { _ in events.append("launch"); return activation },
                                                     isFrontmost: { _ in frontmost }))
        try runner.enqueue(index: 0, action: .macro([.application(target), .delay(0.2), .keyboard(key), .keyboard(key)]))
        func pump(_ time: Double) throws {
            try runner.pump(at: time, press: { _ in events.append("down") }, release: { events.append("up") })
        }
        try pump(0)
        try pump(0.1)
        activation.complete(true)
        try pump(0.2)
        XCTAssertEqual(events, ["launch"])
        frontmost = true
        try pump(0.3)
        try pump(0.49)
        XCTAssertEqual(events, ["launch"])
        try pump(0.5)
        try pump(0.53)
        XCTAssertEqual(events, ["launch", "down"])
        try pump(0.55)
        try pump(0.60)
        XCTAssertEqual(events, ["launch", "down", "up", "down", "up"])
    }

    func testFailedOrTimedOutActivationNeverSendsMacroKeys() throws {
        for failed in [false, true] {
            let activation = ApplicationActivation()
            let runner = HostActionRunner(launcher: .init(launch: { _ in activation }, isFrontmost: { _ in false }))
            try runner.enqueue(index: 0, action: .macro([.application(target), .keyboard(key)]))
            try runner.pump(at: 0, press: { _ in XCTFail("Unexpected key") }, release: {})
            if failed { activation.complete(false) }
            XCTAssertThrowsError(try runner.pump(at: 5, press: { _ in XCTFail("Unexpected key") }, release: {}))
            activation.complete(true)
            try runner.pump(at: 6, press: { _ in XCTFail("Unexpected key") }, release: {})
        }
    }

    func testForegroundChangesAbortBeforeLaterKeyAndCancellationIgnoresLateActivation() throws {
        let activation = ApplicationActivation()
        var frontmost = true
        let runner = HostActionRunner(launcher: .init(launch: { _ in activation }, isFrontmost: { _ in frontmost }))
        try runner.enqueue(index: 0, action: .macro([.application(target), .delay(1), .keyboard(key)]))
        try runner.pump(at: 0, press: { _ in XCTFail("Unexpected key") }, release: {})
        activation.complete(true)
        try runner.pump(at: 0.1, press: { _ in XCTFail("Unexpected key") }, release: {})
        frontmost = false
        XCTAssertThrowsError(try runner.pump(at: 0.2, press: { _ in XCTFail("Unexpected key") }, release: {})) {
            XCTAssertEqual($0 as? HostActionError, .foregroundChanged)
        }
        let pending = ApplicationActivation()
        let cancelled = HostActionRunner(launcher: .init(launch: { _ in pending }, isFrontmost: { _ in true }))
        try cancelled.enqueue(index: 0, action: .macro([.application(target), .keyboard(key)]))
        try cancelled.pump(at: 0, press: { _ in XCTFail("Unexpected key") }, release: {})
        cancelled.cancel()
        pending.complete(true)
        try cancelled.pump(at: 1, press: { _ in XCTFail("Unexpected key") }, release: {})
        guard case .cancelled = pending.state else { return XCTFail("Activation was not cancelled") }
    }

    func testQueueIsBoundedAndDuplicateControlDoesNotAccumulate() throws {
        let runner = HostActionRunner()
        XCTAssertTrue(try runner.enqueue(index: 0, action: .macro([.delay(1)])))
        XCTAssertFalse(try runner.enqueue(index: 0, action: .macro([.delay(1)])))
        try runner.pump(at: 0, press: { _ in }, release: {})
        XCTAssertFalse(try runner.enqueue(index: 0, action: .macro([.delay(1)])))
        for index in 1..<8 { XCTAssertTrue(try runner.enqueue(index: index, action: .macro([.delay(1)]))) }
        XCTAssertFalse(try runner.enqueue(index: 8, action: .macro([.delay(1)])))
        runner.cancel()
        XCTAssertTrue(try runner.enqueue(index: 0, action: .macro([.delay(1)])))
    }

    func testBridgeCancelsAndReleasesMacrosOnReconfigureDisconnectAndPermissionLoss() throws {
        for cause in 0..<4 {
            var time = 0.0
            var granted = true
            var events: [Bool] = []
            let bridge = VendorKeyBridge(permissions: { (granted, granted) }, now: { time }, emit: { entries, down, _ in
                if !entries.isEmpty { events.append(down) }
            })
            var map = HostKeymap.defaultKeymap
            map.controls[0].pressAction = .macro([.keyboard(key), .delay(1), .keyboard(key)])
            bridge.synchronize(configuration: map, connected: true, online: true)
            bridge.receive(.init(index: 0, pressed: true))
            XCTAssertEqual(events, [true])
            switch cause {
            case 0:
                map.controls[1].press = key
                bridge.synchronize(configuration: map, connected: true, online: true)
            case 1: bridge.synchronize(configuration: map, connected: false, online: nil)
            case 2: granted = false; bridge.refreshPermissions()
            default: bridge.close()
            }
            XCTAssertEqual(events, [true, false])
            time = 3
            if cause != 3 { bridge.pump() }
            XCTAssertEqual(events, [true, false])
        }
    }
    func testFailedMacroPressReleasesPartialKeysAndCancelsRemainingSteps() throws {
        var time = 0.0
        var events: [Bool] = []
        var fail = true
        let bridge = VendorKeyBridge(permissions: { (true, true) }, now: { time }, emit: { entries, down, _ in
            guard !entries.isEmpty else { return }
            events.append(down)
            if down && fail { fail = false; throw HostActionError.activationFailed }
        })
        var map = HostKeymap.defaultKeymap
        map.controls[0].pressAction = .macro([.keyboard(key), .keyboard(key)])
        bridge.synchronize(configuration: map, connected: true, online: true)
        bridge.receive(.init(index: 0, pressed: true))
        XCTAssertEqual(events, [true, false])
        XCTAssertNotNil(bridge.status.error)
        time = 1
        bridge.pump()
        XCTAssertEqual(events, [true, false])
    }

    func testMacroReleaseFailureRetriesWithoutReplayingAndPreservesOtherModifierOwner() throws {
        var time = 0.0
        var failed = false
        var events: [(UInt8, Bool)] = []
        let modifier = KeyEntry(code: 0xE3)
        let bridge = VendorKeyBridge(permissions: { (true, true) }, now: { time }, emit: { entries, down, _ in
            events += entries.map { ($0.code, down) }
            if !down && !failed && entries.contains(where: { $0.code == 0x04 }) {
                failed = true
                throw HostActionError.activationFailed
            }
        })
        var map = HostKeymap.defaultKeymap
        map.controls[0].pressAction = .macro([.keyboard([modifier] + key), .keyboard(key)])
        map.controls[1].press = [modifier]
        bridge.synchronize(configuration: map, connected: true, online: true)
        bridge.receive(.init(index: 1, pressed: true))
        bridge.receive(.init(index: 0, pressed: true))
        time = 0.05
        bridge.pump()
        time = 1
        bridge.pump()
        XCTAssertEqual(events.filter { $0.0 == 0x04 && $0.1 }.count, 1)
        XCTAssertFalse(events.contains { $0.0 == 0xE3 && !$0.1 })
        bridge.receive(.init(index: 1, pressed: false))
        XCTAssertEqual(events.filter { $0.0 == 0xE3 && !$0.1 }.count, 1)
    }

    func testDelayKeepsBridgeAvailableToOtherControlsAndCancelledDelayDoesNotResume() throws {
        var time = 0.0
        var events: [(UInt8, Bool)] = []
        let bridge = VendorKeyBridge(permissions: { (true, true) }, now: { time }, emit: { entries, down, _ in
            events += entries.map { ($0.code, down) }
        })
        var map = HostKeymap.defaultKeymap
        map.controls[0].pressAction = .macro([.delay(10), .keyboard(key)])
        bridge.synchronize(configuration: map, connected: true, online: true)
        bridge.receive(.init(index: 0, pressed: true))
        for tick in 1...5 {
            time = Double(tick)
            bridge.pump()
            XCTAssertTrue(bridge.status.active)
        }
        bridge.receive(.init(index: 1, pressed: true))
        bridge.receive(.init(index: 1, pressed: false))
        XCTAssertEqual(events.map(\.0), [0x28, 0x28])
        bridge.synchronize(configuration: map, connected: false, online: nil)
        time = 20
        bridge.synchronize(configuration: map, connected: true, online: true)
        XCTAssertEqual(events.map(\.0), [0x28, 0x28])
    }

    func testAnotherControlsFailedReleaseCancelsAndReleasesActiveMacro() throws {
        var time = 0.0
        var failed = false
        var events: [(UInt8, Bool)] = []
        let bridge = VendorKeyBridge(permissions: { (true, true) }, now: { time }, emit: { entries, down, _ in
            events += entries.map { ($0.code, down) }
            if !down && !failed && entries.contains(where: { $0.code == 0x28 }) {
                failed = true
                throw HostActionError.activationFailed
            }
        })
        var map = HostKeymap.defaultKeymap
        map.controls[0].pressAction = .macro([.keyboard(key), .keyboard([KeyEntry(code: 0x05)])])
        bridge.synchronize(configuration: map, connected: true, online: true)
        bridge.receive(.init(index: 1, pressed: true))
        bridge.receive(.init(index: 0, pressed: true))
        time = 0.01
        bridge.receive(.init(index: 1, pressed: false))
        XCTAssertTrue(failed)
        XCTAssertEqual(events.filter { $0.0 == 0x04 && !$0.1 }.count, 1)
        time = 0.1
        bridge.pump()
        XCTAssertTrue(bridge.status.active)
        XCTAssertFalse(events.contains { $0.0 == 0x05 })
        // 重试成功后新宏仍能发键，不能被遗留的宏所有权吞掉。
        bridge.receive(.init(index: 0, pressed: false))
        bridge.receive(.init(index: 0, pressed: true))
        XCTAssertEqual(events.filter { $0.0 == 0x04 && $0.1 }.count, 2)
        time = 0.15
        bridge.pump()
        XCTAssertEqual(events.filter { $0.0 == 0x05 && $0.1 }.count, 1)
        bridge.close()
    }

    func testOneMacroSwitchesBetweenTwoApplicationsAndSendsKeysOnlyToConfirmedTargets() throws {
        let second = ApplicationTarget(bundleIdentifier: "com.example.viewer", path: "/Applications/Viewer.app", name: "Viewer")
        let firstActivation = ApplicationActivation()
        let secondActivation = ApplicationActivation()
        var frontmost: ApplicationTarget?
        var events: [String] = []
        var pressed = false
        let runner = HostActionRunner(launcher: .init(launch: { application in
            events.append("launch " + application.name)
            return application == self.target ? firstActivation : secondActivation
        }, isFrontmost: { $0 == frontmost }))
        try runner.enqueue(index: 0, action: .macro([
            .application(target), .keyboard(key), .application(second),
            .delay(0.5), .keyboard([KeyEntry(code: 0x05)])
        ]))
        func pump(_ time: Double) throws {
            try runner.pump(at: time, press: { entries in
                pressed = true
                events.append("down " + String(entries[0].code) + " " + (frontmost?.name ?? "none"))
            }, release: {
                if pressed { events.append("up"); pressed = false }
            })
        }
        try pump(0)
        firstActivation.complete(true)
        frontmost = target
        try pump(0.1)
        try pump(0.15)
        XCTAssertEqual(events, ["launch Editor", "down 4 Editor", "up", "launch Viewer"])
        // 第二次启动期间前台可以暂时为空，不能仍要求第一个应用处于前台。
        frontmost = nil
        try pump(0.2)
        secondActivation.complete(true)
        try pump(0.3)
        XCTAssertEqual(events.count, 4)
        frontmost = second
        try pump(0.4)
        try pump(0.6)
        try pump(0.8)
        XCTAssertEqual(events.count, 4)
        try pump(0.91)
        try pump(0.96)
        XCTAssertEqual(events, ["launch Editor", "down 4 Editor", "up", "launch Viewer", "down 5 Viewer", "up"])
    }

    func testFailedSecondApplicationStopsCombinedMacroBeforeItsLaterKey() throws {
        let second = ApplicationTarget(bundleIdentifier: "com.example.viewer", path: "/Applications/Viewer.app", name: "Viewer")
        let firstActivation = ApplicationActivation()
        let secondActivation = ApplicationActivation()
        var frontmost: ApplicationTarget?
        var launched: [ApplicationTarget] = []
        var sent: [UInt8] = []
        var releases = 0
        var pressed = false
        let runner = HostActionRunner(launcher: .init(launch: { application in
            launched.append(application)
            return application == self.target ? firstActivation : secondActivation
        }, isFrontmost: { $0 == frontmost }))
        try runner.enqueue(index: 0, action: .macro([
            .application(target), .keyboard(key), .application(second),
            .delay(0.5), .keyboard([KeyEntry(code: 0x05)])
        ]))
        func pump(_ time: Double) throws {
            try runner.pump(at: time, press: { entries in
                sent += entries.map(\.code)
                pressed = true
            }, release: {
                if pressed { releases += 1; pressed = false }
            })
        }
        try pump(0)
        firstActivation.complete(true)
        frontmost = target
        try pump(0.1)
        try pump(0.15)
        XCTAssertEqual(launched, [target, second])
        XCTAssertEqual(sent, [0x04])
        XCTAssertEqual(releases, 1)
        frontmost = nil
        try pump(0.2)
        secondActivation.complete(false)
        XCTAssertThrowsError(try pump(0.3)) {
            XCTAssertEqual($0 as? HostActionError, .activationFailed)
        }
        // 即使应用后来进入前台，也不能恢复已经失败的后续步骤。
        frontmost = second
        try pump(1)
        try pump(10)
        XCTAssertEqual(sent, [0x04])
        XCTAssertEqual(releases, 1)
    }

}
