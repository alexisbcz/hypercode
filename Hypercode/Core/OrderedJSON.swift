import Foundation

/// JSON that keeps keys in file order and numbers as written, for editing files people also edit by hand:
/// a save should change the one setting you touched, not reorder the file or turn `40` into `40.0`.
nonisolated enum OrderedJSON: Equatable, Sendable {
    case null
    case bool(Bool)
    /// The number's text, as written.
    case number(String)
    case string(String)
    case array([OrderedJSON])
    case object([(key: String, value: OrderedJSON)])

    static func == (a: OrderedJSON, b: OrderedJSON) -> Bool {
        switch (a, b) {
        case (.null, .null): true
        case let (.bool(x), .bool(y)): x == y
        case let (.number(x), .number(y)): x == y || Double(x) == Double(y)
        case let (.string(x), .string(y)): x == y
        case let (.array(x), .array(y)): x == y
        case let (.object(x), .object(y)): x.count == y.count && zip(x, y).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: false
        }
    }

    // MARK: Reading values

    subscript(key: String) -> OrderedJSON? {
        if case .object(let pairs) = self { return pairs.first { $0.key == key }?.value }
        return nil
    }

    var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var bool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var int: Int? {
        if case .number(let n) = self { return Int(n) ?? Double(n).map { Int($0) } }
        return nil
    }

    var array: [OrderedJSON]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var pairs: [(key: String, value: OrderedJSON)]? {
        if case .object(let p) = self { return p }
        return nil
    }

    var strings: [String] { array?.compactMap(\.string) ?? [] }

    func value(at path: [String]) -> OrderedJSON? {
        path.reduce(Optional(self)) { $0?[$1] }
    }

    /// Sets the value at a path, creating objects on the way; nil removes the key, and objects left empty
    /// by a removal go too, so clearing a setting doesn't leave `"permissions": {}` behind.
    mutating func set(_ value: OrderedJSON?, at path: [String]) {
        guard let key = path.first else {
            if let value { self = value }
            return
        }
        var pairs = self.pairs ?? []
        let index = pairs.firstIndex { $0.key == key }
        if path.count == 1 {
            switch (index, value) {
            case let (i?, v?): pairs[i].value = v
            case let (nil, v?): pairs.append((key, v))
            case let (i?, nil): pairs.remove(at: i)
            case (nil, nil): break
            }
        } else {
            var child = index.map { pairs[$0].value } ?? .object([])
            child.set(value, at: Array(path.dropFirst()))
            let isEmpty = child.pairs?.isEmpty == true && value == nil
            switch (index, isEmpty) {
            case let (i?, true): pairs.remove(at: i)
            case let (i?, false): pairs[i].value = child
            case (nil, false): pairs.append((key, child))
            case (nil, true): break
            }
        }
        self = .object(pairs)
    }

    // MARK: Writing

    /// Two-space indented, like the files Claude Code writes.
    func formatted(indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent + 1), end = String(repeating: "  ", count: indent)
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n
        case .string(let s): return Self.quoted(s)
        case .array(let items):
            if items.isEmpty { return "[]" }
            return "[\n" + items.map { pad + $0.formatted(indent: indent + 1) }.joined(separator: ",\n") + "\n\(end)]"
        case .object(let pairs):
            if pairs.isEmpty { return "{}" }
            return "{\n" + pairs.map { pad + Self.quoted($0.key) + ": " + $0.value.formatted(indent: indent + 1) }
                .joined(separator: ",\n") + "\n\(end)}"
        }
    }

    private static func quoted(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case let c where c.value < 0x20: out += String(format: "\\u%04x", c.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    // MARK: Parsing

    struct ParseError: LocalizedError {
        let message: String
        let line: Int
        var errorDescription: String? { "Line \(line): \(message)" }
    }

    static func parse(_ text: String) throws -> OrderedJSON {
        var parser = Parser(bytes: Array(text.utf8))
        parser.skipSpace()
        let value = try parser.value()
        parser.skipSpace()
        guard parser.index == parser.bytes.count else { throw parser.error("Unexpected text after the end") }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        func error(_ message: String) -> ParseError {
            ParseError(message: message, line: bytes[..<min(index, bytes.count)].count { $0 == 0x0A } + 1)
        }

        mutating func skipSpace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func expect(_ literal: String, _ value: OrderedJSON) throws -> OrderedJSON {
            let word = Array(literal.utf8)
            guard bytes.count - index >= word.count, Array(bytes[index..<index + word.count]) == word else {
                throw error("Unexpected character")
            }
            index += word.count
            return value
        }

        mutating func value() throws -> OrderedJSON {
            guard index < bytes.count else { throw error("Unexpected end") }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try object()
            case UInt8(ascii: "["): return try array()
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): return try expect("true", .bool(true))
            case UInt8(ascii: "f"): return try expect("false", .bool(false))
            case UInt8(ascii: "n"): return try expect("null", .null)
            default: return try number()
            }
        }

        mutating func object() throws -> OrderedJSON {
            index += 1
            var pairs: [(key: String, value: OrderedJSON)] = []
            skipSpace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(pairs) }
            while true {
                skipSpace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw error("Expected a quoted key") }
                let key = try string()
                skipSpace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw error("Expected “:” after “\(key)”") }
                index += 1
                skipSpace()
                pairs.append((key, try value()))
                skipSpace()
                guard index < bytes.count else { throw error("Missing “}”") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(pairs) }
                throw error("Expected “,” or “}”")
            }
        }

        mutating func array() throws -> OrderedJSON {
            index += 1
            var items: [OrderedJSON] = []
            skipSpace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
            while true {
                skipSpace()
                items.append(try value())
                skipSpace()
                guard index < bytes.count else { throw error("Missing “]”") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                throw error("Expected “,” or “]”")
            }
        }

        mutating func string() throws -> String {
            index += 1
            var out: [UInt8] = []
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                switch byte {
                case UInt8(ascii: "\""):
                    return String(decoding: out, as: UTF8.self)
                case UInt8(ascii: "\\"):
                    guard index < bytes.count else { throw error("Unfinished escape") }
                    let escaped = bytes[index]
                    index += 1
                    switch escaped {
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "u"):
                        var code = try hex4()
                        // A surrogate pair: "😀".
                        if (0xD800..<0xDC00).contains(code), bytes.count - index >= 6,
                           bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                            index += 2
                            let low = try hex4()
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        }
                        out += Array(String(Character(Unicode.Scalar(code) ?? "\u{FFFD}")).utf8)
                    default: out.append(escaped) // \" \\ \/
                    }
                default:
                    out.append(byte)
                }
            }
            throw error("Missing closing quote")
        }

        mutating func hex4() throws -> UInt32 {
            guard bytes.count - index >= 4, let code = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16) else {
                throw error("Bad \\u escape")
            }
            index += 4
            return code
        }

        mutating func number() throws -> OrderedJSON {
            let start = index
            while index < bytes.count, "+-0123456789.eE".utf8.contains(bytes[index]) { index += 1 }
            let text = String(decoding: bytes[start..<index], as: UTF8.self)
            guard !text.isEmpty, Double(text) != nil else { throw error("Unexpected character") }
            return .number(text)
        }
    }
}
