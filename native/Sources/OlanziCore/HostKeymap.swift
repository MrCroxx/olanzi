import Foundation

public enum HostKeymapError: LocalizedError, Equatable {
    case unsupportedVersion
    case invalidControls
    case invalidLayer
    case invalidLayerAction
    case invalidTiming
    case invalidLongPressTapCount
    case invalidPressTapCount
    case invalidDoublePressBehavior
    case invalidInheritedGestures
    case unsupportedGesture
    case invalidName
    case tooLarge

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion: return "配置版本不受支持。"
        case .invalidControls: return "配置必须包含且仅包含六个控件，每个控件只能出现一次。"
        case .invalidLayer: return "Layer 编号必须为 1–3 且不能重复，每层控件索引必须唯一且在 0–5 之间。"
        case .invalidLayerAction: return "切层动作仅支持按键或旋钮按下的单击和长按，目标层必须为 1–3；单击切层时不能同时设置双击。"
        case .invalidTiming: return "双击间隔应为 0.15–0.5 秒，长按阈值应为 0.3–2 秒，且长按阈值必须大于双击间隔。"
        case .invalidInheritedGestures: return "基础层不能继承其他层的动作。"
        case .invalidPressTapCount: return "单击和双击的连按次数应为 2–20 次。"
        case .invalidDoublePressBehavior: return "双击动作不能保持按住，请选择按一次或连按。"
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

public enum ControlGesture: String, Codable, CaseIterable, Sendable {
    case press, doublePress, longPress
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
    public var pressBehavior: LongPressBehavior
    public var pressTapCount: Int
    public var doublePressBehavior: LongPressBehavior
    public var doublePressTapCount: Int
    public var longPressBehavior: LongPressBehavior
    public var longPressTapCount: Int
    public var inheritedGestures: Set<ControlGesture>

    public init(index: Int, press: [KeyEntry], doublePress: [KeyEntry]? = nil,
                longPress: [KeyEntry]? = nil, longPressBehavior: LongPressBehavior = .hold, longPressTapCount: Int = 2,
                pressAction: HostAction? = nil, doublePressAction: HostAction? = nil, longPressAction: HostAction? = nil,
                pressBehavior: LongPressBehavior = .hold, pressTapCount: Int = 2,
                doublePressBehavior: LongPressBehavior = .tap, doublePressTapCount: Int = 2,
                inheritedGestures: Set<ControlGesture> = []) {
        self.index = index
        self.press = press
        self.doublePress = doublePress
        self.longPress = longPress
        self.pressAction = pressAction
        self.doublePressAction = doublePressAction
        self.longPressAction = longPressAction
        self.pressBehavior = pressBehavior
        self.pressTapCount = pressTapCount
        self.doublePressBehavior = doublePressBehavior
        self.doublePressTapCount = doublePressTapCount
        self.longPressBehavior = longPressBehavior
        self.longPressTapCount = longPressTapCount
        self.inheritedGestures = inheritedGestures
    }

    private enum CodingKeys: String, CodingKey {
        case index, press, doublePress, longPress, longPressBehavior, longPressTapCount
        case pressAction, doublePressAction, longPressAction
        case pressBehavior, pressTapCount, doublePressBehavior, doublePressTapCount, inheritedGestures
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
        pressBehavior = try values.decodeIfPresent(LongPressBehavior.self, forKey: .pressBehavior) ?? .hold
        pressTapCount = try values.decodeIfPresent(Int.self, forKey: .pressTapCount) ?? 2
        doublePressBehavior = try values.decodeIfPresent(LongPressBehavior.self, forKey: .doublePressBehavior) ?? .tap
        doublePressTapCount = try values.decodeIfPresent(Int.self, forKey: .doublePressTapCount) ?? 2
        inheritedGestures = try values.decodeIfPresent(Set<ControlGesture>.self, forKey: .inheritedGestures) ?? []
        // 旧配置没有该字段，其长按动作一直保持到物理松开。
        longPressBehavior = try values.decodeIfPresent(LongPressBehavior.self, forKey: .longPressBehavior) ?? .hold
        longPressTapCount = try values.decodeIfPresent(Int.self, forKey: .longPressTapCount) ?? 2
    }
}

/// 稀疏层：未配置的控件继续查找较低的活动层，最后回到基础层。
public struct HostLayer: Codable, Equatable, Identifiable, Sendable {
    public var id: Int
    public var controls: [ControlActionMap]

