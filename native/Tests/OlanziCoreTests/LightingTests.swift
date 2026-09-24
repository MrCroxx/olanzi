import Foundation
import XCTest
@testable import OlanziCore

private let lightingReply: [UInt8] = [
    0x81, 0x0B, 0x88, 0x11, 0xA5, 3, 1, 2,
    2, 11, 12, 13, 14,
    1, 21, 22, 23, 24,
    0, 31, 32, 33, 34,
    1, 41, 42, 43, 44,
]

private final class LightingTransport: DeviceTransport, @unchecked Sendable {
    enum Behavior { case normal, mismatch, readFailure, writeFailure, staleKnob }
    private let lock = NSLock()
    private var enabled = false
    private var records: [String] = []
    private var value: DeviceLighting
    private let behavior: Behavior
    private let online: Bool
    private var attemptedWrite = false
    private var knobConfirmation: UInt8?
    var acknowledgedKnobBrightness: UInt8? { lock.withLock { knobConfirmation } }
    var onKeyEvent: ((VendorKeyEvent) -> Void)?
    var onPump: (() -> Void)?
    var lastHeartbeat: Date? { nil }
    var heartbeatEnabled: Bool {
        get { lock.withLock { enabled } }
        set { lock.withLock { enabled = newValue } }
    }
    var operations: [String] { lock.withLock { records } }
    init(value: DeviceLighting, behavior: Behavior = .normal, online: Bool = true) {
        self.value = value; self.behavior = behavior; self.online = online
    }
    func open() throws {}
    func close() { heartbeatEnabled = false; lock.withLock { knobConfirmation = nil } }
    func pump(for duration: TimeInterval) throws { onPump?() }
    func queryOnline() throws -> Bool { online }
    func setSoftwareOnline(_ online: Bool) throws {}
    func readKey(index: Int) throws -> KeyBinding {
        KeyBinding(index: index, entries: [KeyEntry(code: DeviceProtocol.defaultCodes[index])])
    }
    func writeKey(index: Int, code: UInt8) throws { XCTFail("灯效测试不得写按键") }
    func readLighting() throws -> DeviceLighting {
        try lock.withLock {
            records.append("read")
            if attemptedWrite && behavior == .readFailure { throw DeviceProtocolError.message("回读失败测试") }
            return value
        }
    }
    func writeLighting(_ desired: DeviceLighting, expected: DeviceLighting, setKnobBrightness: Bool) throws {
        try lock.withLock {
            records.append("write")
            XCTAssertTrue(expected.differingFields(from: value, ignoringKnobBrightness: true).isEmpty)
            attemptedWrite = true
            if behavior == .writeFailure { throw DeviceProtocolError.message("写入失败测试") }
            if behavior != .mismatch {
                let previous = value.lights[3].alwaysOnBrightness
                if setKnobBrightness || desired.lights[3].alwaysOnBrightness != expected.lights[3].alwaysOnBrightness {
                    knobConfirmation = desired.lights[3].alwaysOnBrightness
                }
                value = desired
                if behavior == .staleKnob { value.lights[3].alwaysOnBrightness = previous }
            }
        }
    }
}

private final class LightingSnapshots: @unchecked Sendable {
    private let condition = NSCondition()
    private var latest: DeviceSnapshot?
    func append(_ snapshot: DeviceSnapshot) {
        condition.lock(); latest = snapshot; condition.broadcast(); condition.unlock()
    }
    func wait(_ predicate: (DeviceSnapshot) -> Bool) -> DeviceSnapshot? {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: 2)
        while true {
            if let latest, predicate(latest) { return latest }
            guard condition.wait(until: deadline) else { return nil }
        }
    }
}

