import Foundation

// Port of `packages/shared/src/targeting-eval.ts`.

public struct Rule: Decodable, Sendable, Hashable {
    public var id: String
    /// `user.attribute`, `url.path`, `app.version`, … (unknown fields resolve to undefined).
    public var field: String
    public var key: String?
    public var op: String
    public var value: JSONValue?
    public var negate: Bool

    public init(id: String = "r", field: String, op: String, value: JSONValue? = nil, key: String? = nil, negate: Bool = false) {
        self.id = id; self.field = field; self.key = key; self.op = op; self.value = value; self.negate = negate
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: GKey.self)
        id = c.lenient("id", "")
        field = c.lenient("field", "")
        key = c.optional("key")
        op = c.lenient("op", "")
        value = c.contains("value") ? (try? c.decode(JSONValue.self, forKey: "value")) : nil
        if value == .null { value = nil }
        negate = c.lenient("negate", false)
    }
}

public indirect enum RuleNode: Decodable, Sendable, Hashable {
    case rule(Rule)
    case group(RuleGroup)

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: GKey.self)
        if c.contains("rules") { self = .group(try RuleGroup(from: decoder)) } else { self = .rule(try Rule(from: decoder)) }
    }
}

public struct RuleGroup: Decodable, Sendable, Hashable {
    public var id: String
    /// `and` / `or`.
    public var op: String
    public var rules: [RuleNode]
    public var negate: Bool

    public static let empty = RuleGroup(id: "root", op: "and", rules: [])

    public init(id: String = "g", op: String = "and", rules: [RuleNode], negate: Bool = false) {
        self.id = id; self.op = op; self.rules = rules; self.negate = negate
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: GKey.self)
        id = c.lenient("id", "")
        op = c.lenient("op", "and")
        rules = c.lossy("rules")
        negate = c.lenient("negate", false)
    }
}

public struct DeviceInfo: Sendable, Hashable {
    /// `mobile`, `tablet` or `desktop`.
    public var type: String
    public var browser: String?
    public var os: String?
    public init(type: String = "mobile", browser: String? = nil, os: String? = "ios") { self.type = type; self.browser = browser; self.os = os }
}

/// Everything targeting evaluation can see.
public struct TargetingContext: Sendable {
    public var userId: String?
    public var anonymousId: String
    public var userAttributes: [String: JSONValue]
    public var accountAttributes: [String: JSONValue]
    public var url: String
    public var path: String
    public var query: [String: String]
    public var device: DeviceInfo
    public var firstVisit: Bool
    public var eventsSeen: Set<String>
    public var completedGuides: Set<String>
    public var dismissedGuides: Set<String>
    public var seenGuides: Set<String>
    public var completedChecklists: Set<String>
    public var audienceIds: Set<String>
    public var now: Date
    public var environment: String
    public var locale: String?
    /// `web`, `ios` or `android`; nil means web.
    public var platform: String?
    public var screen: String?
    public var appVersion: String?
    public var rolloutSalt: String?

    public init(userId: String? = nil, anonymousId: String, userAttributes: [String: JSONValue] = [:], accountAttributes: [String: JSONValue] = [:], url: String = "/", path: String = "/", query: [String: String] = [:], device: DeviceInfo = DeviceInfo(), firstVisit: Bool = false, eventsSeen: Set<String> = [], completedGuides: Set<String> = [], dismissedGuides: Set<String> = [], seenGuides: Set<String> = [], completedChecklists: Set<String> = [], audienceIds: Set<String> = [], now: Date = Date(), environment: String = "development", locale: String? = nil, platform: String? = "ios", screen: String? = nil, appVersion: String? = nil, rolloutSalt: String? = nil) {
        self.userId = userId; self.anonymousId = anonymousId; self.userAttributes = userAttributes; self.accountAttributes = accountAttributes
        self.url = url; self.path = path; self.query = query; self.device = device; self.firstVisit = firstVisit; self.eventsSeen = eventsSeen
        self.completedGuides = completedGuides; self.dismissedGuides = dismissedGuides; self.seenGuides = seenGuides
        self.completedChecklists = completedChecklists; self.audienceIds = audienceIds; self.now = now; self.environment = environment
        self.locale = locale; self.platform = platform; self.screen = screen; self.appVersion = appVersion; self.rolloutSalt = rolloutSalt
    }
}

