import Foundation

// Wire format of the feature-flag payload served by `GET /api/v1/sdk/flags` and the results of
// evaluating it (docs/feature-flags-spec.md §2–3, `packages/flags/src/types.ts`). Parsing is lenient:
// unknown fields are ignored, and unknown rule types, condition kinds and operators never match.

/// A downloaded (and, when encrypted, decrypted) flags payload.
public struct FlagsPayload: Sendable {
    /// The payload object as received (decrypted). Persisted for offline use.
    public let raw: JSONValue
    public let schemaVersion: Int
    public let projectId: String
    public let environment: String
    /// Bumps on every change affecting this environment.
    public let version: Int
    public let generatedAt: String?
    /// Salt for the hashed (confidential) operators.
    public let salt: String
    let flags: [String: FlagDef]
    let segments: [String: SegmentDef]
    let holdouts: [HoldoutDef]

    /// Keys of every flag in the payload.
    public var flagKeys: [String] { Array(flags.keys).sorted() }

    /// The declared value type of a flag (`boolean`, `string`, `number`, `json`).
    public func flagType(_ key: String) -> String? { flags[key]?.type }

    public init(json: JSONValue) {
        raw = json
        let o = json.objectValue ?? [:]
        schemaVersion = Int(FlagValues.coerceNumber(o["schemaVersion"]))
        projectId = o["projectId"]?.stringValue ?? ""
        environment = o["environment"]?.stringValue ?? ""
        version = Int(FlagValues.coerceNumber(o["version"]))
        generatedAt = o["generatedAt"]?.stringValue
        salt = o["salt"]?.stringValue ?? ""
        var flags: [String: FlagDef] = [:]
        for (k, v) in o["flags"]?.objectValue ?? [:] { if let f = FlagDef(v, mapKey: k) { flags[k] = f } }
        self.flags = flags
        var segments: [String: SegmentDef] = [:]
        for (k, v) in o["segments"]?.objectValue ?? [:] { if let s = v.objectValue { segments[k] = SegmentDef(s) } }
        self.segments = segments
        holdouts = (o["holdouts"]?.arrayValue ?? []).compactMap { $0.objectValue.map(HoldoutDef.init) }
    }

    /// Parses JSON data. Throws when the data is not a JSON object.
    public init(data: Data) throws {
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        guard json.objectValue != nil else { throw GuidelyError("[Guidely] flags payload is not a JSON object") }
        self.init(json: json)
    }

    public static let empty = FlagsPayload(json: .object([:]))
}

/// JavaScript truthiness for flags such as `enabled` / `negate` in hand-edited payloads.
@inline(__always)
func truthy(_ v: JSONValue?) -> Bool { FlagValues.isOn(v) }

struct FlagDef: Sendable {
    let key: String
    let type: String
    let enabled: Bool
    let offValue: JSONValue
    let defaultValue: JSONValue
    let prerequisites: [Prerequisite]
    let rules: [RuleDef]

    struct Prerequisite: Sendable {
        let flag: String?
        let op: String
        let value: JSONValue?
    }

    init?(_ json: JSONValue, mapKey: String) {
        guard let o = json.objectValue else { return nil }
        key = o["key"]?.stringValue ?? mapKey
        type = o["type"]?.stringValue ?? "json"
        enabled = truthy(o["enabled"])
        offValue = o["offValue"] ?? .null
        defaultValue = o["defaultValue"] ?? .null
        prerequisites = (o["prerequisites"]?.arrayValue ?? []).map { p in
            let po = p.objectValue ?? [:]
            return Prerequisite(flag: po["flag"]?.stringValue, op: po["operator"]?.stringValue ?? "", value: po["value"])
        }
        rules = (o["rules"]?.arrayValue ?? []).compactMap { $0.objectValue.map(RuleDef.init) }
    }
}

struct RuleDef: Sendable {
    struct Bucket: Sendable { let weight: Double; let value: JSONValue; let variationId: String? }
    struct Variation: Sendable { let id: String?; let name: String?; let value: JSONValue; let weight: Double }
    struct Namespace: Sendable { let id: String; let start: Double?; let end: Double? }
    struct RampStep: Sendable { let at: JSONValue?; let coverage: JSONValue? }

