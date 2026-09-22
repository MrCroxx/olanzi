import XCTest
@testable import OlanziCore

/// 编解码只处理值，不创建发射器、启动应用或向桌面发送按键。
final class QMKMacroCodecTests: XCTestCase {
    private func keyboard(_ codes: UInt8...) -> MacroStep { .keyboard(codes.map { KeyEntry(code: $0) }) }

    func testCodexWorkflowUsesQMKStatementsAndExplicitAppExtension() throws {
        let decoded = try QMKMacroCodec.decode("""
        // 切换应用，再触发输入框快捷键。
        OLANZI_APP("com.openai.codex", "/Applications/Codex.app", "Codex");
        wait_ms(800);
        tap_code16(LCTL(LALT(LGUI(KC_I))));
        """)
        let target = ApplicationTarget(bundleIdentifier: "com.openai.codex", path: "/Applications/Codex.app", name: "Codex")
        XCTAssertEqual(decoded, [.application(target), .delay(0.8), keyboard(0xE0, 0xE2, 0xE3, 0x0C)])
        XCTAssertEqual(try QMKMacroCodec.decode(QMKMacroCodec.encode(decoded)), decoded)
        XCTAssertEqual(try QMKMacroCodec.decode("OLANZI_APP(\"com.openai.codex\");"),
                       [.application(ApplicationTarget(bundleIdentifier: "com.openai.codex", path: "", name: "com.openai.codex"))])
    }

    func testApplicationStringsRoundTripWithoutDroppingNameOrPath() throws {
        let target = ApplicationTarget(bundleIdentifier: "", path: "/Applications/我的 \\\"Editor.app", name: "编辑器\n\t\\\"")
        let steps: [MacroStep] = [.application(target)]
        XCTAssertEqual(try QMKMacroCodec.decode(QMKMacroCodec.encode(steps)), steps)
    }

    func testBasicQMKKeycodesAliasesAndFnExtension() throws {
        let cases: [(String, UInt8)] = [
            ("KC_A", 0x04), ("KC_Z", 0x1D), ("KC_1", 0x1E), ("KC_0", 0x27),
            ("KC_ENT", 0x28), ("KC_ENTER", 0x28), ("KC_ESCAPE", 0x29), ("KC_BSPC", 0x2A),
            ("KC_SPC", 0x2C), ("KC_NUHS", 0x32), ("KC_PSLS", 0x54), ("KC_P0", 0x62),
            ("KC_LEFT_GUI", 0xE3), ("KC_RCMD", 0xE7), ("KC_F13", 0x68), ("KC_F20", 0x6F),
            ("KC_NUBS", 0x64), ("KC_APP", 0x65), ("OLANZI_FN", 1), ("KC_NO", 0)
        ]
        for (name, code) in cases {
            XCTAssertEqual(try QMKMacroCodec.decode("tap_code(\(name));"), [keyboard(code)], name)
        }
        for name in ["KC_FN", "KC_TRNS", "KC_F21", "KC_AUDIO_VOL_UP", "KC_NONSENSE"] {
            XCTAssertThrowsError(try QMKMacroCodec.decode("tap_code(\(name));"), name)
        }
        XCTAssertEqual(try QMKMacroCodec.encode([keyboard(1)]), "tap_code(OLANZI_FN);")
    }

    func testAllSupportedCatalogKeysCanBeEncodedAndDecoded() throws {
        for key in KeyCatalog.options where (try? MacKeyEmitter.validate(entries: [KeyEntry(code: key.code)])) != nil {
            let steps = [keyboard(key.code)]
            XCTAssertEqual(try QMKMacroCodec.decode(QMKMacroCodec.encode(steps)), steps, key.label)
        }
    }

    func testQMKModifierExpressionsAndAliases() throws {
        XCTAssertEqual(try QMKMacroCodec.decode("tap_code16(RCTL(RSFT(RALT(RGUI(KC_A)))));"),
                       [keyboard(0xE4, 0xE5, 0xE6, 0xE7, 0x04)])
        XCTAssertEqual(try QMKMacroCodec.decode("tap_code16(C(S(A(G(KC_A)))));"),
                       [keyboard(0xE0, 0xE1, 0xE2, 0xE3, 0x04)])
        XCTAssertEqual(try QMKMacroCodec.decode("tap_code16(LOPT(LCMD(KC_I)));"), [keyboard(0xE2, 0xE3, 0x0C)])
        for source in ["tap_code(LCTL(KC_A));", "tap_code16(LCTL(RSFT(KC_A)));",
                       "tap_code16(LCTL(LCTL(KC_A)));", "tap_code16(LCTL(OLANZI_FN));"] {
            XCTAssertThrowsError(try QMKMacroCodec.decode(source), source)
        }
    }

    func testArbitraryChordsKeepAllKeysAndSidesUsingRegisterGroups() throws {
        for codes: [UInt8] in [[0xE0, 0x04, 0x05], [0xE0, 0xE5, 0x04], [1, 0xE3, 0x0C],
                               [0xE0, 0xE1], [0x04, 0x05, 0x06]] {
            let steps: [MacroStep] = [.keyboard(codes.map { KeyEntry(code: $0) })]
            let source = try QMKMacroCodec.encode(steps)
            XCTAssertTrue(source.contains("register_code("))
            XCTAssertFalse(source.contains("tap_code16("))
            XCTAssertEqual(try QMKMacroCodec.decode(source), steps)
        }
    }

