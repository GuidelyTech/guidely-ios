import Foundation

// Port of `packages/sdk-core/src/client.ts` for native apps: screens replace URLs, registered
// target views replace DOM elements, and rendering is delegated to a `GuidelyPresenter`.

/// Why triggers are being evaluated.
enum EvalReason: String { case ready, navigation, event, click, visible, identify, afterGuide = "after_guide", timer, manual }

struct EvalDetail {
    var eventName: String?
    var target: String?
    var guideId: String?
    var endedGuide: PublishedGuide?
    var newAudiences: Set<String>?
}

/// Trigger types whose queued guides are dropped when the screen changes.
let PAGE_SCOPED: Set<TriggerType> = [.pageLoad, .urlMatch, .elementClick, .elementVisible, .delay]

@MainActor
final class ActiveGuide {
    let guide: PublishedGuide
    var controller: StepController?
    var survey: SurveyViewHandle?
    let manual: Bool
    let startUrl: String
    init(guide: PublishedGuide, manual: Bool, startUrl: String) { self.guide = guide; self.manual = manual; self.startUrl = startUrl }
}

@MainActor
final class WidgetEntry {
    var controller: StepController?
    var checklist: ChecklistViewHandle?
    private let onDestroy: () -> Void
    init(controller: StepController? = nil, checklist: ChecklistViewHandle? = nil, onDestroy: @escaping () -> Void) {
        self.controller = controller; self.checklist = checklist; self.onDestroy = onDestroy
    }
    func destroy() { onDestroy() }
}

struct QueuedGuide {
    let guide: PublishedGuide
    let url: String
    let pageScoped: Bool
}

struct IdentifyResponse: Decodable {
    var endUserId: String
    var audienceIds: [String]
    var guideState: [String: GuideLocalState]
    var checklistProgress: [String: ChecklistProgress]
    var surveysSubmitted: [String]
    var firstSeenAt: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: GKey.self)
        endUserId = c.lenient("endUserId", "")
        audienceIds = c.strings("audienceIds") ?? []
        guideState = c.lenient("guideState", [:])
        checklistProgress = c.lenient("checklistProgress", [:])
        surveysSubmitted = c.strings("surveysSubmitted") ?? []
        firstSeenAt = c.optional("firstSeenAt")
    }
}

/// Headless Guidely client engine. UI-free and main-actor bound; the `Guidely` facade wires it to
/// UIKit, but it can run anywhere (tests drive it with a fake transport, store and scheduler).
@MainActor
public final class GuidelyEngine: StepControllerHost {
    public let options: GuidelyOptions
    public let scheduler: GuidelyScheduler
    public var presenter: GuidelyPresenter?
    public weak var targetResolver: GuidelyTargetResolver?
    public var hostInfo: GuidelyHostInfo
    /// Debug log sink (default `NSLog`). Only called when `options.debug` is on.
    public var logger: (String) -> Void = { NSLog("%@", $0) }

    let api: GuidelyAPI
    let store: GuidelyKeyValueStore
    private(set) var queue: EventQueue!
    public private(set) var config: SdkConfig?
    private var etag: String?
    private var configFetchedAt: Date?
    public private(set) var anonymousId: String
    private(set) var user: StoredUser?
    private(set) var state: PersistedState
    private(set) var session: SessionState
    public private(set) var consent: GuidelyConsent
    public private(set) var isReady = false
    public private(set) var isDestroyed = false
    /// The end user's audiences from the last identify (audience-targeted help articles).
    public var audienceIds: Set<String> { Set(state.audienceIds) }
    private(set) var active: ActiveGuide?
    private(set) var queued: [QueuedGuide] = []
    private(set) var widgets: [String: WidgetEntry] = [:]
    private var resourceCenter: ResourceCenterViewHandle?
    /// Scout messenger (present only when `config.messenger.enabled`).
    public private(set) var messenger: MessengerController?
    /// Feature flags & experiments (nil when `options.flags?.enabled == false`).
    public private(set) var flags: GuidelyFlagsClient?
    private var messengerView: GuidelyViewHandle?
    private var timers: [GuidelyCancellable] = []
    private var visibilityObservers: [String: GuidelyCancellable] = [:]
    private var firedDelays = Set<String>()
    private(set) var firstVisit: Bool
    private var lastUrl: String
    private(set) var currentScreen: String?
    private var lastAudiences = Set<String>()
    private var listeners: [GuidelyEventType: [UUID: (GuidelyEvent) -> Void]] = [:]
    private var customListeners: [String: [UUID: @MainActor () -> Void]] = [:]
    private var tapListeners: [UUID: @MainActor (String) -> Void] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var identifyTask: Task<Void, Never>?
    private var started = false
    private var backgroundedAt: Date?
    private var pollTimer: GuidelyCancellable?
    private var refreshTimer: GuidelyCancellable?
    private var isForeground = true
    /// Poll interval for element-visibility triggers and queue draining (seconds).
    var pollInterval: TimeInterval = 1
    /// Retry base for state sync (seconds).
    var retryBase: TimeInterval = 0.5

    public init(options: GuidelyOptions, transport: GuidelyTransport = URLSessionTransport(), store: GuidelyKeyValueStore? = nil, scheduler: GuidelyScheduler? = nil, hostInfo: GuidelyHostInfo = GuidelyHostInfo()) {
        self.options = options
        self.scheduler = scheduler ?? MainScheduler()
        self.store = store ?? (options.storage == .memory ? InMemoryStore() : UserDefaultsStore())
        self.api = GuidelyAPI(baseURL: options.apiURL, key: options.projectId, transport: transport)
        var info = hostInfo
        if info.appVersion == nil { info.appVersion = options.appVersion ?? GuidelyHostInfo.bundleVersion }
        if options.appVersion != nil { info.appVersion = options.appVersion }
        self.hostInfo = info
        self.consent = options.consent
        let s = self.store
        if let anon = s.get(StoreKeys.anon), !anon.isEmpty { anonymousId = anon } else {
            anonymousId = "anon_\(GuidelyUtils.randomId(20))"
            s.set(StoreKeys.anon, anonymousId)
        }
        let now = self.scheduler.now
        firstVisit = s.get(StoreKeys.seen) == nil
        s.set(StoreKeys.seen, ISODate.format(now))
        state = s.readJSON(StoreKeys.state(options.projectId), as: PersistedState.self) ?? PersistedState()
        user = s.readJSON(StoreKeys.user(options.projectId), as: StoredUser.self)
        session = SessionState(id: "s_\(GuidelyUtils.randomId(16))", startedAt: now)
        lastUrl = "/"
        lastAudiences = Set(state.audienceIds)
        queue = EventQueue(
            store: s, storageKey: StoreKeys.queue(options.projectId), scheduler: self.scheduler,
            enabled: { [weak self] in self?.analyticsEnabled() ?? false },
            send: { [weak self] events in
                guard let self else { return .init(ok: false, retry: false) }
                let res = try await self.api.post("/events", EventBatch(events: events, sentAt: ISODate.format(self.scheduler.now), sdk: .init(name: GuidelySDKName, version: GuidelySDKVersion)))
                self.log("events → \(res.status) (\(events.count))")
                return .init(ok: res.ok, retry: !(res.status >= 400 && res.status < 500 && res.status != 429))
            },
            onError: { [weak self] err in self?.reportError(err) },
            spawn: { [weak self] work in self?.spawn(work) }
        )
        if options.flagsEnabled {
            let flags = GuidelyFlagsClient(sdkKey: options.projectId, options: options.flags ?? FlagsOptions(), api: api, store: s, scheduler: self.scheduler, embedded: true,
                                           onError: { [weak self] err in self?.reportError(err) }, logger: { [weak self] msg in self?.log(msg) })
            flags.exposureSink = { [weak self] result in self?.trackExperimentViewed(result) }
            flags.usageAllowed = { [weak self] in guard let self else { return false }; return self.options.analytics && self.consent == .granted }
            self.flags = flags
            syncFlagAttributes()
        }
    }