    let id: String?
    let type: String
    let conditions: [ConditionDef]?
    let scheduleStart: JSONValue?
    let scheduleEnd: JSONValue?
    // force / rollout
    let value: JSONValue
    let variationId: String?
    // rollout / split / experiment
    let hashAttribute: String
    let seed: String
    let coverage: JSONValue?
    let ramp: [RampStep]
    let buckets: [Bucket]?
    // experiment
    let experimentKey: String
    let name: String?
    let fallbackAttribute: String?
    let variations: [Variation]
    let namespace: Namespace?
    let bucketVersion: String
    let minBucketVersion: Double
    let disableStickyBucketing: Bool

    init(_ o: [String: JSONValue]) {
        id = o["id"]?.stringValue
        type = o["type"]?.stringValue ?? ""
        conditions = o["conditions"].flatMap { $0.isNull ? nil : ($0.arrayValue ?? []).map(ConditionDef.init) }
        let schedule = o["schedule"]?.objectValue
        scheduleStart = schedule?["start"]
        scheduleEnd = schedule?["end"]
        value = o["value"] ?? .null
        variationId = o["variationId"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        hashAttribute = o["hashAttribute"]?.stringValue ?? ""
        seed = o["seed"].map { $0.jsString } ?? ""
        coverage = o["coverage"]
        ramp = (o["ramp"]?.arrayValue ?? []).map { s in RampStep(at: s.objectValue?["at"], coverage: s.objectValue?["coverage"]) }
        buckets = o["buckets"]?.arrayValue.map { list in
            list.map { b in
                let bo = b.objectValue ?? [:]
                return Bucket(weight: max(0, FlagValues.coerceNumber(bo["weight"])), value: bo["value"] ?? .null, variationId: bo["variationId"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 })
            }
        }
        experimentKey = o["key"].map { $0.jsString } ?? ""
        name = o["name"]?.stringValue
        fallbackAttribute = o["fallbackAttribute"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        variations = (o["variations"]?.arrayValue ?? []).map { v in
            let vo = v.objectValue ?? [:]
            return Variation(id: vo["id"]?.stringValue, name: vo["name"]?.stringValue, value: vo["value"] ?? .null, weight: max(0, FlagValues.coerceNumber(vo["weight"])))
        }
        namespace = o["namespace"]?.objectValue.map { n in
            Namespace(id: n["id"].map { $0.jsString } ?? "", start: n["start"]?.numberValue, end: n["end"]?.numberValue)
        }
        let bv = o["bucketVersion"]
        bucketVersion = (bv == nil || bv == .null) ? "0" : bv!.jsString
        let mbv = o["minBucketVersion"]
        minBucketVersion = (mbv == nil || mbv == .null) ? 0 : FlagValues.coerceNumber(mbv)
        disableStickyBucketing = truthy(o["disableStickyBucketing"])
    }
}

indirect enum ConditionDef: Sendable {
    case attribute(name: String, op: String, values: [JSONValue], caseInsensitive: Bool)
    case segment(op: String, key: String)
    case flag(key: String, op: String, value: JSONValue?)
    case group(op: String, negate: Bool, conditions: [ConditionDef])
    case invalid

    init(_ json: JSONValue) {
        guard let o = json.objectValue else { self = .invalid; return }
        switch o["kind"]?.stringValue {
        case "attribute":
            self = .attribute(name: o["attribute"]?.stringValue ?? "", op: o["operator"]?.stringValue ?? "", values: o["values"]?.arrayValue ?? [], caseInsensitive: truthy(o["caseInsensitive"]))
        case "segment":
            guard let key = o["segment"]?.stringValue else { self = .invalid; return }
            self = .segment(op: o["operator"]?.stringValue ?? "", key: key)
        case "flag":
            guard let key = o["flag"]?.stringValue else { self = .invalid; return }
            self = .flag(key: key, op: o["operator"]?.stringValue ?? "", value: o["value"])
        case "group":
            self = .group(op: o["op"]?.stringValue ?? "", negate: truthy(o["negate"]), conditions: (o["conditions"]?.arrayValue ?? []).map(ConditionDef.init))
        default:
            self = .invalid
        }
    }
}

enum SegmentDef: Sendable {
    case conditions([ConditionDef]?)
    case list(attribute: String, values: [JSONValue], hashed: Bool)
    case unknown

    init(_ o: [String: JSONValue]) {
        switch o["kind"]?.stringValue {
        case "conditions": self = .conditions(o["conditions"].flatMap { $0.isNull ? nil : ($0.arrayValue ?? []).map(ConditionDef.init) })
        case "list": self = .list(attribute: o["attribute"]?.stringValue ?? "", values: o["values"]?.arrayValue ?? [], hashed: truthy(o["hashed"]))
        default: self = .unknown
        }
    }
}

struct HoldoutDef: Sendable {
    let hashAttribute: String
    let seed: String
    let coverage: JSONValue?
    let flags: [JSONValue]

    init(_ o: [String: JSONValue]) {
        hashAttribute = o["hashAttribute"]?.stringValue ?? ""
        seed = o["seed"].map { $0.jsString } ?? ""
        coverage = o["coverage"]
        flags = o["flags"]?.arrayValue ?? []
    }
}

// MARK: - Results

/// Why a flag has the value it has (§3.1).
public enum FlagEvaluationReason: String, LenientStringEnum {
    case flagNotFound = "FLAG_NOT_FOUND"
    case disabled = "DISABLED"
    case prerequisiteFailed = "PREREQUISITE_FAILED"
    case holdout = "HOLDOUT"
    case ruleMatch = "RULE_MATCH"
    case experiment = "EXPERIMENT"
    case `default` = "DEFAULT"
    case override = "OVERRIDE"
    case error = "ERROR"

    public static var fallbackCase: FlagEvaluationReason { .default }
}

/// The variation an experiment rule assigned (§3.1 `experiment`).
public struct FlagExperimentAssignment: Codable, Sendable, Hashable {
    public var key: String
    public var name: String?
    public var variationId: String
    public var variationName: String?
    public var variationIndex: Int
    public var hashAttribute: String
    /// The hash attribute's value that was bucketed (`hashValue` on the wire). Not named `hashValue`:
    /// that would clash with `Hashable.hashValue` (a compile error before Swift 6.2).
    public var hashAttributeValue: String
    public var bucket: Double
    public var stickyBucketUsed: Bool

    public init(key: String, name: String? = nil, variationId: String, variationName: String? = nil, variationIndex: Int, hashAttribute: String, hashAttributeValue: String, bucket: Double, stickyBucketUsed: Bool = false) {
        self.key = key; self.name = name; self.variationId = variationId; self.variationName = variationName; self.variationIndex = variationIndex
        self.hashAttribute = hashAttribute; self.hashAttributeValue = hashAttributeValue; self.bucket = bucket; self.stickyBucketUsed = stickyBucketUsed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: GKey.self)
        key = c.lenient("key", "")
        name = c.optional("name")
        variationId = c.lenient("variationId", "")
        variationName = c.optional("variationName")
        variationIndex = c.lenient("variationIndex", 0)
        hashAttribute = c.lenient("hashAttribute", "id")
        hashAttributeValue = c.lenient("hashValue", "")
        bucket = c.lenient("bucket", 0)
        stickyBucketUsed = c.lenient("stickyBucketUsed", false)
    }

    private enum CodingKeys: String, CodingKey {
        case key, name, variationId, variationName, variationIndex, hashAttribute, bucket, stickyBucketUsed
        case hashAttributeValue = "hashValue"
    }
}

/// The result of evaluating one flag: its value and why (`featureDetails(_:)`).
public struct FlagEvaluationResult: Codable, Sendable, Hashable {
    public var key: String
    /// `.null` when the flag does not exist or has no value for this user.
    public var value: JSONValue
    public var reason: FlagEvaluationReason
    /// The rule that served the value.
    public var ruleId: String?
    /// The serving rule's / bucket's / variation's id.
    public var variationId: String?
    /// The user was bucketed into an experiment (an exposure is tracked).
    public var inExperiment: Bool
    public var experiment: FlagExperimentAssignment?
    /// Reason `ERROR` only.
    public var errorMessage: String?

