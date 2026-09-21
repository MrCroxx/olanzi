import ApplicationServices
import CoreGraphics
import Foundation
import IOKit
import IOKit.hid
import IOKit.hidsystem
import OSLog

public enum InputPermission: Equatable, Sendable {
    case inputMonitoring, accessibility

    public var title: String { self == .inputMonitoring ? "输入监控" : "辅助功能" }
    public var settingsURL: URL {
        let pane = self == .inputMonitoring ? "Privacy_ListenEvent" : "Privacy_Accessibility"
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }

    @MainActor public func requestAccess() {
        // 在前台按钮的调用栈中请求，必须先于打开系统设置，不能绕行设备任务队列。
        switch self {
        case .inputMonitoring:
            let hidGranted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            // 部分系统上 HID 请求直接返回拒绝，事件监听请求提供同一权限的系统入口。
            let listenGranted = hidGranted || CGRequestListenEventAccess()
            Logger(subsystem: "com.mrcroxx.olanzi", category: "permissions")
                .info("输入监控权限请求：HID=\(hidGranted)，事件监听=\(listenGranted)")
        case .accessibility:
            if !AXIsProcessTrusted() {
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            } else if !CGPreflightPostEventAccess() {
                _ = CGRequestPostEventAccess()
            }
        }
    }
}

/// Fn 为本机运行时桥接；所有状态只由设备工作线程访问。
public struct FnStatus: Equatable, Sendable {
    public var enabled: Bool
    public var active: Bool
    public var pressed: Bool
    public var inputPermission: Bool?
    public var accessibilityPermission: Bool?
    public var error: String?
    public var events: Int

    public var missingPermissions: [InputPermission] {
        var missing: [InputPermission] = []
        if inputPermission != true { missing.append(.inputMonitoring) }
        if accessibilityPermission != true { missing.append(.accessibility) }
        return missing
    }

    public init(enabled: Bool = false, active: Bool = false, pressed: Bool = false,
                inputPermission: Bool? = nil, accessibilityPermission: Bool? = nil,
                error: String? = nil, events: Int = 0) {
        self.enabled = enabled
        self.active = active
        self.pressed = pressed
        self.inputPermission = inputPermission
        self.accessibilityPermission = accessibilityPermission
        self.error = error
        self.events = events
    }
}

public enum FnReport {
    /// AU05 使用一个 0x01 槽位作为自定义键；六个 0x01 是标准 rollover 错误。
    public static func decode(reportID: Int, data: [UInt8]) -> Bool? {
        guard reportID == 3 else { return nil }
        let payload: ArraySlice<UInt8>
        if data.count == 9 {
            guard data[0] == 3 else { return nil }
            payload = data.dropFirst()
        } else {
            payload = data[...]
        }
        guard payload.count == 8, payload[payload.startIndex + 1] == 0 else { return nil }
        let codes = payload.dropFirst(2)
        return codes.filter { $0 == 1 }.count == 1 && !codes.contains(2) && !codes.contains(3)
    }

    /// 松开合成 Fn 时保留真实 Fn 和当前硬件修饰键。
    public static func flags(hardware: CGEventFlags, pressed: Bool) -> CGEventFlags {
        pressed ? hardware.union(.maskSecondaryFn) : hardware
    }
}

// 原生接口可替换为测试替身，回归测试不会访问输入设备或向桌面发送按键。
protocol FnBackend: AnyObject {
    var callbackError: String? { get set }
    func permissions() -> (input: Bool?, accessibility: Bool)
    func requestPermissions()
    func open(onReport: @escaping (Int, [UInt8]) -> Void,
              onLost: @escaping (String) -> Void) throws
    func postFn(pressed: Bool) throws
    func close() throws
}

private struct FnFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// 标准输入接口与厂商接口分开打开，失败不会关闭厂商通道或停止心跳。
final class NativeFnBackend: FnBackend {
    private let inputLog = Logger(subsystem: "com.mrcroxx.olanzi", category: "device-input")
    var callbackError: String?
    private var device: IOHIDDevice?
    private var source: CGEventSource?
    private var runLoop: CFRunLoop?
    private var buffer: UnsafeMutablePointer<UInt8>?
    private var onReport: ((Int, [UInt8]) -> Void)?
    private var onLost: ((String) -> Void)?
    private var scheduled = false
    private static let bufferSize = 64
    private let checkInput: () -> IOHIDAccessType
    private let checkPosting: () -> Bool
    private let checkAccessibility: () -> Bool

