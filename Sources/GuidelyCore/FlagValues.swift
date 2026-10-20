import CryptoKit
import Foundation

// Value conversions and hashing shared by the feature-flag evaluator
// (docs/feature-flags-spec.md §3.2–3.4). Port of `packages/flags/src/{values,hash}.ts`.
// Pure and thread-safe.

/// Hashing used by flag rollouts, splits, experiments and the confidential (hashed) operators.
public enum FlagHash {
    /// 32-bit FNV-1a over bytes.
    public static func fnv1a32<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var h: UInt32 = 0x811C_9DC5
        for b in bytes {
            h ^= UInt32(b)
            h = h &* 0x0100_0193
        }
        return h
    }

    /// Deterministic bucket in `[0, 1)` with 4 decimals (GrowthBook hash v2 for ASCII input):
    /// `(fnv1a32(utf8(decimal(fnv1a32(utf8(seed + value))))) mod 10000) / 10000`.
    public static func bucket(seed: String, value: String) -> Double {
        let inner = fnv1a32((seed + value).utf8)
        return Double(fnv1a32(String(inner).utf8) % 10000) / 10000
    }

    /// Lowercase hex SHA-256 of the UTF-8 bytes of `input`.
    public static func sha256Hex(_ input: String) -> String { sha256Hex(bytes: Array(input.utf8)) }

    public static func sha256Hex(bytes: [UInt8]) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// `H(x)` for the hashed operators: SHA-256 of `salt + x`.
    public static func confidential(salt: String, _ value: String) -> String { sha256Hex(bytes: Array(salt.utf8) + Array(value.utf8)) }

    static func confidential(salt: String, bytes: ArraySlice<UInt8>) -> String { sha256Hex(bytes: Array(salt.utf8) + Array(bytes)) }

    /// Comparison value for the hashed prefix/suffix operators: `"<byteLength>_<H(part)>"`.
    public static func confidentialAffix(salt: String, _ part: String) -> String { "\(part.utf8.count)_\(confidential(salt: salt, part))" }
}

/// A parsed SemVer 2.0 version (`v` prefix and missing minor/patch allowed; build metadata ignored).
public struct FlagSemVer: Sendable, Hashable, Comparable {
    public var major: Double
    public var minor: Double
    public var patch: Double
    public var prerelease: [String]

    /// Parses a version string (or the text form of a number). nil when invalid.
    public init?(_ value: JSONValue) {
        let s: String
        switch value {
        case .number: guard let t = FlagValues.text(value) else { return nil }; s = t
        case .string(let str): s = FlagValues.jsTrim(str)
        default: return nil
        }
        self.init(parsing: s)
    }

    public init?(_ string: String) { self.init(parsing: FlagValues.jsTrim(string)) }

    private init?(parsing input: String) {
        var s = Substring(input)
        if s.first == "v" || s.first == "V" { s = s.dropFirst() }
        if let plus = s.firstIndex(of: "+") {
            guard Self.validIdentifiers(s[s.index(after: plus)...]) else { return nil }
            s = s[..<plus]
        }
        var pre: [String] = []
        if let dash = s.firstIndex(of: "-") {
            let p = s[s.index(after: dash)...]
            guard Self.validIdentifiers(p) else { return nil }
            pre = p.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            s = s[..<dash]
        }
        let core = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(core.count), core.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 } }) else { return nil }
        let nums = core.map { Double(String($0)) ?? 0 }
        major = nums[0]
        minor = nums.count > 1 ? nums[1] : 0
        patch = nums.count > 2 ? nums[2] : 0
        prerelease = pre
    }

    /// Dot-separated non-empty `[0-9A-Za-z-]+` identifiers.
    private static func validIdentifiers(_ s: Substring) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { p in
            !p.isEmpty && p.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D }
        }
    }

    /// SemVer 2.0 precedence: -1, 0 or 1.
    public static func compare(_ a: FlagSemVer, _ b: FlagSemVer) -> Int {
        func cmp(_ x: Double, _ y: Double) -> Int { x < y ? -1 : x > y ? 1 : 0 }
        let c = [cmp(a.major, b.major), cmp(a.minor, b.minor), cmp(a.patch, b.patch)].first { $0 != 0 } ?? 0
        if c != 0 { return c }
        // A release outranks its pre-releases.
        if a.prerelease.isEmpty || b.prerelease.isEmpty { return !a.prerelease.isEmpty ? -1 : !b.prerelease.isEmpty ? 1 : 0 }
        for i in 0..<max(a.prerelease.count, b.prerelease.count) {
            guard i < a.prerelease.count else { return -1 }
            guard i < b.prerelease.count else { return 1 }
            let x = a.prerelease[i], y = b.prerelease[i]
            let xn = x.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }, yn = y.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
            if xn && yn {
                let d = cmp(Double(x) ?? 0, Double(y) ?? 0)
                if d != 0 { return d }
            } else if xn { return -1 } else if yn { return 1 } else if !FlagValues.same(x, y) { return Array(x.utf8).lexicographicallyPrecedes(Array(y.utf8)) ? -1 : 1 }
        }
        return 0
    }

    public static func < (a: FlagSemVer, b: FlagSemVer) -> Bool { compare(a, b) < 0 }
    public static func == (a: FlagSemVer, b: FlagSemVer) -> Bool { compare(a, b) == 0 }
    public func hash(into hasher: inout Hasher) { hasher.combine(major); hasher.combine(minor); hasher.combine(patch) }
}

