import Foundation

/// A tiny, Sendable JSON value for reading Claude Code's stream-json output.
nonisolated enum JSON: Sendable, Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    /// JSONSerialization is several times faster than decoding this enum with JSONDecoder,
    /// which matters for stream events and multi-megabyte transcripts.
    static func parse(_ data: Data) -> JSON? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return JSON(any: object)
    }

    private init(any: Any) {
        switch any {
        case let s as String: self = .string(s)
        case let n as NSNumber:
            self = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
        case let a as [Any]: self = .array(a.map(JSON.init(any:)))
        case let o as [String: Any]: self = .object(o.mapValues(JSON.init(any:)))
        default: self = .null
        }
    }

    subscript(key: String) -> JSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var array: [JSON]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var bool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var pretty: String {
        if case .string(let s) = self { return s }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Flattens a tool_result `content` (a string, or an array of text blocks).
    var flattenedText: String {
        switch self {
        case .string(let s): return s
        case .array(let items): return items.compactMap { $0["text"]?.string }.joined(separator: "\n")
        default: return ""
        }
    }
}
