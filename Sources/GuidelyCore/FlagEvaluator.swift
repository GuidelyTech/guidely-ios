import Foundation

/// Pure, synchronous flag evaluation — a port of the reference implementation
/// (`packages/flags/src/evaluate.ts`, docs/feature-flags-spec.md §3). No I/O and thread-safe:
/// give it a payload and attributes, get a result. Never throws; problems come back as reason `ERROR`.
public enum FlagEvaluator {
    static let maxDepth = 32

    /// Evaluates one flag. `now` drives rule schedules and ramps; `stickyBuckets` keeps experiment
    /// assignments stable across config changes.
    public static func evaluate(_ payload: FlagsPayload, key: String, attributes: [String: JSONValue] = [:], now: Date = Date(), stickyBuckets: FlagStickyBucketStore? = nil) -> FlagEvaluationResult {
        let ctx = Context(payload: payload, attributes: attributes, nowMs: now.timeIntervalSince1970 * 1000, sticky: stickyBuckets)
        do {
            return try ctx.evalFlag(key)
        } catch let e as CycleError {
            return FlagEvaluationResult(key: key, reason: .error, errorMessage: e.message)
        } catch {
            return FlagEvaluationResult(key: key, reason: .error, errorMessage: "\(error)")
        }
    }

    /// Evaluates every flag in the payload.
    public static func evaluateAll(_ payload: FlagsPayload, attributes: [String: JSONValue] = [:], now: Date = Date(), stickyBuckets: FlagStickyBucketStore? = nil) -> [String: FlagEvaluationResult] {
        var out: [String: FlagEvaluationResult] = [:]
        for key in payload.flags.keys { out[key] = evaluate(payload, key: key, attributes: attributes, now: now, stickyBuckets: stickyBuckets) }
        return out
    }

    /// Attribute by literal key, then by dot path. `null` counts as missing.
    public static func lookupAttribute(_ attributes: [String: JSONValue], _ name: String) -> JSONValue? {
        // Careful: `JSONValue` is `ExpressibleByNilLiteral`, so `cond ? nil : v` would yield `.some(.null)`.
        if let v = attributes[name] { return v.isNull ? Optional<JSONValue>.none : v }
        guard name.contains(".") else { return nil }
        var cur: JSONValue = .object(attributes)
        for part in name.components(separatedBy: ".") {
            guard case .object(let o) = cur, let next = o[part] else { return nil }
            cur = next
        }
        return cur.isNull ? Optional<JSONValue>.none : cur
    }

    // MARK: - Regex cache

    private static let regexLock = NSLock()
    nonisolated(unsafe) private static var regexCache: [String: NSRegularExpression?] = [:]

    static func regex(_ pattern: String, caseInsensitive: Bool) -> NSRegularExpression? {
        let k = "\(caseInsensitive ? "i" : "-"):\(pattern)"
        regexLock.lock()
        if let cached = regexCache[k] { regexLock.unlock(); return cached }
        regexLock.unlock()
        let re = try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
        regexLock.lock()
        if regexCache.count > 500 { regexCache.removeAll() }
        regexCache[k] = .some(re)
        regexLock.unlock()
        return re
    }

    static func isScheduleActive(start: JSONValue?, end: JSONValue?, nowMs: Double) -> Bool {
        if truthy(start) {
            guard let s = FlagValues.instantMs(start), nowMs >= s else { return false }
        }
        if truthy(end) {
            guard let e = FlagValues.instantMs(end), nowMs < e else { return false }
        }
        return true
    }

    static func clamp01(_ v: JSONValue?) -> Double {
        guard case .number(let n)? = v, n.isFinite else { return 0 }
        return min(1, max(0, n))
    }

    static func effectiveCoverage(_ rule: RuleDef, nowMs: Double) -> Double {
        var coverage = clamp01(rule.coverage)
        var latest = -Double.infinity
        for step in rule.ramp {
            if let at = FlagValues.instantMs(step.at), at <= nowMs, at >= latest {
                latest = at
                coverage = clamp01(step.coverage)
            }
        }
        return coverage
    }
}