final class LightingTests: XCTestCase {
    func testReplyOffsetsAndFullFourLightPayload() throws {
        XCTAssertEqual(DeviceProtocol.lightingRequest, [1, 0x0B, 0x88, 1])
        let original = try DeviceProtocol.parseLighting(lightingReply)
        XCTAssertEqual(original.mode, 1)
        XCTAssertEqual(original.brightness, 2)
        XCTAssertEqual(original.lights, [
            IndicatorLight(type: 2, workTime: 11, breatheLevel: 12, breatheBrightness: 13, alwaysOnBrightness: 14),
            IndicatorLight(type: 1, workTime: 21, breatheLevel: 22, breatheBrightness: 23, alwaysOnBrightness: 24),
            IndicatorLight(type: 0, workTime: 31, breatheLevel: 32, breatheBrightness: 33, alwaysOnBrightness: 34),
            IndicatorLight(type: 1, workTime: 41, breatheLevel: 42, breatheBrightness: 43, alwaysOnBrightness: 44),
        ])
        var desired = original
        desired.mode = 0
        desired.brightness = 1
        let writes = try DeviceProtocol.lightingWrites(desired, expected: original)
        XCTAssertEqual(writes, [
            [1, 0x0B, 0x88, 4, 1, 0, 0, 1] + Array(lightingReply[8..<28]),
            [1, 0x0B, 0x88, 4, 2, 0, 0, 1] + Array(lightingReply[8..<28]),
        ])
    }

    func testTypeEditRetainsEveryOtherFieldAndSelectsEachLight() throws {
        let original = try DeviceProtocol.parseLighting(lightingReply)
        for index in 0..<4 {
            var desired = original
            desired.lights[index].type = original.lights[index].type == 0 ? 1 : 0
            var payload = Array(lightingReply[8..<28])
            payload[index * 5] = desired.lights[index].type
            XCTAssertEqual(try DeviceProtocol.lightingWrites(desired, expected: original),
                           [[1, 0x0B, 0x88, 4, 4, UInt8(index), 1, 2] + payload])
        }
    }

    func testUnknownValuesRoundTripWhileIllegalEditsAreRejected() throws {
        var reply = lightingReply
        reply[6] = 0xFA; reply[7] = 0xFB; reply[8] = 0xFC; reply[27] = 0xFD
        let original = try DeviceProtocol.parseLighting(reply)
        XCTAssertEqual(original.mode, 0xFA)
        XCTAssertEqual(original.brightness, 0xFB)
        XCTAssertEqual(original.lights[0].type, 0xFC)
        XCTAssertEqual(original.lights[3].alwaysOnBrightness, 0xFD)
        XCTAssertEqual(try DeviceProtocol.lightingWrites(original, expected: original), [])
        var desired = original
        desired.lights[2].type = 1
        var payload = Array(reply[6..<28]); payload[12] = 1
        XCTAssertEqual(try DeviceProtocol.lightingWrites(desired, expected: original),
                       [[1, 0x0B, 0x88, 4, 4, 2] + payload])
        for invalid in 0..<8 {
            var changed = original
            switch invalid {
            case 0: changed.mode = 3
            case 1: changed.brightness = 21
            case 2: changed.lights[0].type = 3
            case 3: changed.lights[1].type = 2
            case 4: changed.lights[0].workTime += 1
            case 5: changed.lights[1].breatheLevel += 1
            case 6: changed.lights[2].breatheBrightness = 21
            default: changed.lights[3].alwaysOnBrightness = 21
            }
            XCTAssertThrowsError(try DeviceProtocol.lightingWrites(changed, expected: original))
        }
        var short = original; short.lights.removeLast()
        XCTAssertThrowsError(try DeviceProtocol.lightingWrites(short, expected: original))
        XCTAssertThrowsError(try DeviceProtocol.lightingWrites(original, expected: short))
    }

    func testStudioBrightnessLevelsAndPerLightMasks() throws {
        let original = try DeviceProtocol.parseLighting(lightingReply)
        for level: UInt8 in [0, 7, 20] {
            var desired = original
            desired.brightness = level
            desired.lights[0].breatheBrightness = level
            desired.lights[3].alwaysOnBrightness = level
            let writes = try DeviceProtocol.lightingWrites(desired, expected: original)
            XCTAssertEqual(writes.map { $0[4] }, [2, 0x20, 0x40])
            XCTAssertEqual(writes.map { $0[5] }, [0, 0, 3])
            for frame in writes {
                XCTAssertEqual(frame[7], level)
                XCTAssertEqual(frame[11], level)
                XCTAssertEqual(frame[27], level)
                XCTAssertEqual(frame[9], original.lights[0].workTime)
                XCTAssertEqual(frame[10], original.lights[0].breatheLevel)
                XCTAssertEqual(Array(frame[13..<23]), Array(lightingReply[13..<23]))
            }
        }
    }

