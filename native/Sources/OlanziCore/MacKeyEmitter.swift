import CoreGraphics
import Foundation
import OSLog

public enum MacKeyEmitterError: LocalizedError, Equatable {
    case unsupportedType(UInt8)
    case unsupportedCode(UInt8)
    case tooManyEntries
    case sourceUnavailable
    case eventUnavailable(UInt8)

    public var errorDescription: String? {
        switch self {
        case .unsupportedType(let type):
            return String(format: "当前不支持类型 0x%02X 的设备键位，只支持普通键盘类型 0x02。", type)
        case .unsupportedCode(let code):
            return String(format: "键码 0x%02X 没有可用的 macOS 虚拟键映射（F21–F24 暂不支持）。", code)
        case .tooManyEntries: return "单个控件的组合键不能超过 24 项。"
        case .sourceUnavailable: return "无法创建 macOS 键盘事件源。"
        case .eventUnavailable(let code): return String(format: "无法创建键码 0x%02X 的 macOS 键盘事件。", code)
        }
    }
}

/// 由设备工作线程使用；控件的按住状态、重复报文和跨控件引用计数由调用者管理。
public final class MacKeyEmitter {
    private static let logger = Logger(subsystem: "com.mrcroxx.olanzi", category: "emitter")
    private let hardwareFlags: () -> CGEventFlags
    private let physicalFn: (() throws -> Bool)?
    private let physicalModifiers: (() throws -> CGEventFlags)?
    private let sourceFactory: () -> CGEventSource?
    private let eventFactory: (CGEventSource, CGKeyCode, Bool) -> CGEvent?
    private let post: (CGEvent) throws -> Void
    private var source: CGEventSource?
    private var lastHardwareCaps: Bool?
    private var capsLock: Bool?

    public init() {
        hardwareFlags = { CGEventSource.flagsState(.hidSystemState) }
        let fnMonitor = PhysicalFnMonitor()
        physicalFn = nil
        physicalModifiers = { try fnMonitor.modifierFlags() }
        sourceFactory = { CGEventSource(stateID: .privateState) }
        eventFactory = { CGEvent(keyboardEventSource: $0, virtualKey: $1, keyDown: $2) }
        post = { $0.post(tap: .cghidEventTap) }
    }

    // 测试只替换事件发布与硬件旗标，不向桌面发键，不读取其他键盘内容。
    init(hardwareFlags: @escaping () -> CGEventFlags,
         physicalFn: (() throws -> Bool)? = nil,
         physicalModifiers: (() throws -> CGEventFlags)? = nil,
         sourceFactory: @escaping () -> CGEventSource? = { CGEventSource(stateID: .privateState) },
         eventFactory: @escaping (CGEventSource, CGKeyCode, Bool) -> CGEvent? = {
             CGEvent(keyboardEventSource: $0, virtualKey: $1, keyDown: $2)
         }, post: @escaping (CGEvent) throws -> Void) {
        self.hardwareFlags = hardwareFlags
        self.physicalFn = physicalFn
        self.physicalModifiers = physicalModifiers
        self.sourceFactory = sourceFactory
        self.eventFactory = eventFactory
        self.post = post
    }

    /// 在桥接就绪时提前监听，不能等用户按下 AU05 后才开始记录真实修饰键。
    func prepareFnMonitoring() throws {
        if let physicalModifiers { _ = try physicalModifiers() }
        else if let physicalFn { _ = try physicalFn() }
    }