struct CycleError: Error { let message: String }

private final class Context {
    let payload: FlagsPayload
    let attributes: [String: JSONValue]
    let nowMs: Double
    let sticky: FlagStickyBucketStore?
    var stack: [String] = []

    init(payload: FlagsPayload, attributes: [String: JSONValue], nowMs: Double, sticky: FlagStickyBucketStore?) {
        self.payload = payload; self.attributes = attributes; self.nowMs = nowMs; self.sticky = sticky
    }

    func enter<T>(_ frame: String, _ fn: () throws -> T) throws -> T {
        if stack.contains(frame) { throw CycleError(message: "Cycle detected: \((stack + [frame]).joined(separator: " → "))") }
        if stack.count >= FlagEvaluator.maxDepth { throw CycleError(message: "Flag references nest deeper than \(FlagEvaluator.maxDepth) levels: \(stack.joined(separator: " → "))") }
        stack.append(frame)
        defer { stack.removeLast() }
        return try fn()
    }

    /// Text form of a hashing attribute, or nil when missing or empty.
    func hashValue(_ name: String) -> String? {
        guard let v = FlagEvaluator.lookupAttribute(attributes, name), let t = FlagValues.text(v), !t.isEmpty else { return nil }
        return t
    }

    // MARK: Attribute conditions

    func textValues(_ values: [JSONValue], _ ci: Bool) -> [String] {
        values.compactMap { FlagValues.text($0).map { ci ? FlagValues.lower($0) : $0 } }
    }

    func affixMatches(_ text: String, _ values: [JSONValue], suffix: Bool) -> Bool {
        let bytes = Array(text.utf8)
        return values.contains { v in
            guard case .string(let s) = v, let sep = s.firstIndex(of: "_"), sep > s.startIndex else { return false }
            guard let n = JSNumber.parse(String(s[..<sep])), n == n.rounded(), n >= 0, n <= Double(bytes.count) else { return false }
            let count = Int(n)
            let part = suffix ? bytes[(bytes.count - count)...] : bytes[..<count]
            return FlagValues.same(FlagHash.confidential(salt: payload.salt, bytes: part), String(s[s.index(after: sep)...]))
        }
    }

    func includesString(_ values: [JSONValue], _ s: String) -> Bool {
        values.contains { if case .string(let v) = $0 { return FlagValues.same(v, s) }; return false }
    }

