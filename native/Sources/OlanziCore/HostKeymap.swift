import Foundation

public enum HostKeymapError: LocalizedError, Equatable {
    case unsupportedVersion
    case invalidControls
    case invalidTiming
    case unsupportedGesture
    case invalidName
    case tooLarge

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion: return "配置版本不受支持。"
        case .invalidControls: return "配置必须包含且仅包含六个控件，每个控件只能出现一次。"
        case .invalidTiming: return "双击间隔应为 0.15–0.5 秒，长按阈值应为 0.3–2 秒，且长按阈值必须大于双击间隔。"
        case .unsupportedGesture: return "旋钮转动不支持双击或长按动作。"
        case .invalidName: return "配置名称不能为空，且不能超过 80 个字符。"
        case .tooLarge: return "配置文件不能超过 32 KiB。"
        }
    }
}

public enum LongPressBehavior: String, Codable, CaseIterable, Identifiable, Sendable {
    case hold, tap
    public var id: Self { self }
}

public struct ControlActionMap: Codable, Equatable, Sendable {
    public var index: Int
    public var press: [KeyEntry]
    public var doublePress: [KeyEntry]?
    public var longPress: [KeyEntry]?
    public var longPressBehavior: LongPressBehavior

    public init(index: Int, press: [KeyEntry], doublePress: [KeyEntry]? = nil,
                longPress: [KeyEntry]? = nil, longPressBehavior: LongPressBehavior = .hold) {
        self.index = index
        self.press = press
        self.doublePress = doublePress
        self.longPress = longPress
        self.longPressBehavior = longPressBehavior
    }

    private enum CodingKeys: String, CodingKey {
        case index, press, doublePress, longPress, longPressBehavior
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        index = try values.decode(Int.self, forKey: .index)
        press = try values.decode([KeyEntry].self, forKey: .press)
        doublePress = try values.decodeIfPresent([KeyEntry].self, forKey: .doublePress)
        longPress = try values.decodeIfPresent([KeyEntry].self, forKey: .longPress)
        // 旧配置没有该字段，其长按动作一直保持到物理松开。
        longPressBehavior = try values.decodeIfPresent(LongPressBehavior.self, forKey: .longPressBehavior) ?? .hold
    }
}

public struct HostKeymap: Codable, Equatable, Sendable {
    public static let maximumJSONBytes = 32 * 1024
    /// 首次编辑使用独立本机草稿，不依赖设备回读；由用户显式保存后才激活。
    public static let defaultKeymap = HostKeymap(controls: DeviceProtocol.defaultCodes.enumerated().map {
        ControlActionMap(index: $0.offset, press: [KeyEntry(code: $0.element)])
    })
    public var version: Int = 1
    public var controls: [ControlActionMap]
    public var doublePressWindow: TimeInterval
    public var longPressThreshold: TimeInterval

    public init(controls: [ControlActionMap], doublePressWindow: TimeInterval = 0.25,
                longPressThreshold: TimeInterval = 0.5) {
        self.controls = controls
        self.doublePressWindow = doublePressWindow
        self.longPressThreshold = longPressThreshold
    }

    public static func fromDeviceBindings(_ bindings: [KeyBinding]) throws -> HostKeymap {
        let map = HostKeymap(controls: bindings.sorted { $0.index < $1.index }.map {
            ControlActionMap(index: $0.index, press: $0.entries)
        })
        try map.validate()
        return map
    }

    public func validate() throws {
        guard version == 1 else { throw HostKeymapError.unsupportedVersion }
        guard controls.count == 6, Set(controls.map(\.index)) == Set(0..<6) else {
            throw HostKeymapError.invalidControls
        }
        guard doublePressWindow.isFinite, longPressThreshold.isFinite,
              (0.15...0.5).contains(doublePressWindow), (0.3...2).contains(longPressThreshold),
              longPressThreshold > doublePressWindow else { throw HostKeymapError.invalidTiming }
        for control in controls {
            guard control.index < 4 || (control.doublePress == nil && control.longPress == nil && control.longPressBehavior == .hold) else {
                throw HostKeymapError.unsupportedGesture
            }
            try MacKeyEmitter.validate(entries: control.press)
            if let action = control.doublePress { try MacKeyEmitter.validate(entries: action) }
            if let action = control.longPress { try MacKeyEmitter.validate(entries: action) }
        }
    }

    /// 导入入口先限制原始数据大小，再交给 Codable 检查字段与动作。
    public static func decode(data: Data) throws -> HostKeymap {
        guard data.count <= maximumJSONBytes else { throw HostKeymapError.tooLarge }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    private enum CodingKeys: String, CodingKey {
        case version, controls, doublePressWindow, longPressThreshold
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        controls = try values.decode([ControlActionMap].self, forKey: .controls)
        doublePressWindow = try values.decode(TimeInterval.self, forKey: .doublePressWindow)
        longPressThreshold = try values.decode(TimeInterval.self, forKey: .longPressThreshold)
        try validate()
    }
}