    public init(key: String, value: JSONValue = .null, reason: FlagEvaluationReason, ruleId: String? = nil, variationId: String? = nil, inExperiment: Bool = false, experiment: FlagExperimentAssignment? = nil, errorMessage: String? = nil) {
        self.key = key; self.value = value; self.reason = reason; self.ruleId = ruleId; self.variationId = variationId
        self.inExperiment = inExperiment; self.experiment = experiment; self.errorMessage = errorMessage
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: GKey.self)
        key = c.lenient("key", "")
        value = c.lenient("value", JSONValue.null)
        reason = c.lenient("reason", FlagEvaluationReason.default)
        ruleId = c.optional("ruleId")
        variationId = c.optional("variationId")
        inExperiment = c.lenient("inExperiment", false)
        experiment = c.optional("experiment")
        errorMessage = c.optional("errorMessage")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: GKey.self)
        try c.encode(key, forKey: "key")
        try c.encode(value, forKey: "value")
        try c.encode(reason, forKey: "reason")
        try c.encodeIfPresent(ruleId, forKey: "ruleId")
        try c.encodeIfPresent(variationId, forKey: "variationId")
        try c.encode(inExperiment, forKey: "inExperiment")
        try c.encodeIfPresent(experiment, forKey: "experiment")
        try c.encodeIfPresent(errorMessage, forKey: "errorMessage")
    }

    /// The flag exists and served a non-null value.
    public var hasValue: Bool { !value.isNull }

    static func notFound(_ key: String) -> FlagEvaluationResult { FlagEvaluationResult(key: key, reason: .flagNotFound) }
}