    func evalAttribute(name: String, op: String, values: [JSONValue], ci: Bool) -> Bool {
        let raw = FlagEvaluator.lookupAttribute(attributes, name)
        if op == "notExists" { return raw == nil }
        guard let raw else { return false }
        switch op {
        case "exists":
            return true
        case "isType":
            guard let t = FlagValues.jsonType(raw), case .string(let want)? = values.first else { return false }
            return t == want
        case "isTrue":
            if case .bool(true) = raw { return true }
            if case .string(let s) = raw { return FlagValues.same(FlagValues.lower(s), "true") }
            return false
        case "isFalse":
            if case .bool(false) = raw { return true }
            if case .string(let s) = raw { return FlagValues.same(FlagValues.lower(s), "false") }
            return false
        case "equals", "notEquals", "in", "notIn", "contains", "notContains", "startsWith", "notStartsWith", "endsWith", "notEndsWith":
            guard let t0 = FlagValues.text(raw) else { return false }
            let t = ci ? FlagValues.lower(t0) : t0
            let vs = textValues(values, ci)
            switch op {
            case "equals": return !vs.isEmpty && FlagValues.same(t, vs[0])
            case "notEquals": return !vs.isEmpty && !FlagValues.same(t, vs[0])
            case "in": return vs.contains { FlagValues.same(t, $0) }
            case "notIn": return !vs.contains { FlagValues.same(t, $0) }
            case "contains": return vs.contains { FlagValues.contains(t, $0) }
            case "notContains": return !vs.contains { FlagValues.contains(t, $0) }
            case "startsWith": return vs.contains { FlagValues.hasPrefix(t, $0) }
            case "notStartsWith": return !vs.contains { FlagValues.hasPrefix(t, $0) }
            case "endsWith": return vs.contains { FlagValues.hasSuffix(t, $0) }
            default: return !vs.contains { FlagValues.hasSuffix(t, $0) }
            }
        case "regex", "notRegex":
            guard let t = FlagValues.text(raw) else { return false }
            var res: [NSRegularExpression] = []
            for v in values {
                guard case .string(let p) = v, let re = FlagEvaluator.regex(p, caseInsensitive: ci) else { return false }
                res.append(re)
            }
            let range = NSRange(location: 0, length: (t as NSString).length)
            let any = res.contains { $0.firstMatch(in: t, options: [], range: range) != nil }
            return op == "regex" ? any : !any
        case "numEquals", "numNotEquals", "gt", "gte", "lt", "lte":
            guard let a = FlagValues.number(raw), let b = FlagValues.number(values.first) else { return false }
            switch op {
            case "numEquals": return a == b
            case "numNotEquals": return a != b
            case "gt": return a > b
            case "gte": return a >= b
            case "lt": return a < b
            default: return a <= b
            }
        case "semverEquals", "semverNotEquals", "semverGt", "semverGte", "semverLt", "semverLte", "semverIn", "semverNotIn":
            guard let a = FlagSemVer(raw) else { return false }
            var bs: [FlagSemVer] = []
            for v in values {
                guard let b = FlagSemVer(v) else { return false }
                bs.append(b)
            }
            if op == "semverIn" { return bs.contains { FlagSemVer.compare(a, $0) == 0 } }
            if op == "semverNotIn" { return !bs.contains { FlagSemVer.compare(a, $0) == 0 } }
            guard let b = bs.first else { return false }
            let d = FlagSemVer.compare(a, b)
            switch op {
            case "semverEquals": return d == 0
            case "semverNotEquals": return d != 0
            case "semverGt": return d > 0
            case "semverGte": return d >= 0
            case "semverLt": return d < 0
            default: return d <= 0
            }
        case "before", "after":
            guard let a = FlagValues.instantMs(raw), let b = FlagValues.instantMs(values.first) else { return false }
            return op == "before" ? a < b : a > b
        case "arrayContainsAny", "arrayNotContainsAny", "arrayContainsAll":
            guard let arr = FlagValues.array(raw) else { return false }
            let elems = textValues(arr, ci)
            let vs = textValues(values, ci)
            if op == "arrayContainsAll" { return vs.allSatisfy { v in elems.contains { FlagValues.same($0, v) } } }
            let any = vs.contains { v in elems.contains { FlagValues.same($0, v) } }
            return op == "arrayContainsAny" ? any : !any
        case "equalsHashed", "notEqualsHashed", "inHashed", "notInHashed", "startsWithHashed", "notStartsWithHashed", "endsWithHashed", "notEndsWithHashed":
            guard let t = FlagValues.text(raw) else { return false }
            switch op {
            case "startsWithHashed": return affixMatches(t, values, suffix: false)
            case "notStartsWithHashed": return !affixMatches(t, values, suffix: false)
            case "endsWithHashed": return affixMatches(t, values, suffix: true)
            case "notEndsWithHashed": return !affixMatches(t, values, suffix: true)
            default: break
            }
            let h = FlagHash.confidential(salt: payload.salt, t)
            switch op {
            case "equalsHashed": if case .string(let v)? = values.first { return FlagValues.same(h, v) }; return false
            case "notEqualsHashed": if case .string(let v)? = values.first { return !FlagValues.same(h, v) }; return false
            case "inHashed": return includesString(values, h)
            default: return !includesString(values, h)
            }
        case "arrayContainsAnyHashed", "arrayNotContainsAnyHashed":
            guard let arr = FlagValues.array(raw) else { return false }
            let any = arr.contains { e in FlagValues.text(e).map { includesString(values, FlagHash.confidential(salt: payload.salt, $0)) } ?? false }
            return op == "arrayContainsAnyHashed" ? any : !any
        default:
            return false
        }
    }

    // MARK: Segments, flag references, groups

