import Foundation

public enum HostKeymapError: LocalizedError, Equatable {
    case unsupportedVersion
    case invalidControls
    case invalidTiming
    case invalidLongPressTapCount
    case unsupportedGesture
    case invalidName
    case tooLarge

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion: return "配置版本不受支持。"
        case .invalidControls: return "配置必须包含且仅包含六个控件，每个控件只能出现一次。"
        case .invalidTiming: return "双击间隔应为 0.15–0.5 秒，长按阈值应为 0.3–2 秒，且长按阈值必须大于双击间隔。"
        case .invalidLongPressTapCount: return "长按连按次数应为 2–20 次。"
        case .unsupportedGesture: return "旋钮转动不支持双击或长按动作。"
        case .invalidName: return "配置名称不能为空，且不能超过 80 个字符。"
        case .tooLarge: return "配置文件不能超过 32 KiB。"
        }
    }
}

public enum LongPressBehavior: String, Codable, CaseIterable, Identifiable, Sendable {
    case hold, tap, burst
    public var id: Self { self }
}

public struct ControlActionMap: Codable, Equatable, Sendable {
    public var index: Int
    public var press: [KeyEntry]
    public var doublePress: [KeyEntry]?
    public var longPress: [KeyEntry]?
    public var pressAction: HostAction?
    public var doublePressAction: HostAction?
    public var longPressAction: HostAction?
    public var effectivePress: HostAction { pressAction ?? .keyboard(press) }
    public var effectiveDoublePress: HostAction? { doublePressAction ?? doublePress.map(HostAction.keyboard) }
    public var effectiveLongPress: HostAction? { longPressAction ?? longPress.map(HostAction.keyboard) }
    public var longPressBehavior: LongPressBehavior
    public var longPressTapCount: Int

    public init(index: Int, press: [KeyEntry], doublePress: [KeyEntry]? = nil,
                longPress: [KeyEntry]? = nil, longPressBehavior: LongPressBehavior = .hold, longPressTapCount: Int = 2,
                pressAction: HostAction? = nil, doublePressAction: HostAction? = nil, longPressAction: HostAction? = nil) {
        self.index = index
        self.press = press
        self.doublePress = doublePress
        self.longPress = longPress
        self.pressAction = pressAction
        self.doublePressAction = doublePressAction
        self.longPressAction = longPressAction
        self.longPressBehavior = longPressBehavior
        self.longPressTapCount = longPressTapCount
    }

    private enum CodingKeys: String, CodingKey {
        case index, press, doublePress, longPress, longPressBehavior, longPressTapCount
        case pressAction, doublePressAction, longPressAction
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        index = try values.decode(Int.self, forKey: .index)
        press = try values.decode([KeyEntry].self, forKey: .press)
        doublePress = try values.decodeIfPresent([KeyEntry].self, forKey: .doublePress)
        longPress = try values.decodeIfPresent([KeyEntry].self, forKey: .longPress)
        pressAction = try values.decodeIfPresent(HostAction.self, forKey: .pressAction)
        doublePressAction = try values.decodeIfPresent(HostAction.self, forKey: .doublePressAction)
        longPressAction = try values.decodeIfPresent(HostAction.self, forKey: .longPressAction)
        // 旧配置没有该字段，其长按动作一直保持到物理松开。
        longPressBehavior = try values.decodeIfPresent(LongPressBehavior.self, forKey: .longPressBehavior) ?? .hold
        longPressTapCount = try values.decodeIfPresent(Int.self, forKey: .longPressTapCount) ?? 2
    }
}

public struct HostKeymap: Codable, Equatable, Sendable {
    public static let maximumJSONBytes = 32 * 1024
    /// 首次编辑使用独立本机草稿，不依赖设备回读；由用户显式保存后才激活。
    public static let defaultKeymap = HostKeymap(controls: DeviceProtocol.defaultCodes.enumerated().map {
        ControlActionMap(index: $0.offset, press: [KeyEntry(code: $0.element)])
    })
    public var version: Int = 1
    public var controls: [ControlActionMap] {
        didSet {
            normalizeVersion()
        }
    }
    public var actionLibrary: [NamedHostAction] {
        didSet { normalizeVersion() }
    }
    private var requiredVersion: Int {
        if !actionLibrary.isEmpty || controls.contains(where: { control in
            [control.pressAction, control.doublePressAction, control.longPressAction].contains { action in
                if case .library = action { return true }
                return false
            }
        }) { return 3 }
        return hasExtendedActions ? 2 : 1
    }
    private mutating func normalizeVersion() {
        if (1...3).contains(version) { version = requiredVersion }
    }
    private var hasExtendedActions: Bool {
        controls.contains { $0.pressAction != nil || $0.doublePressAction != nil || $0.longPressAction != nil }
    }
    public var doublePressWindow: TimeInterval
    public var longPressThreshold: TimeInterval

