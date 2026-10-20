import Foundation

// Dev overrides (docs/feature-flags-spec.md §4.1): flag values pinned from outside the code, so CI
// and UI tests can switch flags without editing the app. Read once, when a flags client is created,
// from the process environment — XCUITest `app.launchEnvironment` and
// `SIMCTL_CHILD_GUIDELY_FLAG_OVERRIDES=… xcrun simctl launch` both land there. Port of
// `packages/flags/src/dev-overrides.ts` and `parseOverrides` in `packages/flags/src/util.ts`.

/// Overrides text, as held by `GUIDELY_FLAG_OVERRIDES` or an overrides file.
public enum FlagOverridesText {
    /// A JSON object (`{"new-checkout":true}`) or a list of `key:value` items separated by commas or
    /// newlines (`new-checkout:true,limit:5,theme:"dark"`), where each value is JSON when it parses
    /// (strictly: `01` and `True` stay text) and text otherwise. `nil` when the text starts with `{`
    /// but is not a JSON object.
    public static func parse(_ text: String) -> [String: JSONValue]? {
        let raw = JSText.trim(text)
        if raw.unicodeScalars.first == "{" {
            guard case .object(let o)? = StrictJSON.parse(raw) else { return nil }
            return o
        }
        // Split on top-level commas and newlines: those inside quotes, arrays or objects belong to the
        // value. Scalars, not Characters: "\r\n" is one Character.
        let s = Array(raw.unicodeScalars)
        var items: [ArraySlice<Unicode.Scalar>] = []
        var depth = 0, quoted = false, start = 0, i = 0
        while i < s.count {
            let c = s[i]
            if quoted {
                if c == "\\" { i += 1 } else if c == "\"" { quoted = false }
            } else if c == "\"" {
                quoted = true
            } else if c == "[" || c == "{" {
                depth += 1
            } else if c == "]" || c == "}" {
                depth = max(0, depth - 1)
            } else if (c == "," || c == "\n") && depth == 0 {
                items.append(s[start..<i])
                start = i + 1
            }
            i += 1
        }
        items.append(s[min(start, s.count)...])
        var out: [String: JSONValue] = [:]
        for item in items {
            guard let sep = item.firstIndex(of: ":"), sep > item.startIndex else { continue }
            let key = JSText.trim(string(item[..<sep]))
            let value = JSText.trim(string(item[(sep + 1)...]))
            if key.isEmpty { continue }
            out[key] = StrictJSON.parse(value) ?? .string(value)
        }
        return out
    }

    private static func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }
}

/// JavaScript string helpers.
enum JSText {
    /// `String.prototype.trim()`: JavaScript WhiteSpace and LineTerminator (differs from
    /// `.whitespacesAndNewlines`, which keeps U+FEFF and strips U+0085).
    static func trim(_ text: String) -> String {
        let s = text.unicodeScalars
        guard let first = s.firstIndex(where: { !isSpace($0) }) else { return "" }
        let last = s.lastIndex(where: { !isSpace($0) })!
        return String(s[first...last])
    }

    static func isSpace(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: return true
        default: return false
        }
    }
}