    init(checkInput: @escaping () -> IOHIDAccessType = { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) },
         checkPosting: @escaping () -> Bool = { CGPreflightPostEventAccess() },
         checkAccessibility: @escaping () -> Bool = { AXIsProcessTrusted() }) {
        self.checkInput = checkInput
        self.checkPosting = checkPosting
        self.checkAccessibility = checkAccessibility
    }

    deinit { try? close() }

    func permissions() -> (input: Bool?, accessibility: Bool) {
        let input: Bool?
        switch checkInput() {
        case kIOHIDAccessTypeGranted: input = true
        case kIOHIDAccessTypeDenied: input = false
        default: input = nil
        }
        // AXIsProcessTrusted 在未授权时会影响系统权限记录，不能当成无副作用预检。
        // 先检查事件发送权限，避免辅助功能拒绝记录挡住后续输入监控的注册请求。
        return (input, checkPosting() && checkAccessibility())
    }

    func requestPermissions() {
        let access = permissions()
        let status = FnStatus(inputPermission: access.input, accessibilityPermission: access.accessibility)
        guard let permission = status.missingPermissions.first else { return }
        // 一次只请求当前缺少的一项。系统提示交给主线程，不能阻塞设备心跳。
        DispatchQueue.main.async {
            permission.requestAccess()
        }
    }

    static func matches(vendor: Int, product: Int, usagePage: Int, usage: Int) -> Bool {
        // 接口 2 以 Consumer 集合开头，同一接口还承载键盘 Report ID 3。
        vendor == 0xFFF1 && product == 0x00DD &&
            ((usagePage == 12 && usage == 1) || (usagePage == 1 && usage == 6))
    }

    private func candidates() throws -> [IOHIDDevice] {
        let matching: CFDictionary = [
            "IOProviderClass": "IOHIDDevice", kIOHIDVendorIDKey: 0xFFF1,
            kIOHIDProductIDKey: 0x00DD
        ] as CFDictionary
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard result == KERN_SUCCESS else {
            throw FnFailure(message: "Fn 输入接口枚举失败：\(Self.hex(result))")
        }
        defer { IOObjectRelease(iterator) }
        var devices: [IOHIDDevice] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            guard let candidate = IOHIDDeviceCreate(kCFAllocatorDefault, service) else { continue }
            func number(_ key: String) -> Int {
                (IOHIDDeviceGetProperty(candidate, key as CFString) as? NSNumber)?.intValue ?? -1
            }
            if Self.matches(vendor: number(kIOHIDVendorIDKey), product: number(kIOHIDProductIDKey),
                            usagePage: number(kIOHIDPrimaryUsagePageKey), usage: number(kIOHIDPrimaryUsageKey)) {
                devices.append(candidate)
            }
        }
        return devices
    }

    func open(onReport: @escaping (Int, [UInt8]) -> Void,
              onLost: @escaping (String) -> Void) throws {
        let devices = try candidates()
        guard devices.count == 1, let device = devices.first else {
            throw FnFailure(message: "Fn 桥接需要恰好一个 Vibe Key 标准输入接口。")
        }
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            let detail: String
            switch UInt32(bitPattern: result) {
            case 0xE00002E2: detail = "请在系统设置的输入监控中授权 Olanzi，然后重新打开 App"
            case 0xE00002C5: detail = "输入接口被占用，请关闭 Studio 或其他抓包程序"
            default: detail = "无法打开 Fn 输入接口"
            }
            throw FnFailure(message: "\(detail)（\(Self.hex(result))）。")
        }
        self.device = device
        self.onReport = onReport
        self.onLost = onLost
        callbackError = nil
        do {
            // 独立源保留自己的事件状态；投递层级由 postFn 单独选择。
            guard let source = CGEventSource(stateID: .privateState) else {
                throw FnFailure(message: "无法创建 Mac Fn 事件源。")
            }
            self.source = source
            guard let runLoop = CFRunLoopGetCurrent() else {
                throw FnFailure(message: "无法取得 Fn 工作线程的 run loop。")
            }
            self.runLoop = runLoop
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.bufferSize)
            buffer.initialize(repeating: 0, count: Self.bufferSize)
            self.buffer = buffer
            let context = Unmanaged.passUnretained(self).toOpaque()
            IOHIDDeviceRegisterInputReportCallback(device, buffer, Self.bufferSize, { context, result, sender, type, reportID, report, count in
                guard let context else { return }
                let owner = Unmanaged<NativeFnBackend>.fromOpaque(context).takeUnretainedValue()
                owner.receive(result: result, sender: sender, type: type,
                              reportID: reportID, report: report, count: count)
            }, context)
            IOHIDDeviceRegisterRemovalCallback(device, { context, _, sender in
                guard let context else { return }
                let owner = Unmanaged<NativeFnBackend>.fromOpaque(context).takeUnretainedValue()
                guard let current = owner.device,
                      sender == Unmanaged.passUnretained(current).toOpaque() else { return }
                owner.lost("Vibe Key 输入接口已断开。")
            }, context)
            IOHIDDeviceScheduleWithRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
            scheduled = true
            inputLog.info("AU05 标准输入接口已连接，等待设备报文")
        } catch {
            try? close()
            throw error
        }
    }

    private func receive(result: IOReturn, sender: UnsafeMutableRawPointer?, type: IOHIDReportType,
                         reportID: UInt32, report: UnsafeMutablePointer<UInt8>, count: CFIndex) {
        let senderMatches = device.map { sender == Unmanaged.passUnretained($0).toOpaque() } ?? false
        inputLog.info("AU05 输入回调：结果=\(result)，来源匹配=\(senderMatches)，类型=\(type.rawValue)，报告=\(reportID)，长度=\(count)")
        guard let device, sender == Unmanaged.passUnretained(device).toOpaque(), type == kIOHIDReportTypeInput else { return }
        guard result == kIOReturnSuccess else {
            lost("Fn 输入读取失败：\(Self.hex(result))")
            return
        }
        guard reportID == 3, count == 8 || count == 9 else { return }
        let bytes = Array(UnsafeBufferPointer(start: report, count: count))
        let fn = FnReport.decode(reportID: Int(reportID), data: bytes)
        // 只记录目标设备的报文形态与 Fn 状态，不记录其他键盘或输入内容。
        inputLog.info("AU05 键盘报文：长度=\(count)，Fn=\(String(describing: fn), privacy: .public)")
        onReport?(Int(reportID), bytes)
    }

    private func lost(_ message: String) {
        callbackError = message
        onLost?(message)
    }

    func postFn(pressed: Bool) throws {
        guard let source else { throw FnFailure(message: "Mac Fn 事件源尚未就绪。") }
        let flags = FnReport.flags(hardware: CGEventSource.flagsState(.hidSystemState), pressed: pressed)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: 63, keyDown: pressed) else {
            throw FnFailure(message: "无法创建 Mac Fn 事件。")
        }
        // Fn 的按下与松开均为 flagsChanged，普通按键事件无法替代。
        event.type = .flagsChanged
        event.flags = flags
        // 豆包等输入法在 HID 层监听，投递到后面的 session 层会绕过这些监听器。
        event.post(tap: .cghidEventTap)
        inputLog.info("Fn 事件已投递：按下=\(pressed)，标志=\(flags.rawValue)")
    }

    func close() throws {
        var closeResult: IOReturn = kIOReturnSuccess
        if let device {
            if let buffer {
                IOHIDDeviceRegisterInputReportCallback(device, buffer, Self.bufferSize, nil, nil)
            }
            IOHIDDeviceRegisterRemovalCallback(device, nil, nil)
            if scheduled, let runLoop {
                IOHIDDeviceUnscheduleFromRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
            }
            closeResult = IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        // 回调取消、run loop 移除后才释放上下文引用与输入缓冲区。
        device = nil
        source = nil
        runLoop = nil
        scheduled = false
        onReport = nil
        onLost = nil
        buffer?.deinitialize(count: Self.bufferSize)
        buffer?.deallocate()
        buffer = nil
        if closeResult != kIOReturnSuccess {
            throw FnFailure(message: "Fn 输入接口关闭失败：\(Self.hex(closeResult))")
        }
    }

    private static func hex(_ result: IOReturn) -> String {
        String(format: "0x%08X", UInt32(bitPattern: result))
    }
}