    public init(controls: [ControlActionMap], doublePressWindow: TimeInterval = 0.25,
                longPressThreshold: TimeInterval = 0.5, actionLibrary: [NamedHostAction] = []) {
        self.controls = controls
        self.actionLibrary = actionLibrary
        self.doublePressWindow = doublePressWindow
        self.longPressThreshold = longPressThreshold
        normalizeVersion()
    }

    public static func fromDeviceBindings(_ bindings: [KeyBinding]) throws -> HostKeymap {
        let map = HostKeymap(controls: bindings.sorted { $0.index < $1.index }.map {
            ControlActionMap(index: $0.index, press: $0.entries)
        })
        try map.validate()
        return map
    }

    public func validate() throws {
        guard (1...3).contains(version), version >= requiredVersion else {
            throw HostKeymapError.unsupportedVersion
        }
        guard controls.count == 6, Set(controls.map(\.index)) == Set(0..<6) else {
            throw HostKeymapError.invalidControls
        }
        guard doublePressWindow.isFinite, longPressThreshold.isFinite,
              (0.15...0.5).contains(doublePressWindow), (0.3...2).contains(longPressThreshold),
              longPressThreshold > doublePressWindow else { throw HostKeymapError.invalidTiming }
        guard Set(actionLibrary.map(\.id)).count == actionLibrary.count else {
            throw HostActionError.duplicateLibraryEntry
        }
        var slots = Set<String>()
        for item in actionLibrary {
            try item.validate()
            guard slots.insert("\(item.isMacro)-\(item.slot)").inserted else {
                throw HostActionError.duplicateLibraryEntry
            }
        }
        for control in controls {
            guard (2...20).contains(control.longPressTapCount) else { throw HostKeymapError.invalidLongPressTapCount }
            guard control.index < 4 || (control.effectiveDoublePress == nil && control.effectiveLongPress == nil && control.longPressBehavior == .hold) else {
                throw HostKeymapError.unsupportedGesture
            }
            for action in [control.effectivePress, control.effectiveDoublePress, control.effectiveLongPress].compactMap({ $0 }) {
                guard let resolved = resolve(action) else { throw HostActionError.missingLibraryAction }
                try resolved.validate()
            }
            try MacKeyEmitter.validate(entries: control.press)
            if let action = control.doublePress { try MacKeyEmitter.validate(entries: action) }
            if let action = control.longPress { try MacKeyEmitter.validate(entries: action) }
        }
    }

    /// 只解析一层引用；无效目标或嵌套引用返回 nil，由 validate 给出明确错误。
    public func resolve(_ action: HostAction?) -> HostAction? {
        guard let action else { return nil }
        guard case .library(let id) = action else { return action }
        guard let item = actionLibrary.first(where: { $0.id == id }) else { return nil }
        switch item.action {
        case .application, .macro: return item.action
        case .keyboard, .library: return nil
        }
    }

    /// 导入入口先限制原始数据大小，再交给 Codable 检查字段与动作。
    public static func decode(data: Data) throws -> HostKeymap {
        guard data.count <= maximumJSONBytes else { throw HostKeymapError.tooLarge }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    private enum CodingKeys: String, CodingKey {
        case version, controls, doublePressWindow, longPressThreshold, actionLibrary
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(controls, forKey: .controls)
        if !actionLibrary.isEmpty { try values.encode(actionLibrary, forKey: .actionLibrary) }
        try values.encode(doublePressWindow, forKey: .doublePressWindow)
        try values.encode(longPressThreshold, forKey: .longPressThreshold)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        controls = try values.decode([ControlActionMap].self, forKey: .controls)
        actionLibrary = try values.decodeIfPresent([NamedHostAction].self, forKey: .actionLibrary) ?? []
        doublePressWindow = try values.decode(TimeInterval.self, forKey: .doublePressWindow)
        longPressThreshold = try values.decode(TimeInterval.self, forKey: .longPressThreshold)
        try validate()
        normalizeVersion()
    }
}
