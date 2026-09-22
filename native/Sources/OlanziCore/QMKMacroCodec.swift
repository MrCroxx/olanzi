import Foundation

/// 只解析可无损映射为本机宏的 QMK 语句子集；不编译或执行 C 代码。
public enum QMKMacroCodec {
    public struct ParseError: LocalizedError, Equatable {
        public let line: Int
        public let column: Int
        public let message: String
        public var errorDescription: String? { "Line \(line), column \(column): \(message)" }
    }

    public static func decode(_ source: String) throws -> [MacroStep] {
        guard source.utf8.count <= 32 * 1024 else {
            throw ParseError(line: 1, column: 1, message: "Macro source exceeds 32 KiB.")
        }
        var parser = Parser(tokens: try lex(source))
        return try parser.program()
    }

    public static func encode(_ steps: [MacroStep]) throws -> String {
        // 空编辑器允许进入代码模式，但 decode 和保存仍要求至少一个步骤。
        guard !steps.isEmpty else { return "" }
        try HostAction.macro(steps).validate()
        let lines = try steps.flatMap { step -> [String] in
            switch step {
            case .application(let target):
                return ["OLANZI_APP(\(quote(target.bundleIdentifier)), \(quote(target.path)), \(quote(target.name)));"]
            case .delay(let duration):
                let milliseconds = duration * 1000
                guard abs(milliseconds - milliseconds.rounded()) < 0.00000001 else {
                    throw ParseError(line: 1, column: 1, message: "QMK wait_ms requires whole milliseconds; use at most three decimal places in seconds.")
                }
                return ["wait_ms(\(Int(milliseconds.rounded())));"]
            case .keyboard(let entries):
                // 发射器去重、忽略 KC_NO，并先发送修饰键；代码采用相同顺序。
                var seen = Set<UInt8>()
                let active = entries.map(\.code).filter { $0 != 0 && seen.insert($0).inserted }
                let codes = active.filter(isModifier) + active.filter { !isModifier($0) }
                if codes.isEmpty { return ["tap_code(KC_NO);"] }
                let names = try codes.map { code -> String in
                    guard let name = canonicalNames[code] else {
                        throw ParseError(line: 1, column: 1, message: "No supported QMK name for keycode \(code).")
                    }
                    return name
                }
                if names.count == 1 { return ["tap_code(\(names[0]));"] }
                let mods = codes.dropLast()
                let last = codes.last!
                let oneSide = mods.allSatisfy { (0xE0...0xE3).contains($0) }
                    || mods.allSatisfy { (0xE4...0xE7).contains($0) }
                if !isModifier(last), mods.allSatisfy({ (0xE0...0xE7).contains($0) }), oneSide {
                    let expression = zip(mods, names).reversed().reduce(names.last!) { value, pair in
                        "\(modifierNames[Int(pair.0 - 0xE0)])(\(value))"
                    }
                    return ["tap_code16(\(expression));"]
                }
                return names.map { "register_code(\($0));" }
                    + names.reversed().map { "unregister_code(\($0));" }
            }
        }
        let source = lines.joined(separator: "\n")
        guard source.utf8.count <= 32 * 1024 else {
            throw ParseError(line: 1, column: 1, message: "Macro source exceeds 32 KiB.")
        }
        return source
    }

    private static let modifierNames = ["LCTL", "LSFT", "LALT", "LGUI", "RCTL", "RSFT", "RALT", "RGUI"]
    private static let modifierAliases: [String: UInt8] = {
        var result = Dictionary(uniqueKeysWithValues: modifierNames.enumerated().map { ($0.element, UInt8(0xE0 + $0.offset)) })
        for (name, code): (String, UInt8) in [("C", 0xE0), ("S", 0xE1), ("A", 0xE2), ("G", 0xE3),
            ("LOPT", 0xE2), ("LCMD", 0xE3), ("LWIN", 0xE3), ("ROPT", 0xE6), ("ALGR", 0xE6), ("RCMD", 0xE7), ("RWIN", 0xE7)] {
            result[name] = code
        }
        return result
    }()
    private static func isModifier(_ code: UInt8) -> Bool { code == 1 || (0xE0...0xE7).contains(code) }

