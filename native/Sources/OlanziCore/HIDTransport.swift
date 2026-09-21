import Foundation
import IOKit
import IOKit.hid

protocol DeviceTransport: AnyObject {
    var lastHeartbeat: Date? { get }
    var onKeyEvent: ((VendorKeyEvent) -> Void)? { get set }
    var onPump: (() -> Void)? { get set }
    func open() throws
    func close()
    func pump(for duration: TimeInterval) throws
    func queryOnline() throws -> Bool
    func readKey(index: Int) throws -> KeyBinding
    func writeKey(index: Int, code: UInt8) throws
    func takeKeyEvents() -> [VendorKeyEvent]
}

extension DeviceTransport {
    var onKeyEvent: ((VendorKeyEvent) -> Void)? { get { nil } set {} }
    var onPump: (() -> Void)? { get { nil } set {} }
    func takeKeyEvents() -> [VendorKeyEvent] { [] }
}

/// 实例、回调以及所有 IOKit 操作仅在设备工作线程中使用。
final class MacHIDTransport: DeviceTransport {
    var onKeyEvent: ((VendorKeyEvent) -> Void)?
    var onPump: (() -> Void)?
    private var device: IOHIDDevice?
    private var runLoop: CFRunLoop?
    private var buffer: UnsafeMutablePointer<UInt8>?
    private var frames: [[UInt8]] = []
    private var keyEvents: [VendorKeyEvent] = []
    private var removed = false
    private var callbackError: String?
    private var nextHeartbeat: TimeInterval = 0
    private(set) var lastHeartbeat: Date?