    /// nil when the segment does not exist.
    func segmentMatches(_ key: String) throws -> Bool? {
        guard let seg = payload.segments[key] else { return nil }
        return try enter("segment:\(key)") {
            switch seg {
            case .list(let attribute, let values, let hashed):
                guard let v = FlagEvaluator.lookupAttribute(attributes, attribute), let t = FlagValues.text(v) else { return false }
                return includesString(values, hashed ? FlagHash.confidential(salt: payload.salt, t) : t)
            case .conditions(let conditions):
                return try allMatch(conditions)
            case .unknown:
                return false
            }
        }
    }

    func compareFlag(_ op: String, _ actual: JSONValue, _ expected: JSONValue?) -> Bool {
        switch op {
        case "isOn": return FlagValues.isOn(actual)
        case "isOff": return !FlagValues.isOn(actual)
        case "equals": return FlagValues.jsonEquals(actual, expected ?? .null)
        case "notEquals": return !FlagValues.jsonEquals(actual, expected ?? .null)
        default: return false
        }
    }

    /// Value of a referenced flag, or nil when it does not exist.
    func referencedValue(_ key: String) throws -> JSONValue? {
        let res = try evalFlag(key)
        return res.reason == .flagNotFound ? Optional<JSONValue>.none : res.value
    }

    func conditionMatches(_ c: ConditionDef) throws -> Bool {
        switch c {
        case .attribute(let name, let op, let values, let ci):
            return evalAttribute(name: name, op: op, values: values, ci: ci)
        case .segment(let op, let key):
            guard let m = try segmentMatches(key) else { return false }
            if op == "in" { return m }
            if op == "notIn" { return !m }
            return false
        case .flag(let key, let op, let value):
            guard let v = try referencedValue(key) else { return false }
            return compareFlag(op, v, value)
        case .group(let op, let negate, let conditions):
            let r: Bool
            if op == "and" { r = try allMatch(conditions) } else if op == "or" {
                var any = false
                for x in conditions {
                    if try conditionMatches(x) { any = true; break }
                }
                r = any
            } else { return false }
            return negate ? !r : r
        case .invalid:
            return false
        }
    }

    func allMatch(_ conditions: [ConditionDef]?) throws -> Bool {
        guard let conditions else { return true }
        for c in conditions {
            if try !conditionMatches(c) { return false }
        }
        return true
    }

    // MARK: Rules

    func result(_ flag: FlagDef, _ value: JSONValue, _ reason: FlagEvaluationReason, ruleId: String? = nil, variationId: String? = nil) -> FlagEvaluationResult {
        FlagEvaluationResult(key: flag.key, value: value, reason: reason, ruleId: ruleId, variationId: variationId)
    }

