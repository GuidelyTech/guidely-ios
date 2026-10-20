#if canImport(UIKit)
import SwiftUI
import UIKit
#if canImport(GuidelyCore)
import GuidelyCore
#endif

/// Guidely for iOS: in-app tours, tooltips, checklists, surveys, a resource center, and feature
/// flags & experiments (`Guidely.isFeatureEnabled(_:)`, `@FeatureFlag`, see FeatureFlags.swift).
///
/// ```swift
/// Guidely.configure(GuidelyOptions(projectId: "pk_dev_…"))
/// Guidely.shared.identify("user_1", traits: ["plan": "pro"])
/// Guidely.shared.screen("Deals")
/// Guidely.shared.track("deal_created", properties: ["value": 1200])
/// ```
///
/// All methods must be called on the main thread. The SDK never throws into the app: errors go to
/// `GuidelyOptions.onError`, the `.error` listener event and (with `debug: true`) the console.
@MainActor
public final class Guidely {
    /// The shared instance. Call `Guidely.configure(_:)` once at launch before using it.
    public static let shared = Guidely()

    /// The headless engine (advanced use / debugging). nil until configured.
    public private(set) var engine: GuidelyEngine?
    public private(set) var options: GuidelyOptions?
    private var overlay: OverlayController?
    private var observers: [NSObjectProtocol] = []
    private var listeners: [GuidelyEventType: [UUID: (GuidelyEvent) -> Void]] = [:]
    private var pendingScreen: String?
    private var pendingIdentify: (String, [String: JSONValue], GuidelyAccount?)?
    private var warnedUnconfigured = false

    private init() {}

    /// Configures the shared instance and starts loading the published config.
    public static func configure(_ options: GuidelyOptions) {
        shared.configure(options)
    }

    /// Configures (or re-configures) this instance. `transport` is for tests and proxies.
    public func configure(_ options: GuidelyOptions, transport: GuidelyTransport? = nil) {
        guard !options.projectId.isEmpty else {
            NSLog("[Guidely] configure: `projectId` (your environment public key, e.g. pk_dev_…) is required.")
            return
        }
        if let engine, engine.options.projectId == options.projectId, engine.options.apiURL == options.apiURL, !engine.isDestroyed {
            log("configure called again with the same key; ignoring")
            return
        }
        teardown()
        self.options = options
        let overlay = OverlayController(registry: GuidelyTargetRegistry.shared, launcherBottomOffset: CGFloat(options.launcherBottomOffset))
        let idiom = UIDevice.current.userInterfaceIdiom
        let host = GuidelyHostInfo(
            platform: "ios",
            device: DeviceInfo(type: idiom == .pad ? "tablet" : "mobile", os: "ios"),
            locale: GuidelyHostInfo.currentLocale,
            appVersion: options.appVersion ?? GuidelyHostInfo.bundleVersion,
            osVersion: UIDevice.current.systemVersion
        )
        let engine = GuidelyEngine(options: options, transport: transport ?? URLSessionTransport(), hostInfo: host)
        engine.presenter = overlay
        engine.targetResolver = GuidelyTargetRegistry.shared
        overlay.model.navigate = { [weak engine] url in engine?.navigate(url.absoluteString) }
        overlay.log = { [weak engine] msg in engine?.log(msg) }
        GuidelyTargetRegistry.shared.onTap = { [weak engine] id in engine?.handleTargetTap(id) }
        for type in GuidelyEventType.allCases {
            engine.on(type) { [weak self] event in self?.dispatch(event) }
        }
        self.engine = engine
        self.overlay = overlay
        GuidelyFlagsStore.shared.bind(engine.flags)
        overlay.prepare()
        observeLifecycle()
        engine.log("configure \(options.projectId) → \(options.apiURL.absoluteString) (\(options.resolvedEnvironment.rawValue)), SDK \(GuidelySDKName) \(GuidelySDKVersion)")
        if let (id, traits, account) = pendingIdentify {
            engine.identify(id, traits: traits, account: account)
            pendingIdentify = nil
        }
        if let s = pendingScreen {
            engine.screen(s)
            pendingScreen = nil
        }
        engine.start()
    }

