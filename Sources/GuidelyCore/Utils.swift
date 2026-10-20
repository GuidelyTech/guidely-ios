import Foundation

/// ISO 8601 helpers matching JavaScript `Date#toISOString()` / `Date.parse`.
public enum ISODate {
    private static let lock = NSLock()
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// `2026-06-15T10:30:00.000Z`
    public static func format(_ date: Date) -> String {
        lock.lock(); defer { lock.unlock() }
        return fractional.string(from: date)
    }

    /// Parses ISO 8601 date-times (with or without fractional seconds / offset) and dates
    /// (`2026-02-01`, UTC). Date-times without an offset are local time, like `Date.parse`.
    public static func parse(_ string: String) -> Date? {
        let s = string.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }
        lock.lock()
        let direct = fractional.date(from: s) ?? plain.date(from: s)
        lock.unlock()
        if let direct { return direct }
        let pattern = #"^([+-]?\d{4,6})(?:-(\d{2})(?:-(\d{2}))?)?(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:[.,](\d{1,9}))?)?\s*(Z|[+-]\d{2}:?\d{2})?)?$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        func group(_ i: Int) -> String? {
            let r = m.range(at: i)
            guard r.location != NSNotFound, let rr = Range(r, in: s) else { return nil }
            return String(s[rr])
        }
        var comps = DateComponents()
        comps.year = Int(group(1) ?? "")
        comps.month = Int(group(2) ?? "1") ?? 1
        comps.day = Int(group(3) ?? "1") ?? 1
        let hasTime = group(4) != nil
        comps.hour = Int(group(4) ?? "0") ?? 0
        comps.minute = Int(group(5) ?? "0") ?? 0
        comps.second = Int(group(6) ?? "0") ?? 0
        if let frac = group(7) {
            let padded = (frac + "000000000").prefix(9)
            comps.nanosecond = Int(padded) ?? 0
        }
        var cal = Calendar(identifier: .gregorian)
        if let tz = group(8) {
            if tz == "Z" { cal.timeZone = TimeZone(identifier: "UTC")! } else {
                let sign = tz.hasPrefix("-") ? -1 : 1
                let digits = tz.dropFirst().replacingOccurrences(of: ":", with: "")
                let h = Int(digits.prefix(2)) ?? 0
                let mm = Int(digits.suffix(2)) ?? 0
                cal.timeZone = TimeZone(secondsFromGMT: sign * (h * 3600 + mm * 60)) ?? TimeZone(identifier: "UTC")!
            }
        } else {
            cal.timeZone = hasTime ? TimeZone.current : TimeZone(identifier: "UTC")!
        }
        return cal.date(from: comps)
    }

    /// Milliseconds since the epoch, or nil.
    public static func parseMs(_ string: String) -> Double? {
        parse(string).map { ($0.timeIntervalSince1970 * 1000).rounded() }
    }
}

/// Small helpers ported from `packages/shared/src/{utils,platform,events-util}.ts`.
public enum GuidelyUtils {
    /// FNV-1a 32-bit hash over the UTF-16 code units of `input`.
    public static func fnv1a(_ input: String) -> UInt32 {
        var h: UInt32 = 0x811c_9dc5
        for unit in input.utf16 {
            h ^= UInt32(unit)
            h = h &* 0x0100_0193
        }
        return h
    }

    /// Deterministic 0-99 bucket for percentage rollouts.
    public static func rolloutBucket(subject: String, salt: String) -> Int {
        Int(fnv1a("\(salt):\(subject)") % 100)
    }

    private static let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")

    /// URL-safe random id of `size` characters from `[0-9a-zA-Z]`.
    public static func randomId(_ size: Int = 16) -> String {
        var g = SystemRandomNumberGenerator()
        return String((0..<size).map { _ in alphabet[Int(UInt8.random(in: 0...255, using: &g)) % alphabet.count] })
    }

    // MARK: URL patterns

