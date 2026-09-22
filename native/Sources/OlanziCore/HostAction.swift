import Foundation

public struct ApplicationTarget: Codable, Equatable, Sendable {
    public var bundleIdentifier: String
    public var path: String
    public var name: String

    public init(bundleIdentifier: String, path: String, name: String) {
        self.bundleIdentifier = bundleIdentifier
        self.path = path
        self.name = name
    }

    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 200,
              bundleIdentifier.count <= 255, path.count <= 4096,
              !bundleIdentifier.isEmpty || (!path.isEmpty && path.hasPrefix("/") && path.hasSuffix(".app")),
              path.isEmpty || (path.hasPrefix("/") && path.hasSuffix(".app")),
              ![bundleIdentifier, path, name].contains(where: { $0.contains("\0") }) else {
            throw HostActionError.invalidApplication
        }
    }
}

public enum MacroStep: Codable, Equatable, Sendable {
    case keyboard([KeyEntry])
    case application(ApplicationTarget)
    case delay(TimeInterval)
}

public enum HostAction: Codable, Equatable, Sendable {
    case keyboard([KeyEntry])
    case application(ApplicationTarget)
    case macro([MacroStep])
    case library(UUID)
    case momentaryLayer(Int)

    public func validate() throws {
        switch self {
        // 引用目标由整份配置校验；UUID 自身没有额外格式需要校验。
        case .library: break
        case .momentaryLayer(let layer):
            guard (1...3).contains(layer) else { throw HostKeymapError.invalidLayer }
        case .keyboard(let entries): try MacKeyEmitter.validate(entries: entries)
        case .application(let target): try target.validate()
        case .macro(let steps):
            guard (1...32).contains(steps.count) else { throw HostActionError.invalidStepCount }
            for step in steps {
                switch step {
                case .keyboard(let entries): try MacKeyEmitter.validate(entries: entries)
                case .application(let target): try target.validate()
                case .delay(let duration):
                    guard duration.isFinite, (0.05...10).contains(duration) else { throw HostActionError.invalidDelay }
                }
            }
        }
    }
}

public enum HostActionError: LocalizedError, Equatable {
    case invalidApplication, invalidStepCount, invalidDelay, applicationUnavailable, activationFailed, foregroundChanged
    case invalidLibraryName, invalidLibrarySlot, invalidLibraryAction, duplicateLibraryEntry, missingLibraryAction

    public var errorDescription: String? {
        switch self {
        case .invalidLibraryName: return "功能名称不能为空，且不能超过 80 个字符。"
        case .invalidLibrarySlot: return "宏和 APP 功能各支持 16 个编号（0–15）。"
        case .invalidLibraryAction: return "功能库只能保存 APP 或宏，不能嵌套引用。"
        case .duplicateLibraryEntry: return "功能库存在重复的标识或同类编号。"
        case .missingLibraryAction: return "引用的功能不存在，请重新选择。"
        case .invalidApplication: return "请选择有效的应用程序。"
        case .invalidStepCount: return "宏必须包含 1–32 个步骤。"
        case .invalidDelay: return "宏的等待时间必须为 0.05–10 秒。"
        case .applicationUnavailable: return "找不到配置的应用程序，请重新选择。"
        case .activationFailed: return "应用程序未能切换到前台，已停止当前宏。"
        case .foregroundChanged: return "前台应用已改变，已停止当前宏以避免发送到其他窗口。"
        }
    }
}

/// 配置内的可复用功能；控件通过 UUID 绑定，编辑名称或内容不会改变绑定。
public struct NamedHostAction: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var slot: Int
    public var action: HostAction

    public init(id: UUID = UUID(), name: String, slot: Int, action: HostAction) {
        self.id = id
        self.name = name
        self.slot = slot
        self.action = action
    }

    public var isMacro: Bool {
        if case .macro = action { return true }
        return false
    }

    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 80, !name.contains("\0") else { throw HostActionError.invalidLibraryName }
        guard (0..<16).contains(slot) else { throw HostActionError.invalidLibrarySlot }
        switch action {
        case .application, .macro: try action.validate()
        case .keyboard, .library, .momentaryLayer: throw HostActionError.invalidLibraryAction
        }
    }
}
