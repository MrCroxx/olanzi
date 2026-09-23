import XCTest
@testable import OlanziCore

final class ProtocolTests: XCTestCase {
    func testConfirmedTEAZeroVectorAndRoundTrip() {
        let ciphertext: [UInt8] = [0x38, 0x90, 0xC4, 0x99, 0xA3, 0x60, 0xAA, 0xAD]
        XCTAssertEqual(DeviceProtocol.teaEncrypt(Array(repeating: 0, count: 8)), ciphertext)
        XCTAssertEqual(DeviceProtocol.teaDecrypt(ciphertext), Array(repeating: 0, count: 8))
        let input = (0..<67).map(UInt8.init)
        XCTAssertEqual(DeviceProtocol.teaDecrypt(DeviceProtocol.teaEncrypt(input)), input)
        XCTAssertEqual(Array(DeviceProtocol.teaEncrypt(input).suffix(3)), [64, 65, 66])
    }

    func testWireFramingAndOnlyCompleteBlocksDecoded() throws {
        let request: [UInt8] = [1, 6, 0x50, 4, 0, 1, 1, 2, 0x68]
        let report = try DeviceProtocol.encodeReport(request)
        XCTAssertEqual(report.count, 64)
        XCTAssertEqual(report.first, 0x55)
        let decoded = try XCTUnwrap(DeviceProtocol.decodeReport(reportID: 0x55, bytes: report))
        XCTAssertEqual(decoded.count, 56)
        XCTAssertEqual(Array(decoded.prefix(request.count)), request)
        XCTAssertEqual(DeviceProtocol.decodeReport(reportID: 0x55, bytes: Array(report.dropFirst())), decoded)
        XCTAssertNil(DeviceProtocol.decodeReport(reportID: 3, bytes: report))
        XCTAssertNil(DeviceProtocol.decodeReport(reportID: 0x55, bytes: Array(report.prefix(62))))
        XCTAssertNil(DeviceProtocol.decodeReport(reportID: 0x55, bytes: [0] + report.dropFirst()))
        XCTAssertThrowsError(try DeviceProtocol.encodeReport(Array(repeating: 0, count: 65)))
    }

    func testReadReplyValidationAndPreservesCompoundEntries() throws {
        let frame: [UInt8] = [0x81, 6, 0x50, 0x11, 3, 1, 2, 0x82, 0xE3, 2, 0x28]
        XCTAssertTrue(DeviceProtocol.matchesReply(frame, access: 0x11, index: 3))
        XCTAssertFalse(DeviceProtocol.matchesReply(frame, access: 0x14, index: 3))
        XCTAssertFalse(DeviceProtocol.matchesReply(frame, access: 0x11, index: 2))
        XCTAssertEqual(try DeviceProtocol.parseEntries(frame), [[0x82, 0xE3], [2, 0x28]])
        XCTAssertThrowsError(try DeviceProtocol.parseEntries(Array(frame.dropLast())))
        XCTAssertThrowsError(try DeviceProtocol.parseEntries([0x81, 6, 0x50, 0x11, 0, 1, 25]))
    }

    func testWritesRestrictedToSixControlsAndKnownSingleKeyboardEntries() throws {
        XCTAssertEqual(try DeviceProtocol.writeRequest(index: 0, entries: [[2, 0x01]]),
                       [1, 6, 0x50, 4, 0, 1, 1, 2, 1])
        for index in [-1, 6, 7, 256] {
            XCTAssertThrowsError(try DeviceProtocol.readRequest(index: index))
            XCTAssertThrowsError(try DeviceProtocol.writeRequest(index: index, entries: [[2, 4]]))
        }
        for entries: [[UInt8]] in [[], [[3, 4]], [[2]], [[2, 4], [2, 5]], [[2, 0xFF]]] {
            XCTAssertThrowsError(try DeviceProtocol.writeRequest(index: 0, entries: entries))
        }
    }

    func testSoftwareOnlineHandoffUsesDistinctVolatileControlReport() throws {
        for (online, expected) in [(true, [UInt8](arrayLiteral: 0x01, 0x01, 0x10, 0x00, 0x03)),
                                   (false, [UInt8](arrayLiteral: 0x01, 0x01, 0x10, 0x00, 0x00))] {
            let request = DeviceProtocol.softwareOnline(online)
            XCTAssertEqual(request, expected)
            let report = try DeviceProtocol.encodeReport(request)
            let decoded = try XCTUnwrap(DeviceProtocol.decodeReport(reportID: 0x55, bytes: report))
            XCTAssertEqual(Array(decoded.prefix(5)), expected)
        }
    }

