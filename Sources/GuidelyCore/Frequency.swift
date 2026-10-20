import Foundation

// Port of `packages/sdk-core/src/frequency.ts` and `packages/shared/src/widgets.ts`.

/// Per-guide state kept locally and merged with the server's `guideState`.
public struct GuideLocalState: Codable, Sendable, Hashable {
    public var impressions: Int
    public var completedAt: String?
    public var dismissedAt: String?
    public var lastShownAt: String?

    public init(impressions: Int = 0, completedAt: String? = nil, dismissedAt: String? = nil, lastShownAt: String? = nil) {
        self.impressions = impressions; self.completedAt = completedAt; self.dismissedAt = dismissedAt; self.lastShownAt = lastShownAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: GKey.self)
        impressions = c.lenient("impressions", 0)
        completedAt = c.optional("completedAt")
        dismissedAt = c.optional("dismissedAt")
        lastShownAt = c.optional("lastShownAt")
    }
}

public enum Frequency {
    static let hourMs = 3_600_000.0

    /// Pure frequency evaluation (`isFrequencyEligible`).
    public static func isEligible(_ freq: FrequencyConfig, state: GuideLocalState?, shownThisSession: Bool, now: Date = Date()) -> Bool {
        let s = state ?? GuideLocalState()
        let nowMs = now.timeIntervalSince1970 * 1000
        if let max = freq.maxImpressions, s.impressions >= max { return false }
        if let c = s.completedAt, !c.isEmpty, freq.mode != .everyTime { return false }
        let dismissed = s.dismissedAt.map { !$0.isEmpty } ?? false
        if dismissed {
            if !freq.reshowAfterDismiss { return false }
            if freq.cooldownHours > 0 {
                // `now - Date.parse(dismissedAt) < cooldown` is false for an unparsable date (NaN).
                if let d = ISODate.parseMs(s.dismissedAt ?? ""), nowMs - d < freq.cooldownHours * hourMs { return false }
            }
        }
        switch freq.mode {
        case .once:
            return s.impressions == 0 || (dismissed && freq.reshowAfterDismiss)
        case .oncePerSession:
            return !shownThisSession
        case .interval:
            guard let last = s.lastShownAt, !last.isEmpty else { return true }
            let hours = freq.intervalHours ?? 24
            guard let lastMs = ISODate.parseMs(last) else { return false }
            return nowMs - lastMs >= hours * hourMs
        case .everyTime:
            return true
        }
    }

    /// Exclusive guides (flows, modals, tooltips, announcements, surveys) run one at a time.
    /// Banners, checklists and hotspot/banner-only guides coexist with an active flow.
    public static func isExclusive(_ guide: PublishedGuide) -> Bool {
        if guide.kind == .banner || guide.kind == .checklist { return false }
        let steps = guide.config.steps
        if !steps.isEmpty && steps.allSatisfy({ $0.type == .hotspot || $0.type == .banner }) { return false }
        return true
    }

    /// Is `a` mutually exclusive with `b` (by id or key, in either direction)?
    public static func areMutuallyExclusive(_ a: PublishedGuide, _ b: PublishedGuide) -> Bool {
        let la = a.config.frequency.mutuallyExclusiveWith
        let lb = b.config.frequency.mutuallyExclusiveWith
        return la.contains(b.id) || la.contains(b.key) || lb.contains(a.id) || lb.contains(a.key)
    }

    /// Survey scheduling window.
    public static func isWithinSchedule(_ guide: PublishedGuide, now: Date = Date()) -> Bool {
        guard let s = guide.config.survey else { return true }
        let nowMs = now.timeIntervalSince1970 * 1000
        if let start = s.startAt, let ms = ISODate.parseMs(start), nowMs < ms { return false }
        if let end = s.endAt, let ms = ISODate.parseMs(end), nowMs > ms { return false }
        return true
    }
}

/// A survey answer: number (scales), string (choice / text), bool (thumbs), string list (multiple choice).
public enum SurveyAnswer: Sendable, Hashable {
    case number(Double)
    case string(String)
    case bool(Bool)
    case list([String])

    public var json: JSONValue {
        switch self {
        case .number(let n): return .number(n)
        case .string(let s): return .string(s)
        case .bool(let b): return .bool(b)
        case .list(let l): return .array(l.map { .string($0) })
        }
    }

    var jsString: String { json.jsString }

    var jsNumber: Double {
        switch self {
        case .number(let n): return n
        case .string(let s): return JSNumber.parse(s) ?? .nan
        case .bool(let b): return b ? 1 : 0
        case .list(let l): return l.isEmpty ? 0 : (l.count == 1 ? (JSNumber.parse(l[0]) ?? .nan) : .nan)
        }
    }
}

public enum SurveyLogic {
    /// `isQuestionVisible`: evaluates `showWhen` against the current answers.
    public static func isQuestionVisible(_ q: SurveyQuestion, answers: [String: SurveyAnswer]) -> Bool {
        guard let w = q.showWhen else { return true }
        guard let actual = answers[w.questionId] else { return false }
        let expected = w.value
        func num(_ v: JSONValue) -> Double {
            switch v {
            case .number(let n): return n
            case .string(let s): return JSNumber.parse(s) ?? .nan
            case .bool(let b): return b ? 1 : 0
            case .null: return 0
            case .array(let a): return a.isEmpty ? 0 : (a.count == 1 ? num(a[0]) : .nan)
            case .object: return .nan
            }
        }
        switch w.op {
        case "equals":
            if case .list(let l) = actual { return l.contains(expected.jsString) }
            return actual.jsString == expected.jsString
        case "lte": return actual.jsNumber <= num(expected)
        case "gte": return actual.jsNumber >= num(expected)
        case "in":
            let list: [JSONValue] = expected.arrayValue ?? [.string(expected.jsString)]
            if case .list(let l) = actual { return l.contains { a in list.contains(.string(a)) } }
            return list.contains(.string(actual.jsString))
        default:
            return false
        }
    }

    /// Required, visible questions without an answer.
    public static func missingRequired(_ questions: [SurveyQuestion], answers: [String: SurveyAnswer]) -> [SurveyQuestion] {
        questions.filter { $0.required && isQuestionVisible($0, answers: answers) && answers[$0.id] == nil }
    }

    /// Drops answers of questions that are no longer visible (repeat until stable for chains).
    public static func pruneHidden(_ questions: [SurveyQuestion], answers: [String: SurveyAnswer]) -> [String: SurveyAnswer] {
        var out = answers
        var changed = true
        while changed {
            changed = false
            for q in questions where out[q.id] != nil && !isQuestionVisible(q, answers: out) {
                out[q.id] = nil
                changed = true
            }
        }
        return out
    }
}

public enum ChecklistLogic {
    /// Are all required tasks done?
    public static func isComplete(_ config: ChecklistConfig, completedTaskIds: [String]) -> Bool {
        let done = Set(completedTaskIds)
        return config.tasks.filter { $0.required }.allSatisfy { done.contains($0.id) }
    }

    /// Ordered checklists lock every task after the first incomplete one.
    public static func lockedTaskIds(_ config: ChecklistConfig, completedTaskIds: [String]) -> Set<String> {
        guard config.ordered else { return [] }
        let done = Set(completedTaskIds)
        var locked = false
        var out = Set<String>()
        for t in config.tasks {
            let isDone = done.contains(t.id)
            if locked && !isDone { out.insert(t.id) }
            if !isDone { locked = true }
        }
        return out
    }
}