/// Conversions with the JavaScript semantics of the reference evaluator.
public enum FlagValues {
    /// Text form (§3.2): strings as-is, `true` / `false`, integral numbers without a decimal point,
    /// other numbers in the shortest round-trip (ECMAScript) form. nil for null, arrays, objects.
    public static func text(_ v: JSONValue) -> String? {
        switch v {
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n.isFinite ? JSNumber.toString(n) : nil
        default: return nil
        }
    }

    /// Numbers, or numeric strings (`"42"`, `" 3.5 "`, `"1e3"`). Booleans do not convert.
    public static func number(_ v: JSONValue?) -> Double? {
        switch v {
        case .number(let n)?: return n.isFinite ? n : nil
        case .string(let s)?:
            let t = jsTrim(s)
            guard isDecimalLiteral(t) else { return nil }
            var norm = t
            if norm.hasSuffix(".") { norm += "0" }
            if let dot = norm.firstIndex(of: "."), dot == norm.startIndex || !(norm[norm.index(before: dot)].isNumber) {
                norm.insert("0", at: dot)
            }
            if let e = norm.firstIndex(where: { $0 == "e" || $0 == "E" }), e > norm.startIndex, norm[norm.index(before: e)] == "." {
                norm.insert("0", at: e)
            }
            guard let d = Double(norm), d.isFinite else { return nil }
            return d
        default: return nil
        }
    }

    /// `^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$` (ASCII digits).
    static func isDecimalLiteral(_ s: String) -> Bool {
        let b = Array(s.utf8)
        var i = 0
        func digits() -> Int { let start = i; while i < b.count, b[i] >= 0x30, b[i] <= 0x39 { i += 1 }; return i - start }
        if i < b.count, b[i] == 0x2B || b[i] == 0x2D { i += 1 }
        let intDigits = digits()
        if intDigits > 0 {
            if i < b.count, b[i] == 0x2E { i += 1; _ = digits() }
        } else {
            guard i < b.count, b[i] == 0x2E else { return false }
            i += 1
            guard digits() > 0 else { return false }
        }
        if i < b.count, b[i] == 0x65 || b[i] == 0x45 {
            i += 1
            if i < b.count, b[i] == 0x2B || b[i] == 0x2D { i += 1 }
            guard digits() > 0 else { return false }
        }
        return i == b.count
    }

    /// Elements of an array attribute, or of a string holding a JSON array.
    public static func array(_ v: JSONValue) -> [JSONValue]? {
        switch v {
        case .array(let a): return a
        case .string(let s):
            let t = jsTrim(s)
            guard t.hasPrefix("["), let data = t.data(using: .utf8), let parsed = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
            return parsed.arrayValue
        default: return nil
        }
    }

    private static let isoPattern = try! NSRegularExpression(
        pattern: #"^([0-9]{4})-([0-9]{2})-([0-9]{2})(?:[Tt ]([0-9]{2}):([0-9]{2})(?::([0-9]{2})(?:\.([0-9]+))?)?(Z|z|[+-][0-9]{2}:[0-9]{2})?)?$"#
    )

    /// Milliseconds since the epoch: numbers are Unix seconds, strings ISO 8601 (`YYYY-MM-DD`, or
    /// `YYYY-MM-DDTHH:MM[:SS[.fraction]][Z|±HH:MM]`, no offset = UTC).
    public static func instantMs(_ v: JSONValue?) -> Double? {
        switch v {
        case .number(let n)?: return n.isFinite ? n * 1000 : nil
        case .string(let s)?: return parseISOms(s)
        default: return nil
        }
    }

    /// `Date` → milliseconds; other values per `instantMs(_:)`.
    public static func instantMs(any value: Any?) -> Double? {
        if let d = value as? Date { return d.timeIntervalSince1970 * 1000 }
        return instantMs(JSONValue(any: value))
    }