/// `JSON.parse` semantics on every OS version: strict RFC 8259 grammar (no leading zeros, `NaN`,
/// comments or trailing text), any value at the top level, duplicate keys keep the last value.
/// `nil` when the text is not valid JSON. Not `JSONSerialization` / `JSONDecoder`, whose leniency
/// differs between iOS releases.
enum StrictJSON {
    static func parse(_ text: String) -> JSONValue? {
        var p = Parser(bytes: Array(text.utf8))
        p.skipSpace()
        guard let v = p.value(depth: 0) else { return nil }
        p.skipSpace()
        guard p.i == p.bytes.count else { return nil } // not `? v : nil`: JSONValue is ExpressibleByNilLiteral
        return v
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        var peek: UInt8? { i < bytes.count ? bytes[i] : nil }

        mutating func skipSpace() {
            while let c = peek, c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { i += 1 }
        }

        mutating func literal(_ word: String, _ value: JSONValue) -> JSONValue? {
            let w = Array(word.utf8)
            guard i + w.count <= bytes.count, Array(bytes[i..<(i + w.count)]) == w else { return nil }
            i += w.count
            return value
        }

        mutating func value(depth: Int) -> JSONValue? {
            guard depth < 512, let c = peek else { return nil }
            switch c {
            case UInt8(ascii: "{"): return object(depth: depth)
            case UInt8(ascii: "["): return array(depth: depth)
            case UInt8(ascii: "\""): return string().map(JSONValue.string)
            case UInt8(ascii: "t"): return literal("true", .bool(true))
            case UInt8(ascii: "f"): return literal("false", .bool(false))
            case UInt8(ascii: "n"): return literal("null", .null)
            default: return number()
            }
        }

        mutating func object(depth: Int) -> JSONValue? {
            i += 1
            var out: [String: JSONValue] = [:]
            skipSpace()
            if peek == UInt8(ascii: "}") { i += 1; return .object(out) }
            while true {
                skipSpace()
                guard peek == UInt8(ascii: "\""), let key = string() else { return nil }
                skipSpace()
                guard peek == UInt8(ascii: ":") else { return nil }
                i += 1
                skipSpace()
                guard let v = value(depth: depth + 1) else { return nil }
                out[key] = v
                skipSpace()
                if peek == UInt8(ascii: ",") { i += 1; continue }
                if peek == UInt8(ascii: "}") { i += 1; return .object(out) }
                return nil
            }
        }

        mutating func array(depth: Int) -> JSONValue? {
            i += 1
            var out: [JSONValue] = []
            skipSpace()
            if peek == UInt8(ascii: "]") { i += 1; return .array(out) }
            while true {
                skipSpace()
                guard let v = value(depth: depth + 1) else { return nil }
                out.append(v)
                skipSpace()
                if peek == UInt8(ascii: ",") { i += 1; continue }
                if peek == UInt8(ascii: "]") { i += 1; return .array(out) }
                return nil
            }
        }

        mutating func digits() -> Bool {
            let start = i
            while let c = peek, c >= 0x30 && c <= 0x39 { i += 1 }
            return i > start
        }

        /// `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?`
        mutating func number() -> JSONValue? {
            let start = i
            if peek == UInt8(ascii: "-") { i += 1 }
            if peek == UInt8(ascii: "0") {
                i += 1
            } else if let c = peek, c >= 0x31 && c <= 0x39 {
                _ = digits()
            } else {
                return nil
            }
            if peek == UInt8(ascii: ".") {
                i += 1
                guard digits() else { return nil }
            }
            if peek == UInt8(ascii: "e") || peek == UInt8(ascii: "E") {
                i += 1
                if peek == UInt8(ascii: "+") || peek == UInt8(ascii: "-") { i += 1 }
                guard digits() else { return nil }
            }
            guard let text = String(bytes: bytes[start..<i], encoding: .utf8), let d = Double(text) else { return nil }
            return .number(d)
        }

        mutating func hex4() -> UInt16? {
            guard i + 4 <= bytes.count, let s = String(bytes: bytes[i..<(i + 4)], encoding: .ascii), let v = UInt16(s, radix: 16) else { return nil }
            i += 4
            return v
        }

        mutating func string() -> String? {
            i += 1 // opening quote
            var utf8: [UInt8] = []
            while let c = peek {
                i += 1
                switch c {
                case UInt8(ascii: "\""):
                    return String(decoding: utf8, as: UTF8.self)
                case UInt8(ascii: "\\"):
                    guard let e = peek else { return nil }
                    i += 1
                    switch e {
                    case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): utf8.append(e)
                    case UInt8(ascii: "b"): utf8.append(0x08)
                    case UInt8(ascii: "f"): utf8.append(0x0C)
                    case UInt8(ascii: "n"): utf8.append(0x0A)
                    case UInt8(ascii: "r"): utf8.append(0x0D)
                    case UInt8(ascii: "t"): utf8.append(0x09)
                    case UInt8(ascii: "u"):
                        guard let unit = hex4() else { return nil }
                        var units = [unit]
                        // A high surrogate followed by an escaped low one is one scalar; lone halves become U+FFFD.
                        if UTF16.isLeadSurrogate(unit), bytes.count >= i + 6, bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") {
                            let save = i
                            i += 2
                            if let low = hex4(), UTF16.isTrailSurrogate(low) { units.append(low) } else { i = save }
                        }
                        utf8.append(contentsOf: Array(String(decoding: units, as: UTF16.self).utf8))
                    default: return nil
                    }
                default:
                    if c < 0x20 { return nil } // unescaped control character
                    utf8.append(c)
                }
            }
            return nil // unterminated
        }
    }
}

/// Dev overrides read from the environment (§4.1). Never throws: problems land in `errors`.
struct FlagDevOverrides {
    static let overridesVariable = "GUIDELY_FLAG_OVERRIDES"
    static let fileVariable = "GUIDELY_FLAG_OVERRIDES_FILE"
    static let behaviourVariable = "GUIDELY_FLAG_OVERRIDE_BEHAVIOUR"

    /// Merged values: file, then environment variable (later wins per key).
    var values: [String: JSONValue] = [:]
    /// Replaces the configured `overrideBehaviour` when set.
    var behaviour: FlagOverrideBehaviour?
    /// Where values or the behaviour came from, for the start-up warning.
    var sources: [String] = []
    /// Unreadable or malformed sources (ignored).
    var errors: [String] = []

    static func read(_ environment: [String: String], readFile: (String) throws -> String = { try String(contentsOfFile: $0, encoding: .utf8) }) -> FlagDevOverrides {
        var out = FlagDevOverrides()
        let file = JSText.trim(environment[fileVariable] ?? "")
        if !file.isEmpty {
            do {
                out.merge(try readFile(file), source: "\(fileVariable) (\(file))")
            } catch {
                out.errors.append("Could not read \(fileVariable) (\(file)): \(error.localizedDescription); ignoring it.")
            }
        }
        out.merge(environment[overridesVariable], source: overridesVariable)
        if let raw = environment[behaviourVariable], !JSText.trim(raw).isEmpty {
            if let b = FlagOverrideBehaviour(rawValue: JSText.trim(raw)) {
                out.behaviour = b
                out.sources.append(behaviourVariable)
            } else {
                out.errors.append("\(behaviourVariable) must be localOnly, localOverRemote or remoteOverLocal (got \"\(raw)\"); ignoring it.")
            }
        }
        return out
    }

    private mutating func merge(_ text: String?, source: String) {
        guard let text, !JSText.trim(text).isEmpty else { return }
        guard let parsed = FlagOverridesText.parse(text) else {
            errors.append("\(source) is not a JSON object or a key:value list; ignoring it.")
            return
        }
        if parsed.isEmpty { return }
        for (k, v) in parsed { values[k] = v }
        sources.append(source)
    }
}