    /// Glob-style pattern match: `*` matches any chars except `/`, `**` matches anything. Anchored, case-sensitive.
    public static func matchUrlPattern(_ pattern: String, _ url: String) -> Bool {
        if pattern.isEmpty { return true }
        if pattern == url { return true }
        guard let re = globRegex(pattern) else { return false }
        if regexTest(re, url) { return true }
        return regexTest(re, stripOrigin(url))
    }

    private static let specials: Set<Character> = [".", "+", "?", "^", "$", "{", "}", "(", ")", "|", "[", "]", "\\"]

    static func globRegex(_ pattern: String) -> NSRegularExpression? {
        var out = "^"
        let chars = Array(pattern)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "*" {
                if i + 1 < chars.count, chars[i + 1] == "*" { out += ".*"; i += 2; continue }
                out += "[^/]*"
            } else if specials.contains(c) {
                out += "\\" + String(c)
            } else {
                out += String(c)
            }
            i += 1
        }
        out += "$"
        return try? NSRegularExpression(pattern: out, options: [])
    }

    static func regexTest(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, options: [], range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// `new URL(url)` → pathname + search + hash; non-absolute input is returned unchanged.
    public static func stripOrigin(_ url: String) -> String {
        guard let schemeEnd = url.range(of: "://"), url[..<schemeEnd.lowerBound].allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) }), !url[..<schemeEnd.lowerBound].isEmpty else { return url }
        let rest = url[schemeEnd.upperBound...]
        if let slash = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            let tail = String(rest[slash...])
            return tail.hasPrefix("/") ? tail : "/" + tail
        }
        return "/"
    }

    /// `urlMatches` from guide-runtime: a pattern without `?`/`#` also matches the path with any query removed.
    public static func urlMatches(_ pattern: String?, _ url: String) -> Bool {
        guard let pattern, !pattern.isEmpty else { return true }
        if matchUrlPattern(pattern, url) { return true }
        if !pattern.contains("?") && !pattern.contains("#") {
            var path = stripOrigin(url)
            if let q = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = String(path[..<q]) }
            if path.isEmpty || !path.hasPrefix("/") { path = "/" + path }
            if matchUrlPattern(pattern, path) { return true }
            if matchUrlPattern(pattern, "http://localhost" + path) { return true }
        }
        return false
    }

    /// Case-insensitive regex with a 200-character cap (ReDoS guard). Invalid → nil.
    public static func safeRegExp(_ source: String) -> NSRegularExpression? {
        if source.isEmpty || source.utf16.count > 200 { return nil }
        return try? NSRegularExpression(pattern: source, options: [.caseInsensitive])
    }

    /// Safe nested getter: `getPath(obj, "account.plan")`.
    public static func getPath(_ obj: [String: JSONValue], _ path: String) -> JSONValue? {
        if path.isEmpty { return .object(obj) }
        var cur: JSONValue? = .object(obj)
        for part in path.split(separator: ".", omittingEmptySubsequences: false).map(String.init) {
            guard let c = cur else { return nil }
            switch c {
            case .null: return nil
            case .object(let o): cur = o[part]
            case .array(let a):
                if part == "length" { cur = .number(Double(a.count)) } else if let i = Int(part), i >= 0, i < a.count { cur = a[i] } else { cur = nil }
            case .string(let s):
                if part == "length" { cur = .number(Double(s.utf16.count)) } else { cur = nil }
            default: cur = nil
            }
        }
        return cur
    }

    // MARK: Platform helpers

    /// Platforms a guide config targets (missing field → web only).
    public static func supportsPlatform(_ platforms: [String]?, _ platform: String) -> Bool {
        (platforms ?? ["web"]).contains(platform)
    }

    private static let bareId = try! NSRegularExpression(pattern: #"^[A-Za-z0-9_][A-Za-z0-9_\-:.]*$"#)
    private static let hashId = try! NSRegularExpression(pattern: #"^#([A-Za-z0-9_][A-Za-z0-9_\-:.]*)$"#)
    private static let attrId = try! NSRegularExpression(pattern: #"^(?:[a-z][a-z0-9]*)?\[\s*data-(?:guidely-id|testid|tour)\s*=\s*(["']?)([^"'\]]+)\1\s*\]$"#, options: [.caseInsensitive])

    /// Extracts a Guidely target id from a bare id, `#id` or `[data-guidely-id="id"]` (also `data-testid` / `data-tour`).
    public static func guidelyIdFromSelector(_ value: String?) -> String? {
        let v = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty { return nil }
        let range = NSRange(v.startIndex..., in: v)
        if bareId.firstMatch(in: v, range: range) != nil { return v }
        if let m = hashId.firstMatch(in: v, range: range), let r = Range(m.range(at: 1), in: v) { return String(v[r]) }
        if let m = attrId.firstMatch(in: v, range: range), let r = Range(m.range(at: 2), in: v) {
            return String(v[r]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// `/<Screen>` (no double slash; empty → `/`).
    public static func screenPath(_ screen: String?) -> String {
        let s = (screen ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return "/" }
        return s.hasPrefix("/") ? s : "/" + s
    }

    /// Compares dotted versions numerically (`2.10.0` > `2.9.3`). nil when either side is empty.
    public static func compareVersions(_ a: JSONValue?, _ b: JSONValue?) -> Int? {
        func norm(_ v: JSONValue?) -> String {
            guard let v, !v.isNull else { return "" }
            var s = v.jsString.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.first == "v" || s.first == "V" { s.removeFirst() }
            return s
        }
        let sa = norm(a), sb = norm(b)
        if sa.isEmpty || sb.isEmpty { return nil }
        let split: (String) -> [String] = { $0.split(omittingEmptySubsequences: false, whereSeparator: { ".+-".contains($0) }).map(String.init) }
        let pa = split(sa), pb = split(sb)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : "0"
            let y = i < pb.count ? pb[i] : "0"
            let isNum: (String) -> Bool = { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }
            if isNum(x), isNum(y), let nx = Double(x), let ny = Double(y) {
                if nx != ny { return nx < ny ? -1 : 1 }
            } else if x != y {
                return utf16Less(x, y) ? -1 : 1
            }
        }
        return 0
    }

    public static func compareVersions(_ a: String?, _ b: String?) -> Int? {
        compareVersions(a.map { JSONValue.string($0) }, b.map { JSONValue.string($0) })
    }

    static func utf16Less(_ a: String, _ b: String) -> Bool {
        let ua = Array(a.utf16), ub = Array(b.utf16)
        for i in 0..<min(ua.count, ub.count) where ua[i] != ub[i] { return ua[i] < ub[i] }
        return ua.count < ub.count
    }

    // MARK: Properties

    /// Reserved property names stripped from `properties` (sensitive data).
    public static let sensitivePropertyPattern = try! NSRegularExpression(pattern: "(password|passwd|secret|token|credit|card|cvv|ssn|iban)", options: [.caseInsensitive])
    public static let maxPropertyBytes = 8 * 1024

    public static func isSensitiveKey(_ key: String) -> Bool {
        regexTest(sensitivePropertyPattern, key)
    }

    /// Drops sensitive keys, truncates keys (100) and string values (1000), caps total size at 8 KB.
    /// Keys are visited in sorted order so the result is deterministic.
    public static func sanitizeProperties(_ props: [String: JSONValue]?) -> [String: JSONValue] {
        guard let props else { return [:] }
        var out: [String: JSONValue] = [:]
        var size = 0
        for k in props.keys.sorted() {
            guard let v = props[k] else { continue }
            if isSensitiveKey(k) { continue }
            let str: String
            if case .string(let s) = v { str = s } else { str = v.jsonString }
            size += k.utf16.count + str.utf16.count
            if size > maxPropertyBytes { break }
            let key = String(k.prefix(100))
            if case .string(let s) = v { out[key] = .string(String(s.prefix(1000))) } else { out[key] = v }
        }
        return out
    }
}
