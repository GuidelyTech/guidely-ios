import CryptoKit
import Foundation
#if canImport(Combine)
import Combine
#endif

// Feature-flag client (docs/feature-flags-spec.md §1, §4): downloads the environment's payload
// (`GET /api/v1/sdk/flags`, ETag aware), caches it for offline cold starts, polls / streams for
// changes, evaluates locally (or remotely with `remoteEval`), applies local overrides, keeps sticky
// experiment assignments and reports usage counts. Embedded in `GuidelyEngine`, or standalone
// (`GuidelyFlagsClient(sdkKey:)`) for app extensions and apps that only want flags.

/// How local overrides combine with the flags from Guidely.
public enum FlagOverrideBehaviour: String, Sendable, Codable {
    /// Only overrides, then a bootstrap payload, are used; nothing is fetched and no payload cached
    /// by an earlier run is read (hermetic tests).
    case localOnly
    /// Overrides win over remote values (reason `OVERRIDE`). Default.
    case localOverRemote
    /// Overrides apply only to flags that do not exist remotely.
    case remoteOverLocal
}

/// Feature-flag options (`GuidelyOptions.flags`, or the standalone `GuidelyFlagsClient`).
public struct FlagsOptions {
    /// Load and evaluate flags (default true). With the Guidely SDK, `false` skips every flag request.
    public var enabled: Bool
    /// Seconds between payload refreshes while the app is in the foreground (default 60). `0` = only
    /// at start, on foreground and on `refreshFlags()`.
    public var pollInterval: TimeInterval
    /// Listen to `/flags/stream` (Server-Sent Events) and refetch as soon as flags change. Polling
    /// takes over while the stream is down.
    public var streaming: Bool
    /// Evaluate on the server (`POST /flags/evaluate`) instead of downloading the rules. Required
    /// when the environment's exposure mode is `remote`. Re-runs whenever attributes change.
    public var remoteEval: Bool
    /// Base64 AES-256 key from the dashboard for environments with encrypted payloads.
    public var decryptionKey: String?
    /// Local values by flag key (QA menus, previews, tests).
    public var overrides: [String: JSONValue]
    public var overrideBehaviour: FlagOverrideBehaviour
    /// Read dev overrides from the process environment at start (default true):
    /// `GUIDELY_FLAG_OVERRIDES`, `GUIDELY_FLAG_OVERRIDES_FILE` and `GUIDELY_FLAG_OVERRIDE_BEHAVIOUR`
    /// (XCUITest `launchEnvironment`, `SIMCTL_CHILD_*`). They win over `overrides`, and their
    /// behaviour over `overrideBehaviour`. `false` ignores every source.
    public var devOverrides: Bool
    /// A payload (`GET /flags` body) or remote-evaluation response used immediately at start, e.g.
    /// shipped in the app bundle so the first launch has flags before the network answers.
    public var bootstrapPayload: Data?
    /// Report aggregated evaluation counts to `/flags/events` (default true).
    public var reportUsage: Bool
    /// Keep users in their experiment variation across config changes (default true).
    public var stickyBucketing: Bool
    /// Extra attributes merged over the automatic ones (see also `setFlagAttributes`).
    public var attributes: [String: JSONValue]
    /// Called once per (experiment, user, variation) when a user is bucketed into an experiment.
    public var trackingCallback: ((FlagExperimentAssignment, FlagEvaluationResult) -> Void)?

    public init(enabled: Bool = true, pollInterval: TimeInterval = 60, streaming: Bool = false, remoteEval: Bool = false, decryptionKey: String? = nil, overrides: [String: Any] = [:], overrideBehaviour: FlagOverrideBehaviour = .localOverRemote, bootstrapPayload: Data? = nil, reportUsage: Bool = true, stickyBucketing: Bool = true, attributes: [String: Any] = [:], trackingCallback: ((FlagExperimentAssignment, FlagEvaluationResult) -> Void)? = nil, devOverrides: Bool = true) {
        self.enabled = enabled; self.pollInterval = pollInterval; self.streaming = streaming; self.remoteEval = remoteEval
        self.decryptionKey = decryptionKey; self.overrides = JSONValue.object(from: overrides); self.overrideBehaviour = overrideBehaviour
        self.bootstrapPayload = bootstrapPayload; self.reportUsage = reportUsage; self.stickyBucketing = stickyBucketing
        self.attributes = JSONValue.object(from: attributes); self.trackingCallback = trackingCallback
        self.devOverrides = devOverrides
    }
}

extension StoreKeys {
    static func flags(_ k: String) -> String { "guidely:flags:\(k)" }
    static func flagsEtag(_ k: String) -> String { "guidely:flagsEtag:\(k)" }
    static func flagsRemote(_ k: String) -> String { "guidely:flagsRemote:\(k)" }
    static func flagsSticky(_ k: String) -> String { "guidely:flagsSticky:\(k)" }
}