    private func teardown() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        engine?.destroy()
        overlay?.teardown()
        if engine != nil { GuidelyFlagsStore.shared.bind(nil) }
        engine = nil
        overlay = nil
    }

    private func observeLifecycle() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.didEnterBackground() }
        })
        observers.append(nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.engine?.handleForeground() }
        })
    }

    private func didEnterBackground() {
        guard let engine else { return }
        var task: UIBackgroundTaskIdentifier = .invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "guidely.flush") {
            UIApplication.shared.endBackgroundTask(task)
            task = .invalid
        }
        engine.handleBackground()
        Task { @MainActor in
            await engine.flush()
            if task != .invalid { UIApplication.shared.endBackgroundTask(task); task = .invalid }
        }
    }

    private func requireEngine(_ fn: String) -> GuidelyEngine? {
        if let engine { return engine }
        if !warnedUnconfigured {
            warnedUnconfigured = true
            NSLog("[Guidely] \(fn) called before Guidely.configure(_:) — ignored.")
        }
        return nil
    }

    func log(_ message: String) { engine?.log(message) }

    // MARK: Identity

    /// Identifies the end user. Traits accept JSON-compatible values (String, numbers, Bool, Date, arrays, dictionaries).
    public func identify(_ userId: String, traits: [String: Any] = [:], account: GuidelyAccount? = nil) {
        let json = JSONValue.object(from: traits)
        guard let engine else {
            pendingIdentify = (userId, json, account)
            return
        }
        engine.identify(userId, traits: json, account: account)
    }

    /// Sets or replaces the account (company / organisation) of the current user.
    public func setAccount(_ account: GuidelyAccount) { requireEngine("setAccount")?.setAccount(account) }

    /// Merges traits into the current user.
    public func updateTraits(_ traits: [String: Any]) { requireEngine("updateTraits")?.updateTraits(JSONValue.object(from: traits)) }

    /// Forgets the user (log out): new anonymous id, cleared guide state, new session.
    public func reset() {
        pendingIdentify = nil
        requireEngine("reset")?.reset()
    }

    /// `granted` sends buffered events, `pending` buffers, `denied` drops them.
    public func setConsent(_ consent: GuidelyConsent) { requireEngine("setConsent")?.setConsent(consent) }

    public var anonymousId: String? { engine?.anonymousId }
    public var userId: String? { engine?.userId }
    /// Config loaded and triggers evaluated.
    public var isReady: Bool { engine?.isReady ?? false }

    // MARK: Events & screens

    /// Tracks a custom event (drives `event` triggers, `advanceOn: event` steps and checklist tasks).
    public func track(_ name: String, properties: [String: Any] = [:]) {
        requireEngine("track")?.track(name, properties: JSONValue.object(from: properties))
    }

    /// Records a screen view; URL patterns and multi-screen steps match `/<name>`.
    public func screen(_ name: String) {
        guard let engine else {
            pendingScreen = name
            return
        }
        engine.screen(name)
    }

    // MARK: Guides

    /// Starts a guide by id or key, bypassing targeting and frequency. Returns false for unknown guides.
    @discardableResult
    public func startGuide(_ idOrKey: String, stepId: String? = nil) -> Bool {
        requireEngine("startGuide")?.startGuide(idOrKey, stepId: stepId) ?? false
    }

    /// Stops the active guide without recording a dismissal.
    public func stopGuide() { engine?.stopGuide() }

    /// Dismisses the active guide (recorded as a dismissal).
    public func dismissGuide() { engine?.dismissGuide() }

    public var activeGuide: PublishedGuide? { engine?.activeGuide }

    /// Published guides delivered to iOS.
    public var guides: [PublishedGuide] { engine?.guides ?? [] }

    public func isGuideCompleted(_ idOrKey: String) -> Bool { engine?.isGuideCompleted(idOrKey) ?? false }

    // MARK: Checklists

    public func checklistProgress(_ idOrKey: String) -> ChecklistProgress { engine?.checklistProgress(idOrKey) ?? ChecklistProgress() }

    public func completeChecklistTask(_ idOrKey: String, taskId: String) { requireEngine("completeChecklistTask")?.completeChecklistTask(idOrKey, taskId: taskId) }

    public func openChecklist(_ idOrKey: String) { requireEngine("openChecklist")?.openChecklist(idOrKey) }

    public func closeChecklist(_ idOrKey: String) { engine?.closeChecklist(idOrKey) }

    // MARK: Resource center

    public func openResourceCenter() { requireEngine("openResourceCenter")?.openResourceCenter() }

    public func closeResourceCenter() { engine?.closeResourceCenter() }

    // MARK: Scout messenger

    /// Opens the Scout messenger (when it is enabled for iOS), optionally on a tab. No-op otherwise.
    public func openMessenger(_ tab: MessengerTab? = nil) { requireEngine("openMessenger")?.openMessenger(tab) }

    public func closeMessenger() { engine?.closeMessenger() }

    /// Opens a new conversation, optionally pre-filling the composer.
    public func showNewMessage(_ text: String? = nil) { requireEngine("showNewMessage")?.showNewMessage(text) }

    /// Whether the Scout messenger is enabled for this app (config loaded and iOS ticked in Scout settings).
    public var isMessengerEnabled: Bool { engine?.messenger != nil }

    // MARK: Config & events

    /// Re-fetches the published config (fire and forget).
    public func refresh() {
        guard let engine = requireEngine("refresh") else { return }
        Task { @MainActor in await engine.refresh() }
    }

    /// Sends queued analytics events now.
    public func flush() async { await engine?.flush() }

    /// Adds a listener. Listeners survive `configure` calls.
    @discardableResult
    public func on(_ type: GuidelyEventType, _ callback: @escaping (GuidelyEvent) -> Void) -> GuidelyListenerToken {
        let token = GuidelyListenerToken(id: UUID(), type: type)
        listeners[type, default: [:]][token.id] = callback
        return token
    }

    public func off(_ token: GuidelyListenerToken) {
        listeners[token.type]?[token.id] = nil
    }

    private func dispatch(_ event: GuidelyEvent) {
        for cb in (listeners[event.type] ?? [:]).values { cb(event) }
    }

    /// Ids of views currently registered as targets (debugging "guide not showing").
    public var registeredTargetIds: [String] { GuidelyTargetRegistry.shared.registeredIds }

    /// Snapshot of the SDK state (debugging).
    public var debugState: [String: Any] {
        var s = engine?.debugState ?? ["configured": false]
        s["targets"] = registeredTargetIds
        return s
    }
}
#endif