    func testRejectsTruncatedAndUnrelatedReplies() throws {
        for count in 0..<28 {
            XCTAssertThrowsError(try DeviceProtocol.parseLighting(Array(lightingReply.prefix(count))))
        }
        for index in 0..<4 {
            var reply = lightingReply; reply[index] = 0
            XCTAssertFalse(DeviceProtocol.matchesLightingReply(reply))
            XCTAssertThrowsError(try DeviceProtocol.parseLighting(reply))
        }
    }

    private func apply(transport: LightingTransport, expected: DeviceLighting, desired: DeviceLighting,
                       online: Bool = true) throws -> DeviceSnapshot {
        let snapshots = LightingSnapshots()
        let service = NativeDeviceService(demo: false, transportFactory: { transport },
            loadHostKeymap: { nil }, saveHostKeymap: { _ in XCTFail("灯效不应保存主机按键配置") },
            bridgeFactory: { VendorKeyBridge(permissions: { (true, true) }, emit: { _, _, _ in }) },
            onChange: { snapshots.append($0) })
        service.start()
        defer {
            let stopped = expectation(description: "灯效服务结束")
            service.stop { stopped.fulfill() }
            wait(for: [stopped], timeout: 2)
        }
        _ = try XCTUnwrap(snapshots.wait { !$0.busy && $0.online == online })
        let requestID = UUID()
        service.applyLighting(desired, expected: expected, requestID: requestID)
        return try XCTUnwrap(snapshots.wait { !$0.busy && $0.lightingResult?.requestID == requestID })
    }

    func testServiceReadsBeforeWriteAndConfirmsReadbackBeforeSuccess() throws {
        let original = try DeviceProtocol.parseLighting(lightingReply)
        var desired = original; desired.brightness = 0
        let transport = LightingTransport(value: original)
        let result = try apply(transport: transport, expected: original, desired: desired)
        XCTAssertEqual(transport.operations, ["read", "write", "read"])
        XCTAssertNil(result.lightingResult?.error)
        XCTAssertNil(result.lightingError)
        XCTAssertEqual(result.lighting, desired)
    }

    func testServiceRejectsStaleExpectedConfigurationWithoutWrite() throws {
        let original = try DeviceProtocol.parseLighting(lightingReply)
        var actual = original; actual.mode = 0
        var desired = original; desired.brightness = 0
        let transport = LightingTransport(value: actual)
        let result = try apply(transport: transport, expected: original, desired: desired)
        XCTAssertEqual(transport.operations, ["read"])
        XCTAssertNotNil(result.lightingResult?.error)
        XCTAssertEqual(result.lighting, actual)
    }

    func testServiceNeverReportsSuccessForMismatchOrReadWriteFailure() throws {
        let original = try DeviceProtocol.parseLighting(lightingReply)
        var desired = original; desired.brightness = 0
        for behavior in [LightingTransport.Behavior.mismatch, .readFailure, .writeFailure] {
            let transport = LightingTransport(value: original, behavior: behavior)
            let result = try apply(transport: transport, expected: original, desired: desired)
            XCTAssertEqual(Array(transport.operations.prefix(2)), ["read", "write"])
            XCTAssertNotNil(result.lightingResult?.error)
            if behavior == .mismatch {
                XCTAssertNil(result.lightingError)
                XCTAssertEqual(result.lightingFailureFields, ["全亮亮度"])
            } else { XCTAssertNotNil(result.lightingError) }
            XCTAssertEqual(result.lighting, behavior == .readFailure ? nil : original)
        }
    }