// MARK: - Sticky bucketing

/// Persists experiment assignments so users keep their variation across config changes (§3.5).
/// Documents are keyed `"<attribute>||<value>"` and map `"<experimentKey>__<bucketVersion>"` → variation id.
/// Implementations must be thread-safe.
public protocol FlagStickyBucketStore: AnyObject {
    func get(_ docKey: String) -> [String: String]?
    func set(_ docKey: String, _ assignments: [String: String])
}

/// In-memory sticky bucket documents.
public final class InMemoryStickyBucketStore: FlagStickyBucketStore, @unchecked Sendable {
    private let lock = NSLock()
    private var docs: [String: [String: String]]
    public init(_ docs: [String: [String: String]] = [:]) { self.docs = docs }
    public func get(_ docKey: String) -> [String: String]? { lock.lock(); defer { lock.unlock() }; return docs[docKey] }
    public func set(_ docKey: String, _ assignments: [String: String]) { lock.lock(); docs[docKey] = assignments; lock.unlock() }
    public var documents: [String: [String: String]] { lock.lock(); defer { lock.unlock() }; return docs }
}

/// Sticky bucket documents persisted in the SDK's key/value storage (one JSON object per project key).
final class PersistentStickyBucketStore: FlagStickyBucketStore, @unchecked Sendable {
    private let lock = NSLock()
    private let store: GuidelyKeyValueStore
    private let storageKey: String
    private var docs: [String: [String: String]]
    /// Upper bound on persisted documents (oldest dropped first is not tracked; we simply cap growth).
    private let maxDocs = 200

    init(store: GuidelyKeyValueStore, storageKey: String) {
        self.store = store
        self.storageKey = storageKey
        docs = store.readJSON(storageKey, as: [String: [String: String]].self) ?? [:]
    }

    func get(_ docKey: String) -> [String: String]? { lock.lock(); defer { lock.unlock() }; return docs[docKey] }

    func set(_ docKey: String, _ assignments: [String: String]) {
        lock.lock()
        if docs[docKey] == assignments { lock.unlock(); return }
        if docs[docKey] == nil, docs.count >= maxDocs, let drop = docs.keys.sorted().first { docs[drop] = nil }
        docs[docKey] = assignments
        let snapshot = docs
        lock.unlock()
        store.writeJSON(storageKey, snapshot)
    }
}

/// Reads through to another store but drops writes (change detection without side effects).
final class ReadOnlyStickyBucketStore: FlagStickyBucketStore {
    let base: FlagStickyBucketStore
    init(_ base: FlagStickyBucketStore) { self.base = base }
    func get(_ docKey: String) -> [String: String]? { base.get(docKey) }
    func set(_ docKey: String, _ assignments: [String: String]) {}
}
