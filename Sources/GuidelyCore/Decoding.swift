import Foundation

/// String coding key usable as a literal: `c.lenient("waitMs", 5000)`.
struct GKey: CodingKey, ExpressibleByStringLiteral {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
    init(stringLiteral value: String) { self.stringValue = value }
    init(_ value: String) { self.stringValue = value }
}

extension KeyedDecodingContainer where Key == GKey {
    /// Decodes `key`, falling back to `def` when missing, null or malformed.
    func lenient<T: Decodable>(_ key: String, _ def: T) -> T {
        (try? decodeIfPresent(T.self, forKey: GKey(key))) ?? def
    }

    /// Optional value; malformed → nil.
    func optional<T: Decodable>(_ key: String) -> T? {
        (try? decodeIfPresent(T.self, forKey: GKey(key))) ?? nil
    }

    func required<T: Decodable>(_ key: String) throws -> T {
        try decode(T.self, forKey: GKey(key))
    }

    /// Array where malformed elements are skipped instead of failing the whole array.
    func lossy<T: Decodable>(_ key: String) -> [T] {
        guard var arr = try? nestedUnkeyedContainer(forKey: GKey(key)) else { return [] }
        var out: [T] = []
        while !arr.isAtEnd {
            if let v = try? arr.decode(T.self) { out.append(v) } else if (try? arr.decode(JSONValue.self)) == nil { break }
        }
        return out
    }

    /// String array, skipping non-strings. nil when the key is missing.
    func strings(_ key: String) -> [String]? {
        guard contains(GKey(key)), let arr = try? decode([JSONValue].self, forKey: GKey(key)) else { return nil }
        return arr.compactMap { $0.stringValue }
    }
}

/// A string enum that decodes unknown values to `fallbackCase` instead of failing.
public protocol LenientStringEnum: RawRepresentable, Codable, Sendable, Hashable where RawValue == String {
    static var fallbackCase: Self { get }
}

extension LenientStringEnum {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try? c.decode(String.self)
        self = raw.flatMap { Self(rawValue: $0) } ?? Self.fallbackCase
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}
