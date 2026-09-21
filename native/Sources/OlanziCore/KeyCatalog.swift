import Foundation

public struct KeyOption: Identifiable, Sendable {
    public let code: UInt8
    public let label: String
    public let category: String
    public var id: UInt8 { code }
}

public enum KeyCatalog {
    public static let categories = ["常用", "字母", "数字", "功能键", "导航", "修饰键", "符号", "数字键盘"]
    public static let defaults: [UInt8] = [1, 0x28, 0x29, 0x46, 0x4F, 0x2A]
    public static let controlNames = ["顶部按键", "中部按键", "底部按键", "旋钮按下", "顺时针旋转", "逆时针旋转"]
    public static let options: [KeyOption] = {
        var keys: [KeyOption] = []
        func add(_ code: Int, _ label: String, _ category: String) {
            keys.append(KeyOption(code: UInt8(code), label: label, category: category))
        }
        for i in 0..<26 { add(i + 4, String(UnicodeScalar(65 + i)!), "字母") }
        for i in 0..<10 { add(i + 0x1E, String((i + 1) % 10), "数字") }
        for (i, label) in ["Enter", "Esc", "⌫", "Tab", "Space"].enumerated() { add(i + 0x28, label, "常用") }
        for (i, label) in ["−", "=", "[", "]", "\\", "Non-US #", ";", "'", "`", ",", ".", "/"].enumerated() {
            add(i + 0x2D, label, "符号")
        }
        add(0x39, "Caps Lock", "常用")
        for i in 0..<12 { add(i + 0x3A, "F\(i + 1)", "功能键") }
        for i in 0..<12 { add(i + 0x68, "F\(i + 13)", "功能键") }
        for (i, label) in ["Print Screen", "Scroll Lock", "Pause", "Insert", "Home", "Page Up", "Delete", "End", "Page Down", "→", "←", "↓", "↑"].enumerated() {
            add(i + 0x46, label, "导航")
        }
        for (i, label) in ["Num Lock", "KP /", "KP *", "KP −", "KP +", "KP Enter", "KP 1", "KP 2", "KP 3", "KP 4", "KP 5", "KP 6", "KP 7", "KP 8", "KP 9", "KP 0", "KP ."].enumerated() {
            add(i + 0x53, label, "数字键盘")
        }
        add(0x65, "Menu", "常用")
        for (i, label) in ["左 Control", "左 Shift", "左 Option", "左 Command", "右 Control", "右 Shift", "右 Option", "右 Command"].enumerated() {
            add(i + 0xE0, label, "修饰键")
        }
        add(1, "Fn", "修饰键")
        add(0, "未分配", "常用")
        return keys
    }()
    public static func label(_ code: UInt8?) -> String {
        guard let code else { return "复杂配置" }
        return options.first(where: { $0.code == code })?.label ?? String(format: "0x%02X", code)
    }
}

public struct KeyProfile: Codable, Identifiable, Equatable {
    public var id: UUID
    public var version: Int
    public var name: String
    public var codes: [UInt8]
    public init(name: String, codes: [UInt8]) {
        self.id = UUID(); self.version = 1; self.name = name; self.codes = codes
    }
    public func validate() throws {
        guard version == 1, codes.count == 6, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 80, codes.allSatisfy({ code in KeyCatalog.options.contains(where: { $0.code == code }) }) else {
            throw NSError(domain: "Olanzi", code: 1, userInfo: [NSLocalizedDescriptionKey: "配置文件无效，请导入 Olanzi 原生应用导出的六键配置。"])
        }
    }
}