/// Thread-safe feature-flag client. Getters (`isEnabled`, `value`, `details`, …) can be called from
/// any thread and never throw: they return the default for missing, null and wrong-type values.
/// Lifecycle methods (`start`, `refresh`, `destroy`, …) run on the main actor; change listeners are
/// called on the main thread.
public final class GuidelyFlagsClient: @unchecked Sendable {
    public let sdkKey: String
    public let options: FlagsOptions
    let api: GuidelyAPI
    let store: GuidelyKeyValueStore
    let scheduler: GuidelyScheduler
    /// Embedded in the Guidely SDK: exposures go through the event pipeline, not `/flags/events`.
    let embedded: Bool
    /// Dev overrides read from the environment at start (§4.1); win over `overrides`.
    public let devOverrides: [String: JSONValue]
    private let sticky: FlagStickyBucketStore?
    /// Evaluation clock (schedules and ramps). Set before use from tests.
    public var now: @Sendable () -> Date = { Date() }

    // Hooks, set once before `start()`.
    var onError: ((Error) -> Void)?
    var logger: ((String) -> Void)?
    /// Warnings shown without `debug` (dev overrides left set in a release build). Default `NSLog`.
    var warner: (String) -> Void = { NSLog("%@", "[Guidely] \($0)") }
    /// Embedded mode: every in-experiment evaluation (the engine dedupes per session).
    var exposureSink: (@MainActor (FlagEvaluationResult) -> Void)?
    /// Whether usage may be sent now (consent); counts are kept until it may.
    var usageAllowed: (@MainActor () -> Bool)?

    #if canImport(Combine)
    /// Fires (on the main thread) when flag values may have changed, so `@ObservedObject var flags`
    /// re-renders SwiftUI views.
    public let objectWillChange = ObservableObjectPublisher()
    #endif

    // MARK: Locked state

    private struct UsageKey: Hashable { let flag: String; let variationId: String?; let value: String }
    struct ExposureRecord: Encodable {
        let experiment: String
        let flag: String
        let variationId: String
        let hashAttribute: String
        let hashValue: String
        let userId: String?
        let anonymousId: String?
        let timestamp: String
    }

    private let lock = NSLock()
    private var _payload: FlagsPayload?
    private var _remote: [String: FlagEvaluationResult]?
    private var _remoteVersion = 0
    private var _baseAttributes: [String: JSONValue] = [:]
    private var _appAttributes: [String: JSONValue] = [:]
    private var _overrides: [String: JSONValue]
    private var _behaviour: FlagOverrideBehaviour
    private var _remoteMode: Bool
    private var _usage: [UsageKey: Int] = [:]
    private var _exposures: [ExposureRecord] = []
    private var _tracked = Set<String>()
    private var _listeners: [UUID: @MainActor () -> Void] = [:]
    private var _ready = false

    private func locked<T>(_ fn: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return fn()
    }

    // MARK: Main-actor state

    private var etag: String?
    private var started = false
    private var destroyed = false
    private var foreground = true
    private var pollTimer: GuidelyCancellable?
    private var usageTimer: GuidelyCancellable?
    private var reconnectTimer: GuidelyCancellable?
    private var streamTask: Task<Void, Never>?
    private(set) var streamConnected = false
    private var streamAttempt = 0
    private var sseEvent = ""
    private var sseData = ""
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var remoteSeq = 0
    private var firstFetch: Task<Void, Never>?
    private var lastSnapshot: [String: FlagEvaluationResult]?
    private var lifecycleObservers: [NSObjectProtocol] = []
    /// Interval of the usage report timer (seconds).
    var usageInterval: TimeInterval = 60

    // MARK: - Init

    /// A standalone flags client (no guides), e.g. for app extensions or flag-only apps. Call
    /// `start()` to begin fetching; cached flags are available immediately.
    @MainActor
    public convenience init(sdkKey: String, apiURL: URL = URL(string: "https://guidelytech.com")!, options: FlagsOptions = FlagsOptions(), attributes: [String: Any] = [:], storage: GuidelyStorageKind = .userDefaults, debug: Bool = false, transport: GuidelyTransport = URLSessionTransport(), store: GuidelyKeyValueStore? = nil, scheduler: GuidelyScheduler? = nil, observeAppLifecycle: Bool = true, onError: ((Error) -> Void)? = nil) {
        let kv = store ?? (storage == .memory ? InMemoryStore() : UserDefaultsStore())
        self.init(sdkKey: sdkKey, options: options, api: GuidelyAPI(baseURL: apiURL, key: sdkKey, transport: transport), store: kv, scheduler: scheduler ?? MainScheduler(), embedded: false,
                  onError: { error in
                      if debug { NSLog("[Guidely] %@", "\(error)") }
                      onError?(error)
                  },
                  logger: debug ? { NSLog("%@", "[Guidely] \($0)") } : nil)
        if !attributes.isEmpty { _appAttributes = JSONValue.object(from: attributes) }
        if observeAppLifecycle { self.observeAppLifecycle() }
    }

