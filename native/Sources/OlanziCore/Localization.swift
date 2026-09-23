import Foundation

public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system, simplifiedChinese, english
    public var id: String { rawValue }
}

/// 界面语言独立于系统语言；未知错误与用户填写的路径、名称原样保留。
public struct AppLocalizer: Sendable {
    public let language: AppLanguage
    public let locale: Locale
    private let languageCode: String

    public init(language: AppLanguage, preferredLanguages: [String] = Locale.preferredLanguages) {
        self.language = language
        switch language {
        case .simplifiedChinese: languageCode = "zh-Hans"
        case .english: languageCode = "en"
        case .system:
            languageCode = preferredLanguages.compactMap { language -> String? in
                let code = language.lowercased().replacingOccurrences(of: "_", with: "-")
                if code == "zh" || code.hasPrefix("zh-") { return "zh-Hans" }
                if code == "en" || code.hasPrefix("en-") { return "en" }
                return nil
            }.first ?? "en"
        }
        locale = Locale(identifier: languageCode)
    }

    public func text(_ source: String) -> String { Self.catalog(languageCode)[source] ?? source }

    public func format(_ source: String, _ args: CVarArg...) -> String {
        format(source, arguments: args)
    }

    public func format(_ source: String, arguments: [CVarArg]) -> String {
        String(format: text(source), locale: locale, arguments: arguments)
    }

    public func diagnostic(_ raw: String) -> String { diagnostic(raw, depth: 0) }

    private func diagnostic(_ raw: String, depth: Int) -> String {
        guard languageCode == "en", depth < 8 else { return raw }
        let direct = text(raw)
        if direct != raw { return direct }
        // 只识别已知诊断的完整前缀；绝不在任意用户路径或配置名中替换词语。
        for prefix in Self.diagnosticPrefixes where raw.hasPrefix(prefix) {
            return text(prefix) + diagnostic(String(raw.dropFirst(prefix.count)), depth: depth + 1)
        }
        let numericTemplates = [
            "当前不支持类型 0x%02X 的设备键位，只支持普通键盘类型 0x02。",
            "键码 0x%02X 没有可用的 macOS 虚拟键映射（F21–F24 暂不支持）。",
            "无法创建键码 0x%02X 的 macOS 键盘事件。",
            "读取 HID 报文失败：0x%08X"
        ]
        for template in numericTemplates {
            let specifier = template.contains("%08X") ? "%08X" : "%02X"
            let parts = template.components(separatedBy: specifier)
            let width = specifier == "%08X" ? 8 : 2
            guard parts.count == 2, raw.hasPrefix(parts[0]), raw.hasSuffix(parts[1]) else { continue }
            let end = raw.count - parts[1].count
            guard end >= parts[0].count else { continue }
            let hex = String(raw.dropFirst(parts[0].count).prefix(end - parts[0].count))
            guard hex.count == width, let number = UInt32(hex, radix: 16) else { continue }
            return format(template, number)
        }
        // IOKit 错误只有固定的十六进制后缀；仅翻译已收录的错误摘要。
        if let range = raw.range(of: "（0x", options: .backwards), raw.hasSuffix("）。") {
            let base = String(raw[..<range.lowerBound])
            let suffix = String(raw[range.upperBound...].dropLast(2))
            if suffix.count == 8, UInt32(suffix, radix: 16) != nil, text(base) != base {
                return text(base) + " (0x" + suffix + ")."
            }
        }
        return raw
    }

    private static let diagnosticPrefixes = [
        "按键唤醒监听不可用，请点击恢复保活：",
        "本机动作配置读取失败，已保留原文件且停止动作执行：", "本机动作配置未更改：",
        "写入未全部完成，部分改动可能已生效。", "无法监听真实 Fn 状态：",
        "Mac Fn 桥接不可用：", "Fn 报文处理失败：", "Fn 松开事件发送失败：",
        "Fn 输入接口枚举失败：", "Fn 输入读取失败：", "Fn 输入接口关闭失败：",
        "无法读取本地配置列表，原始数据已备份保留：", "暂时无法读取电量，将自动重试：",
        "保存未完成，草稿已保留。", "设备键位导入失败：", "导入失败："
    ]

    private static let resourceBundle: Bundle = {
        // SwiftPM 的开发目录和签名 App 的 Contents/Resources 都使用同一个资源包。
        if let url = Bundle.main.url(forResource: "Olanzi_OlanziCore", withExtension: "bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return Bundle.module
    }()

    private static let catalogs = ["en": loadCatalog("en"), "zh-Hans": loadCatalog("zh-Hans")]
    static func catalog(_ language: String) -> [String: String] { catalogs[language] ?? [:] }

    private static func loadCatalog(_ language: String) -> [String: String] {
        guard let url = resourceBundle.url(forResource: "Localizable", withExtension: "strings",
                                          subdirectory: nil, localization: language),
              let data = try? Data(contentsOf: url),
              let table = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        else { return [:] }
        return table
    }
}
