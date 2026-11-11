import Foundation

/// 可跨 actor 传递的 JSON 树，替代 Go 版的 `json.RawMessage`。
/// 不用 `NSDictionary`/`Any`：Swift 6 严格并发下它们不是 Sendable。
/// 整数与浮点分开存，避免大体积种子（size 可达 TB 级）经 Double 丢精度。
public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public var objectValue: [String: JSONValue]? {
        if case .object(let v) = self { v } else { nil }
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let v) = self { v } else { nil }
    }

    public var stringValue: String? {
        if case .string(let v) = self { v } else { nil }
    }

    public var intValue: Int64? {
        switch self {
        case .int(let v): v
        case .double(let v): Int64(v)
        default: nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .int(let v): Double(v)
        case .double(let v): v
        default: nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let v) = self { v } else { nil }
    }

    /// 把任意 JSON 值重新解码成模型。增量合并后只对变更的条目调用，不是全表。
    public func decoded<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int64.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "无法识别的 JSON 值")
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}