public enum Targeting {
    private static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// Resolves a rule's field. nil = JavaScript `undefined`.
    static func resolveField(_ rule: Rule, _ ctx: TargetingContext) -> JSONValue? {
        func opt(_ s: String?) -> JSONValue? { s.map { .string($0) } }
        func has(_ set: Set<String>) -> JSONValue { .bool(rule.key.map { set.contains($0) } ?? false) }
        switch rule.field {
        case "user.attribute": return rule.key.flatMap { $0.isEmpty ? nil : GuidelyUtils.getPath(ctx.userAttributes, $0) }
        case "account.attribute": return rule.key.flatMap { $0.isEmpty ? nil : GuidelyUtils.getPath(ctx.accountAttributes, $0) }
        case "user.role": return ctx.userAttributes["role"]
        case "user.plan":
            if let p = ctx.userAttributes["plan"], !p.isNull { return p }
            return ctx.accountAttributes["plan"]
        case "url.path": return .string(ctx.path)
        case "url.full": return .string(ctx.url)
        case "url.query": return rule.key.flatMap { k in ctx.query[k].map { .string($0) } }
        case "device.type": return .string(ctx.device.type)
        case "device.browser": return opt(ctx.device.browser)
        case "device.os": return opt(ctx.device.os)
        case "visitor.firstVisit": return .bool(ctx.firstVisit)
        case "visitor.returning": return .bool(!ctx.firstVisit)
        case "event.seen": return has(ctx.eventsSeen)
        case "guide.completed": return has(ctx.completedGuides)
        case "guide.dismissed": return has(ctx.dismissedGuides)
        case "guide.seen": return has(ctx.seenGuides)
        case "checklist.completed": return has(ctx.completedChecklists)
        case "audience.member": return has(ctx.audienceIds)
        case "datetime.now": return .string(ISODate.format(ctx.now))
        case "datetime.dayOfWeek": return .number(Double(utc.component(.weekday, from: ctx.now) - 1))
        case "datetime.hour": return .number(Double(utc.component(.hour, from: ctx.now)))
        case "rollout.percentage":
            let subject = (ctx.userId?.isEmpty == false ? ctx.userId : nil) ?? ctx.anonymousId
            let salt = (ctx.rolloutSalt?.isEmpty == false ? ctx.rolloutSalt : nil) ?? "guidely"
            return .number(Double(GuidelyUtils.rolloutBucket(subject: subject, salt: salt)))
        case "environment": return .string(ctx.environment)
        case "locale": return opt(ctx.locale)
        case "app.platform": return .string(ctx.platform ?? "web")
        case "app.screen": return opt(ctx.screen)
        case "app.version": return opt(ctx.appVersion)
        default: return nil
        }
    }

    /// `String(v ?? "")`: undefined and null become "".
    static func str(_ v: JSONValue?) -> String {
        guard let v, !v.isNull else { return "" }
        return v.jsString
    }

    static func toNumber(_ v: JSONValue?) -> Double? {
        switch v {
        case .number(let n)?: return n
        case .string(let s)?:
            if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
            return JSNumber.parse(s)
        default: return nil
        }
    }

    static func toDateMs(_ v: JSONValue?) -> Double? {
        switch v {
        case .string(let s)?: return ISODate.parseMs(s)
        case .number(let n)?: return n
        default: return nil
        }
    }

