import CoreGraphics
import Foundation
import OSLog

/// 只按真实事件中发生变化的侧键更新状态，不从其它位继承合成修饰键的反馈。
struct PhysicalModifierState {
    private var held = Set<Int64>()
    var pressed: Bool { held.contains(63) }
    var flags: CGEventFlags {
        held.reduce(into: CGEventFlags()) { result, key in
            if key == 63 { result.insert(.maskSecondaryFn) }
            else if let modifier = Self.modifiers[key] { result.formUnion(modifier.family); result.formUnion(modifier.side) }
        }
    }

    private static let modifiers: [Int64: (family: CGEventFlags, side: CGEventFlags)] = [
        59: (.maskControl, CGEventFlags(rawValue: 0x0001)),
        62: (.maskControl, CGEventFlags(rawValue: 0x2000)),
        56: (.maskShift, CGEventFlags(rawValue: 0x0002)),
        60: (.maskShift, CGEventFlags(rawValue: 0x0004)),
        58: (.maskAlternate, CGEventFlags(rawValue: 0x0020)),
        61: (.maskAlternate, CGEventFlags(rawValue: 0x0040)),
        55: (.maskCommand, CGEventFlags(rawValue: 0x0008)),
        54: (.maskCommand, CGEventFlags(rawValue: 0x0010))
    ]
    static let managedMask: CGEventFlags = modifiers.values.reduce(into: CGEventFlags.maskSecondaryFn) {
        $0.formUnion($1.family); $0.formUnion($1.side)
    }
    static func isModifier(_ keyCode: Int64) -> Bool { keyCode == 63 || modifiers[keyCode] != nil }

    init(pressed: Bool = false) { if pressed { held.insert(63) } }

    mutating func resetAfterInterruption() { held.removeAll() }

    /// 失活时清除可能漏掉松开事件的缓存；不能让旧 true 永久污染后续动作。
    @discardableResult
    mutating func receive(type: CGEventType, sourcePID: Int64,
                          keyCode: Int64, flags: CGEventFlags) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            resetAfterInterruption()
            return true
        }
        guard type == .flagsChanged, sourcePID == 0, Self.isModifier(keyCode) else { return false }
        let mask = keyCode == 63 ? CGEventFlags.maskSecondaryFn : Self.modifiers[keyCode]!.side
        if flags.contains(mask) { held.insert(keyCode) }
        else { held.remove(keyCode) }
        return false
    }
}

// 兼容旧的纯 Fn 状态测试；生产逻辑已统一跟踪全部真实修饰键。
typealias PhysicalFnState = PhysicalModifierState

private struct PhysicalFnMonitorError: LocalizedError {
    let detail: String
    var errorDescription: String? { "无法监听真实 Fn 状态：" + detail }
}

/// 仅由设备工作线程使用；首次读取必须先于本 App 的第一条合成事件。
final class PhysicalFnMonitor {
    private let log = Logger(subsystem: "com.mrcroxx.olanzi", category: "physical-fn")
    private var state = PhysicalModifierState()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?

    deinit {
        if let source, let runLoop {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }
        if let source { CFRunLoopSourceInvalidate(source) }
        if let tap { CFMachPortInvalidate(tap) }
    }

    func isPressed() throws -> Bool {
        try modifierFlags().contains(.maskSecondaryFn)
    }

    func modifierFlags() throws -> CGEventFlags {
        if tap == nil { try start() }
        guard let tap, CFMachPortIsValid(tap) else {
            throw PhysicalFnMonitorError(detail: "监听端口已失效。")
        }
        if !CGEvent.tapIsEnabled(tap: tap) {
            state.resetAfterInterruption()
            log.warning("修饰键监听中断，已清除缓存并重新启用。")
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        guard CGEvent.tapIsEnabled(tap: tap) else {
            throw PhysicalFnMonitorError(detail: "监听已暂停，请检查输入监控权限。")
        }
        return state.flags
    }

    private func start() throws {
        let mask = CGEventMask(1) << CGEventType.flagsChanged.rawValue
        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<PhysicalFnMonitor>.fromOpaque(context).takeUnretainedValue()
                monitor.receive(type: type, event: event)
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            throw PhysicalFnMonitorError(detail: "不能创建修饰键监听，请检查输入监控权限。")
        }
        guard CFMachPortIsValid(newTap), CGEvent.tapIsEnabled(tap: newTap),
              let newSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0),
              let currentLoop = CFRunLoopGetCurrent() else {
            CFMachPortInvalidate(newTap)
            throw PhysicalFnMonitorError(detail: "不能启动修饰键监听。")
        }
        // 旧进程留下的合成修饰键也会污染初始状态；只信任本次监听到的真实侧键变化。
        tap = newTap
        source = newSource
        runLoop = currentLoop
        CFRunLoopAddSource(currentLoop, newSource, .commonModes)
    }

    private func receive(type: CGEventType, event: CGEvent) {
        let sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        // 仅诊断修饰键的来源与状态，不读取普通按键内容。
        if type == .flagsChanged, keyCode == 63 {
            log.debug("Fn 来源 PID=\(sourcePID, privacy: .public)，按住=\(event.flags.contains(.maskSecondaryFn))")
        } else if type == .flagsChanged, PhysicalModifierState.isModifier(keyCode) {
            log.debug("修饰键来源 PID=\(sourcePID, privacy: .public)，键码=\(keyCode, privacy: .public)，标志=\(event.flags.rawValue, privacy: .public)")
        }
        let shouldEnable = state.receive(
            type: type, sourcePID: sourcePID, keyCode: keyCode, flags: event.flags)
        if shouldEnable, let tap {
            log.warning("修饰键监听中断，已清除缓存并重新启用。")
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }
}