    func testOnlineStatusUsesExplicitByteNotHeartbeatACK() throws {
        XCTAssertEqual(DeviceProtocol.heartbeat, [6, 1, 0x23, 0, 1])
        XCTAssertTrue(try DeviceProtocol.parseOnline([6, 3, 0x0A, 0x11, 1]))
        XCTAssertFalse(try DeviceProtocol.parseOnline([6, 3, 0x0A, 0x11, 0]))
        XCTAssertThrowsError(try DeviceProtocol.parseOnline([6, 3, 0x0A, 0x11, 2]))
        XCTAssertThrowsError(try DeviceProtocol.parseOnline(DeviceProtocol.heartbeat))
    }

    func testDemoTransportIsolatedState() throws {
        let first = DemoHIDTransport()
        let second = DemoHIDTransport()
        try first.open(); try second.open()
        try first.writeKey(index: 0, code: 0x69)
        XCTAssertEqual(try first.readKey(index: 0).code, 0x69)
        XCTAssertEqual(try second.readKey(index: 0).code, 0x01)
        first.close(); second.close()
    }

    func testTransportHeartbeatRequiresExplicitEnableAndCloseResetsIt() throws {
        let transport = DemoHIDTransport()
        try transport.open()
        try transport.pump(for: 0)
        XCTAssertFalse(transport.heartbeatEnabled)
        XCTAssertNil(transport.lastHeartbeat)
        transport.heartbeatEnabled = true
        try transport.pump(for: 0)
        XCTAssertNotNil(transport.lastHeartbeat)
        transport.heartbeatEnabled = false
        try transport.pump(for: 0)
        XCTAssertNil(transport.lastHeartbeat)
        transport.heartbeatEnabled = true
        transport.close()
        try transport.open()
        try transport.pump(for: 0)
        XCTAssertNil(transport.lastHeartbeat)
        XCTAssertFalse(transport.heartbeatEnabled)

        // 无需打开真实设备也可验证原生 transport 不继承旧开关。
        let native = MacHIDTransport()
        XCTAssertFalse(native.heartbeatEnabled)
        native.heartbeatEnabled = true
        native.close()
        XCTAssertFalse(native.heartbeatEnabled)
    }
}

private final class FakeTransport: DeviceTransport {
    var heartbeatEnabled = false
    var keys = DeviceProtocol.defaultCodes.enumerated().map { KeyBinding(index: $0.offset, entries: [KeyEntry(code: $0.element)]) }
    var writes: [Int] = []
    var closed = false
    var mainThreadCalls: [Bool] = []
    var failWriteIndex: Int?
    var disconnectOnSecondPump = false
    var pumpCount = 0
    var openCount = 0
    var queryCount = 0
    var failSecondQuery = false
    var lastHeartbeat: Date? = Date()
    func setSoftwareOnline(_ online: Bool) throws {}
    func open() throws { mainThreadCalls.append(Thread.isMainThread); openCount += 1 }
    func close() { mainThreadCalls.append(Thread.isMainThread); closed = true }
    func pump(for duration: TimeInterval) throws {
        mainThreadCalls.append(Thread.isMainThread)
        pumpCount += 1
        if disconnectOnSecondPump && pumpCount == 2 { throw DeviceProtocolError.message("测试接收器断开") }
    }
    func queryOnline() throws -> Bool {
        mainThreadCalls.append(Thread.isMainThread)
        queryCount += 1
        if failSecondQuery && queryCount == 2 { throw DeviceProtocolError.message("测试在线查询超时") }
        return true
    }
    func readKey(index: Int) throws -> KeyBinding { mainThreadCalls.append(Thread.isMainThread); return keys[index] }
    func writeKey(index: Int, code: UInt8) throws {
        mainThreadCalls.append(Thread.isMainThread)
        if index == failWriteIndex { throw DeviceProtocolError.message("测试写入失败") }
        writes.append(index)
        keys[index] = KeyBinding(index: index, entries: [KeyEntry(code: code)])
    }
}

private final class HeartbeatSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Date] = []
    func record(_ sent: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard values.count < 3, values.last != sent else { return false }
        values.append(sent)
        return values.count == 3
    }
    var snapshot: [Date] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}

final class NativeServiceTests: XCTestCase {
    func testHeartbeatAdvancesWithoutWindowOrUIRequests() {
        let heartbeats = expectation(description: "没有窗口或界面请求时仍持续发送心跳")
        let samples = HeartbeatSamples()
        let service = NativeDeviceService(demo: true) { state in
            guard state.connected, state.heartbeatEnabled, let sent = state.lastHeartbeat else { return }
            if samples.record(sent) { heartbeats.fulfill() }
        }
        service.start()
        wait(for: [heartbeats], timeout: 5)
        let stopped = expectation(description: "明确退出后关闭后台线程")
        service.stop { stopped.fulfill() }
        wait(for: [stopped], timeout: 2)
        let timestamps = samples.snapshot
        XCTAssertEqual(timestamps.count, 3)
        if let first = timestamps.first, let last = timestamps.last {
            XCTAssertGreaterThanOrEqual(last.timeIntervalSince(first), 1.8)
        }
    }