    // 标准名称及 HID usage 来自 QMK Basic Keycodes；最终能力仍由 MacKeyEmitter 校验。
    private static let keyNames: [String: UInt8] = {
        var result: [String: UInt8] = ["KC_NO": 0, "OLANZI_FN": 1]
        func add(_ code: Int, _ names: String) {
            for name in names.split(separator: " ") { result["KC_" + name] = UInt8(code) }
        }
        for index in 0..<26 { add(4 + index, String(UnicodeScalar(65 + index)!)) }
        for index in 0..<10 { add(0x1E + index, String((index + 1) % 10)) }
        let main = ["ENTER ENT", "ESCAPE ESC", "BACKSPACE BSPC", "TAB", "SPACE SPC", "MINUS MINS", "EQUAL EQL",
                    "LEFT_BRACKET LBRC", "RIGHT_BRACKET RBRC", "BACKSLASH BSLS", "NONUS_HASH NUHS", "SEMICOLON SCLN",
                    "QUOTE QUOT", "GRAVE GRV", "COMMA COMM", "DOT", "SLASH SLSH", "CAPS_LOCK CAPS"]
        for (index, name) in main.enumerated() { add(0x28 + index, name) }
        for index in 0..<12 { add(0x3A + index, "F\(index + 1)"); add(0x68 + index, "F\(index + 13)") }
        let navigation = ["PRINT_SCREEN PSCR", "SCROLL_LOCK SCRL BRMD", "PAUSE PAUS BRK BRMU", "INSERT INS", "HOME",
                          "PAGE_UP PGUP", "DELETE DEL", "END", "PAGE_DOWN PGDN", "RIGHT RGHT", "LEFT", "DOWN", "UP"]
        for (index, name) in navigation.enumerated() { add(0x46 + index, name) }
        let keypad = ["NUM_LOCK NUM", "KP_SLASH PSLS", "KP_ASTERISK PAST", "KP_MINUS PMNS", "KP_PLUS PPLS", "KP_ENTER PENT",
                      "KP_1 P1", "KP_2 P2", "KP_3 P3", "KP_4 P4", "KP_5 P5", "KP_6 P6", "KP_7 P7", "KP_8 P8", "KP_9 P9", "KP_0 P0", "KP_DOT PDOT"]
        for (index, name) in keypad.enumerated() { add(0x53 + index, name) }
        add(0x64, "NONUS_BACKSLASH NUBS"); add(0x65, "APPLICATION APP")
        for (index, names) in ["LEFT_CTRL LCTL", "LEFT_SHIFT LSFT", "LEFT_ALT LALT LOPT", "LEFT_GUI LGUI LCMD LWIN",
                               "RIGHT_CTRL RCTL", "RIGHT_SHIFT RSFT", "RIGHT_ALT RALT ROPT ALGR", "RIGHT_GUI RGUI RCMD RWIN"].enumerated() {
            add(0xE0 + index, names)
        }
        return result
    }()
    private static let canonicalNames: [UInt8: String] = {
        var result: [UInt8: String] = [:]
        // 首选短别名以便编辑；字典遍历顺序不得影响导出结果。
        for name in keyNames.keys.sorted(by: { ($0.count, $0) > ($1.count, $1) }) { result[keyNames[name]!] = name }
        for (index, name) in modifierNames.enumerated() { result[UInt8(0xE0 + index)] = "KC_" + name }
        result[0x48] = "KC_PAUS"; result[0x47] = "KC_SCRL"
        return result
    }()

    private static func quote(_ string: String) -> String {
        "\"" + string.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\t", with: "\\t") + "\""
    }