    func testMismatchIdentifiesOnlyTheUnappliedFields() throws {
        let actual = try DeviceProtocol.parseLighting(lightingReply)
        var desired = actual
        desired.lights[3].alwaysOnBrightness = 8
        XCTAssertEqual(desired.differingFields(from: actual), ["旋钮常亮亮度"])
        desired.lights[0].breatheBrightness = 7
        XCTAssertEqual(desired.differingFields(from: actual), ["键 1呼吸亮度", "旋钮常亮亮度"])
        XCTAssertEqual(actual.differingFields(from: actual), [])
    }

    func testKnobCommandConfirmationDoesNotForgeRawReadback() throws {
        let original = try DeviceProtocol.parseLighting(lightingReply)
        var desired = original; desired.lights[3].alwaysOnBrightness = 5
        let transport = LightingTransport(value: original, behavior: .staleKnob)
        let result = try apply(transport: transport, expected: original, desired: desired)
        XCTAssertNil(result.lightingResult?.error)
        XCTAssertEqual(result.lighting, original)
        XCTAssertEqual(result.effectiveLighting, desired)
        XCTAssertEqual(result.lightingKnobBrightnessConfirmation, 5)
        XCTAssertTrue(result.lightingFailureFields.isEmpty)
    }

    func testKnobWithoutWriteConfirmationCannotBeReportedSuccessful() throws {
        let original = try DeviceProtocol.parseLighting(lightingReply)
        var desired = original; desired.lights[3].alwaysOnBrightness = 5
        let transport = LightingTransport(value: original, behavior: .mismatch)
        let result = try apply(transport: transport, expected: original, desired: desired)
        XCTAssertNotNil(result.lightingResult?.error)
        XCTAssertEqual(result.lightingFailureFields, ["旋钮常亮亮度"])
        XCTAssertNil(result.lightingKnobBrightnessConfirmation)
    }

    func testExplicitKnobWriteEvenWhenUnreliableReadbackMatches() throws {
        var original = try DeviceProtocol.parseLighting(lightingReply)
        original.lights[3].alwaysOnBrightness = 2
        let writes = try DeviceProtocol.lightingWrites(original, expected: original, setKnobBrightness: true)
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes[0][4], 0x40)
        XCTAssertEqual(writes[0][5], 3)
        XCTAssertEqual(writes[0][27], original.lights[3].alwaysOnBrightness)
    }

    func testWriteAcknowledgmentMustMatchFieldIndexAndValue() throws {
        let original = try DeviceProtocol.parseLighting(lightingReply)
        var desired = original; desired.mode = 0; desired.brightness = 7
        desired.lights[0].type = 1; desired.lights[0].breatheBrightness = 5
        desired.lights[3].alwaysOnBrightness = 5
        for request in try DeviceProtocol.lightingWrites(desired, expected: original) {
            var ack = request; ack[0] = 0x81; ack[3] = 0x14
            XCTAssertTrue(DeviceProtocol.matchesLightingWriteReply(ack, request: request))
            let offset = request[4] == 1 ? 6 : request[4] == 2 ? 7 : 8 + 5 * Int(request[5]) + (request[4] == 4 ? 0 : request[4] == 0x20 ? 3 : 4)
            for position in [0, 1, 2, 3, 4, 5, offset] {
                var bad = ack; bad[position] ^= 1
                XCTAssertFalse(DeviceProtocol.matchesLightingWriteReply(bad, request: request))
            }
            XCTAssertFalse(DeviceProtocol.matchesLightingWriteReply(Array(ack.prefix(27)), request: request))
            XCTAssertFalse(DeviceProtocol.matchesLightingWriteReply(ack, request: []))
        }
    }

    func testOfflineServiceNeverReadsOrWritesLighting() throws {
        let original = try DeviceProtocol.parseLighting(lightingReply)
        var desired = original; desired.brightness = 0
        let transport = LightingTransport(value: original, online: false)
        let result = try apply(transport: transport, expected: original, desired: desired, online: false)
        XCTAssertEqual(transport.operations, [])
        XCTAssertNotNil(result.lightingResult?.error)
        XCTAssertNil(result.lighting)
    }
}
