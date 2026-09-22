import CoreGraphics
import Foundation

public enum ShortcutCaptureError: LocalizedError, Equatable {
    case modifierOnly
    case capsLockUnsupported
    case unsupportedKey(UInt16)

    public var errorDescription: String? {
        switch self {
        case .modifierOnly:
            return "请同时按下一个普通按键；Fn 和单独修饰键请从键盘列表中选择。"
        case .unsupportedKey:
            return "此按键暂不支持录制，请从键盘列表中选择。"
        case .capsLockUnsupported:
            return "Caps Lock 暂不支持录制，请选择其他按键。"
        }
    }
}

/// 一次重叠按住区间形成一个组合；全部松开后封存，不把后续文本串成宏。
public struct ShortcutRecordingSession {
    public private(set) var isComplete = false
    /// 只暴露本次录制已观测到且尚未松开的键，供调用者补查漏失的松开事件。
    /// Fn 必须先有明确的 keyCode 63 事件，不能从普通键的 function 标记推断。
    public var heldKeyCodes: Set<UInt16> {
        fnHeld ? heldKeys.union([63]) : heldKeys
    }
    public var candidate: [KeyEntry] {
        Self.modifierOrder.filter { recordedModifiers.contains($0) }.map { KeyEntry(code: $0) }
            + primaryOrder.map { KeyEntry(code: $0) }
    }

    private static let modifierOrder: [UInt8] = [0xE0, 0xE2, 0xE1, 0xE3, 1]
    private var recordedModifiers = Set<UInt8>()
    private var heldModifiers = Set<UInt8>()
    private var heldKeys = Set<UInt16>()
    private var primaryOrder: [UInt8] = []
    private var fnHeld = false

    public init() {}

    public mutating func receiveKeyDown(keyCode: UInt16, flags: UInt64, isRepeat: Bool = false) throws {
        guard !isComplete, !isRepeat, !heldKeys.contains(keyCode) else { return }
        if keyCode == 57 { throw ShortcutCaptureError.capsLockUnsupported }
        let primary = try ShortcutCapture.entries(keyCode: keyCode, flags: 0)[0].code
        var next = self
        next.updateModifiers(flags)
        next.heldKeys.insert(keyCode)
        if !next.primaryOrder.contains(primary) { next.primaryOrder.append(primary) }
        try accept(next)
    }

    public mutating func receiveKeyUp(keyCode: UInt16, flags: UInt64) throws {
        // 开始监听前已经按住的键可能只有 up，不能由它凭空创建录制内容。
        guard !isComplete, heldKeys.contains(keyCode) else { return }
        var next = self
        next.heldKeys.remove(keyCode)
        next.updateModifiers(flags)
        try accept(next)
    }

    public mutating func receiveFlagsChanged(keyCode: UInt16, flags: UInt64) throws {
        guard !isComplete else { return }
        if keyCode == 57 { throw ShortcutCaptureError.capsLockUnsupported }
        var next = self
        // 聚合或合成的 flagsChanged 可能没有标准修饰键码；四种修饰状态直接来自 flags。
        // 仅明确的 Fn 键码更新 Fn，不把其它键码推断成普通键或拒绝整个录制。
        next.updateModifiers(flags)
        if keyCode == 63 {
            next.fnHeld = flags & CGEventFlags.maskSecondaryFn.rawValue != 0
            if next.fnHeld { next.recordedModifiers.insert(1) }
        }
        try accept(next)
    }

    /// 只补记已观测按键的松开，不从轮询状态录入新键或修饰键。
    /// 调用者应先排空近期事件，并留出短暂宽限，避免物理状态领先待处理事件。
    public mutating func reconcileReleasedKeys(pressedKeyCodes: Set<UInt16>, flags: UInt64) throws {
        guard !isComplete else { return }
        var next = self
        next.heldKeys.formIntersection(pressedKeyCodes)
        next.heldModifiers.formIntersection(Self.modifiers(in: flags))
        if next.fnHeld, !pressedKeyCodes.contains(63) { next.fnHeld = false }
        try accept(next)
    }

    private mutating func updateModifiers(_ flags: UInt64) {
        heldModifiers = Self.modifiers(in: flags)
        recordedModifiers.formUnion(heldModifiers)
    }

    private static func modifiers(in flags: UInt64) -> Set<UInt8> {
        let modifiers: [(CGEventFlags, UInt8)] = [
            (.maskControl, 0xE0), (.maskAlternate, 0xE2), (.maskShift, 0xE1), (.maskCommand, 0xE3)
        ]
        return Set(modifiers.compactMap { flag, usage in flags & flag.rawValue != 0 ? usage : nil })
    }

    private mutating func accept(_ next: Self) throws {
        // 先整体校验再提交；不支持的键或第 25 项不会污染此前的有效候选值。
        try MacKeyEmitter.validate(entries: next.candidate)
        self = next
        if !candidate.isEmpty, heldKeys.isEmpty, heldModifiers.isEmpty, !fnHeld { isComplete = true }
    }
}

/// 只解析调用者提供的单次键盘事件，不监听键盘、不发送事件，也不更改配置。
public enum ShortcutCapture {
    /// 规范顺序为 Control、Option、Shift、Command、主键；左右修饰键统一保存为左侧。
    /// function 位也用于 F 键和导航键的类别标记，因此不能将其直接录成物理 Fn。
    public static func entries(keyCode: UInt16, flags: UInt64) throws -> [KeyEntry] {
        guard !modifierVirtualKeys.contains(keyCode) else { throw ShortcutCaptureError.modifierOnly }
        guard let primary = primaryUsage[keyCode] else { throw ShortcutCaptureError.unsupportedKey(keyCode) }
        let modifiers: [(CGEventFlags, UInt8)] = [
            (.maskControl, 0xE0), (.maskAlternate, 0xE2), (.maskShift, 0xE1), (.maskCommand, 0xE3)
        ]
        var entries = modifiers.compactMap { flag, usage in
            flags & flag.rawValue != 0 ? KeyEntry(code: usage) : nil
        }
        entries.append(KeyEntry(code: primary))
        try MacKeyEmitter.validate(entries: entries)
        return entries
    }

    // Caps Lock 和 Fn 由已有选择器分配；仅按这些键不构成录制的快捷键。
    private static let modifierVirtualKeys: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    private static let primaryUsage: [UInt16: UInt8] = {
        var result: [UInt16: UInt8] = [:]
        // 先录 F 系列，保证同虚拟键的 Print Screen / Scroll Lock / Pause 不抢占 F13–F15。
        let candidates = Array(0x3A...0x45) + Array(0x68...0x6F) + Array(0x04...0x65)
        for candidate in candidates {
            let usage = UInt8(candidate)
            guard let key = MacKeyEmitter.virtualKey(for: usage),
                  !modifierVirtualKeys.contains(key), result[key] == nil else { continue }
            // 其余同码按 usage 顺序取首项，例如反斜杠 0x31 优先于 Non-US # 0x32。
            result[key] = usage
        }
        return result
    }()
}
