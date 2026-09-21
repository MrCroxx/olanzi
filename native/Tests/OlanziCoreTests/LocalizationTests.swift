import Foundation
import XCTest
@testable import OlanziCore

final class LocalizationTests: XCTestCase {
    func testSystemLanguageSelectsSupportedPreferenceAndFallsBackToEnglish() {
        XCTAssertEqual(AppLocalizer(language: .system, preferredLanguages: ["fr-FR", "zh-Hans-CN"]).locale.identifier, "zh-Hans")
        XCTAssertEqual(AppLocalizer(language: .system, preferredLanguages: ["en-GB", "zh-CN"]).text("设置"), "Settings")
        XCTAssertEqual(AppLocalizer(language: .system, preferredLanguages: ["fr-FR"]).text("设置"), "Settings")
        XCTAssertEqual(AppLocalizer(language: .system, preferredLanguages: []).locale.identifier, "en")
    }

    func testExplicitLanguageOverridesSystemAndChineseKeepsSource() {
        let chinese = AppLocalizer(language: .simplifiedChinese, preferredLanguages: ["en-US"])
        let english = AppLocalizer(language: .english, preferredLanguages: ["zh-Hans"])
        XCTAssertEqual(chinese.text("输入监控"), "输入监控")
        XCTAssertEqual(english.text("输入监控"), "Input Monitoring")
        XCTAssertEqual(chinese.locale.identifier, "zh-Hans")
        XCTAssertEqual(english.locale.identifier, "en")
        XCTAssertEqual(english.text("User-created profile / 工作.json"), "User-created profile / 工作.json")
    }

    func testFormattingPreservesArgumentsHexAndNumericPrecision() {
        let english = AppLocalizer(language: .english)
        XCTAssertEqual(english.format("%@：%@", "我的配置", "/tmp/输入监控.json"), "我的配置: /tmp/输入监控.json")
        XCTAssertEqual(english.format("%@：%@", arguments: ["A", "B"]), "A: B")
        XCTAssertEqual(english.format("当前不支持类型 0x%02X 的设备键位，只支持普通键盘类型 0x02。", UInt32(3)),
                       "Device mapping type 0x03 is not supported. Only keyboard type 0x02 is supported.")
        XCTAssertTrue(english.format("电池电压 %.3f V · 每 20 秒自动刷新", 3.318).contains("3.318 V"))
    }

    func testDiagnosticTranslatesKnownNestedErrorsWithoutTouchingUnknownContent() {
        let english = AppLocalizer(language: .english)
        let raw = "本机动作配置未更改：无法监听真实 Fn 状态：监听端口已失效。"
        XCTAssertEqual(english.diagnostic(raw),
                       "The local action configuration was not changed: Could not monitor physical Fn state: The monitoring port is no longer valid.")
        XCTAssertEqual(english.diagnostic("导入失败：/tmp/输入监控/默认键位.json"),
                       "Import failed: /tmp/输入监控/默认键位.json")
        XCTAssertEqual(english.diagnostic("未知配置 /tmp/辅助功能.json"), "未知配置 /tmp/辅助功能.json")
        XCTAssertEqual(english.diagnostic("/tmp/输入监控/配置版本不受支持。"), "/tmp/输入监控/配置版本不受支持。")
        XCTAssertEqual(AppLocalizer(language: .simplifiedChinese).diagnostic(raw), raw)
    }

    func testDiagnosticHexTemplatesMatchOnlyCompleteKnownMessages() {
        let english = AppLocalizer(language: .english)
        XCTAssertEqual(english.diagnostic("厂商通道打开失败（0xE00002C5）。"),
                       "Could not open the vendor channel (0xE00002C5).")
        XCTAssertEqual(english.diagnostic("读取 HID 报文失败：0xE00002E2"),
                       "Could not read the HID report: 0xE00002E2")
        let type = String(format: "当前不支持类型 0x%02X 的设备键位，只支持普通键盘类型 0x02。", 3)
        XCTAssertEqual(english.diagnostic(type), english.format("当前不支持类型 0x%02X 的设备键位，只支持普通键盘类型 0x02。", 3))
        XCTAssertEqual(english.diagnostic(type + "/用户.json"), type + "/用户.json")
        XCTAssertEqual(english.diagnostic("用户名字（0xE00002C5）。"), "用户名字（0xE00002C5）。")
    }

    func testAllMissingPermissionVariantsAndControlNamesTranslate() {
        let english = AppLocalizer(language: .english)
        for permissions in ["输入监控", "辅助功能", "输入监控与辅助功能"] {
            let raw = "权限不足：按键转换需要" + permissions + "权限，心跳已暂停。"
            let result = english.diagnostic(raw)
            XCTAssertNotEqual(result, raw)
            XCTAssertTrue(result.contains("heartbeat is paused"))
            XCTAssertNil(result.range(of: "[\\p{Han}]", options: .regularExpression))
        }
        XCTAssertEqual(english.diagnostic("顺时针旋转"), "Clockwise Rotation")
    }

    func testResourceCatalogsHaveIdenticalKeysAndFormatSignatures() throws {
        let english = AppLocalizer.catalog("en")
        let chinese = AppLocalizer.catalog("zh-Hans")
        XCTAssertGreaterThan(english.count, 200)
        XCTAssertEqual(Set(english.keys), Set(chinese.keys))
        let format = try NSRegularExpression(pattern: "%[-+ #0-9.]*[@diuoxXfFeEgGcCsSp%]")
        func signature(_ value: String) -> [String] {
            format.matches(in: value, range: NSRange(value.startIndex..., in: value)).map {
                String(value[Range($0.range, in: value)!])
            }.sorted()
        }
        for (key, translation) in english {
            XCTAssertEqual(chinese[key], key)
            XCTAssertFalse(translation.isEmpty, key)
            XCTAssertEqual(signature(key), signature(translation), key)
        }
        for key in KeyCatalog.categories + KeyCatalog.controlNames {
            XCTAssertNotNil(english[key], key)
            XCTAssertNotEqual(english[key], key)
        }
    }
}