    private enum Kind: Equatable { case identifier(String), integer(Int), string(String), symbol(String), end }
    private struct Token { let kind: Kind; let line: Int; let column: Int }
    private static func lex(_ source: String) throws -> [Token] {
        let chars = Array(source.unicodeScalars)
        var position = 0, line = 1, column = 1
        var tokens: [Token] = []
        func peek(_ offset: Int = 0) -> UnicodeScalar? { position + offset < chars.count ? chars[position + offset] : nil }
        func advance() { if chars[position] == "\n" { line += 1; column = 1 } else { column += 1 }; position += 1 }
        func error(_ message: String) -> ParseError { ParseError(line: line, column: column, message: message) }
        while let char = peek() {
            if CharacterSet.whitespacesAndNewlines.contains(char) { advance(); continue }
            if char == "/", peek(1) == "/" {
                while let next = peek(), next != "\n" { advance() }; continue
            }
            if char == "/", peek(1) == "*" {
                let start = error("Unterminated block comment.")
                advance(); advance()
                while peek() != nil && !(peek() == "*" && peek(1) == "/") { advance() }
                guard peek() != nil else { throw start }
                advance(); advance(); continue
            }
            let tokenLine = line, tokenColumn = column
            let kind: Kind
            if char == "\"" {
                advance()
                var string = ""
                while let next = peek(), next != "\"" {
                    guard next != "\n" && next != "\r" else { throw error("Unescaped newline in string.") }
                    if next == "\\" {
                        advance()
                        guard let escape = peek() else { throw error("Unterminated string escape.") }
                        let escapes: [UnicodeScalar: String] = ["\\": "\\", "\"": "\"", "n": "\n", "r": "\r", "t": "\t", "b": "\u{08}", "e": "\u{1B}"]
                        guard let value = escapes[escape] else { throw error("Unsupported string escape \\\(escape).") }
                        string += value; advance()
                    } else { string.unicodeScalars.append(next); advance() }
                }
                guard peek() == "\"" else { throw error("Unterminated string literal.") }
                advance(); kind = .string(string)
            } else if (48...57).contains(char.value) {
                let start = position
                while let next = peek(), (48...57).contains(next.value) { advance() }
                guard position - start == 1 || chars[start] != "0" else {
                    throw ParseError(line: tokenLine, column: tokenColumn,
                                     message: "Use decimal milliseconds without leading zeroes; C octal literals are unsupported.")
                }
                guard let number = Int(String(String.UnicodeScalarView(chars[start..<position]))) else { throw error("Integer is too large.") }
                kind = .integer(number)
            } else if char == "_" || (65...90).contains(char.value) || (97...122).contains(char.value) {
                let start = position
                while let next = peek(), next == "_" || (48...57).contains(next.value) || (65...90).contains(next.value) || (97...122).contains(next.value) { advance() }
                kind = .identifier(String(String.UnicodeScalarView(chars[start..<position])))
            } else if ["(", ")", ",", ";"].contains(String(char)) {
                kind = .symbol(String(char)); advance()
            } else { throw error("Unsupported character '\(char)'; only the documented QMK statement subset is accepted.") }
            tokens.append(Token(kind: kind, line: tokenLine, column: tokenColumn))
        }
        tokens.append(Token(kind: .end, line: line, column: column))
        return tokens
    }