    func testKeyboardBridgeStaysEnabledForOrdinaryMappingsAndStopsOnDisconnect() {
        let initial = expectation(description: "出厂 Fn 自动就绪")
        let removed = expectation(description: "最后一个 Fn 改走后普通键仍需转换")
        let assigned = expectation(description: "另一控件分配 Fn 后自动启用")
        let disconnected = expectation(description: "断开后不保留 Fn 状态")
        for item in [initial, removed, assigned, disconnected] { item.assertForOverFulfill = false }
        let transport = FakeTransport()
        let service = NativeDeviceService(demo: true, transportFactory: { transport }) { state in
            guard !state.busy else { return }
            if state.keys.count == 6 {
                if state.keys[0].code == 1, state.fn.enabled { initial.fulfill() }
                if state.keys[0].code == 0x68, state.keys[1].code == 0x28, state.fn.enabled { removed.fulfill() }
                if state.keys[0].code == 0x68, state.keys[1].code == 1, state.fn.enabled { assigned.fulfill() }
            }
            if transport.closed, !state.connected, !state.fn.enabled, !state.fn.active, !state.fn.pressed {
                disconnected.fulfill()
            }
        }
        service.start()
        wait(for: [initial], timeout: 2)
        service.apply(changes: [KeyChange(index: 0, code: 0x68)], expected: [
            KeyBinding(index: 0, entries: [KeyEntry(code: 1)])])
        wait(for: [removed], timeout: 2)
        service.apply(changes: [KeyChange(index: 1, code: 1)], expected: [
            KeyBinding(index: 1, entries: [KeyEntry(code: 0x28)])])
        wait(for: [assigned], timeout: 2)
        service.disconnect()
        wait(for: [disconnected], timeout: 2)
        let stopped = expectation(description: "安全退出")
        service.stop { stopped.fulfill() }
        wait(for: [stopped], timeout: 2)
    }

    func testPartiallyAppliedFnMappingUsesActualReadback() {
        let ready = expectation(description: "启动时普通键转换就绪")
        let partial = expectation(description: "部分写入成功的 Fn 仍自动启用")
        ready.assertForOverFulfill = false
        partial.assertForOverFulfill = false
        let transport = FakeTransport()
        transport.keys[0] = KeyBinding(index: 0, entries: [KeyEntry(code: 0x68)])
        transport.failWriteIndex = 1
        let service = NativeDeviceService(demo: true, transportFactory: { transport }) { state in
            guard !state.busy, state.keys.count == 6 else { return }
            if state.keys[0].code == 0x68, state.fn.enabled { ready.fulfill() }
            if state.keys[0].code == 1, state.fn.enabled, state.error?.contains("部分改动") == true { partial.fulfill() }
        }
        service.start()
        wait(for: [ready], timeout: 2)
        service.apply(changes: [KeyChange(index: 0, code: 1), KeyChange(index: 1, code: 0x69)], expected: [
            KeyBinding(index: 0, entries: [KeyEntry(code: 0x68)]),
            KeyBinding(index: 1, entries: [KeyEntry(code: 0x28)])])
        wait(for: [partial], timeout: 2)
        let stopped = expectation(description: "安全退出")
        service.stop { stopped.fulfill() }
        wait(for: [stopped], timeout: 2)
        XCTAssertEqual(transport.writes, [0])
    }

    func testConnectQueryTimeoutClearsOldOnlineStateAndPausesHeartbeat() {
        let ready = expectation(description: "设备在线")
        let unknown = expectation(description: "状态未知时暂停心跳，保留只读连接")
        ready.assertForOverFulfill = false
        unknown.assertForOverFulfill = false
        let transport = FakeTransport()
        transport.failSecondQuery = true
        let service = NativeDeviceService(demo: true, transportFactory: { transport }) { state in
            if state.online == true, state.keys.count == 6 { ready.fulfill() }
            if !state.busy, state.error?.contains("在线查询超时") == true,
               state.online == nil, state.connected, !state.heartbeatEnabled { unknown.fulfill() }
        }
        service.start()
        wait(for: [ready], timeout: 2)
        service.connect()
        wait(for: [unknown], timeout: 2)
        let stopped = expectation(description: "安全关闭")
        service.stop { stopped.fulfill() }
        wait(for: [stopped], timeout: 2)
        XCTAssertEqual(transport.openCount, 1)
    }