public final class MacFnBridge {
    public private(set) var status = FnStatus()
    private let demo: Bool
    private let now: () -> TimeInterval
    private var backend: (any FnBackend)?
    private var connected = false
    private var online: Bool?
    private var opened = false
    private var fault: String?
    private var nextRetry: TimeInterval = 0

    public init(demo: Bool = false) {
        self.demo = demo
        self.now = { ProcessInfo.processInfo.systemUptime }
    }

    init(demo: Bool = false, backend: any FnBackend,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.demo = demo
        self.backend = backend
        self.now = now
    }

    deinit { close() }

    public func synchronize(enabled: Bool, connected: Bool, online: Bool?) {
        let wasReady = status.enabled && self.connected && self.online == true
        status.enabled = enabled
        self.connected = connected
        self.online = online
        if !enabled || !connected || online != true {
            stop()
            if !enabled && !status.pressed {
                fault = nil
                status.error = nil
            }
        } else if !wasReady {
            nextRetry = 0
        }
        pump()
    }

    public func refreshPermissions() {
        guard !demo else { return }
        let granted = updatePermissions()
        if granted && (!connected || online != true) && !status.pressed { status.error = nil }
        nextRetry = 0
        pump()
    }

    public func requestPermissions() {
        guard !demo else { return }
        let backend = getBackend()
        backend.requestPermissions()
        _ = updatePermissions()
        nextRetry = 0
        pump()
    }