    private struct Parser {
        let tokens: [Token]
        var position = 0
        var current: Token { tokens[position] }
        func error(_ message: String, at token: Token? = nil) -> ParseError {
            let location = token ?? current
            return ParseError(line: location.line, column: location.column, message: message)
        }
        mutating func expect(_ symbol: String) throws {
            guard current.kind == .symbol(symbol) else { throw error("Expected '\(symbol)'.") }; position += 1
        }
        mutating func identifier() throws -> String {
            guard case .identifier(let value) = current.kind else { throw error("Expected an identifier.") }; position += 1; return value
        }
        mutating func string() throws -> String {
            guard case .string(let value) = current.kind else { throw error("Expected a quoted string.") }; position += 1; return value
        }
        func checkDepth(_ depth: Int) throws { guard depth <= 32 else { throw error("Nesting exceeds 32 levels.") } }
        func checked(_ step: MacroStep, at token: Token) throws -> MacroStep {
            do { try HostAction.macro([step]).validate() } catch { throw self.error(error.localizedDescription, at: token) }
            return step
        }
        mutating func program() throws -> [MacroStep] {
            var steps: [MacroStep] = []
            while current.kind != .end {
                let token = current
                let name = try identifier()
                try expect("(")
                let additions: [MacroStep]
                switch name {
                case "tap_code", "tap_code16":
                    let keys = try keyExpression(depth: 1, allowModifiers: name == "tap_code16")
                    additions = [.keyboard(keys)]
                case "wait_ms": additions = [.delay(try duration())]
                case "OLANZI_APP":
                    let bundle = try string()
                    var path = "", name = bundle
                    if current.kind == .symbol(",") {
                        try expect(","); path = try string(); try expect(","); name = try string()
                    }
                    additions = [.application(ApplicationTarget(bundleIdentifier: bundle, path: path, name: name))]
                case "SEND_STRING": additions = try sendSequence(depth: 1)
                case "register_code":
                    let keys = try registerGroup()
                    // registerGroup 负责整组语句的所有右括号与分号。
                    steps.append(try checked(.keyboard(keys), at: token))
                    guard steps.count <= 32 else { throw error("Macro exceeds 32 steps.", at: token) }
                    continue
                default: throw error("Unsupported statement '\(name)'.", at: token)
                }
                try expect(")"); try expect(";")
                for step in additions { steps.append(try checked(step, at: token)) }
                guard steps.count <= 32 else { throw error("Macro exceeds 32 steps.", at: token) }
            }
            guard !steps.isEmpty else { throw error("Macro must contain at least one step.") }
            return steps
        }
        mutating func duration() throws -> TimeInterval {
            guard case .integer(let milliseconds) = current.kind else { throw error("Expected whole milliseconds (50–10000).") }
            guard (50...10000).contains(milliseconds) else { throw error("Delay must be 50–10000 milliseconds.") }
            position += 1
            return Double(milliseconds) / 1000
        }
        mutating func basicKey(prefix: String = "KC_") throws -> KeyEntry {
            let token = current
            let name = try identifier()
            let lookup: String
            if prefix == "X_" {
                guard name.hasPrefix(prefix) else { throw error("SS_TAP requires an X_ keycode.", at: token) }
                lookup = "KC_" + name.dropFirst(2)
            } else { lookup = name }
            guard let code = keyNames[lookup] else { throw error("Unknown or unsupported keycode '\(name)'.", at: token) }
            let key = KeyEntry(code: code)
            do { try MacKeyEmitter.validate(entries: [key]) } catch { throw self.error(error.localizedDescription, at: token) }
            return key
        }
        mutating func keyExpression(depth: Int, allowModifiers: Bool) throws -> [KeyEntry] {
            try checkDepth(depth)
            let token = current
            if case .identifier(let name) = token.kind, let code = modifierAliases[name] {
                guard allowModifiers else { throw error("Modifier expressions require tap_code16.", at: token) }
                position += 1; try expect("(")
                let inside = try keyExpression(depth: depth + 1, allowModifiers: true)
                try expect(")")
                guard !inside.contains(where: { $0.code == 1 }) else { throw error("Use register_code for OLANZI_FN combinations.", at: token) }
                // QMK 的 16 位修饰编码只有一个左右选择位，混用会改变原义。
                let nestedMods = inside.dropLast().map(\.code)
                guard nestedMods.allSatisfy({ ($0 < 0xE4) == (code < 0xE4) }) else {
                    throw error("Mixed left/right modifier expressions are not representable in QMK; use a register_code group.", at: token)
                }
                guard !inside.contains(where: { $0.code == code }) else { throw error("Duplicate modifier in expression.", at: token) }
                return [KeyEntry(code: code)] + inside
            }
            return [try basicKey()]
        }
        mutating func registerGroup() throws -> [KeyEntry] {
            var keys = [try basicKey()]
            try expect(")"); try expect(";")
            while current.kind == .identifier("register_code") {
                position += 1; try expect("("); keys.append(try basicKey()); try expect(")"); try expect(";")
                guard keys.count <= 24 else { throw error("A chord may contain at most 24 keycodes.") }
            }
            // 发射器始终先按修饰键；拒绝必须依赖其他事件顺序的 C 代码。
            var sawOrdinary = false
            var seen = Set<UInt8>()
            for key in keys {
                guard seen.insert(key.code).inserted else { throw error("Duplicate key in register_code group.") }
                if isModifier(key.code), sawOrdinary { throw error("Register modifiers before ordinary keys.") }
                if key.code != 0 && !isModifier(key.code) { sawOrdinary = true }
            }
            for key in keys.reversed() {
                guard current.kind == .identifier("unregister_code") else {
                    throw error("A register_code group must immediately release every key in reverse order; held keys across other statements are unsupported.")
                }
                position += 1; try expect("(")
                let token = current
                guard try basicKey() == key else { throw error("Release register_code keys in reverse order.", at: token) }
                try expect(")"); try expect(";")
            }
            return keys
        }
        mutating func sendSequence(depth: Int) throws -> [MacroStep] {
            try checkDepth(depth)
            var steps: [MacroStep] = []
            while current.kind != .symbol(")") {
                let token = current
                if case .string(let value) = token.kind {
                    position += 1
                    for scalar in value.unicodeScalars { steps.append(.keyboard(try ascii(scalar, at: token))) }
                } else {
                    let name = try identifier(); try expect("(")
                    switch name {
                    case "SS_TAP": steps.append(.keyboard([try basicKey(prefix: "X_")]))
                    case "SS_DELAY": steps.append(.delay(try duration()))
                    default:
                        guard name.hasPrefix("SS_"), let modifier = modifierAliases[String(name.dropFirst(3))],
                              String(name.dropFirst(3)).count > 1 else { throw error("Unsupported SEND_STRING element '\(name)'.", at: token) }
                        let inside = try sendSequence(depth: depth + 1)
                        guard inside.count == 1, case .keyboard(let keys) = inside[0] else {
                            throw error("An SS_ modifier wrapper must contain exactly one tap and no delay; holding modifiers across steps is unsupported.", at: token)
                        }
                        guard !keys.contains(where: { $0.code == modifier }) else {
                            throw error("Duplicate held modifier in SEND_STRING.", at: token)
                        }
                        steps.append(.keyboard([KeyEntry(code: modifier)] + keys))
                    }
                    try expect(")")
                }
                guard steps.count <= 32 else { throw error("Macro exceeds 32 steps.", at: token) }
            }
            return steps
        }
        func ascii(_ scalar: UnicodeScalar, at token: Token) throws -> [KeyEntry] {
            let value = scalar.value
            var code: UInt8
            var shift = false
            switch value {
            case 97...122: code = UInt8(value - 97 + 4)
            case 65...90: code = UInt8(value - 65 + 4); shift = true
            case 49...57: code = UInt8(value - 49 + 0x1E)
            case 48: code = 0x27
            case 32: code = 0x2C
            case 8: code = 0x2A
            case 9: code = 0x2B
            case 10: code = 0x28
            case 27: code = 0x29
            case 127: code = 0x4C
            default:
                let plain = Array("-=[]\\;'`,./".unicodeScalars)
                let shifted = Array("_+{}|:\"~<>?".unicodeScalars)
                let codes: [UInt8] = [0x2D, 0x2E, 0x2F, 0x30, 0x31, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38]
                if let index = plain.firstIndex(of: scalar) { code = codes[index] }
                else if let index = shifted.firstIndex(of: scalar) { code = codes[index]; shift = true }
                else if let index = Array("!@#$%^&*()".unicodeScalars).firstIndex(of: scalar) { code = UInt8(0x1E + index); shift = true }
                else { throw error("SEND_STRING supports printable US ANSI ASCII plus \\n, \\t, \\b and \\e; unsupported character U+\(String(value, radix: 16, uppercase: true)).", at: token) }
            }
            return (shift ? [KeyEntry(code: 0xE1)] : []) + [KeyEntry(code: code)]
        }
    }
}