    // MARK: - Tasks

    /// Runs async work on the main actor and tracks it (see `settle()`).
    func spawn(_ work: @escaping @MainActor () async -> Void) {
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            await work()
            self?.tasks[id] = nil
        }
        tasks[id] = task
    }

    /// Waits until every tracked background task has finished (tests).
    func settle() async {
        var rounds = 0
        while rounds < 1000 {
            if let (id, task) = tasks.first {
                await task.value
                tasks[id] = nil
            } else if let flags, flags.hasPendingTasks {
                await flags.settle()
            } else { break }
            rounds += 1
        }
    }

    // MARK: - Lifecycle

    /// Loads config (cache first, then network), identifies the stored user, evaluates triggers.
    public func start() {
        guard !started else { return }
        started = true
        flags?.start()
        spawn { [weak self] in await self?.bootstrap() }
    }

    func bootstrap() async {
        let key = options.projectId
        if let raw = store.get(StoreKeys.config(key)), let data = raw.data(using: .utf8), let cached = try? JSONDecoder().decode(SdkConfig.self, from: data) {
            config = filterPlatform(cached)
            etag = store.get(StoreKeys.etag(key))
            if let at = store.get(StoreKeys.configFetchedAt(key)) { configFetchedAt = ISODate.parse(at) }
        }
        _ = await fetchConfig()
        if isDestroyed { return }
        wireTimers()
        if let t = identifyTask { await t.value } else if let u = user, !u.id.isEmpty {
            await identifyAsync(u.id, traits: nil, account: nil)
        }
        if isDestroyed { return }
        isReady = true
        if let config { emit(.ready(config)) }
        renderPersistentWidgets()
        evaluate(.ready)
    }

    @discardableResult
    func fetchConfig() async -> Bool {
        let key = options.projectId
        do {
            let res = try await api.get("/config", etag: config != nil ? etag : nil, params: ["platform": hostInfo.platform])
            if res.status == 304 {
                configFetchedAt = scheduler.now
                store.set(StoreKeys.configFetchedAt(key), ISODate.format(scheduler.now))
                log("config not modified")
                return true
            }
            if res.ok, let cfg = try? JSONDecoder().decode(SdkConfig.self, from: res.data) {
                let filtered = filterPlatform(cfg)
                config = filtered
                etag = res.header("etag")
                configFetchedAt = scheduler.now
                if let raw = String(data: res.data, encoding: .utf8) { store.set(StoreKeys.config(key), raw) }
                if let etag { store.set(StoreKeys.etag(key), etag) } else { store.remove(StoreKeys.etag(key)) }
                store.set(StoreKeys.configFetchedAt(key), ISODate.format(scheduler.now))
                emit(.config(filtered))
                log("config loaded v\(filtered.configVersion), \(filtered.guides.count) guides: \(filtered.guides.map(\.key).joined(separator: ", "))")
                return true
            }
            reportError(GuidelyError("[Guidely] config request failed (\(res.status))\(config != nil ? "; using cached config" : "")"))
            return false
        } catch {
            reportError(GuidelyError("[Guidely] config request failed: \(error.localizedDescription)\(config != nil ? "; using cached config" : "")"))
            return false
        }
    }

    private func filterPlatform(_ cfg: SdkConfig) -> SdkConfig {
        var c = cfg
        c.guides = cfg.guides.filter { GuidelyUtils.supportsPlatform($0.config.platforms, hostInfo.platform) }
        return c
    }

    private func wireTimers() {
        schedulePoll()
        scheduleRefresh()
    }

    private func schedulePoll() {
        pollTimer?.cancel()
        pollTimer = scheduler.schedule(after: pollInterval) { [weak self] in
            guard let self, !self.isDestroyed else { return }
            if self.isReady, self.isForeground, let config = self.config {
                let url = self.currentUrl()
                var ctx = self.getContext()
                for g in config.guides where g.config.trigger.type == .elementVisible && g.config.trigger.value != nil {
                    self.armVisibility(g, &ctx, url)
                }
                self.drainQueue(url, &ctx)
            }
            self.schedulePoll()
        }
    }

    private func scheduleRefresh() {
        refreshTimer?.cancel()
        let interval = max(30, options.configRefreshInterval)
        refreshTimer = scheduler.schedule(after: interval) { [weak self] in
            guard let self, !self.isDestroyed else { return }
            if self.isForeground { self.spawn { [weak self] in await self?.refresh() } }
            self.scheduleRefresh()
        }
    }

    /// Re-fetches the published config and re-evaluates triggers when it changed.
    public func refresh() async {
        if isDestroyed { return }
        let before = config?.configVersion
        await fetchConfig()
        if let config, config.configVersion != before {
            renderPersistentWidgets()
            if isReady { evaluate(.ready) }
        }
    }

    /// App moved to the background: flush events and remember when.
    public func handleBackground() {
        isForeground = false
        backgroundedAt = scheduler.now
        messenger?.setForeground(false)
        flags?.handleBackground()
        spawn { [weak self] in await self?.queue.flushAll() }
    }

    /// App returns to the foreground: new session after the timeout; refresh a stale config.
    public func handleForeground() {
        isForeground = true
        messenger?.setForeground(true)
        let now = scheduler.now
        if let bg = backgroundedAt {
            let timeout = (config?.settings.sessionTimeoutMinutes ?? 30) * 60
            if now.timeIntervalSince(bg) >= timeout {
                session = SessionState(id: "s_\(GuidelyUtils.randomId(16))", startedAt: now)
                firedDelays.removeAll()
                log("new session \(session.id)")
            }
        }
        guard backgroundedAt != nil else { return } // launch also posts willEnterForeground
        backgroundedAt = nil
        flags?.handleForeground()
        if configFetchedAt.map({ now.timeIntervalSince($0) >= options.configRefreshInterval }) ?? true {
            spawn { [weak self] in await self?.refresh() }
        }
    }

    /// Flushes queued events now.
    public func flush() async {
        await queue.flushAll()
        await flags?.flushUsage()
    }

    /// Tears everything down.
    public func destroy() {
        if isDestroyed { return }
        isDestroyed = true
        active?.controller?.destroy()
        active?.survey?.destroy()
        active = nil
        queued = []
        widgets.values.forEach { $0.destroy() }
        widgets.removeAll()
        resourceCenter?.destroy()
        resourceCenter = nil
        destroyMessenger()
        visibilityObservers.values.forEach { $0.cancel() }
        visibilityObservers.removeAll()
        timers.forEach { $0.cancel() }
        timers.removeAll()
        pollTimer?.cancel()
        refreshTimer?.cancel()
        queue.destroy()
        flags?.destroy()
        listeners.removeAll()
    }

    // MARK: - Identity

    /// Identifies the end user (fire and forget).
    public func identify(_ userId: String, traits: [String: JSONValue]? = nil, account: GuidelyAccount? = nil) {
        // Flags see the new identity immediately (the server sync below is async).
        syncFlagAttributes(mergedUser(userId, traits: traits, account: account))
        let previous = identifyTask
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await self?.identifyAsync(userId, traits: traits, account: account)
        }
        identifyTask = task
        let id = UUID()
        tasks[id] = Task { @MainActor [weak self] in
            await task.value
            self?.tasks[id] = nil
        }
    }

    /// Identifies the end user and loads server-held state (audiences, guide history, checklist progress).
    public func identifyAsync(_ userId: String, traits: [String: JSONValue]?, account: GuidelyAccount?) async {
        if isDestroyed { return }
        user = mergedUser(userId, traits: traits, account: account)
        persistUser()
        syncFlagAttributes()
        let merged = user?.traits ?? [:]
        enqueue(.identify, properties: ["traits": .object(GuidelyUtils.sanitizeProperties(merged))])
        await syncIdentify()
        emit(.identify(userId: userId, anonymousId: anonymousId))
        if isReady { evaluate(.identify) }
    }

    private func mergedUser(_ userId: String, traits: [String: JSONValue]?, account: GuidelyAccount?) -> StoredUser {
        let same = user?.id == userId
        var merged = same ? (user?.traits ?? [:]) : [:]
        for (k, v) in traits ?? [:] { merged[k] = v }
        let acct = account.map { StoredUser.Account(id: $0.id, traits: $0.traits) } ?? (same ? user?.account : nil)
        return StoredUser(id: userId, traits: merged, account: acct)
    }

    private struct IdentifyBody: Encodable {
        struct Account: Encodable { let id: String; let traits: [String: JSONValue]? }
        let anonymousId: String
        let userId: String?
        let traits: [String: JSONValue]?
        let account: Account?
        let sessionId: String
        let url: String?
    }

    private func syncIdentify() async {
        let body = IdentifyBody(
            anonymousId: anonymousId, userId: (user?.id).flatMap { $0.isEmpty ? nil : $0 },
            traits: user?.traits.map { GuidelyUtils.sanitizeProperties($0) },
            account: user?.account.map { IdentifyBody.Account(id: $0.id, traits: $0.traits.map { GuidelyUtils.sanitizeProperties($0) }) },
            sessionId: session.id, url: collectUrls() ? currentUrl() : nil
        )
        if let res = await postWithRetry("/identify", body, attempts: 2), res.ok {
            if let data = try? JSONDecoder().decode(IdentifyResponse.self, from: res.data) { mergeServerState(data) }
        }
    }

    func mergeServerState(_ data: IdentifyResponse) {
        var guides = state.guides
        for (id, s) in data.guideState {
            let local = guides[id]
            guides[id] = GuideLocalState(
                impressions: max(local?.impressions ?? 0, s.impressions),
                completedAt: local?.completedAt ?? s.completedAt,
                dismissedAt: local?.dismissedAt ?? s.dismissedAt,
                lastShownAt: local?.lastShownAt ?? s.lastShownAt
            )
        }
        var checklists = state.checklists
        for (id, p) in data.checklistProgress {
            let local = checklists[id]
            var ids = local?.completedTaskIds ?? []
            for t in p.completedTaskIds where !ids.contains(t) { ids.append(t) }
            checklists[id] = ChecklistProgress(completedTaskIds: ids, completedAt: local?.completedAt ?? p.completedAt, dismissedAt: local?.dismissedAt ?? p.dismissedAt)
        }
        var submitted = state.surveysSubmitted
        for s in data.surveysSubmitted where !submitted.contains(s) { submitted.append(s) }
        let firstSeen = state.firstSeenAt ?? data.firstSeenAt
        state = PersistedState()
        state.guides = guides
        state.checklists = checklists
        state.surveysSubmitted = submitted
        state.audienceIds = data.audienceIds
        state.firstSeenAt = firstSeen
        if let f = data.firstSeenAt, let ms = ISODate.parseMs(f), scheduler.now.timeIntervalSince1970 * 1000 - ms > 60_000 { firstVisit = false }
        persistState()
        syncFlagAttributes()
        for (id, w) in widgets {
            if let c = w.checklist, let g = findGuide(id) { c.setProgress(checklistProgress(g.id)) }
        }
    }

    /// Sets or replaces the account for the current user.
    public func setAccount(_ account: GuidelyAccount) {
        guard let u = user, !u.id.isEmpty else {
            user = StoredUser(id: user?.id ?? "", traits: user?.traits, account: .init(id: account.id, traits: account.traits))
            persistUser()
            syncFlagAttributes()
            return
        }
        identify(u.id, traits: nil, account: account)
    }

    /// Merges additional traits into the current user.
    public func updateTraits(_ traits: [String: JSONValue]) {
        guard let u = user, !u.id.isEmpty else {
            var merged = user?.traits ?? [:]
            for (k, v) in traits { merged[k] = v }
            user = StoredUser(id: "", traits: merged, account: user?.account)
            syncFlagAttributes()
            return
        }
        identify(u.id, traits: traits, account: u.account.map { GuidelyAccount(id: $0.id, jsonTraits: $0.traits ?? [:]) })
    }

    /// Forgets the user: new anonymous id, cleared guide/checklist state, new session, triggers re-evaluated.
    public func reset() {
        stopGuide()
        user = nil
        store.remove(StoreKeys.user(options.projectId))
        anonymousId = "anon_\(GuidelyUtils.randomId(20))"
        store.set(StoreKeys.anon, anonymousId)
        state = PersistedState()
        persistState()
        session = SessionState(id: "s_\(GuidelyUtils.randomId(16))", startedAt: scheduler.now)
        lastAudiences = []
        firedDelays.removeAll()
        queued = []
        widgets.values.forEach { $0.destroy() }
        widgets.removeAll()
        resourceCenter?.close()
        // Conversations belong to the previous user: forget their tokens and rebuild the messenger.
        MessengerTransport.forgetAll(store: store, projectId: options.projectId)
        destroyMessenger()
        flags?.resetUser()
        syncFlagAttributes()
        emit(.identify(userId: nil, anonymousId: anonymousId))
        if isReady {
            renderPersistentWidgets()
            evaluate(.identify)
        }
    }

    public var userId: String? { (user?.id).flatMap { $0.isEmpty ? nil : $0 } }

    // MARK: - Events

    /// `granted` flushes buffered events; `denied` drops them.
    public func setConsent(_ consent: GuidelyConsent) {
        self.consent = consent
        if consent == .denied { queue.clear() } else if consent == .granted { spawn { [weak self] in await self?.queue.flush() } }
    }

    func analyticsEnabled() -> Bool {
        // Events wait for the config so `settings.analyticsEnabled == false` is always honoured.
        options.analytics && consent == .granted && (config?.settings.analyticsEnabled ?? false)
    }

    private func collectUrls() -> Bool { config?.settings.collectUrls ?? true }

    @discardableResult
    func enqueue(_ name: SdkEventName, customName: String? = nil, guideId: String? = nil, guideVersion: Int? = nil, stepId: String? = nil, stepIndex: Int? = nil, properties: [String: JSONValue]? = nil) -> SdkEvent? {
        if consent == .denied || !options.analytics { return nil }
        let event = SdkEvent(
            eventId: GuidelyUtils.randomId(24), name: name, customName: customName, occurredAt: ISODate.format(scheduler.now),
            anonymousId: anonymousId, userId: userId, accountId: user?.account?.id, sessionId: session.id,
            guideId: guideId, guideVersion: guideVersion, stepId: stepId, stepIndex: stepIndex,
            url: collectUrls() ? currentUrl() : nil, properties: properties.map { GuidelyUtils.sanitizeProperties($0) }
        )
        queue.enqueue(event)
        emit(.track(event))
        return event
    }

    /// Tracks a custom event (drives `event` triggers, `advanceOn: event` steps and checklist tasks).
    public func track(_ name: String, properties: [String: JSONValue]? = nil) {
        if isDestroyed || name.isEmpty { return }
        if !session.events.contains(name) { session.events.append(name) }
        enqueue(.custom, customName: String(name.prefix(120)), properties: properties ?? [:])
        for cb in (customListeners[name] ?? [:]).values { cb() }
        completeChecklistTasksBy(.event, value: name)
        if isReady { evaluate(.event, EvalDetail(eventName: name)) }
    }

    /// Records a screen view (`page_view` with `{ path, screen }`) and re-evaluates triggers.
    public func screen(_ name: String) {
        if isDestroyed { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        currentScreen = trimmed.isEmpty ? nil : trimmed
        syncFlagAttributes()
        let path = GuidelyUtils.screenPath(trimmed)
        enqueue(.pageView, properties: ["path": .string(path), "screen": .string(trimmed)])
        log("screen \(path)")
        handleNavigation(path)
    }

    /// The current screen path (`/Deals`), standing in for the page URL.
    public func currentUrl() -> String { GuidelyUtils.screenPath(currentScreen) }

    private func handleNavigation(_ url: String) {
        let changed = url != lastUrl
        lastUrl = url
        completeChecklistTasksBy(.urlVisited, value: url)
        active?.controller?.resume()
        if let a = active, let c = a.controller, c.status == .running, !a.manual {
            let pats = a.guide.config.urlPatterns
            if !pats.isEmpty && !pats.contains(where: { GuidelyUtils.urlMatches($0, url) }) { c.destroy() }
        }
        // Screen-scoped banners / hotspots end too (a Deals tip should not follow the user to Contacts).
        for (id, w) in widgets {
            guard let c = w.controller, c.status == .running, let g = findGuide(id) else { continue }
            let pats = g.config.urlPatterns
            if !pats.isEmpty && !pats.contains(where: { GuidelyUtils.urlMatches($0, url) }) { c.destroy() }
        }
        firedDelays.removeAll()
        if isReady { evaluate(.navigation) }
        if changed { spawn { [weak self] in await self?.queue.flush() } }
    }

    /// A registered target view was tapped (element_click triggers, advanceOn, checklist `click` tasks).
    public func handleTargetTap(_ id: String) {
        if isDestroyed { return }
        log("tap \(id)")
        completeChecklistTasksBy(.click, value: id)
        for cb in Array(tapListeners.values) { cb(id) }
        if isReady { evaluate(.click, EvalDetail(target: id)) }
    }

    // MARK: - Feature flags

    /// Flag attributes derived from identity, traits, account, audiences, device and screen:
    /// `id` (user id, else anonymous id), `anonymousId`, every trait at top level (a trait never
    /// replaces `id` / `anonymousId`), `account` = `{ id, …traits }`, `$audiences`, `platform`,
    /// `appVersion`, `osVersion`, `deviceType` (`phone` / `tablet`), `locale`, `environment`, `screen`.
    public func flagAttributes() -> [String: JSONValue] { flagAttributes(for: user) }

    func flagAttributes(for u: StoredUser?) -> [String: JSONValue] {
        var a: [String: JSONValue] = ["platform": .string(hostInfo.platform), "environment": .string(options.resolvedEnvironment.rawValue)]
        if let v = hostInfo.appVersion { a["appVersion"] = .string(v) }
        if let v = hostInfo.osVersion { a["osVersion"] = .string(v) }
        let type = hostInfo.device.type
        a["deviceType"] = .string(type == "mobile" ? "phone" : type)
        if let l = hostInfo.locale { a["locale"] = .string(l) }
        if let s = currentScreen { a["screen"] = .string(s) }
        for (k, v) in u?.traits ?? [:] { a[k] = v }
        let uid = (u?.id).flatMap { $0.isEmpty ? nil : $0 }
        a["id"] = .string(uid ?? anonymousId)
        a["anonymousId"] = .string(anonymousId)
        if let acct = u?.account, !acct.id.isEmpty {
            var o = acct.traits ?? [:]
            o["id"] = .string(acct.id)
            a["account"] = .object(o)
        }
        a["$audiences"] = .array(state.audienceIds.sorted().map { .string($0) })
        return a
    }

    private func syncFlagAttributes(_ u: StoredUser? = nil) {
        guard let flags else { return }
        flags.setBaseAttributes(flagAttributes(for: u ?? user))
    }

    /// Records `experiment_viewed` once per (experiment, variation, user) per session.
    func trackExperimentViewed(_ result: FlagEvaluationResult) {
        guard !isDestroyed, result.inExperiment, let exp = result.experiment else { return }
        let id = "\(exp.key)|\(exp.variationId)|\(exp.hashAttributeValue)"
        guard session.experimentsViewed.insert(id).inserted else { return }
        var props: [String: JSONValue] = [
            "experimentKey": .string(exp.key), "variationId": .string(exp.variationId),
            "flagKey": .string(result.key), "hashAttribute": .string(exp.hashAttribute),
        ]
        if let name = exp.variationName { props["variationName"] = .string(name) }
        log("experiment \(exp.key) → \(exp.variationId) (\(result.key))")
        enqueue(.experimentViewed, properties: props)
    }

    // MARK: - Targeting + triggers

    /// Builds the targeting context for the current moment.
    public func getContext() -> TargetingContext {
        let guides = state.guides
        func keysOf(_ ids: [String]) -> Set<String> { Set(ids.flatMap { [$0, findGuide($0)?.key ?? $0] }) }
        let path = currentUrl()
        return TargetingContext(
            userId: userId, anonymousId: anonymousId,
            userAttributes: user?.traits ?? [:], accountAttributes: user?.account?.traits ?? [:],
            url: path, path: path, query: [:], device: hostInfo.device, firstVisit: firstVisit,
            eventsSeen: Set(session.events),
            completedGuides: keysOf(guides.filter { !($0.value.completedAt ?? "").isEmpty }.map(\.key)),
            dismissedGuides: keysOf(guides.filter { !($0.value.dismissedAt ?? "").isEmpty }.map(\.key)),
            seenGuides: keysOf(guides.filter { $0.value.impressions > 0 }.map(\.key)),
            completedChecklists: keysOf(state.checklists.filter { $0.value.isCompleted }.map(\.key)),
            audienceIds: Set(state.audienceIds), now: scheduler.now, environment: options.resolvedEnvironment.rawValue,
            locale: hostInfo.locale, platform: hostInfo.platform, screen: currentScreen, appVersion: hostInfo.appVersion
        )
    }

    func targetingContext() -> TargetingContext? { getContext() }

    private func isTargeted(_ guide: PublishedGuide, _ ctx: inout TargetingContext, _ url: String) -> Bool {
        let c = guide.config
        if !GuidelyUtils.supportsPlatform(c.platforms, hostInfo.platform) { return false }
        if !c.urlPatterns.isEmpty && !c.urlPatterns.contains(where: { GuidelyUtils.urlMatches($0, url) }) { return false }
        if let p = c.trigger.urlPattern, !p.isEmpty, !GuidelyUtils.urlMatches(p, url) { return false }
        if !Frequency.isWithinSchedule(guide, now: scheduler.now) { return false }
        if guide.kind == .survey && (state.surveysSubmitted.contains(guide.id) || state.surveysSubmitted.contains(guide.key)) { return false }
        ctx.rolloutSalt = guide.id
        return Targeting.evaluate(c.targeting, ctx)
    }

    private func isEligible(_ guide: PublishedGuide, _ ctx: inout TargetingContext, _ url: String) -> Bool {
        if !isTargeted(guide, &ctx, url) { return false }
        if guide.kind == .checklist { return (state.checklists[guide.id]?.dismissedAt ?? "").isEmpty }
        return Frequency.isEligible(guide.config.frequency, state: state.guides[guide.id], shownThisSession: session.shownGuides.contains(guide.id), now: scheduler.now)
    }

    private func triggerFires(_ guide: PublishedGuide, _ reason: EvalReason, _ detail: EvalDetail, _ url: String) -> Bool {
        let t = guide.config.trigger
        switch t.type {
        case .pageLoad:
            // Delayed page_load guides fire only from their own timer (matches the fixed reference engine).
            if t.delayMs > 0 { return reason == .timer && detail.guideId == guide.id }
            return reason == .ready || reason == .navigation || reason == .identify
        case .urlMatch:
            return (reason == .ready || reason == .navigation || reason == .identify) && GuidelyUtils.urlMatches(t.value, url)
        case .event:
            return reason == .event && !(t.value ?? "").isEmpty && detail.eventName == t.value
        case .elementClick:
            guard reason == .click, let target = detail.target, let id = GuidelyUtils.guidelyIdFromSelector(t.value) else { return false }
            return id == target
        case .elementVisible:
            return reason == .visible && detail.guideId == guide.id
        case .delay:
            return reason == .timer && detail.guideId == guide.id
        case .afterGuide:
            guard reason == .afterGuide, let ended = detail.endedGuide, let v = t.value else { return false }
            return ended.id == v || ended.key == v
        case .segmentEnter:
            guard reason == .identify, let v = t.value, !v.isEmpty else { return false }
            return detail.newAudiences?.contains(v) ?? false
        case .manual, .unknown:
            return false
        }
    }

    func evaluate(_ reason: EvalReason, _ detailIn: EvalDetail = EvalDetail()) {
        guard let config, !isDestroyed else { return }
        let url = currentUrl()
        var ctx = getContext()
        var detail = detailIn
        if reason == .identify {
            let current = Set(state.audienceIds)
            detail.newAudiences = current.subtracting(lastAudiences)
            lastAudiences = current
        }
        var candidates: [PublishedGuide] = []
        for guide in config.guides {
            let t = guide.config.trigger
            if let ended = detail.endedGuide, ended.id == guide.id { continue } // never re-show the guide that just ended
            if reason == .ready || reason == .navigation {
                if t.type == .elementVisible, t.value != nil { armVisibility(guide, &ctx, url) }
                if (t.type == .delay || (t.type == .pageLoad && t.delayMs > 0)) && !firedDelays.contains(guide.id) {
                    if !isEligible(guide, &ctx, url) { continue }
                    firedDelays.insert(guide.id)
                    let gid = guide.id
                    setTimer(Double(t.delayMs) / 1000) { [weak self] in self?.evaluate(.timer, EvalDetail(guideId: gid)) }
                    log("armed \(guide.key) in \(t.delayMs)ms")
                    continue
                }
            }
            if t.type == .pageLoad && t.delayMs > 0 && reason != .timer { continue }
            if t.type == .pageLoad && t.delayMs > 0 && reason == .timer && detail.guideId != guide.id { continue }
            if !triggerFires(guide, reason, detail, url) { continue }
            if !isEligible(guide, &ctx, url) { continue }
            candidates.append(guide)
        }
        if reason == .afterGuide || reason == .navigation { drainQueue(url, &ctx) }
        if candidates.isEmpty { return }
        let sorted = candidates.enumerated().sorted { a, b in
            a.element.config.frequency.priority != b.element.config.frequency.priority ? a.element.config.frequency.priority < b.element.config.frequency.priority : a.offset < b.offset
        }.map(\.element)
        log("evaluate(\(reason.rawValue)) → \(sorted.map(\.key).joined(separator: ", "))")
        for guide in sorted {
            if widgets[guide.id] != nil || active?.guide.id == guide.id { continue }
            let t = guide.config.trigger
            let delay = t.type != .delay && t.type != .pageLoad ? t.delayMs : 0
            if delay > 0 {
                setTimer(Double(delay) / 1000) { [weak self] in _ = self?.tryShow(guide, url, manual: false) }
                continue
            }
            _ = tryShow(guide, url, manual: false)
        }
    }

    private func armVisibility(_ guide: PublishedGuide, _ ctx: inout TargetingContext, _ url: String) {
        guard let selector = guide.config.trigger.value, visibilityObservers[guide.id] == nil else { return }
        guard let id = GuidelyUtils.guidelyIdFromSelector(selector) else { return }
        if !isEligible(guide, &ctx, url) { return }
        let gid = guide.id
        visibilityObservers[gid] = GuidelyCancellable()
        pollVisibility(gid, id)
    }

    private func pollVisibility(_ guideId: String, _ targetId: String) {
        guard let token = visibilityObservers[guideId], !token.isCancelled, !isDestroyed else { return }
        if targetResolver?.isTargetVisible(targetId) == true {
            visibilityObservers[guideId] = nil
            evaluate(.visible, EvalDetail(guideId: guideId))
            return
        }
        let handle = scheduler.schedule(after: 0.25) { [weak self] in self?.pollVisibility(guideId, targetId) }
        visibilityObservers[guideId] = GuidelyCancellable { handle.cancel() }
    }

    private func setTimer(_ seconds: TimeInterval, _ fn: @escaping @MainActor () -> Void) {
        var handle: GuidelyCancellable?
        handle = scheduler.schedule(after: seconds) { [weak self] in
            guard let self else { return }
            self.timers.removeAll { $0 === handle }
            if !self.isDestroyed { fn() }
        }
        if let handle { timers.append(handle) }
    }

    /// Decides whether a guide can show now, otherwise queues it.
    private func tryShow(_ guide: PublishedGuide, _ url: String, manual: Bool) -> Bool {
        if isDestroyed { return false }
        if !Frequency.isExclusive(guide) {
            if widgets[guide.id] != nil { return false }
            show(guide, manual: manual)
            return true
        }
        if let a = active {
            if a.guide.id == guide.id { return false }
            if manual { stopGuide() } else {
                if !queued.contains(where: { $0.guide.id == guide.id }) {
                    queued.append(QueuedGuide(guide: guide, url: url, pageScoped: PAGE_SCOPED.contains(guide.config.trigger.type)))
                }
                log("queued \(guide.key) behind \(a.guide.key)")
                return false
            }
        }
        let blocked = widgets.keys.compactMap { findGuide($0) }.contains { Frequency.areMutuallyExclusive($0, guide) }
        if blocked && !manual {
            if !queued.contains(where: { $0.guide.id == guide.id }) { queued.append(QueuedGuide(guide: guide, url: url, pageScoped: true)) }
            return false
        }
        show(guide, manual: manual)
        return true
    }

    private func drainQueue(_ url: String, _ ctx: inout TargetingContext) {
        if active != nil { return }
        queued = queued.filter { !($0.pageScoped && $0.url != url) }
        while !queued.isEmpty {
            let next = queued.removeFirst()
            if !isEligible(next.guide, &ctx, url) { continue }
            if tryShow(next.guide, url, manual: false) { return }
        }
    }

    // MARK: - Showing guides

    func findGuide(_ idOrKey: String) -> PublishedGuide? {
        config?.guides.first { $0.id == idOrKey || $0.key == idOrKey }
    }

    private func recordImpression(_ guide: PublishedGuide) {
        var s = state.guides[guide.id] ?? GuideLocalState()
        s.impressions += 1
        s.lastShownAt = ISODate.format(scheduler.now)
        state.guides[guide.id] = s
        if !session.shownGuides.contains(guide.id) { session.shownGuides.append(guide.id) }
        persistState()
        syncGuideState(guide.id, impression: true)
    }

    private func recordEnd(_ guide: PublishedGuide, _ reason: GuideEndReason) {
        var s = state.guides[guide.id] ?? GuideLocalState()
        if reason == .completed { s.completedAt = ISODate.format(scheduler.now) } else { s.dismissedAt = ISODate.format(scheduler.now) }
        state.guides[guide.id] = s
        persistState()
        syncGuideState(guide.id, completed: reason == .completed ? true : nil, dismissed: reason == .completed ? nil : true)
        if reason == .completed { completeChecklistTasksBy(.guideCompleted, guide: guide) }
    }

    private struct GuideStateBody: Encodable {
        struct Update: Encodable { let guideId: String; let impression: Bool?; let completed: Bool?; let dismissed: Bool? }
        let anonymousId: String
        let userId: String?
        let updates: [Update]
    }

    private func syncGuideState(_ guideId: String, impression: Bool? = nil, completed: Bool? = nil, dismissed: Bool? = nil) {
        let body = GuideStateBody(anonymousId: anonymousId, userId: userId, updates: [.init(guideId: guideId, impression: impression, completed: completed, dismissed: dismissed)])
        spawn { [weak self] in _ = await self?.postWithRetry("/guide-state", body) }
    }

    /// Fire-and-forget POST with bounded retries (state sync never blocks UI).
    func postWithRetry<T: Encodable & Sendable>(_ path: String, _ body: T, attempts: Int = 3) async -> HTTPResponse? {
        for i in 0..<attempts {
            do {
                let res = try await api.post(path, body)
                log("POST \(path) → \(res.status)")
                if res.ok || (res.status >= 400 && res.status < 500 && res.status != 429) { return res }
            } catch {
                log("POST \(path) failed: \(error.localizedDescription)")
            }
            if i < attempts - 1 { await scheduler.sleep(backoffSeconds(i, base: retryBase, max: 8)) }
        }
        return nil
    }

    private func show(_ guide: PublishedGuide, manual: Bool, stepId: String? = nil) {
        if guide.kind == .checklist, guide.config.checklist != nil { return showChecklist(guide) }
        if guide.kind == .survey, guide.config.survey != nil { return showSurvey(guide, manual: manual) }
        showFlow(guide, manual: manual, stepId: stepId)
    }

    private func showFlow(_ guide: PublishedGuide, manual: Bool, stepId: String?) {
        let exclusive = Frequency.isExclusive(guide)
        let entry = ActiveGuide(guide: guide, manual: manual, startUrl: currentUrl())
        let controller = StepController(guide: guide, host: self, theme: theme(guide.config.appearance), startAtStep: stepId)
        controller.onError = { [weak self] err in self?.reportError(err) }
        controller.onEvent = { [weak self] e in
            guard let self else { return }
            let step = e.stepId.flatMap { id in guide.config.steps.first { $0.id == id } }
            self.enqueue(e.name, guideId: guide.id, guideVersion: guide.version, stepId: e.stepId, stepIndex: e.stepIndex, properties: e.properties)
            switch e.name {
            case .guideStarted:
                self.recordImpression(guide)
                self.emit(.guideStart(guide))
            case .stepViewed:
                if let step { self.emit(.guideStep(guide, stepId: step.id, stepIndex: e.stepIndex ?? 0)) }
            case .guideCompleted:
                self.recordEnd(guide, .completed)
                self.emit(.guideComplete(guide))
            case .guideDismissed:
                self.recordEnd(guide, .dismissed)
                self.emit(.guideDismiss(guide))
            case .guideSkipped:
                self.recordEnd(guide, .skipped)
                self.emit(.guideSkip(guide))
            default:
                break
            }
        }
        controller.onNavigate = { [weak self] url, _ in self?.navigate(url) }
        controller.onAction = { [weak self] action, value, _ in
            guard let self else { return }
            switch action {
            case .startGuide:
                if let v = value, !v.isEmpty { self.setTimer(0) { [weak self] in _ = self?.startGuide(v) } }
            case .event:
                if let v = value, !v.isEmpty { self.track(v) }
            case .openResourceCenter:
                self.openResourceCenter()
            default:
                break
            }
        }
        controller.onEnd = { [weak self, weak controller] reason in
            guard let self else { return }
            if exclusive {
                if let c = controller, self.active?.controller === c { self.active = nil }
            } else {
                self.widgets[guide.id] = nil
            }
            if reason != .destroyed && !self.isDestroyed {
                self.setTimer(0) { [weak self] in self?.evaluate(.afterGuide, EvalDetail(endedGuide: guide)) }
            }
        }
        entry.controller = controller
        if exclusive { active = entry } else { widgets[guide.id] = WidgetEntry(controller: controller) { [weak controller] in controller?.destroy() } }
        log("show \(guide.key)\(manual ? " (manual)" : "")")
        controller.start()
        if controller.status == .ended {
            if exclusive && active === entry { active = nil }
            if !exclusive, widgets[guide.id]?.controller === controller { widgets[guide.id] = nil }
        }
    }

    private func showChecklist(_ guide: PublishedGuide) {
        guard let config = guide.config.checklist, widgets[guide.id] == nil, let presenter else { return }
        let progress = checklistProgress(guide.id)
        let first = (state.guides[guide.id]?.impressions ?? 0) == 0
        let gid = guide.id
        let handle = presenter.presentChecklist(ChecklistPresentation(
            guide: guide, config: config, progress: progress, open: config.autoOpen && first && !progress.isCompleted,
            showLauncher: options.showChecklistLauncher, theme: theme(guide.config.appearance),
            onTaskTap: { [weak self] task in self?.handleChecklistTaskTap(guide, task) },
            onDismiss: { [weak self] in self?.dismissChecklist(guide) },
            onOpen: { [weak self] in self?.enqueue(.guideViewed, guideId: gid, guideVersion: guide.version) },
            onClose: {}
        ))
        widgets[guide.id] = WidgetEntry(checklist: handle) { [weak handle] in handle?.destroy() }
        if first { recordImpression(guide) }
    }

    private func showSurvey(_ guide: PublishedGuide, manual: Bool) {
        guard let config = guide.config.survey, let presenter else { return }
        let entry = ActiveGuide(guide: guide, manual: manual, startUrl: currentUrl())
        var finished = false
        let finish: (Bool) -> Void = { [weak self, weak entry] submitted in
            guard let self, !finished else { return }
            finished = true
            entry?.survey?.destroy()
            if let e = entry, self.active === e { self.active = nil }
            if !submitted {
                self.enqueue(.surveyDismissed, guideId: guide.id, guideVersion: guide.version)
                self.recordEnd(guide, .dismissed)
                self.emit(.guideDismiss(guide))
            }
            self.setTimer(0) { [weak self] in self?.evaluate(.afterGuide, EvalDetail(endedGuide: guide)) }
        }
        let handle = presenter.presentSurvey(SurveyPresentation(
            guide: guide, config: config, title: guide.name, theme: theme(guide.config.appearance),
            onSubmit: { [weak self, weak entry] answers in
                guard let self else { return }
                let responseId = GuidelyUtils.randomId(24)
                if !self.state.surveysSubmitted.contains(guide.id) { self.state.surveysSubmitted.append(guide.id) }
                self.persistState()
                self.recordEnd(guide, .completed)
                self.enqueue(.surveySubmitted, guideId: guide.id, guideVersion: guide.version, properties: ["responseId": .string(responseId)])
                let json = answers.mapValues { $0.json }
                let body = SurveyBody(anonymousId: self.anonymousId, userId: self.userId, accountId: self.user?.account?.id, guideVersion: guide.version, answers: json, responseId: responseId)
                let path = "/surveys/\(guide.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? guide.id)/responses"
                self.spawn { [weak self] in _ = await self?.postWithRetry(path, body) }
                self.emit(.surveySubmit(guide, answers: json, responseId: responseId))
                self.emit(.guideComplete(guide))
                entry?.survey?.showThankYou()
            },
            onDismiss: { [weak self] in
                guard let self else { return }
                finish(self.state.surveysSubmitted.contains(guide.id))
            }
        ))
        entry.survey = handle
        active = entry
        recordImpression(guide)
        enqueue(.surveyDisplayed, guideId: guide.id, guideVersion: guide.version)
        emit(.guideStart(guide))
    }

    private struct SurveyBody: Encodable {
        let anonymousId: String
        let userId: String?
        let accountId: String?
        let guideVersion: Int
        let answers: [String: JSONValue]
        let responseId: String
    }

    /// Project theme + app overrides (+ guide appearance).
    public func theme(_ appearance: Appearance? = nil) -> ThemeInput {
        var t = config?.theme ?? .default
        if let o = options.theme {
            if let v = o.primaryColor { t.primaryColor = v }
            if let v = o.backgroundColor { t.backgroundColor = v }
            if let v = o.textColor { t.textColor = v }
            if let v = o.borderRadius { t.borderRadius = v }
            if let v = o.fontFamily { t.fontFamily = v }
        }
        return ThemeInput(project: t, appearance: appearance)
    }

    /// `http(s)` → external; relative paths and custom schemes → `onNavigate` (custom schemes fall back to opening externally).
    public func navigate(_ urlString: String) {
        let s = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, HTMLParser.isSafeLink(s) else {
            if !s.isEmpty { reportError(GuidelyError("[Guidely] refusing to open unsafe URL \(s)")) }
            return
        }
        guard let url = URL(string: s) ?? URL(string: s.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "") else {
            reportError(GuidelyError("[Guidely] invalid URL \(s)"))
            return
        }
        let scheme = url.scheme?.lowercased()
        if scheme == "http" || scheme == "https" {
            presenter?.openExternalURL(url)
        } else if let handler = options.onNavigate {
            handler(url)
        } else if scheme != nil {
            presenter?.openExternalURL(url)
        } else {
            reportError(GuidelyError("[Guidely] no onNavigate handler for \(s); set GuidelyOptions.onNavigate to handle relative paths"))
        }
    }

    func renderPersistentWidgets() {
        guard let config else { return }
        if let m = config.messenger, m.enabled {
            // One entry point: the messenger's Help tab replaces the resource center.
            resourceCenter?.destroy()
            resourceCenter = nil
            if messenger == nil { createMessenger(m, config) }
            return
        }
        destroyMessenger()
        let rc = config.resourceCenter
        if let rc, rc.enabled, resourceCenter == nil, let presenter {
            resourceCenter = presenter.presentResourceCenter(ResourceCenterPresentation(
                config: rc,
                guides: config.guides.map { ResourceCenterGuideRef(id: $0.id, key: $0.key, name: $0.name, kind: $0.kind) },
                theme: theme(), showLauncher: options.showResourceCenterLauncher,
                search: { [weak self] q in await self?.searchResourceCenter(q) ?? [] },
                onStartGuide: { [weak self] id in
                    self?.closeResourceCenter()
                    _ = self?.startGuide(id)
                },
                onOpenChecklist: { [weak self] id in
                    self?.closeResourceCenter()
                    self?.openChecklist(id)
                },
                onArticleView: { [weak self] a in self?.enqueue(.articleViewed, properties: ["articleId": .string(a.id), "slug": .string(a.slug)]) },
                onOpenURL: { [weak self] url in self?.navigate(url) },
                onOpen: { [weak self] in
                    self?.enqueue(.resourceCenterOpened)
                    self?.emit(.resourceCenterOpen)
                },
                onClose: {},
                audienceIds: { [weak self] in self?.audienceIds ?? [] }
            ))
        } else if rc == nil || rc?.enabled == false, let handle = resourceCenter {
            handle.destroy()
            resourceCenter = nil
        }
    }

    private func createMessenger(_ m: MessengerConfig, _ config: SdkConfig) {
        let transport = MessengerTransport(
            api: api, store: store, projectId: options.projectId,
            anonymousId: { [weak self] in self?.anonymousId ?? "" },
            userId: { [weak self] in self?.userId },
            pageUrl: { [weak self] in (self?.collectUrls() ?? false) ? self?.currentUrl() : nil }
        )
        let controller = MessengerController(
            config: m, transport: transport, scheduler: scheduler, resourceCenter: config.resourceCenter,
            guideRefs: config.guides.map { ResourceCenterGuideRef(id: $0.id, key: $0.key, name: $0.name, kind: $0.kind) }
        )
        controller.onOpen = { [weak self] in
            self?.enqueue(.messengerOpened)
            self?.emit(.messengerOpen)
        }
        controller.onMessage = { [weak self] message, conversation in self?.emit(.conversationMessage(message, conversation: conversation)) }
        controller.onStartGuide = { [weak self] key in _ = self?.startGuide(key) }
        controller.onOpenChecklist = { [weak self] id in self?.openChecklist(id) }
        controller.onArticleView = { [weak self] a in self?.enqueue(.articleViewed, properties: ["articleId": .string(a.id), "slug": .string(a.slug)]) }
        controller.onOpenURL = { [weak self] url in self?.navigate(url) }
        controller.audienceIds = { [weak self] in self?.audienceIds ?? [] }
        if !isForeground { controller.setForeground(false) }
        messenger = controller
        messengerView = presenter?.presentMessenger(MessengerPresentation(controller: controller, theme: theme(), showLauncher: options.showMessengerLauncher))
        controller.start()
        log("messenger \(m.name) on (ai: \(m.aiAvailable))")
    }

    private func destroyMessenger() {
        messenger?.destroy()
        messengerView?.destroy()
        messenger = nil
        messengerView = nil
    }

    // MARK: - Messenger

    /// Opens the Scout messenger (no-op unless it is enabled for iOS), optionally on a tab.
    public func openMessenger(_ tab: MessengerTab? = nil) {
        guard let messenger else {
            log("openMessenger: the messenger is not enabled for this platform")
            return
        }
        messenger.open(tab)
    }

    public func closeMessenger() { messenger?.close() }

    /// Opens a new conversation with the composer pre-filled.
    public func showNewMessage(_ text: String? = nil) { messenger?.showNewMessage(text) }

    private struct SearchResponse: Decodable {
        var articles: [ResourceCenterArticle]
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: GKey.self)
            articles = c.lossy("articles")
        }
    }

    func searchResourceCenter(_ q: String) async -> [ResourceCenterArticle] {
        do {
            let res = try await api.get("/resource-center/search", params: ["q": q])
            guard res.ok, let data = try? JSONDecoder().decode(SearchResponse.self, from: res.data) else { return [] }
            return data.articles
        } catch {
            return []
        }
    }

    // MARK: - Checklists

    /// Current progress for a checklist guide (by id or key).
    public func checklistProgress(_ idOrKey: String) -> ChecklistProgress {
        let id = findGuide(idOrKey)?.id ?? idOrKey
        return state.checklists[id] ?? ChecklistProgress()
    }

    /// Marks a checklist task complete and syncs progress.
    public func completeChecklistTask(_ idOrKey: String, taskId: String) {
        guard let guide = findGuide(idOrKey), let task = guide.config.checklist?.tasks.first(where: { $0.id == taskId }) else { return }
        markTaskDone(guide, task)
    }

    private struct ChecklistBody: Encodable {
        let anonymousId: String
        let userId: String?
        let guideVersion: Int
        let completedTaskIds: [String]
        let completed: Bool?
        let dismissed: Bool?
    }

    private func markTaskDone(_ guide: PublishedGuide, _ task: ChecklistTask) {
        guard let config = guide.config.checklist else { return }
        var progress = state.checklists[guide.id] ?? ChecklistProgress()
        if progress.completedTaskIds.contains(task.id) { return }
        progress.completedTaskIds.append(task.id)
        enqueue(.checklistTaskCompleted, guideId: guide.id, guideVersion: guide.version, properties: ["taskId": .string(task.id)])
        let complete = ChecklistLogic.isComplete(config, completedTaskIds: progress.completedTaskIds) && !progress.isCompleted
        if complete {
            progress.completedAt = ISODate.format(scheduler.now)
            enqueue(.checklistCompleted, guideId: guide.id, guideVersion: guide.version)
        }
        state.checklists[guide.id] = progress
        persistState()
        widgets[guide.id]?.checklist?.setProgress(progress)
        let body = ChecklistBody(anonymousId: anonymousId, userId: userId, guideVersion: guide.version, completedTaskIds: progress.completedTaskIds, completed: progress.isCompleted, dismissed: nil)
        let path = "/checklists/\(guide.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? guide.id)/progress"
        spawn { [weak self] in _ = await self?.postWithRetry(path, body) }
        emit(.checklistTask(guide, task: task, progress: progress))
        if complete {
            emit(.checklistComplete(guide))
            widgets[guide.id]?.checklist?.open()
        }
    }

    private func completeChecklistTasksBy(_ kind: ChecklistCompletion, value: String? = nil, guide ended: PublishedGuide? = nil) {
        guard let config else { return }
        for guide in config.guides {
            guard let tasks = guide.config.checklist?.tasks else { continue }
            for task in tasks where task.completion == kind {
                guard let cv = task.completionValue, !cv.isEmpty else { continue }
                var hit = false
                switch kind {
                case .event: hit = value == cv
                case .urlVisited: hit = GuidelyUtils.urlMatches(cv, value ?? "")
                case .guideCompleted: hit = ended.map { $0.id == cv || $0.key == cv } ?? false
                case .click: hit = GuidelyUtils.guidelyIdFromSelector(cv) == value
                default: hit = false
                }
                if hit { markTaskDone(guide, task) }
            }
        }
    }

    private func handleChecklistTaskTap(_ guide: PublishedGuide, _ task: ChecklistTask) {
        if task.completion == .manual { markTaskDone(guide, task) }
        switch task.action {
        case .startGuide:
            if let v = task.actionValue, !v.isEmpty {
                widgets[guide.id]?.checklist?.close()
                _ = startGuide(v)
            }
        case .url:
            if let v = task.actionValue, !v.isEmpty {
                widgets[guide.id]?.checklist?.close()
                navigate(v)
            }
        case .event:
            if let v = task.actionValue, !v.isEmpty { track(v) }
        case .none:
            break
        }
    }

    private func dismissChecklist(_ guide: PublishedGuide) {
        var progress = state.checklists[guide.id] ?? ChecklistProgress()
        progress.dismissedAt = ISODate.format(scheduler.now)
        state.checklists[guide.id] = progress
        persistState()
        enqueue(.checklistDismissed, guideId: guide.id, guideVersion: guide.version)
        let body = ChecklistBody(anonymousId: anonymousId, userId: userId, guideVersion: guide.version, completedTaskIds: progress.completedTaskIds, completed: nil, dismissed: true)
        let path = "/checklists/\(guide.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? guide.id)/progress"
        spawn { [weak self] in _ = await self?.postWithRetry(path, body) }
        widgets[guide.id]?.destroy()
        widgets[guide.id] = nil
    }

    /// Opens (rendering if needed) the checklist panel.
    public func openChecklist(_ idOrKey: String) {
        guard let guide = findGuide(idOrKey), guide.config.checklist != nil else {
            reportError(GuidelyError("[Guidely] openChecklist: unknown checklist \"\(idOrKey)\""))
            return
        }
        if widgets[guide.id] == nil {
            if var p = state.checklists[guide.id], p.dismissedAt != nil {
                p.dismissedAt = nil
                state.checklists[guide.id] = p
                persistState()
            }
            showChecklist(guide)
        }
        widgets[guide.id]?.checklist?.open()
    }

    public func closeChecklist(_ idOrKey: String) {
        guard let guide = findGuide(idOrKey) else { return }
        widgets[guide.id]?.checklist?.close()
    }

    // MARK: - Public guide controls

    /// Starts a guide by id or key, bypassing targeting and frequency rules.
    @discardableResult
    public func startGuide(_ idOrKey: String, stepId: String? = nil) -> Bool {
        guard let guide = findGuide(idOrKey) else {
            reportError(GuidelyError("[Guidely] startGuide: unknown guide \"\(idOrKey)\"\(config == nil ? " (config not loaded yet)" : "")"))
            return false
        }
        if guide.kind == .checklist {
            openChecklist(guide.id)
            return true
        }
        if active != nil { stopGuide() }
        widgets[guide.id]?.destroy()
        widgets[guide.id] = nil
        show(guide, manual: true, stepId: stepId)
        return true
    }

    /// Stops the active guide silently (no dismiss event).
    public func stopGuide() {
        guard let a = active else { return }
        active = nil
        a.controller?.destroy()
        a.survey?.destroy()
    }

    /// Dismisses the active guide (records a dismissal).
    public func dismissGuide() {
        guard let a = active else { return }
        if let c = a.controller { c.dismiss() } else {
            stopGuide()
            recordEnd(a.guide, .dismissed)
            emit(.guideDismiss(a.guide))
        }
    }

    public var activeGuide: PublishedGuide? { active?.guide }
    public var guides: [PublishedGuide] { config?.guides ?? [] }

    public func isGuideCompleted(_ idOrKey: String) -> Bool {
        let id = findGuide(idOrKey)?.id ?? idOrKey
        return !(state.guides[id]?.completedAt ?? "").isEmpty
    }

    public func openResourceCenter() {
        if let messenger { return messenger.open(.help) }
        if resourceCenter == nil { renderPersistentWidgets() }
        guard let rc = resourceCenter else {
            reportError(GuidelyError("[Guidely] openResourceCenter: no resource center is published\(config == nil ? " (config not loaded yet)" : "")"))
            return
        }
        rc.open()
    }

    public func closeResourceCenter() {
        if let messenger { return messenger.close() }
        resourceCenter?.close()
    }

    // MARK: - Listeners

    @discardableResult
    public func on(_ type: GuidelyEventType, _ cb: @escaping (GuidelyEvent) -> Void) -> GuidelyListenerToken {
        let token = GuidelyListenerToken(id: UUID(), type: type)
        listeners[type, default: [:]][token.id] = cb
        return token
    }

    public func off(_ token: GuidelyListenerToken) {
        listeners[token.type]?[token.id] = nil
    }

    private func emit(_ event: GuidelyEvent) {
        for cb in (listeners[event.type] ?? [:]).values { cb(event) }
    }

    func subscribeEvent(_ name: String, _ cb: @escaping @MainActor () -> Void) -> GuidelyCancellable {
        let id = UUID()
        customListeners[name, default: [:]][id] = cb
        return GuidelyCancellable { [weak self] in self?.customListeners[name]?[id] = nil }
    }

    func subscribeTaps(_ cb: @escaping @MainActor (String) -> Void) -> GuidelyCancellable {
        let id = UUID()
        tapListeners[id] = cb
        return GuidelyCancellable { [weak self] in self?.tapListeners[id] = nil }
    }

    // MARK: - Internals

    /// Target ids the engine currently needs frames for (active + widget steps).
    public var anchoredTargetIds: [String] {
        var ids: [String] = []
        if let t = active?.controller?.targetId { ids.append(t) }
        for w in widgets.values { if let t = w.controller?.targetId { ids.append(t) } }
        return ids
    }

    /// Snapshot for debugging.
    public var debugState: [String: Any] {
        [
            "ready": isReady, "anonymousId": anonymousId, "userId": userId as Any, "consent": consent.rawValue,
            "configVersion": config?.configVersion as Any, "guides": guides.map(\.key), "screen": currentScreen as Any,
            "activeGuide": active.map { ["key": $0.guide.key, "step": $0.controller?.stepId as Any, "status": $0.controller?.status.rawValue as Any] } as Any,
            "queued": queued.map(\.guide.key), "widgets": widgets.keys.compactMap { findGuide($0)?.key }, "pendingEvents": queue.size,
            "sessionId": session.id, "flags": flags?.debugState as Any,
        ]
    }

    private func persistState() { store.writeJSON(StoreKeys.state(options.projectId), state) }

    private func persistUser() {
        if let user { store.writeJSON(StoreKeys.user(options.projectId), user) } else { store.remove(StoreKeys.user(options.projectId)) }
    }

    func reportError(_ err: Error) {
        let error = (err as? GuidelyError) ?? GuidelyError(err.localizedDescription)
        log("error \(error.message)")
        options.onError?(error)
        emit(.error(error))
    }

    public func log(_ message: @autoclosure () -> String) {
        if options.debug { logger("[Guidely] \(message())") }
    }
}