    /// `environment` is where dev overrides are read from (tests inject it); hooks are passed here so
    /// problems found while loading (bootstrap payload, dev overrides) reach them.
    @MainActor
    init(sdkKey: String, options: FlagsOptions, api: GuidelyAPI, store: GuidelyKeyValueStore, scheduler: GuidelyScheduler, embedded: Bool, environment: [String: String] = ProcessInfo.processInfo.environment, onError: ((Error) -> Void)? = nil, logger: ((String) -> Void)? = nil, warner: ((String) -> Void)? = nil) {
        self.sdkKey = sdkKey
        self.options = options
        self.api = api
        self.store = store
        self.scheduler = scheduler
        self.embedded = embedded
        self.onError = onError
        self.logger = logger
        if let warner { self.warner = warner }
        sticky = options.stickyBucketing ? PersistentStickyBucketStore(store: store, storageKey: StoreKeys.flagsSticky(sdkKey)) : nil
        let dev = options.devOverrides ? FlagDevOverrides.read(environment) : FlagDevOverrides()
        devOverrides = dev.values
        _overrides = options.overrides
        _behaviour = dev.behaviour ?? options.overrideBehaviour
        _remoteMode = options.remoteEval
        for e in dev.errors { reportError(GuidelyError("[Guidely] \(e)")) }
        if !dev.sources.isEmpty {
            let n = dev.values.count
            self.warner("Dev flag overrides from \(dev.sources.joined(separator: ", ")): \(n) flag\(n == 1 ? "" : "s"), behaviour \(_behaviour.rawValue).")
        }
        loadCached()
        lastSnapshot = snapshot()
    }