    public func pump() {
        if opened, let message = backend?.callbackError {
            fault = message
            backend?.callbackError = nil
        }
        if let message = fault {
            fault = nil
            stop()
            status.error = message
            nextRetry = now() + 2
        }
        guard status.enabled, connected, online == true else { stop(); return }
        if status.pressed && !status.active {
            stop()
            guard !status.pressed else { return }
        }
        // 演示不会创建事件源、访问硬件或报告真实桥接已激活。
        guard !demo else { status.active = false; return }
        guard now() >= nextRetry else { return }
        nextRetry = now() + 2
        do {
            guard updatePermissions() else {
                stop()
                let missing = status.missingPermissions.map(\.title).joined(separator: "、")
                status.error = "Olanzi 需要\(missing)权限。请在系统设置中允许 Olanzi；授权后会自动复查。"
                return
            }
            if !opened {
                try getBackend().open(onReport: { [weak self] reportID, data in
                    self?.receive(reportID: reportID, data: data)
                }, onLost: { [weak self] message in self?.lost(message) })
                opened = true
            }
            status.active = true
            status.error = nil
        } catch {
            stop()
            status.error = "Mac Fn 桥接不可用：\(error.localizedDescription)"
        }
    }

    public func close() {
        connected = false
        online = nil
        // worker 退出后不再 pump，为瞬时事件分配失败提供有界的最终重试。
        for _ in 0..<3 {
            stop()
            if !status.pressed { break }
        }
        if status.pressed, let error = status.error {
            fputs("Olanzi: \(error)\n", stderr)
        }
    }

    private func getBackend() -> any FnBackend {
        if let backend { return backend }
        let backend = NativeFnBackend()
        self.backend = backend
        return backend
    }

    private func updatePermissions() -> Bool {
        let permissions = getBackend().permissions()
        status.inputPermission = permissions.input
        status.accessibilityPermission = permissions.accessibility
        return permissions.input == true && permissions.accessibility
    }

    private func receive(reportID: Int, data: [UInt8]) {
        guard status.active, let pressed = FnReport.decode(reportID: reportID, data: data),
              pressed != status.pressed else { return }
        if pressed {
            // 先保留可能已提交的按下状态；发送失败也必须尝试配对释放。
            status.pressed = true
            do {
                guard let backend else { throw FnFailure(message: "Fn 事件源不存在。") }
                try backend.postFn(pressed: true)
                status.events += 1
            } catch {
                lost("Fn 报文处理失败：\(error.localizedDescription)")
            }
        } else {
            release()
        }
    }

    private func lost(_ message: String) {
        status.active = false
        status.error = message
        fault = message
        release()
    }

    private func release() {
        guard status.pressed else { return }
        do {
            guard let backend else { throw FnFailure(message: "Fn 事件源不存在。") }
            try backend.postFn(pressed: false)
            status.pressed = false
            status.events += 1
        } catch {
            status.active = false
            status.error = "Fn 松开事件发送失败：\(error.localizedDescription)"
            fault = status.error
        }
    }

    private func stop() {
        status.active = false
        release()
        // 释放失败时保留事件源供下一次 pump 重试，不把失败伪装成已松开。
        guard !status.pressed, opened else { return }
        do { try backend?.close() }
        catch { status.error = error.localizedDescription }
        opened = false
    }
}
