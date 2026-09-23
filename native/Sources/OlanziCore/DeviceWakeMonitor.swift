import Foundation
import IOKit
import IOKit.hid

protocol DeviceWakeMonitoring: AnyObject {
    /// 物理活动后是否仍有标准 HID 按键按住；回调不能发起设备查询。
    var onActivity: ((Bool) -> Void)? { get set }
    var error: String? { get }
    func open() throws
    func close()
}

/// 只解析 AU05 已确认的标准输入报告，不把直出按键再次转换为主机动作。
struct DeviceWakeReportParser {
    private var held: [UInt64: [UInt32: Bool]] = [:]

    mutating func receive(reportID: UInt32, bytes: [UInt8], source: UInt64 = 0) -> Bool? {
        let expected: Int
        switch reportID {
        case 1: expected = 2
        case 2: expected = 5
        case 3: expected = 8
        default: return nil
        }
        let payload: [UInt8]
        if bytes.count == expected { payload = bytes }
        else if bytes.count == expected + 1, bytes.first == UInt8(reportID) {
            payload = Array(bytes.dropFirst())
        } else { return nil }
        let pressed: Bool
        let motion: Bool
        switch reportID {
        case 1:
            pressed = payload.contains { $0 != 0 }
            motion = false
        case 2:
            guard payload[0] & 0xF8 == 0 else { return nil }
            pressed = payload[0] != 0
            motion = payload.dropFirst().contains { $0 != 0 }
        default:
            guard payload[1] == 0 else { return nil }
            // ErrorRollOver 也属于物理活动，不能因系统忽略该键码而无法唤醒。
            pressed = payload[0] != 0 || payload.dropFirst(2).contains { $0 != 0 }
            motion = false
        }
        let wasPressed = held[source]?[reportID] == true
        held[source, default: [:]][reportID] = pressed
        guard pressed || motion || wasPressed else { return nil }
        return held.values.contains { $0.values.contains(true) }
    }
}

/// 所有操作和回调均在设备工作线程执行；监听只读且不独占设备。
final class MacDeviceWakeMonitor: DeviceWakeMonitoring {
    var onActivity: ((Bool) -> Void)?
    private(set) var error: String?
    private var parser = DeviceWakeReportParser()
    private var endpoints: [Endpoint] = []
    private var runLoop: CFRunLoop?

    deinit { close() }

    private final class Endpoint {
        weak var monitor: MacDeviceWakeMonitor?
        let device: IOHIDDevice
        let source: UInt64
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
        init(device: IOHIDDevice, source: UInt64, monitor: MacDeviceWakeMonitor) {
            self.device = device
            self.source = source
            self.monitor = monitor
            buffer.initialize(repeating: 0, count: 64)
        }
        deinit { buffer.deinitialize(count: 64); buffer.deallocate() }
    }

    func open() throws {
        close()
        guard let matching = IOServiceMatching("IOHIDDevice"), let loop = CFRunLoopGetCurrent() else {
            throw DeviceProtocolError.message("无法启动 Vibe Key 标准输入监听。")
        }
        let dictionary = matching as NSMutableDictionary
        dictionary[kIOHIDVendorIDKey] = DeviceProtocol.vendorID
        dictionary[kIOHIDProductIDKey] = DeviceProtocol.productID
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard result == KERN_SUCCESS else { throw failure("枚举标准输入接口失败", result) }
        defer { IOObjectRelease(iterator) }
        runLoop = loop
        do {
            while true {
                let service = IOIteratorNext(iterator)
                guard service != 0 else { break }
                defer { IOObjectRelease(service) }
                guard let device = IOHIDDeviceCreate(kCFAllocatorDefault, service) else { continue }
                func property(_ key: String) -> Int? {
                    (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
                }
                guard property(kIOHIDVendorIDKey) == DeviceProtocol.vendorID,
                      property(kIOHIDProductIDKey) == DeviceProtocol.productID else { continue }
                let page = property(kIOHIDPrimaryUsagePageKey)
                let usage = property(kIOHIDPrimaryUsageKey)
                guard (page == 1 && (usage == 2 || usage == 6)) || (page == 12 && usage == 1) else { continue }
                var source: UInt64 = 0
                let identified = IORegistryEntryGetRegistryEntryID(service, &source)
                guard identified == KERN_SUCCESS else { throw failure("识别标准输入接口失败", identified) }
                let opened = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
                guard opened == kIOReturnSuccess else { throw failure("打开标准输入接口失败", opened) }
                let endpoint = Endpoint(device: device, source: source, monitor: self)
                endpoints.append(endpoint)
                let context = Unmanaged.passUnretained(endpoint).toOpaque()
                IOHIDDeviceRegisterInputReportCallback(device, endpoint.buffer, 64, { context, result, sender, type, reportID, report, length in
                    guard let context else { return }
                    let endpoint = Unmanaged<Endpoint>.fromOpaque(context).takeUnretainedValue()
                    guard sender == Unmanaged.passUnretained(endpoint.device).toOpaque() else { return }
                    guard let monitor = endpoint.monitor, monitor.error == nil else { return }
                    guard result == kIOReturnSuccess else {
                        monitor.error = monitor.failure("读取标准输入报文失败", result).localizedDescription
                        return
                    }
                    guard type == kIOHIDReportTypeInput, length > 0, length <= 64 else { return }
                    let bytes = Array(UnsafeBufferPointer(start: report, count: length))
                    if let pressed = monitor.parser.receive(reportID: reportID, bytes: bytes, source: endpoint.source) {
                        monitor.onActivity?(pressed)
                    }
                }, context)
                IOHIDDeviceRegisterRemovalCallback(device, { context, _, sender in
                    guard let context else { return }
                    let endpoint = Unmanaged<Endpoint>.fromOpaque(context).takeUnretainedValue()
                    guard sender == Unmanaged.passUnretained(endpoint.device).toOpaque() else { return }
                    endpoint.monitor?.error = "Vibe Key 标准输入接口已断开，正在等待重新连接。"
                }, context)
                IOHIDDeviceScheduleWithRunLoop(device, loop, CFRunLoopMode.defaultMode.rawValue)
            }
            guard !endpoints.isEmpty else {
                throw DeviceProtocolError.message("未找到 Vibe Key 标准输入接口，无法监听按键唤醒。")
            }
        } catch {
            close()
            throw error
        }
    }

    func close() {
        for endpoint in endpoints {
            IOHIDDeviceRegisterInputReportCallback(endpoint.device, endpoint.buffer, 64, nil, nil)
            IOHIDDeviceRegisterRemovalCallback(endpoint.device, nil, nil)
            if let runLoop {
                IOHIDDeviceUnscheduleFromRunLoop(endpoint.device, runLoop, CFRunLoopMode.defaultMode.rawValue)
            }
            IOHIDDeviceClose(endpoint.device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        endpoints.removeAll()
        runLoop = nil
        parser = DeviceWakeReportParser()
        error = nil
    }

    private func failure(_ message: String, _ result: IOReturn) -> DeviceProtocolError {
        let detail: String
        switch UInt32(bitPattern: result) {
        case 0xE00002E2: detail = "输入监控权限不足，请在系统设置中授权 Olanzi 后重新启动"
        case 0xE00002C5: detail = "接口被占用，请关闭 Studio 或其他抓包进程"
        default: detail = "请检查接收器连接和输入监控权限"
        }
        return .message(String(format: "%@：%@（0x%08X）。", message, detail, UInt32(bitPattern: result)))
    }
}
