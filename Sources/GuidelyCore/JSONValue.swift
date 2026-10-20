import Foundation

/// A JSON-compatible value. Traits, event properties, rule values and survey answers are stored as
/// `JSONValue` so they can be persisted, sent to the API and compared with JavaScript semantics.
public enum JSONValue: Codable, Equatable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if n.isFinite, n == n.rounded(), abs(n) < 9.007_199_254_740_992e15 { try c.encode(Int64(n)) } else if n.isFinite { try c.encode(n) } else { try c.encodeNil() }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    // MARK: Conversion from Swift values

    /// Converts an arbitrary Swift value (String, numbers, Bool, Date, URL, arrays, dictionaries,
    /// `NSNull`, optionals, `JSONValue`) into JSON. Unknown values become their description.
    public init(any value: Any?) {
        guard let value else { self = .null; return }
        if let v = value as? JSONValue { self = v; return }
        // Unwrap Optional<Any> stored inside Any.
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            if let child = mirror.children.first { self = JSONValue(any: child.value) } else { self = .null }
            return
        }
        if let s = value as? String { self = .string(s); return }
        if type(of: value) == Bool.self, let b = value as? Bool { self = .bool(b); return }
        if let n = value as? NSNumber {
            #if canImport(ObjectiveC)
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue); return }
            #endif
            self = .number(n.doubleValue)
            return
        }
        if let i = value as? Int { self = .number(Double(i)); return }
        if let d = value as? Double { self = .number(d); return }
        if let f = value as? Float { self = .number(Double(f)); return }
        if let d = value as? Date { self = .string(ISODate.format(d)); return }
        if let u = value as? URL { self = .string(u.absoluteString); return }
        if value is NSNull { self = .null; return }
        if let dict = value as? [String: Any] { self = .object(dict.mapValues { JSONValue(any: $0) }); return }
        if let dict = value as? [String: Any?] { self = .object(dict.mapValues { JSONValue(any: $0) }); return }
        if let arr = value as? [Any] { self = .array(arr.map { JSONValue(any: $0) }); return }
        if let arr = value as? [Any?] { self = .array(arr.map { JSONValue(any: $0) }); return }
        self = .string(String(describing: value))
    }

    public static func object(from dict: [String: Any]?) -> [String: JSONValue] {
        guard let dict else { return [:] }
        return dict.mapValues { JSONValue(any: $0) }
    }

    // MARK: Accessors

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var numberValue: Double? { if case .number(let n) = self { return n }; return nil }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    public var isNull: Bool { if case .null = self { return true }; return false }

    /// Plain Swift value (`String`, `Double`, `Bool`, `[Any]`, `[String: Any]`, `NSNull`).
    public var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let a): return a.map { $0.anyValue }
        case .object(let o): return o.mapValues { $0.anyValue }
        }
    }

    /// JavaScript `String(value)`.
    public var jsString: String {
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return JSNumber.toString(n)
        case .string(let s): return s
        case .array(let a): return a.map { $0.isNull ? "" : $0.jsString }.joined(separator: ",")
        case .object: return "[object Object]"
        }
    }

    /// Compact JSON text (`JSON.stringify`).
    public var jsonString: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(self), let s = String(data: data, encoding: .utf8) else { return "null" }
        return s
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral, ExpressibleByNilLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(nilLiteral: ()) { self = .null }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(Dictionary(elements, uniquingKeysWith: { _, b in b })) }
}

/// JavaScript number semantics (`String(n)` and `Number(string)`).
public enum JSNumber {
    /// `Number.prototype.toString()` for a double.
    public static func toString(_ d: Double) -> String {
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d < 0 ? "-Infinity" : "Infinity" }
        if d == 0 { return "0" }
        if d == d.rounded(), abs(d) < 1e21, abs(d) < 9.2e18 { return String(Int64(d)) }
        // Shortest round-trip digits from Swift, re-formatted with the ECMAScript rules.
        let negative = d < 0
        var desc = "\(abs(d))"
        var exp = 0
        if let eIdx = desc.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            exp = Int(desc[desc.index(after: eIdx)...]) ?? 0
            desc = String(desc[..<eIdx])
        }
        var intPart = desc
        var fracPart = ""
        if let dot = desc.firstIndex(of: ".") {
            intPart = String(desc[..<dot])
            fracPart = String(desc[desc.index(after: dot)...])
        }
        var digits = intPart + fracPart
        var pointPos = intPart.count + exp // position of the decimal point within `digits`
        // Strip leading zeros.
        while digits.hasPrefix("0") && digits.count > 1 { digits.removeFirst(); pointPos -= 1 }
        // Strip trailing zeros.
        while digits.hasSuffix("0") && digits.count > 1 { digits.removeLast() }
        let k = digits.count
        let n = pointPos
        var out: String
        if k <= n && n <= 21 {
            out = digits + String(repeating: "0", count: n - k)
        } else if 0 < n && n <= 21 {
            let idx = digits.index(digits.startIndex, offsetBy: n)
            out = String(digits[..<idx]) + "." + String(digits[idx...])
        } else if -6 < n && n <= 0 {
            out = "0." + String(repeating: "0", count: -n) + digits
        } else {
            let e = n - 1
            let first = String(digits.prefix(1))
            let rest = String(digits.dropFirst())
            out = first + (rest.isEmpty ? "" : "." + rest) + "e" + (e >= 0 ? "+" : "-") + String(abs(e))
        }
        return negative ? "-" + out : out
    }

    /// `Number(string)`; returns nil for NaN.
    public static func parse(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return 0 }
        switch t {
        case "Infinity", "+Infinity": return .infinity
        case "-Infinity": return -.infinity
        default: break
        }
        let lower = t.lowercased()
        for (prefix, radix) in [("0x", 16), ("0o", 8), ("0b", 2)] where lower.hasPrefix(prefix) {
            let body = String(lower.dropFirst(2))
            guard !body.isEmpty, let v = UInt64(body, radix: radix) else { return nil }
            return Double(v)
        }
        guard t.range(of: #"^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$"#, options: .regularExpression) != nil else { return nil }
        return Double(t)
    }
}