    static func list(_ expected: JSONValue?) -> [JSONValue] {
        if case .array(let a)? = expected { return a }
        return str(expected).split(separator: ",", omittingEmptySubsequences: false).map { .string($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    public static func compare(_ op: String, _ actual: JSONValue?, _ expected: JSONValue?) -> Bool {
        switch op {
        case "exists":
            guard let a = actual, !a.isNull else { return false }
            return a != .string("")
        case "not_exists":
            guard let a = actual, !a.isNull else { return true }
            return a == .string("")
        case "is_true": return actual == .bool(true) || actual == .string("true")
        case "is_false": return actual == .bool(false) || actual == .string("false")
        case "equals":
            if case .bool(let b)? = actual { return (b ? "true" : "false") == (expected.map { $0.jsString } ?? "undefined") }
            return str(actual) == str(expected)
        case "not_equals": return str(actual) != str(expected)
        case "contains":
            guard case .string(let s)? = actual else { return false }
            return s.lowercased().contains(str(expected).lowercased())
        case "not_contains":
            guard case .string(let s)? = actual else { return true }
            return !s.lowercased().contains(str(expected).lowercased())
        case "starts_with":
            guard case .string(let s)? = actual else { return false }
            return s.utf16.starts(with: str(expected).utf16)
        case "ends_with":
            guard case .string(let s)? = actual else { return false }
            return Array(s.utf16).reversed().starts(with: Array(str(expected).utf16).reversed())
        case "gt", "gte", "lt", "lte":
            guard let a = toNumber(actual), let b = toNumber(expected) else { return false }
            switch op {
            case "gt": return a > b
            case "gte": return a >= b
            case "lt": return a < b
            default: return a <= b
            }
        case "in", "not_in":
            let needle = str(actual)
            let found = list(expected).contains { $0 == .string(needle) }
            return op == "in" ? found : !found
        case "regex":
            guard let re = GuidelyUtils.safeRegExp(str(expected)), case .string(let s)? = actual else { return false }
            return GuidelyUtils.regexTest(re, s)
        case "before", "after":
            guard let a = toDateMs(actual), let b = toDateMs(expected) else { return false }
            return op == "before" ? a < b : a > b
        default:
            return false
        }
    }

    public static func evaluateRule(_ rule: Rule, _ ctx: TargetingContext) -> Bool {
        var result: Bool
        if rule.field == "url.path" || rule.field == "url.full" || rule.field == "app.screen" {
            let actual = str(resolveField(rule, ctx))
            if rule.op == "equals" { result = GuidelyUtils.matchUrlPattern(str(rule.value), actual) }
            else if rule.op == "not_equals" { result = !GuidelyUtils.matchUrlPattern(str(rule.value), actual) }
            else { result = compare(rule.op, .string(actual), rule.value) }
        } else if rule.field == "app.version", ["equals", "not_equals", "gt", "gte", "lt", "lte"].contains(rule.op) {
            if let c = GuidelyUtils.compareVersions(resolveField(rule, ctx), rule.value) {
                switch rule.op {
                case "equals": result = c == 0
                case "not_equals": result = c != 0
                case "gt": result = c > 0
                case "gte": result = c >= 0
                case "lt": result = c < 0
                default: result = c <= 0
                }
            } else {
                result = rule.op == "not_equals"
            }
        } else {
            result = compare(rule.op, resolveField(rule, ctx), rule.value)
        }
        return rule.negate ? !result : result
    }

    /// Evaluates a rule tree. An empty group matches everyone (unless negated).
    public static func evaluate(_ group: RuleGroup?, _ ctx: TargetingContext) -> Bool {
        guard let group else { return true }
        if group.rules.isEmpty { return !group.negate }
        let results = group.rules.map { node -> Bool in
            switch node {
            case .rule(let r): return evaluateRule(r, ctx)
            case .group(let g): return evaluate(g, ctx)
            }
        }
        let value = group.op == "and" ? results.allSatisfy { $0 } : results.contains(true)
        return group.negate ? !value : value
    }
}