    static func parseISOms(_ input: String) -> Double? {
        let s = jsTrim(input)
        let ns = s as NSString
        guard let m = isoPattern.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func g(_ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        // Literal proleptic Gregorian years; out-of-range fields are invalid, never rolled over.
        let year = Int(g(1)!)!
        let month = Int(g(2)!)!, day = Int(g(3)!)!
        let hour = Int(g(4) ?? "0")!, minute = Int(g(5) ?? "0")!, second = Int(g(6) ?? "0")!
        guard (1...12).contains(month), day >= 1, day <= daysInMonth(year, month), hour <= 23, minute <= 59, second <= 59 else { return nil }
        let days = daysFromCivil(year, month, day)
        var ms = Double(days) * 86_400_000 + Double(hour * 3_600_000 + minute * 60_000 + second * 1000)
        if let frac = g(7) { ms += ((Double("0.\(frac)") ?? 0) * 1000).rounded(.down) }
        if let tz = g(8), tz != "Z", tz != "z" {
            let b = Array(tz)
            let sign: Double = b[0] == "-" ? -1 : 1
            let hh = Double(String(b[1...2]))!, mm = Double(String(b[4...5]))!
            ms -= sign * (hh * 60 + mm) * 60_000
        }
        return ms
    }

    static func daysInMonth(_ year: Int, _ month: Int) -> Int {
        if month == 2 { return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28 }
        return [4, 6, 9, 11].contains(month) ? 30 : 31
    }

    /// Days since 1970-01-01 of a proleptic Gregorian date (Howard Hinnant's algorithm).
    static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int64 {
        let y = Int64(month <= 2 ? year - 1 : year)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let m = Int64(month)
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + Int64(day) - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    /// JSON deep equality; numbers compare numerically, object keys unordered, strings by code units.
    public static func jsonEquals(_ a: JSONValue, _ b: JSONValue) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case (.bool(let x), .bool(let y)): return x == y
        case (.number(let x), .number(let y)): return x == y
        case (.string(let x), .string(let y)): return same(x, y)
        case (.array(let x), .array(let y)): return x.count == y.count && zip(x, y).allSatisfy { jsonEquals($0, $1) }
        case (.object(let x), .object(let y)):
            return x.count == y.count && x.allSatisfy { k, v in y[k].map { jsonEquals(v, $0) } ?? false }
        default: return false
        }
    }

    /// `isOn`: anything except null, false, 0 and "".
    public static func isOn(_ v: JSONValue?) -> Bool {
        switch v {
        case nil, .null?: return false
        case .bool(let b)?: return b
        case .number(let n)?: return n != 0 && !n.isNaN
        case .string(let s)?: return !s.isEmpty
        default: return true
        }
    }

    public static func jsonType(_ v: JSONValue) -> String? {
        switch v {
        case .null: return nil
        case .array: return "array"
        case .object: return "object"
        case .string: return "string"
        case .number: return "number"
        case .bool: return "boolean"
        }
    }

    /// JavaScript `Number(v) || 0` for weights and versions in hand-edited payloads.
    static func coerceNumber(_ v: JSONValue?) -> Double {
        switch v {
        case .number(let n)?: return n.isFinite ? n : 0
        case .string(let s)?: let d = JSNumber.parse(s) ?? 0; return d.isFinite ? d : 0
        case .bool(let b)?: return b ? 1 : 0
        default: return 0
        }
    }

    /// Exact code-unit equality (Swift `==` would apply Unicode canonical equivalence; JavaScript does not).
    @inline(__always)
    static func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

    static func hasPrefix(_ s: String, _ p: String) -> Bool { s.utf8.starts(with: p.utf8) }

    static func hasSuffix(_ s: String, _ p: String) -> Bool { s.utf8.reversed().starts(with: p.utf8.reversed()) }

    static func contains(_ s: String, _ needle: String) -> Bool {
        let h = Array(s.utf8), n = Array(needle.utf8)
        if n.isEmpty { return true }
        if n.count > h.count { return false }
        outer: for i in 0...(h.count - n.count) {
            for j in 0..<n.count where h[i + j] != n[j] { continue outer }
            return true
        }
        return false
    }

    /// `String.prototype.trim()`: ECMAScript white space and line terminators.
    static func jsTrim(_ s: String) -> String {
        func ws(_ u: Unicode.Scalar) -> Bool {
            switch u.value {
            case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: return true
            default: return false
            }
        }
        let scalars = s.unicodeScalars
        guard let first = scalars.firstIndex(where: { !ws($0) }) else { return "" }
        let last = scalars.lastIndex(where: { !ws($0) })!
        return String(scalars[first...last])
    }

    /// Unicode, locale-independent lowercasing (`toLowerCase`).
    static func lower(_ s: String) -> String { s.lowercased() }
}