    public init(id: Int, controls: [ControlActionMap] = []) {
        self.id = id
        self.controls = controls
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
    public var layers: [HostLayer] {
        didSet { normalizeVersion() }
    }
    private var allControls: [ControlActionMap] { controls + layers.flatMap(\.controls) }
    private var requiredVersion: Int {
        if allControls.contains(where: { $0.pressBehavior != .hold || $0.pressTapCount != 2
            || $0.doublePressBehavior != .tap || $0.doublePressTapCount != 2 || !$0.inheritedGestures.isEmpty }) { return 5 }
        if !layers.isEmpty || allControls.contains(where: { control in
            [control.pressAction, control.doublePressAction, control.longPressAction].contains { action in
                if case .momentaryLayer = action { return true }
                return false
            }
        }) { return 4 }
        if !actionLibrary.isEmpty || controls.contains(where: { control in
            [control.pressAction, control.doublePressAction, control.longPressAction].contains { action in
                if case .library = action { return true }
                return false
            }
        }) { return 3 }
        return hasExtendedActions ? 2 : 1
    }
    private mutating func normalizeVersion() {
        if (1...5).contains(version) { version = requiredVersion }
    }
    private var hasExtendedActions: Bool {
        controls.contains { $0.pressAction != nil || $0.doublePressAction != nil || $0.longPressAction != nil }
    }
    public var doublePressWindow: TimeInterval
    public var longPressThreshold: TimeInterval

    public init(controls: [ControlActionMap], doublePressWindow: TimeInterval = 0.25,
                longPressThreshold: TimeInterval = 0.5, actionLibrary: [NamedHostAction] = [], layers: [HostLayer] = []) {
        self.controls = controls
        self.actionLibrary = actionLibrary
        self.layers = layers
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
        guard (1...5).contains(version), version >= requiredVersion else {
            throw HostKeymapError.unsupportedVersion
        }
        guard controls.count == 6, Set(controls.map(\.index)) == Set(0..<6) else {
            throw HostKeymapError.invalidControls
        }
        guard controls.allSatisfy({ $0.inheritedGestures.isEmpty }) else { throw HostKeymapError.invalidInheritedGestures }
        guard Set(layers.map(\.id)).count == layers.count,
              layers.allSatisfy({ layer in
                  (1...3).contains(layer.id) && Set(layer.controls.map(\.index)).count == layer.controls.count
                      && layer.controls.allSatisfy { (0..<6).contains($0.index) }
              }) else { throw HostKeymapError.invalidLayer }
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
        for control in allControls {
            if case .momentaryLayer(let target) = control.effectivePress {
                guard control.index < 4, (1...3).contains(target) else {
                    throw HostKeymapError.invalidLayerAction
                }
            }
            if case .momentaryLayer = control.effectiveDoublePress { throw HostKeymapError.invalidLayerAction }
            if case .momentaryLayer(let target) = control.effectiveLongPress {
                guard control.index < 4, (1...3).contains(target) else {
                    throw HostKeymapError.invalidLayerAction
                }
            }
            guard (2...20).contains(control.pressTapCount), (2...20).contains(control.doublePressTapCount) else {
                throw HostKeymapError.invalidPressTapCount
            }
            guard control.doublePressBehavior != .hold else { throw HostKeymapError.invalidDoublePressBehavior }
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
        // 分别继承后可能拼出 MO + 双击；覆盖所有三个附加层的活动组合。
        for mask in 0..<8 {
            let active = (1...3).filter { mask & (1 << ($0 - 1)) != 0 }
            for index in 0..<4 {
                guard let control = resolvedControl(index: index, activeLayers: active) else { continue }
                if case .momentaryLayer = control.effectivePress, control.effectiveDoublePress != nil {
                    throw HostKeymapError.invalidLayerAction
                }
            }
        }
    }

    /// 只解析一层引用；无效目标或嵌套引用返回 nil，由 validate 给出明确错误。
    public func resolve(_ action: HostAction?) -> HostAction? {
        guard let action else { return nil }
        guard case .library(let id) = action else { return action }
        guard let item = actionLibrary.first(where: { $0.id == id }) else { return nil }
        switch item.action {
        case .application, .macro: return item.action
        case .keyboard, .library, .momentaryLayer: return nil
        }
    }

    /// 编辑时精确查找该层；缺失返回 nil，避免把继承动作误写成覆盖。
    public func control(index: Int, layer: Int) -> ControlActionMap? {
        if layer == 0 { return controls.first { $0.index == index } }
        return layers.first { $0.id == layer }?.controls.first { $0.index == index }
    }

    /// 从基础层向高层逐个叠加；动作与该手势的重复设置一起继承。
    public func resolvedControl(index: Int, activeLayers: [Int]) -> ControlActionMap? {
        guard var result = control(index: index, layer: 0) else { return nil }
        for layer in Set(activeLayers).filter({ (1...3).contains($0) }).sorted() {
            guard let overlay = control(index: index, layer: layer) else { continue }
            if !overlay.inheritedGestures.contains(.press) {
                result.press = overlay.press
                result.pressAction = overlay.pressAction
                result.pressBehavior = overlay.pressBehavior
                result.pressTapCount = overlay.pressTapCount
            }
            if !overlay.inheritedGestures.contains(.doublePress) {
                result.doublePress = overlay.doublePress
                result.doublePressAction = overlay.doublePressAction
                result.doublePressBehavior = overlay.doublePressBehavior
                result.doublePressTapCount = overlay.doublePressTapCount
            }
            if !overlay.inheritedGestures.contains(.longPress) {
                result.longPress = overlay.longPress
                result.longPressAction = overlay.longPressAction
                result.longPressBehavior = overlay.longPressBehavior
                result.longPressTapCount = overlay.longPressTapCount
            }
        }
        result.inheritedGestures = []
        return result
    }

    /// 导入入口先限制原始数据大小，再交给 Codable 检查字段与动作。
    public static func decode(data: Data) throws -> HostKeymap {
        guard data.count <= maximumJSONBytes else { throw HostKeymapError.tooLarge }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    private enum CodingKeys: String, CodingKey {
        case version, controls, doublePressWindow, longPressThreshold, actionLibrary, layers
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(controls, forKey: .controls)
        if !layers.isEmpty { try values.encode(layers, forKey: .layers) }
        if !actionLibrary.isEmpty { try values.encode(actionLibrary, forKey: .actionLibrary) }
        try values.encode(doublePressWindow, forKey: .doublePressWindow)
        try values.encode(longPressThreshold, forKey: .longPressThreshold)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        controls = try values.decode([ControlActionMap].self, forKey: .controls)
        actionLibrary = try values.decodeIfPresent([NamedHostAction].self, forKey: .actionLibrary) ?? []
        layers = try values.decodeIfPresent([HostLayer].self, forKey: .layers) ?? []
        doublePressWindow = try values.decode(TimeInterval.self, forKey: .doublePressWindow)
        longPressThreshold = try values.decode(TimeInterval.self, forKey: .longPressThreshold)
        try validate()
        normalizeVersion()
    }
}