    /// heldModifiers 必须包含本次以外仍按住的控件；up 时也不能丢弃其他控件的修饰键。
    /// 所有类型、键码和事件分配先整体校验，再开始提交，避免后半配置无效留下半组按下。
    @discardableResult
    public func emit(entries: [KeyEntry], pressed: Bool, heldModifiers: CGEventFlags = []) throws -> Int {
        let codes = try Self.validatedCodes(entries)
        guard !codes.isEmpty else { return 0 }
        let modifiers = codes.filter { !Self.modifierFlags(forCode: $0).isEmpty }
        let keys = codes.filter { Self.modifierFlags(forCode: $0).isEmpty }
        let ordered = pressed ? modifiers + keys : Array((modifiers + keys).reversed())
        if source == nil { source = sourceFactory() }
        guard let source else { throw MacKeyEmitterError.sourceUnavailable }

        // HID 汇总状态也包含本 App 合成的 Cmd/Shift/Option/Control/Fn 及左右侧位。
        // 真实修饰键由独立监听重建；本 App 的按住状态只由 remaining/heldModifiers 合并。
        var physical = hardwareFlags()
        if let physicalModifiers {
            let modifiers = try physicalModifiers()
            physical.subtract(PhysicalModifierState.managedMask)
            physical.formUnion(modifiers.intersection(PhysicalModifierState.managedMask))
        } else if let physicalFn {
            let pressed = try physicalFn()
            physical.remove(.maskSecondaryFn)
            if pressed { physical.insert(.maskSecondaryFn) }
        }
        let hardwareCaps = physical.contains(.maskAlphaShift)
        if lastHardwareCaps == nil || lastHardwareCaps != hardwareCaps { capsLock = hardwareCaps }
        lastHardwareCaps = hardwareCaps
        var plannedCaps = capsLock ?? hardwareCaps
        var remaining = pressed ? [] : modifiers
        var events: [(event: CGEvent, caps: Bool)] = []
        for code in ordered {
            let modifier = Self.modifierFlags(forCode: code)
            if !modifier.isEmpty {
                if pressed { remaining.append(code) }
                else { remaining.removeAll { $0 == code } }
            }
            // Caps Lock 是锁定状态：按下切换、松开保持，不能实现成仅按住时大写。
            if code == 0x39 && pressed { plannedCaps.toggle() }
            var flags = physical.union(heldModifiers).union(Self.flags(forCodes: remaining))
            if plannedCaps { flags.insert(.maskAlphaShift) }
            else { flags.remove(.maskAlphaShift) }
            guard let virtualKey = Self.virtualKey(for: code),
                  let event = eventFactory(source, virtualKey, pressed) else {
                throw MacKeyEmitterError.eventUnavailable(code)
            }
            // F1–F20 的按下和松开自带 function 类别位，与物理 Fn 是否按住无关。
            // 按虚拟键分类，让 Print Screen 等映射到 F13–F15 的别名保持一致；
            // 不加入 modifiers/remaining，避免把功能键变成持续按住的 Fn。
            if Self.functionVirtualKeys.contains(virtualKey) { flags.insert(.maskSecondaryFn) }
            event.type = (!modifier.isEmpty || code == 0x39) ? .flagsChanged : pressed ? .keyDown : .keyUp
            event.flags = flags
            event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
            events.append((event, plannedCaps))
        }
        for item in events {
            try post(item.event)
            capsLock = item.caps
            // 仅记录本 App 为 AU05 生成的事件元数据，不采集其他键盘的按键内容。
            Self.logger.debug("type=\(item.event.type.rawValue, privacy: .public) keycode=\(item.event.getIntegerValueField(.keyboardEventKeycode), privacy: .public) flags=\(item.event.flags.rawValue, privacy: .public)")
        }
        return events.count
    }

    public static func validate(entries: [KeyEntry]) throws { _ = try validatedCodes(entries) }