    func open() throws {
        close()
        guard let matching = IOServiceMatching("IOHIDDevice") else {
            throw DeviceProtocolError.message("无法枚举 HID 设备。")
        }
        let dictionary = matching as NSMutableDictionary
        dictionary[kIOHIDVendorIDKey] = DeviceProtocol.vendorID
        dictionary[kIOHIDProductIDKey] = DeviceProtocol.productID
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard result == KERN_SUCCESS else { throw ioError("HID 枚举失败", result) }
        defer { IOObjectRelease(iterator) }
        var candidates: [IOHIDDevice] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            let candidate = IOHIDDeviceCreate(kCFAllocatorDefault, service)
            IOObjectRelease(service)
            guard let candidate = candidate else { continue }
            if (IOHIDDeviceGetProperty(candidate, kIOHIDPrimaryUsagePageKey as CFString) as? NSNumber)?.intValue
                == DeviceProtocol.vendorUsagePage {
                candidates.append(candidate)
            }
        }
        guard candidates.count == 1 else {
            throw DeviceProtocolError.message(candidates.isEmpty ? "未找到 Vibe Key，请插入 USB 接收器。" : "请只连接一个 Vibe Key 接收器。")
        }
        let selected = candidates[0]
        let opened = IOHIDDeviceOpen(selected, IOOptionBits(kIOHIDOptionsTypeNone))
        guard opened == kIOReturnSuccess else {
            let detail: String
            switch UInt32(bitPattern: opened) {
            case 0xE00002E2: detail = "输入监控权限不足，请在系统设置中授权 Olanzi 后重新启动"
            case 0xE00002C5: detail = "设备被占用，请关闭 Studio 或其他抓包进程"
            default: detail = "厂商通道打开失败"
            }
            throw ioError(detail, opened)
        }
        device = selected
        guard let currentRunLoop = CFRunLoopGetCurrent() else {
            close()
            throw DeviceProtocolError.message("无法取得设备工作线程的 run loop。")
        }
        runLoop = currentRunLoop
        removed = false
        callbackError = nil
        frames.removeAll()
        keyEvents.removeAll()
        let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: 512)
        bytes.initialize(repeating: 0, count: 512)
        buffer = bytes
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(selected, bytes, 512, { context, result, _, _, reportID, report, length in
            guard let context = context else { return }
            let transport = Unmanaged<MacHIDTransport>.fromOpaque(context).takeUnretainedValue()
            if result != kIOReturnSuccess {
                transport.callbackError = String(format: "读取 HID 报文失败：0x%08X", UInt32(bitPattern: result))
                return
            }
            guard length == 63 || length == 64 else { return }
            if let frame = DeviceProtocol.decodeReport(reportID: reportID,
                                                       bytes: Array(UnsafeBufferPointer(start: report, count: length))) {
                transport.receiveDecodedFrame(frame)
            }
        }, context)
        IOHIDDeviceRegisterRemovalCallback(selected, { context, _, _ in
            guard let context = context else { return }
            Unmanaged<MacHIDTransport>.fromOpaque(context).takeUnretainedValue().removed = true
        }, context)
        IOHIDDeviceScheduleWithRunLoop(selected, currentRunLoop, CFRunLoopMode.defaultMode.rawValue)
        nextHeartbeat = 0
    }

    func close() {
        if let device = device {
            if let buffer = buffer { IOHIDDeviceRegisterInputReportCallback(device, buffer, 512, nil, nil) }
            IOHIDDeviceRegisterRemovalCallback(device, nil, nil)
            if let runLoop = runLoop { IOHIDDeviceUnscheduleFromRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue) }
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        device = nil
        runLoop = nil
        buffer?.deinitialize(count: 512)
        buffer?.deallocate()
        buffer = nil
        frames.removeAll()
        keyEvents.removeAll()
        callbackError = nil
        removed = false
        lastHeartbeat = nil
    }

    func pump(for duration: TimeInterval = 0.01) throws {
        if duration > 0 { CFRunLoopRunInMode(CFRunLoopMode.defaultMode, duration, false) }
        // 先处理移除和回调错误，不能在已知断开后吐出到期的旧单击。
        if device != nil {
            if removed { throw DeviceProtocolError.message("USB 接收器已断开，正在等待重新连接。") }
            if let error = callbackError { throw DeviceProtocolError.message(error) }
        }
        // 查询等待期间也推进手势计时；回调不得重新进入设备查询或写入。
        onPump?()
        guard device != nil else { return }
        if ProcessInfo.processInfo.systemUptime >= nextHeartbeat {
            // 心跳没有已确认的 ACK，不据成功发送推断设备本体在线。
            try send(DeviceProtocol.heartbeat)
            lastHeartbeat = Date()
            nextHeartbeat = ProcessInfo.processInfo.systemUptime + 1
        }
    }

    func queryOnline() throws -> Bool {
        let frame = try exchange(DeviceProtocol.onlineRequest, timeout: 0.8, matching: DeviceProtocol.matchesOnlineReply)
        return try DeviceProtocol.parseOnline(frame)
    }

    func takeKeyEvents() -> [VendorKeyEvent] {
        defer { keyEvents.removeAll(keepingCapacity: true) }
        return keyEvents
    }

    func receiveDecodedFrame(_ frame: [UInt8]) {
        if let event = VendorKeyEvent.decode(frame) {
            // 查询同样会泵送此回调，立即发键，避免查询超时把 Fn 上下沿挤到一起。
            // 处理器只允许执行主机输入，不能在此重入设备查询或写入。
            if let onKeyEvent { onKeyEvent(event) }
            else if keyEvents.count < 512 { keyEvents.append(event) }
            else { callbackError = "设备按键事件积压，正在释放按键并重连。" }
            return
        }
        frames.append(frame)
        if frames.count > 128 { frames.removeFirst(frames.count - 128) }
    }

    func readKey(index: Int) throws -> KeyBinding {
        let frame = try exchange(DeviceProtocol.readRequest(index: index)) {
            DeviceProtocol.matchesReply($0, access: 0x11, index: index)
        }
        return KeyBinding(index: index, entries: try DeviceProtocol.parseEntries(frame).map { KeyEntry(type: $0[0], code: $0[1]) })
    }

    func writeKey(index: Int, code: UInt8) throws {
        _ = try exchange(DeviceProtocol.writeRequest(index: index, entries: [[2, code]])) {
            DeviceProtocol.matchesReply($0, access: 0x14, index: index)
        }
    }

    private func exchange(_ request: [UInt8], timeout: TimeInterval = 1.3,
                          matching: ([UInt8]) -> Bool) throws -> [UInt8] {
        guard device != nil else { throw DeviceProtocolError.message("设备尚未连接。") }
        try pump(for: 0.001)
        frames.removeAll()
        try send(request)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            try pump(for: 0.02)
            while !frames.isEmpty {
                let frame = frames.removeFirst()
                if matching(frame) { return frame }
            }
        }
        throw DeviceProtocolError.message("设备回复超时，请确认 Vibe Key 已开机，并关闭其他配置工具。")
    }

    private func send(_ request: [UInt8]) throws {
        guard let device = device else { throw DeviceProtocolError.message("设备尚未连接。") }
        let wire = try DeviceProtocol.encodeReport(request)
        let result = wire.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(DeviceProtocol.reportID), $0.baseAddress!, wire.count)
        }
        guard result == kIOReturnSuccess else { throw ioError("发送设备报文失败", result) }
    }

    private func ioError(_ message: String, _ result: IOReturn) -> DeviceProtocolError {
        .message(String(format: "%@（0x%08X）。", message, UInt32(bitPattern: result)))
    }
}

/// 演示路径只维护内存，不构造 IOKit 设备或调用输入权限 API。
final class DemoHIDTransport: DeviceTransport {
    private var keys = DeviceProtocol.defaultCodes.enumerated().map { KeyBinding(index: $0.offset, entries: [KeyEntry(code: $0.element)]) }
    private var opened = false
    private(set) var lastHeartbeat: Date?
    func open() throws { opened = true; lastHeartbeat = Date() }
    func close() { opened = false; lastHeartbeat = nil }
    func pump(for duration: TimeInterval) throws {
        if opened, Date().timeIntervalSince(lastHeartbeat ?? .distantPast) >= 1 { lastHeartbeat = Date() }
    }
    func queryOnline() throws -> Bool { opened }
    func readKey(index: Int) throws -> KeyBinding {
        guard opened, (0..<6).contains(index) else { throw DeviceProtocolError.invalidControl }
        return keys[index]
    }
    func writeKey(index: Int, code: UInt8) throws {
        _ = try DeviceProtocol.writeRequest(index: index, entries: [[2, code]])
        guard opened else { throw DeviceProtocolError.message("演示设备尚未连接。") }
        keys[index] = KeyBinding(index: index, entries: [KeyEntry(code: code)])
    }
}