    func runExperiment(_ flag: FlagDef, _ rule: RuleDef) -> FlagEvaluationResult? {
        let variations = rule.variations
        if variations.isEmpty { return nil }
        var hashAttribute = rule.hashAttribute
        let primary = hashValue(rule.hashAttribute)
        var hv = primary
        let fallbackValue = rule.fallbackAttribute.flatMap { hashValue($0) }
        if hv == nil, let fb = rule.fallbackAttribute, let fv = fallbackValue {
            hashAttribute = fb
            hv = fv
        }
        guard let hv else { return nil }

        let bucket = FlagHash.bucket(seed: rule.seed, value: hv)
        let useSticky = sticky != nil && !rule.disableStickyBucketing
        var index = -1
        var stickyUsed = false
        if useSticky, let sticky {
            var merged: [String: String] = [:]
            if let fb = rule.fallbackAttribute, let fv = fallbackValue { merged.merge(sticky.get("\(fb)||\(fv)") ?? [:]) { _, b in b } }
            if let p = primary { merged.merge(sticky.get("\(rule.hashAttribute)||\(p)") ?? [:]) { _, b in b } }
            let prefix = "\(rule.experimentKey)__"
            for k in merged.keys where FlagValues.hasPrefix(k, prefix) {
                let suffix = String(k.utf8.dropFirst(prefix.utf8.count)) ?? ""
                if let v = JSNumber.parse(suffix), v == v.rounded(), v < rule.minBucketVersion { return nil } // blocked from re-entering
            }
            if let assigned = merged["\(prefix)\(rule.bucketVersion)"], let i = variations.firstIndex(where: { $0.id.map { FlagValues.same($0, assigned) } ?? false }) {
                index = i
                stickyUsed = true
            }
        }
        if index < 0 {
            if let ns = rule.namespace {
                let n = FlagHash.bucket(seed: "__\(ns.id)", value: hv)
                guard let start = ns.start, let end = ns.end, n >= start, n < end else { return nil }
            }
            let coverage = FlagEvaluator.clamp01(rule.coverage)
            var cum = 0.0
            for (i, v) in variations.enumerated() {
                let start = cum
                let end = cum + coverage * v.weight
                cum += v.weight
                if bucket >= start && bucket < end { index = i; break }
            }
            if index < 0 { return nil }
            if useSticky, let sticky, let id = variations[index].id {
                let docKey = "\(hashAttribute)||\(hv)"
                var doc = sticky.get(docKey) ?? [:]
                doc["\(rule.experimentKey)__\(rule.bucketVersion)"] = id
                sticky.set(docKey, doc)
            }
        }
        let variation = variations[index]
        return FlagEvaluationResult(
            key: flag.key, value: variation.value, reason: .experiment, ruleId: rule.id, variationId: variation.id, inExperiment: true,
            experiment: FlagExperimentAssignment(key: rule.experimentKey, name: rule.name, variationId: variation.id ?? "", variationName: variation.name, variationIndex: index, hashAttribute: hashAttribute, hashAttributeValue: hv, bucket: bucket, stickyBucketUsed: stickyUsed)
        )
    }

    func applyRule(_ flag: FlagDef, _ rule: RuleDef) -> FlagEvaluationResult? {
        switch rule.type {
        case "force":
            return result(flag, rule.value, .ruleMatch, ruleId: rule.id, variationId: rule.variationId)
        case "rollout":
            guard let hv = hashValue(rule.hashAttribute) else { return nil }
            guard FlagHash.bucket(seed: rule.seed, value: hv) < FlagEvaluator.effectiveCoverage(rule, nowMs: nowMs) else { return nil }
            return result(flag, rule.value, .ruleMatch, ruleId: rule.id, variationId: rule.variationId)
        case "split":
            guard let hv = hashValue(rule.hashAttribute), let buckets = rule.buckets else { return nil }
            let n = FlagHash.bucket(seed: rule.seed, value: hv)
            var cum = 0.0
            for b in buckets {
                cum += b.weight
                if n < cum { return result(flag, b.value, .ruleMatch, ruleId: rule.id, variationId: b.variationId) }
            }
            return nil
        case "experiment":
            return runExperiment(flag, rule)
        default:
            return nil
        }
    }

    func evalFlag(_ key: String) throws -> FlagEvaluationResult {
        guard let flag = payload.flags[key] else { return .notFound(key) }
        return try enter("flag:\(key)") {
            if !flag.enabled { return result(flag, flag.offValue, .disabled) }
            for p in flag.prerequisites {
                guard let ref = p.flag, let v = try referencedValue(ref), compareFlag(p.op, v, p.value) else {
                    return result(flag, flag.offValue, .prerequisiteFailed)
                }
            }
            for h in payload.holdouts where includesString(h.flags, key) {
                if let hv = hashValue(h.hashAttribute), FlagHash.bucket(seed: h.seed, value: hv) < FlagEvaluator.clamp01(h.coverage) {
                    return result(flag, flag.defaultValue, .holdout)
                }
            }
            for rule in flag.rules {
                if !FlagEvaluator.isScheduleActive(start: rule.scheduleStart, end: rule.scheduleEnd, nowMs: nowMs) { continue }
                if try !allMatch(rule.conditions) { continue }
                if let res = applyRule(flag, rule) { return res }
            }
            return result(flag, flag.defaultValue, .default)
        }
    }
}