    private static let functionVirtualKeys: Set<CGKeyCode> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
        105, 107, 113, 106, 64, 79, 80, 90
    ]

    /// Caps Lock 不属于持续按住的修饰键；其锁定状态由系统旗标和发射器共同维护。
    public static func modifierFlags(for entries: [KeyEntry]) -> CGEventFlags {
        flags(forCodes: entries.filter { $0.type == 2 }.map(\.code))
    }

    private static func flags(forCodes codes: [UInt8]) -> CGEventFlags {
        codes.reduce(into: CGEventFlags()) { $0.formUnion(modifierFlags(forCode: $1)) }
    }

    private static func modifierFlags(forCode code: UInt8) -> CGEventFlags {
        // 低位使用 IOLLEvent.h 的左右键标记，保留左右修饰键与组合语义。
        switch code {
        case 1: return .maskSecondaryFn
        case 0xE0: return [.maskControl, CGEventFlags(rawValue: 0x0001)]
        case 0xE1: return [.maskShift, CGEventFlags(rawValue: 0x0002)]
        case 0xE2: return [.maskAlternate, CGEventFlags(rawValue: 0x0020)]
        case 0xE3: return [.maskCommand, CGEventFlags(rawValue: 0x0008)]
        case 0xE4: return [.maskControl, CGEventFlags(rawValue: 0x2000)]
        case 0xE5: return [.maskShift, CGEventFlags(rawValue: 0x0004)]
        case 0xE6: return [.maskAlternate, CGEventFlags(rawValue: 0x0040)]
        case 0xE7: return [.maskCommand, CGEventFlags(rawValue: 0x0010)]
        default: return []
        }
    }

    private static func validatedCodes(_ entries: [KeyEntry]) throws -> [UInt8] {
        guard entries.count <= 24 else { throw MacKeyEmitterError.tooManyEntries }
        var seen = Set<UInt8>()
        var codes: [UInt8] = []
        for entry in entries {
            guard entry.type == 2 else { throw MacKeyEmitterError.unsupportedType(entry.type) }
            if entry.code == 0 { continue }
            guard virtualKey(for: entry.code) != nil else { throw MacKeyEmitterError.unsupportedCode(entry.code) }
            if seen.insert(entry.code).inserted { codes.append(entry.code) }
        }
        return codes
    }

    /// HID usage → macOS 虚拟键；遵循 Apple USB2ADB 映射，未定义的 F21–F24 明确拒绝。
    public static func virtualKey(for code: UInt8) -> CGKeyCode? {
        switch code {
        case 1: return 0x3F
        case 0x04...0x1D:
            let letters: [CGKeyCode] = [0x00,0x0B,0x08,0x02,0x0E,0x03,0x05,0x04,0x22,0x26,0x28,0x25,0x2E,
                                       0x2D,0x1F,0x23,0x0C,0x0F,0x01,0x11,0x20,0x09,0x0D,0x07,0x10,0x06]
            return letters[Int(code - 0x04)]
        case 0x1E...0x27: return [0x12,0x13,0x14,0x15,0x17,0x16,0x1A,0x1C,0x19,0x1D][Int(code - 0x1E)]
        case 0x28...0x39:
            return [0x24,0x35,0x33,0x30,0x31,0x1B,0x18,0x21,0x1E,0x2A,0x2A,0x29,0x27,0x32,0x2B,0x2F,0x2C,0x39][Int(code - 0x28)]
        case 0x3A...0x45: return [0x7A,0x78,0x63,0x76,0x60,0x61,0x62,0x64,0x65,0x6D,0x67,0x6F][Int(code - 0x3A)]
        case 0x46...0x52: return [0x69,0x6B,0x71,0x72,0x73,0x74,0x75,0x77,0x79,0x7C,0x7B,0x7D,0x7E][Int(code - 0x46)]
        case 0x53...0x63: return [0x47,0x4B,0x43,0x4E,0x45,0x4C,0x53,0x54,0x55,0x56,0x57,0x58,0x59,0x5B,0x5C,0x52,0x41][Int(code - 0x53)]
        case 0x64: return 0x0A
        case 0x65: return 0x6E
        case 0x68...0x6F: return [0x69,0x6B,0x71,0x6A,0x40,0x4F,0x50,0x5A][Int(code - 0x68)]
        case 0xE0...0xE7: return [0x3B,0x38,0x3A,0x37,0x3E,0x3C,0x3D,0x36][Int(code - 0xE0)]
        default: return nil
        }
    }
}