    deinit {
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func loadCached() {
        let key = sdkKey
        // localOnly is hermetic: a payload cached by an earlier run must not leak into tests.
        if _behaviour != .localOnly, let raw = store.get(StoreKeys.flags(key)), let data = raw.data(using: .utf8), let p = try? Self.decodePayload(data, decryptionKey: options.decryptionKey) {
            _payload = p
            etag = store.get(StoreKeys.flagsEtag(key))
        }
        if _behaviour != .localOnly, let raw = store.get(StoreKeys.flagsRemote(key)), let data = raw.data(using: .utf8), let r = Self.parseRemote(data) {
            _remote = r.flags
            _remoteVersion = r.version
        }
        if let boot = options.bootstrapPayload {
            if let r = Self.parseRemote(boot), r.isRemoteShape {
                if _remote == nil || r.version >= _remoteVersion { _remote = r.flags; _remoteVersion = r.version }
            } else if let p = try? Self.decodePayload(boot, decryptionKey: options.decryptionKey), _payload == nil || p.version >= _payload!.version {
                _payload = p
                etag = nil // the cached ETag belongs to the cached payload
            } else if _payload == nil {
                reportError(GuidelyError("[Guidely] flags bootstrapPayload could not be parsed"))
            }
        }
        _ready = _payload != nil || _remote != nil
    }

    // MARK: - Reading flags (any thread)

    /// The current payload (nil until loaded, or in remote-evaluation mode).
    public var payload: FlagsPayload? { locked { _payload } }

    /// Flags were loaded (from the network, the cache or a bootstrap payload).
    public var isReady: Bool { locked { _ready } }

    /// The attributes flags are evaluated with: automatic ones, then `FlagsOptions.attributes`, then `setAttributes`.
    public var attributes: [String: JSONValue] { locked { mergedAttributes() } }

    private func mergedAttributes() -> [String: JSONValue] {
        var a = _baseAttributes
        for (k, v) in options.attributes { a[k] = v }
        for (k, v) in _appAttributes { a[k] = v }
        return a
    }

    /// The boolean getter: the flag's value when it is a JSON boolean, otherwise `default` (missing,
    /// null, string, number and JSON flags all return `default`).
    public func isEnabled(_ key: String, default defaultValue: Bool = false) -> Bool {
        details(key).value.boolValue ?? defaultValue
    }

    /// The flag's value decoded as `T`; `default` when missing, null or not decodable as `T`.
    public func value<T: Decodable>(_ key: String, default defaultValue: T) -> T {
        Self.decode(details(key).value, as: T.self) ?? defaultValue
    }

    public func string(_ key: String, default defaultValue: String) -> String { details(key).value.stringValue ?? defaultValue }

    public func number(_ key: String, default defaultValue: Double) -> Double { details(key).value.numberValue ?? defaultValue }

    public func bool(_ key: String, default defaultValue: Bool) -> Bool { details(key).value.boolValue ?? defaultValue }

    /// The raw JSON value; `default` when missing or null.
    public func json(_ key: String, default defaultValue: JSONValue = .null) -> JSONValue {
        let v = details(key).value
        return v.isNull ? defaultValue : v
    }

    /// Value, reason, rule, variation and experiment assignment. Tracks usage and exposures.
    public func details(_ key: String) -> FlagEvaluationResult {
        let r = resolve(key, sticky: sticky)
        record(r)
        return r
    }

    /// Every known flag, evaluated for the current attributes (no usage or exposure tracking).
    public func allFeatures() -> [String: FlagEvaluationResult] { snapshot() }

    static func decode<T: Decodable>(_ v: JSONValue, as type: T.Type) -> T? {
        if v.isNull { return nil }
        if T.self == JSONValue.self { return v as? T }
        if T.self == String.self { return v.stringValue as? T }
        if T.self == Bool.self { return v.boolValue as? T }
        if T.self == Double.self { return v.numberValue as? T }
        if T.self == Int.self {
            guard let n = v.numberValue, n == n.rounded(), abs(n) < 9.2e18 else { return nil }
            return Int(n) as? T
        }
        guard let data = try? JSONEncoder().encode(v) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func resolve(_ key: String, sticky: FlagStickyBucketStore?) -> FlagEvaluationResult {
        let (payload, remote, attrs, overrides, behaviour, remoteMode) = locked { (_payload, _remote, mergedAttributes(), _overrides, _behaviour, _remoteMode) }
        if let ov = devOverrides[key] ?? overrides[key] {
            let existsRemotely = (remoteMode ? remote?[key] != nil : false) || payload?.flags[key] != nil
            if behaviour != .remoteOverLocal || !existsRemotely {
                return FlagEvaluationResult(key: key, value: ov, reason: .override)
            }
        }
        if remoteMode, let r = remote?[key] {
            var res = r
            if res.key.isEmpty { res.key = key }
            return res
        }
        guard let payload else { return .notFound(key) }
        return FlagEvaluator.evaluate(payload, key: key, attributes: attrs, now: now(), stickyBuckets: sticky)
    }

    private func knownKeys() -> Set<String> {
        locked {
            var keys = Set(_overrides.keys).union(devOverrides.keys)
            if let p = _payload { keys.formUnion(p.flags.keys) }
            if _remoteMode, let r = _remote { keys.formUnion(r.keys) }
            return keys
        }
    }

    /// Side-effect free evaluation of every flag (change detection, `allFeatures`).
    private func snapshot() -> [String: FlagEvaluationResult] {
        let ro = sticky.map(ReadOnlyStickyBucketStore.init)
        var out: [String: FlagEvaluationResult] = [:]
        for key in knownKeys() { out[key] = resolve(key, sticky: ro) }
        return out
    }

    private func record(_ r: FlagEvaluationResult) {
        // Overrides and errors are local outcomes, never usage (§4).
        if r.reason == .flagNotFound || r.reason == .override || r.reason == .error { return }
        var lifetimeNew = false
        let exp = r.inExperiment ? r.experiment : nil
        locked {
            if options.reportUsage {
                var text = r.value.jsonString
                if text.count > 200 { text = String(text.prefix(200)) }
                let k = UsageKey(flag: r.key, variationId: r.variationId, value: text)
                if _usage[k] != nil || _usage.count < 1000 { _usage[k, default: 0] += 1 }
            }
            if let exp {
                lifetimeNew = _tracked.insert("\(exp.key)|\(exp.hashAttributeValue)|\(exp.variationId)").inserted
                if lifetimeNew && !embedded && _exposures.count < 1000 {
                    let attrs = mergedAttributes()
                    _exposures.append(ExposureRecord(experiment: exp.key, flag: r.key, variationId: exp.variationId, hashAttribute: exp.hashAttribute, hashValue: exp.hashAttributeValue, userId: attrs["id"].flatMap { FlagValues.text($0) }, anonymousId: attrs["anonymousId"]?.stringValue, timestamp: ISODate.format(now())))
                }
            }
        }
        guard let exp else { return }
        if embedded { onMain { [weak self] in self?.exposureSink?(r) } }
        if lifetimeNew, let cb = options.trackingCallback { onMain { cb(exp, r) } }
    }

    private func onMain(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { work() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
        }
    }

    // MARK: - Changing inputs (any thread)

    /// Replaces the app-provided attributes (merged over the automatic ones). Values may be any
    /// JSON-compatible Swift value, including `Date`.
    public func setAttributes(_ attributes: [String: Any]) {
        let json = JSONValue.object(from: attributes)
        let changed = locked { () -> Bool in
            guard _appAttributes != json else { return false }
            _appAttributes = json
            return true
        }
        if changed { onMain { [weak self] in self?.attributesChanged() } }
    }

    /// Automatic attributes from the embedding SDK (identity, traits, device, screen).
    func setBaseAttributes(_ attributes: [String: JSONValue]) {
        let changed = locked { () -> Bool in
            guard _baseAttributes != attributes else { return false }
            _baseAttributes = attributes
            return true
        }
        if changed { onMain { [weak self] in self?.attributesChanged() } }
    }

    /// Replaces the local overrides (flag key → value), optionally changing how they combine with
    /// remote flags. Dev overrides (`devOverrides`) stay and keep winning over these.
    public func setOverrides(_ overrides: [String: Any], behaviour: FlagOverrideBehaviour? = nil) {
        let json = JSONValue.object(from: overrides)
        let wasLocalOnly = locked { () -> Bool in
            let was = _behaviour == .localOnly
            _overrides = json
            if let behaviour { _behaviour = behaviour }
            return was
        }
        onMain { [weak self] in
            guard let self else { return }
            self.stateChanged()
            if wasLocalOnly, self.behaviour != .localOnly, self.started { self.spawn { [weak self] in await self?.refresh() } }
        }
    }

    /// The overrides from `FlagsOptions.overrides` / `setOverrides` (dev overrides are in `devOverrides`).
    public var overrides: [String: JSONValue] { locked { _overrides } }
    public var behaviour: FlagOverrideBehaviour { locked { _behaviour } }
    /// Evaluating remotely (`remoteEval`, or switched on after a `remote_evaluation_required` answer).
    public var isRemoteEvaluation: Bool { locked { _remoteMode } }

    @MainActor
    private func attributesChanged() {
        if isRemoteEvaluation, started, behaviour != .localOnly, !destroyed {
            spawn { [weak self] in await self?.fetchRemote() }
        }
        stateChanged()
    }

    // MARK: - Change listeners

    /// Called on the main thread whenever flag values may have changed (new payload, remote results,
    /// attributes or overrides). Cancel the returned handle to stop listening.
    @discardableResult
    public func onChange(_ callback: @escaping @MainActor () -> Void) -> GuidelyCancellable {
        let id = UUID()
        locked { _listeners[id] = callback }
        return GuidelyCancellable { [weak self] in self?.locked { self?._listeners[id] = nil } }
    }

    @MainActor
    func stateChanged() {
        let snap = snapshot()
        guard snap != lastSnapshot else { return }
        lastSnapshot = snap
        #if canImport(Combine)
        objectWillChange.send()
        #endif
        for cb in locked({ Array(_listeners.values) }) { cb() }
    }

    // MARK: - Lifecycle (main actor)

    /// Fetches flags now and keeps them fresh (polling / streaming). Idempotent.
    @MainActor
    public func start() {
        guard !started, !destroyed else { return }
        started = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refresh()
            self.locked { self._ready = true }
        }
        firstFetch = task
        track(task)
        schedulePoll()
        scheduleUsage()
        connectStream()
    }

    /// Waits for the first fetch after `start()` (successful or not).
    @MainActor
    public func ready() async {
        await firstFetch?.value
    }

    /// Re-fetches the payload (or re-runs remote evaluation) now.
    @MainActor
    public func refresh() async {
        guard !destroyed, behaviour != .localOnly else { return }
        if isRemoteEvaluation { await fetchRemote() } else { await fetchPayload() }
    }

    /// The app returned to the foreground: refresh and reconnect the stream.
    @MainActor
    public func handleForeground() {
        guard !destroyed else { return }
        foreground = true
        guard started else { return }
        spawn { [weak self] in await self?.refresh() }
        connectStream()
    }

    /// The app moved to the background: stop streaming and send usage counts.
    @MainActor
    public func handleBackground() {
        foreground = false
        disconnectStream()
        spawn { [weak self] in await self?.flushUsage() }
    }

    /// Forgets the user (logout): remote results and per-user exposure bookkeeping.
    @MainActor
    func resetUser() {
        locked {
            _tracked.removeAll()
            if _remoteMode { _remote = nil; _remoteVersion = 0 }
        }
        store.remove(StoreKeys.flagsRemote(sdkKey))
        stateChanged()
    }

    /// Stops timers and the stream; queued usage is sent once more.
    @MainActor
    public func destroy() {
        guard !destroyed else { return }
        spawn { [weak self] in await self?.flushUsage() }
        destroyed = true
        pollTimer?.cancel(); usageTimer?.cancel(); reconnectTimer?.cancel()
        disconnectStream()
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        lifecycleObservers = []
    }

    @MainActor
    func spawn(_ work: @escaping @MainActor () async -> Void) {
        track(Task { @MainActor in await work() })
    }

    @MainActor
    private func track(_ task: Task<Void, Never>) {
        let id = UUID()
        tasks[id] = task
        Task { @MainActor [weak self] in
            await task.value
            self?.tasks[id] = nil
        }
    }

    @MainActor
    var hasPendingTasks: Bool { !tasks.isEmpty }

    /// Waits until in-flight requests have finished (tests).
    @MainActor
    func settle() async {
        var rounds = 0
        while let (id, task) = tasks.first, rounds < 1000 {
            await task.value
            tasks[id] = nil
            rounds += 1
        }
    }

    /// Standalone clients follow the app's foreground/background notifications (UIKit names, so
    /// this Foundation-only target does not need to import UIKit).
    @MainActor
    private func observeAppLifecycle() {
        let nc = NotificationCenter.default
        lifecycleObservers.append(nc.addObserver(forName: Notification.Name("UIApplicationWillEnterForegroundNotification"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.foreground == false { self?.handleForeground() } }
        })
        lifecycleObservers.append(nc.addObserver(forName: Notification.Name("UIApplicationDidEnterBackgroundNotification"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleBackground() }
        })
    }

    // MARK: - Fetching

    @MainActor
    private func schedulePoll() {
        pollTimer?.cancel()
        guard options.pollInterval > 0, !destroyed else { return }
        pollTimer = scheduler.schedule(after: max(1, options.pollInterval)) { [weak self] in
            guard let self, !self.destroyed else { return }
            if self.foreground, !self.streamConnected { self.spawn { [weak self] in await self?.refresh() } }
            self.schedulePoll()
        }
    }

    @MainActor
    private func scheduleUsage() {
        usageTimer?.cancel()
        guard !destroyed else { return }
        usageTimer = scheduler.schedule(after: usageInterval) { [weak self] in
            guard let self, !self.destroyed else { return }
            self.spawn { [weak self] in await self?.flushUsage() }
            self.scheduleUsage()
        }
    }

    @MainActor
    func fetchPayload() async {
        let hasPayload = payload != nil
        do {
            let res = try await api.get("/flags", etag: hasPayload ? etag : nil)
            if destroyed { return }
            if res.status == 304 {
                log("flags not modified")
                return
            }
            if res.status == 403, Self.errorCode(res.data) == "remote_evaluation_required" {
                reportError(GuidelyError("[Guidely] this environment only allows remote flag evaluation; set FlagsOptions.remoteEval = true. Switching to remote evaluation."))
                locked { _remoteMode = true }
                await fetchRemote()
                return
            }
            guard res.ok else {
                reportError(GuidelyError("[Guidely] flags request failed (\(res.status))\(hasPayload ? "; using cached flags" : "")"))
                return
            }
            let p = try Self.decodePayload(res.data, decryptionKey: options.decryptionKey)
            locked { _payload = p; _ready = true }
            etag = res.header("etag")
            if let raw = String(data: res.data, encoding: .utf8) { store.set(StoreKeys.flags(sdkKey), raw) }
            if let etag { store.set(StoreKeys.flagsEtag(sdkKey), etag) } else { store.remove(StoreKeys.flagsEtag(sdkKey)) }
            log("flags loaded v\(p.version): \(p.flagKeys.joined(separator: ", "))")
            stateChanged()
        } catch {
            reportError(GuidelyError("[Guidely] flags request failed: \(Self.describe(error))\(hasPayload ? "; using cached flags" : "")"))
        }
    }

    private struct EvaluateBody: Encodable { let attributes: [String: JSONValue] }

    @MainActor
    func fetchRemote() async {
        remoteSeq += 1
        let seq = remoteSeq
        let attrs = attributes
        do {
            let res = try await api.post("/flags/evaluate", EvaluateBody(attributes: attrs))
            guard seq == remoteSeq, !destroyed else { return }
            guard res.ok, let parsed = Self.parseRemote(res.data) else {
                reportError(GuidelyError("[Guidely] remote flag evaluation failed (\(res.status))"))
                return
            }
            locked { _remote = parsed.flags; _remoteVersion = parsed.version; _ready = true }
            if let raw = String(data: res.data, encoding: .utf8) { store.set(StoreKeys.flagsRemote(sdkKey), raw) }
            log("flags evaluated remotely v\(parsed.version): \(parsed.flags.keys.sorted().joined(separator: ", "))")
            stateChanged()
        } catch {
            if seq == remoteSeq { reportError(GuidelyError("[Guidely] remote flag evaluation failed: \(Self.describe(error))")) }
        }
    }

    /// Version of the data being served (payload version, or remote-evaluation version).
    public var version: Int { locked { _remoteMode ? _remoteVersion : (_payload?.version ?? 0) } }

    // MARK: - Streaming

    @MainActor
    private func connectStream() {
        guard options.streaming, started, !destroyed, foreground, streamTask == nil, behaviour != .localOnly else { return }
        reconnectTimer?.cancel()
        reconnectTimer = nil
        var req = api.makeRequest("GET", "/flags/stream")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 3600
        let transport = api.transport
        sseEvent = ""
        sseData = ""
        let task = Task { @MainActor [weak self] in
            var status = 0
            do {
                let res = try await transport.stream(req) { [weak self] line in await self?.handleStreamLine(line) }
                status = res.status
            } catch {
                if !Task.isCancelled { self?.log("flags stream error: \(Self.describe(error))") }
            }
            guard let self else { return }
            self.streamTask = nil
            self.streamConnected = false
            if Task.isCancelled || self.destroyed || !self.foreground { return }
            if status >= 400 && status < 500 && status != 429 {
                self.reportError(GuidelyError("[Guidely] flags stream rejected (\(status)); falling back to polling"))
                return
            }
            self.streamAttempt += 1
            self.reconnectTimer = self.scheduler.schedule(after: backoffSeconds(self.streamAttempt - 1, base: 1, max: 60)) { [weak self] in
                self?.connectStream()
            }
        }
        streamTask = task
    }

    @MainActor
    private func disconnectStream() {
        streamTask?.cancel()
        streamTask = nil
        streamConnected = false
        reconnectTimer?.cancel()
        reconnectTimer = nil
    }

    @MainActor
    func handleStreamLine(_ line: String) {
        if destroyed { return }
        streamConnected = true
        streamAttempt = 0
        if line.isEmpty {
            let event = sseEvent, data = sseData
            sseEvent = ""
            sseData = ""
            guard event == "flags" || (event.isEmpty && !data.isEmpty) else { return }
            let v = data.data(using: .utf8).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }?.objectValue?["version"]?.numberValue
            if let v, Int(v) <= version { return }
            log("flags changed (v\(v.map { String(Int($0)) } ?? "?")); refreshing")
            spawn { [weak self] in await self?.refresh() }
            return
        }
        if line.hasPrefix(":") { return }
        let (field, value): (Substring, Substring)
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            var v = line[line.index(after: colon)...]
            if v.first == " " { v = v.dropFirst() }
            value = v
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "event": sseEvent = String(value)
        case "data": sseData += (sseData.isEmpty ? "" : "\n") + value
        default: break
        }
    }

    // MARK: - Usage reporting

    private struct EventsBody: Encodable {
        struct SDK: Encodable { let name: String; let version: String }
        struct Usage: Encodable { let flag: String; let variationId: String?; let value: String; let count: Int }
        let sdk: SDK
        let usage: [Usage]?
        let exposures: [ExposureRecord]?
    }

    /// Sends aggregated usage counts (and standalone exposures) now. A `localOnly` client drops them
    /// instead: it makes no requests at all, so nothing a test evaluates reaches Guidely.
    @MainActor
    public func flushUsage() async {
        if behaviour == .localOnly {
            locked { _usage = [:]; _exposures = [] }
            return
        }
        if let allowed = usageAllowed, !allowed() { return }
        let (usage, exposures) = locked { () -> ([UsageKey: Int], [ExposureRecord]) in
            let u = _usage, e = _exposures
            _usage = [:]
            _exposures = []
            return (u, e)
        }
        guard !usage.isEmpty || !exposures.isEmpty else { return }
        let body = EventsBody(
            sdk: .init(name: GuidelySDKName, version: GuidelySDKVersion),
            usage: usage.isEmpty ? nil : usage.sorted { ($0.key.flag, $0.key.value) < ($1.key.flag, $1.key.value) }.map { .init(flag: $0.key.flag, variationId: $0.key.variationId, value: $0.key.value, count: $0.value) },
            exposures: exposures.isEmpty ? nil : exposures
        )
        var retry = true
        do {
            let res = try await api.post("/flags/events", body)
            log("flag usage → \(res.status) (\(usage.count) counters, \(exposures.count) exposures)")
            if res.ok { return }
            retry = !(res.status >= 400 && res.status < 500 && res.status != 429)
        } catch {
            log("flag usage failed: \(Self.describe(error))")
        }
        guard retry else { return }
        locked {
            for (k, n) in usage { _usage[k, default: 0] += n }
            _exposures = Array((exposures + _exposures).prefix(1000))
        }
    }

    // MARK: - Payload parsing, decryption

    /// Parses a `GET /flags` body, decrypting `encryptedPayload` (§1.3) when present.
    static func decodePayload(_ data: Data, decryptionKey: String?) throws -> FlagsPayload {
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        guard var envelope = json.objectValue else { throw GuidelyError("[Guidely] flags payload is not a JSON object") }
        if let encrypted = envelope["encryptedPayload"]?.stringValue {
            guard let key = decryptionKey, !key.isEmpty else { throw GuidelyError("[Guidely] flags payload is encrypted; set FlagsOptions.decryptionKey") }
            let plain = try decrypt(encrypted, key: key)
            guard let inner = (try? JSONDecoder().decode(JSONValue.self, from: plain))?.objectValue else { throw GuidelyError("[Guidely] decrypted flags payload is not a JSON object") }
            envelope["encryptedPayload"] = nil
            for (k, v) in inner { envelope[k] = v }
        }
        return FlagsPayload(json: .object(envelope))
    }

    /// AES-256-GCM: `"<base64 iv>.<base64 ciphertext+tag>"` with a base64 32-byte key.
    public static func decrypt(_ encrypted: String, key: String) throws -> Data {
        let parts = encrypted.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2, let iv = base64(parts[0]), let body = base64(parts[1]), iv.count == 12, body.count >= 16 else {
            throw GuidelyError("[Guidely] malformed encrypted flags payload")
        }
        guard let keyData = base64(key), keyData.count == 32 else { throw GuidelyError("[Guidely] decryptionKey must be base64 of 32 bytes") }
        do {
            let box = try AES.GCM.SealedBox(combined: iv + body)
            return try AES.GCM.open(box, using: SymmetricKey(data: keyData))
        } catch {
            throw GuidelyError("[Guidely] could not decrypt flags payload (wrong decryptionKey?)")
        }
    }

    /// Inverse of `decrypt` (tests and tooling).
    public static func encrypt(_ plaintext: Data, key: String, iv: Data? = nil) throws -> String {
        guard let keyData = base64(key), keyData.count == 32 else { throw GuidelyError("[Guidely] key must be base64 of 32 bytes") }
        let nonce = try iv.map { try AES.GCM.Nonce(data: $0) } ?? AES.GCM.Nonce()
        let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: keyData), nonce: nonce)
        return Data(box.nonce).base64EncodedString() + "." + (box.ciphertext + box.tag).base64EncodedString()
    }

    /// Standard or URL-safe base64, padding optional.
    static func base64(_ s: String) -> Data? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    struct RemoteResults {
        var version: Int
        var flags: [String: FlagEvaluationResult]
        /// Results carry `reason` (vs. a payload's flag definitions).
        var isRemoteShape: Bool
    }

    static func parseRemote(_ data: Data) -> RemoteResults? {
        guard let o = (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue, let flags = o["flags"]?.objectValue else { return nil }
        var out: [String: FlagEvaluationResult] = [:]
        var shaped = false
        for (k, v) in flags {
            guard let fo = v.objectValue else { continue }
            if fo["reason"] != nil { shaped = true }
            guard let enc = try? JSONEncoder().encode(v), var r = try? JSONDecoder().decode(FlagEvaluationResult.self, from: enc) else { continue }
            if r.key.isEmpty { r.key = k }
            out[k] = r
        }
        return RemoteResults(version: Int(FlagValues.coerceNumber(o["version"])), flags: out, isRemoteShape: shaped && o["salt"] == nil && o["segments"] == nil)
    }

    static func errorCode(_ data: Data) -> String? {
        (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue?["error"]?.objectValue?["code"]?.stringValue
    }

    static func describe(_ error: Error) -> String { (error as? GuidelyError)?.message ?? error.localizedDescription }

    // MARK: - Logging

    func reportError(_ error: Error) {
        log("error \(Self.describe(error))")
        onError?(error)
    }

    func log(_ message: @autoclosure () -> String) {
        logger?(message())
    }

    /// Snapshot for debugging.
    public var debugState: [String: Any] {
        locked {
            [
                "version": _remoteMode ? _remoteVersion : (_payload?.version ?? 0) as Any, "remoteEval": _remoteMode, "ready": _ready,
                "flags": (_payload?.flagKeys ?? []) as Any, "overrides": Array(_overrides.keys).sorted(), "devOverrides": Array(devOverrides.keys).sorted(), "behaviour": _behaviour.rawValue,
                "pendingUsage": _usage.count,
            ]
        }
    }
}

#if canImport(Combine)
extension GuidelyFlagsClient: ObservableObject {}
#endif