    func testRegisterGroupsRequireCompleteImmediateReverseReleases() throws {
        let valid = "register_code(KC_LCTL); register_code(KC_A); register_code(KC_B); unregister_code(KC_B); unregister_code(KC_A); unregister_code(KC_LCTL);"
        XCTAssertEqual(try QMKMacroCodec.decode(valid), [keyboard(0xE0, 0x04, 0x05)])
        let invalid = [
            "register_code(KC_A);", "unregister_code(KC_A);",
            "register_code(KC_A); wait_ms(100); unregister_code(KC_A);",
            "register_code(KC_A); tap_code(KC_B); unregister_code(KC_A);",
            "register_code(KC_A); register_code(KC_B); unregister_code(KC_A); unregister_code(KC_B);",
            "register_code(KC_A); register_code(KC_LCTL); unregister_code(KC_LCTL); unregister_code(KC_A);",
            "register_code(KC_A); register_code(KC_A); unregister_code(KC_A); unregister_code(KC_A);"
        ]
        for source in invalid { XCTAssertThrowsError(try QMKMacroCodec.decode(source), source) }
    }

    func testSendStringAdjacentLiteralsTapsDelaysAndSingleTapModifiers() throws {
        XCTAssertEqual(try QMKMacroCodec.decode(#"SEND_STRING("a" "B" SS_TAP(X_ENTER) SS_DELAY(800) SS_RCTL(SS_RGUI(SS_TAP(X_I))));"#),
                       [keyboard(0x04), keyboard(0xE1, 0x05), keyboard(0x28), .delay(0.8), keyboard(0xE4, 0xE7, 0x0C)])
        XCTAssertEqual(try QMKMacroCodec.decode(#"SEND_STRING(SS_LCTL("a"));"#), [keyboard(0xE0, 0x04)])
        XCTAssertEqual(try QMKMacroCodec.decode(#"SEND_STRING(SS_LOPT(SS_LCMD("i")));"#), [keyboard(0xE2, 0xE3, 0x0C)])
        XCTAssertEqual(try QMKMacroCodec.decode(#"SEND_STRING(SS_ROPT(SS_RCMD("i")));"#), [keyboard(0xE6, 0xE7, 0x0C)])
        XCTAssertEqual(try QMKMacroCodec.decode(#"SEND_STRING(SS_LCTL(SS_RSFT("i")));"#), [keyboard(0xE0, 0xE5, 0x0C)])
    }

    func testSendStringPrintableASCIIUsesUSANSIAndRecognizesControlEscapes() throws {
        XCTAssertEqual(try QMKMacroCodec.decode(#"SEND_STRING("!@()_+{}|:\"~<>?");"#),
                       [keyboard(0xE1, 0x1E), keyboard(0xE1, 0x1F), keyboard(0xE1, 0x26), keyboard(0xE1, 0x27),
                        keyboard(0xE1, 0x2D), keyboard(0xE1, 0x2E), keyboard(0xE1, 0x2F), keyboard(0xE1, 0x30),
                        keyboard(0xE1, 0x31), keyboard(0xE1, 0x33), keyboard(0xE1, 0x34), keyboard(0xE1, 0x35),
                        keyboard(0xE1, 0x36), keyboard(0xE1, 0x37), keyboard(0xE1, 0x38)])
        XCTAssertEqual(try QMKMacroCodec.decode(#"SEND_STRING("0 -=[]\\;'`,./\n\t\b\e");"#),
                       [keyboard(0x27), keyboard(0x2C), keyboard(0x2D), keyboard(0x2E), keyboard(0x2F), keyboard(0x30),
                        keyboard(0x31), keyboard(0x33), keyboard(0x34), keyboard(0x35), keyboard(0x36), keyboard(0x37),
                        keyboard(0x38), keyboard(0x28), keyboard(0x2B), keyboard(0x2A), keyboard(0x29)])
    }

    func testSendStringRejectsUnicodeAndUnsupportedHeldModifierSemantics() throws {
        let invalid = [
            #"SEND_STRING("你好");"#, #"SEND_STRING(SS_LCTL("ab"));"#,
            #"SEND_STRING(SS_LCTL("a" SS_DELAY(100)));"#, #"SEND_STRING(SS_LSFT("A"));"#,
            #"SEND_STRING(SS_DOWN(X_LCTL) "a" SS_UP(X_LCTL));"#,
            #"SEND_STRING(SS_TAP(KC_A));"#, #"SEND_STRING(SS_TAP(OLANZI_FN));"#,
            #"SEND_STRING("\x41");"#, #"SEND_STRING("\r");"#
        ]
        for source in invalid { XCTAssertThrowsError(try QMKMacroCodec.decode(source), source) }
    }

    func testCommentsAndWhitespaceAreIgnoredOutsideStrings() throws {
        let steps = try QMKMacroCodec.decode("""
        /* tap_code(KC_B); */
        tap_code /* 注释 */ ( KC_A ); // wait_ms(900);
        wait_ms(50);
        OLANZI_APP("org.example./*literal*/", "", "// literal");
        """)
        XCTAssertEqual(steps, [keyboard(0x04), .delay(0.05), .application(ApplicationTarget(bundleIdentifier: "org.example./*literal*/", path: "", name: "// literal"))])
    }

    func testUnknownSyntaxReportsExactLineColumnWithoutPartialSuccess() throws {
        XCTAssertThrowsError(try QMKMacroCodec.decode("tap_code(KC_A);\n  system(\"open app\");")) { error in
            let parsed = error as? QMKMacroCodec.ParseError
            XCTAssertEqual(parsed?.line, 2)
            XCTAssertEqual(parsed?.column, 3)
            XCTAssertTrue(parsed?.message.contains("system") == true)
        }
        XCTAssertThrowsError(try QMKMacroCodec.decode("tap_code(KC_A);\n  tap_code(KC_BAD);")) { error in
            let parsed = error as? QMKMacroCodec.ParseError
            XCTAssertEqual(parsed?.line, 2)
            XCTAssertEqual(parsed?.column, 12)
        }
        for source in ["tap_code(KC_A)", "tap_code(KC_A); if (1) {}", "tap_code(KC_A); #include <stdio.h>",
                       "tap_code(KC_A); /* unfinished", #"OLANZI_APP("unfinished);"#,
                       "tap_code(KC_A); trailing", "wait_ms(1 + 100);"] {
            XCTAssertThrowsError(try QMKMacroCodec.decode(source), source)
        }
    }

    func testSourceDepthStepAndKeyLimitsAreEnforced() throws {
        XCTAssertNoThrow(try QMKMacroCodec.decode(String(repeating: "tap_code(KC_A);", count: 32)))
        XCTAssertThrowsError(try QMKMacroCodec.decode(String(repeating: "tap_code(KC_A);", count: 33)))
        XCTAssertThrowsError(try QMKMacroCodec.decode(#"SEND_STRING("abcdefghijklmnopqrstuvwxyz1234567");"#))
        XCTAssertThrowsError(try QMKMacroCodec.decode("tap_code(KC_A); //" + String(repeating: "x", count: 32 * 1024)))
        XCTAssertThrowsError(try QMKMacroCodec.decode("tap_code16(" + String(repeating: "LCTL(", count: 33) + "KC_A" + String(repeating: ")", count: 33) + ");")) { error in
            XCTAssertTrue((error as? QMKMacroCodec.ParseError)?.message.contains("32 levels") == true)
        }
        let names = (0..<25).map { "KC_" + String(UnicodeScalar(65 + $0)!) }
        let source = names.map { "register_code(\($0));" }.joined() + names.reversed().map { "unregister_code(\($0));" }.joined()
        XCTAssertThrowsError(try QMKMacroCodec.decode(source))
    }

    func testDelayBoundariesAndNoRoundingOnCodeExport() throws {
        XCTAssertEqual(try QMKMacroCodec.decode("wait_ms(50); wait_ms(10000);"), [.delay(0.05), .delay(10)])
        XCTAssertEqual(try QMKMacroCodec.encode([.delay(0.123)]), "wait_ms(123);")
        XCTAssertThrowsError(try QMKMacroCodec.encode([.delay(0.1235)]))
        for source in ["wait_ms(49);", "wait_ms(10001);", "wait_ms(-100);", "wait_ms(100.5);", "wait_ms(0100);", "SEND_STRING(SS_DELAY(0100));", "wait_ms(999999999999999999999999999999999999999);"] {
            XCTAssertThrowsError(try QMKMacroCodec.decode(source), source)
        }
    }

    func testEmptyEditorMayEncodeButEmptyMacroCannotDecode() throws {
        XCTAssertEqual(try QMKMacroCodec.encode([]), "")
        XCTAssertThrowsError(try QMKMacroCodec.decode(""))
        XCTAssertThrowsError(try QMKMacroCodec.decode(" // comment only"))
        XCTAssertThrowsError(try QMKMacroCodec.decode(#"SEND_STRING("");"#))
        // 空键盘步骤与 KC_NO 都是不执行动作，不丢弃它在宏中的位置。
        XCTAssertEqual(try QMKMacroCodec.decode(QMKMacroCodec.encode([.keyboard([]), .delay(0.1)])), [keyboard(0), .delay(0.1)])
    }

    func testVisualChordNormalizationMatchesEmitterWithoutDroppingNonModifierKeys() throws {
        let steps = [keyboard(0x04, 0xE3, 0x05, 0x04, 0)]
        let decoded = try QMKMacroCodec.decode(QMKMacroCodec.encode(steps))
        XCTAssertEqual(decoded, [keyboard(0xE3, 0x04, 0x05)])
        XCTAssertThrowsError(try QMKMacroCodec.encode([.keyboard([KeyEntry(type: 3, code: 0x04)])]))
        XCTAssertThrowsError(try QMKMacroCodec.encode(Array(repeating: keyboard(0x04), count: 33)))
    }
}