    func testUSBRemovalReconnectsAutomatically() {
        let lost = expectation(description: "收到断开状态")
        let restored = expectation(description: "自动重连并回读")
        lost.assertForOverFulfill = false
        restored.assertForOverFulfill = false
        let transport = FakeTransport()
        transport.disconnectOnSecondPump = true
        let service = NativeDeviceService(demo: true, transportFactory: { transport }) { state in
            if !state.connected, state.error?.contains("接收器断开") == true { lost.fulfill() }
            if state.connected, state.online == true, state.keys.count == 6 { restored.fulfill() }
        }
        service.start()
        wait(for: [lost, restored], timeout: 4, enforceOrder: true)
        let stopped = expectation(description: "安全关闭")
        service.stop { stopped.fulfill() }
        wait(for: [stopped], timeout: 2)
        XCTAssertEqual(transport.openCount, 2)
        XCTAssertTrue(transport.closed)
    }

    func testOptimisticConflictMakesNoWritesAndClosesOnWorkerThread() {
        let ready = expectation(description: "设备已读回")
        let conflict = expectation(description: "拒绝覆盖外部修改")
        ready.assertForOverFulfill = false
        conflict.assertForOverFulfill = false
        let transport = FakeTransport()
        let service = NativeDeviceService(demo: true, transportFactory: { transport }) { state in
            if state.online == true, state.keys.count == 6 { ready.fulfill() }
            if state.error?.contains("其他程序") == true, !state.busy { conflict.fulfill() }
        }
        service.start()
        wait(for: [ready], timeout: 2)
        service.apply(changes: [KeyChange(index: 0, code: 0x69)],
                      expected: [KeyBinding(index: 0, entries: [KeyEntry(code: 0x68)])])
        wait(for: [conflict], timeout: 2)
        let stopped = expectation(description: "安全关闭")
        service.stop { stopped.fulfill() }
        wait(for: [stopped], timeout: 2)
        XCTAssertTrue(transport.writes.isEmpty)
        XCTAssertTrue(transport.closed)
        XCTAssertFalse(transport.mainThreadCalls.contains(true))
    }

    func testApplyReadsBackAndReturnsCompleteSixKeys() {
        let ready = expectation(description: "设备已读回")
        let applied = expectation(description: "更新成功且完整回读")
        ready.assertForOverFulfill = false
        applied.assertForOverFulfill = false
        let transport = FakeTransport()
        let service = NativeDeviceService(demo: true, transportFactory: { transport }) { state in
            if state.online == true, state.keys.count == 6 { ready.fulfill() }
            if state.keys.count == 6, state.keys[0].code == 0x69, !state.busy, state.error == nil { applied.fulfill() }
        }
        service.start()
        wait(for: [ready], timeout: 2)
        service.apply(changes: [KeyChange(index: 0, code: 0x69)],
                      expected: [KeyBinding(index: 0, entries: [KeyEntry(code: 1)])])
        wait(for: [applied], timeout: 2)
        let stopped = expectation(description: "安全关闭")
        service.stop { stopped.fulfill() }
        wait(for: [stopped], timeout: 2)
        XCTAssertEqual(transport.writes, [0])
    }

    func testPartialWriteShowsReadbackWithoutAutomaticRollback() {
        let ready = expectation(description: "设备已读回")
        let partial = expectation(description: "保留部分写入证据")
        ready.assertForOverFulfill = false
        partial.assertForOverFulfill = false
        let transport = FakeTransport()
        transport.failWriteIndex = 1
        let service = NativeDeviceService(demo: true, transportFactory: { transport }) { state in
            if state.online == true, state.keys.count == 6 { ready.fulfill() }
            if state.keys.count == 6, state.keys[0].code == 0x69, state.keys[1].code == 0x28,
               state.error?.contains("部分改动") == true, !state.busy { partial.fulfill() }
        }
        service.start()
        wait(for: [ready], timeout: 2)
        service.apply(changes: [KeyChange(index: 0, code: 0x69), KeyChange(index: 1, code: 0x68)], expected: [
            KeyBinding(index: 0, entries: [KeyEntry(code: 1)]), KeyBinding(index: 1, entries: [KeyEntry(code: 0x28)])])
        wait(for: [partial], timeout: 2)
        let stopped = expectation(description: "安全关闭")
        service.stop { stopped.fulfill() }
        wait(for: [stopped], timeout: 2)
        XCTAssertEqual(transport.writes, [0])
    }
}
