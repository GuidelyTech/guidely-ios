import Foundation
#if canImport(Combine)
import Combine
#endif

/// The feature flags of the configured Guidely SDK, as an `ObservableObject` that survives
/// `Guidely.configure` calls. Backs the static `Guidely.isFeatureEnabled(…)` getters and the SwiftUI
/// helpers (`@FeatureFlag`, `@FeatureValue`, `FeatureGate`). Attributes and overrides set before
/// `configure` are applied once the SDK starts. Thread-safe; change notifications arrive on the main thread.
public final class GuidelyFlagsStore: @unchecked Sendable {
    public static let shared = GuidelyFlagsStore()

    #if canImport(Combine)
    public let objectWillChange = ObservableObjectPublisher()
    #endif

    private let lock = NSLock()
    private var _client: GuidelyFlagsClient?
    private var subscription: GuidelyCancellable?
    private var attributes: [String: JSONValue]?
    private var overrides: (values: [String: JSONValue], behaviour: FlagOverrideBehaviour?)?
    private var listeners: [UUID: @MainActor () -> Void] = [:]

    public init() {}

    /// The flags client of the running SDK (nil before `Guidely.configure` or with flags disabled).
    public var client: GuidelyFlagsClient? { lock.lock(); defer { lock.unlock() }; return _client }

    /// Points the store at another client (the SDK does this on `configure`).
    @MainActor
    public func bind(_ client: GuidelyFlagsClient?) {
        lock.lock()
        subscription?.cancel()
        subscription = nil
        _client = client
        let attrs = attributes, ovs = overrides
        lock.unlock()
        if let client {
            if let attrs { client.setAttributes(attrs) }
            if let ovs { client.setOverrides(ovs.values, behaviour: ovs.behaviour) }
            let sub = client.onChange { [weak self] in self?.notify() }
            lock.lock(); subscription = sub; lock.unlock()
        }
        notify()
    }

    @MainActor
    private func notify() {
        #if canImport(Combine)
        objectWillChange.send()
        #endif
        lock.lock()
        let cbs = Array(listeners.values)
        lock.unlock()
        for cb in cbs { cb() }
    }

    // MARK: Getters (any thread; defaults until flags load)

    public func isEnabled(_ key: String, default defaultValue: Bool = false) -> Bool { client?.isEnabled(key, default: defaultValue) ?? defaultValue }
    public func value<T: Decodable>(_ key: String, default defaultValue: T) -> T { client?.value(key, default: defaultValue) ?? defaultValue }
    public func string(_ key: String, default defaultValue: String) -> String { client?.string(key, default: defaultValue) ?? defaultValue }
    public func number(_ key: String, default defaultValue: Double) -> Double { client?.number(key, default: defaultValue) ?? defaultValue }
    public func bool(_ key: String, default defaultValue: Bool) -> Bool { client?.bool(key, default: defaultValue) ?? defaultValue }
    public func json(_ key: String, default defaultValue: JSONValue = .null) -> JSONValue { client?.json(key, default: defaultValue) ?? defaultValue }
    public func details(_ key: String) -> FlagEvaluationResult { client?.details(key) ?? .notFound(key) }
    public func allFeatures() -> [String: FlagEvaluationResult] { client?.allFeatures() ?? [:] }

    // MARK: Inputs

    /// App attributes merged over the automatic ones (kept across `configure`).
    public func setAttributes(_ attributes: [String: Any]) {
        let json = JSONValue.object(from: attributes)
        lock.lock()
        self.attributes = json
        let c = _client
        lock.unlock()
        c?.setAttributes(json)
    }

    /// Local overrides (kept across `configure`).
    public func setOverrides(_ overrides: [String: Any], behaviour: FlagOverrideBehaviour? = nil) {
        let json = JSONValue.object(from: overrides)
        lock.lock()
        self.overrides = (json, behaviour)
        let c = _client
        lock.unlock()
        c?.setOverrides(json, behaviour: behaviour)
    }

    /// Re-fetches flags now.
    @MainActor
    public func refresh() async { await client?.refresh() }

    /// Called on the main thread when flag values may have changed (including when the SDK is
    /// (re)configured). Listeners survive `configure` calls.
    @discardableResult
    public func onChange(_ callback: @escaping @MainActor () -> Void) -> GuidelyCancellable {
        let id = UUID()
        lock.lock(); listeners[id] = callback; lock.unlock()
        return GuidelyCancellable { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.listeners[id] = nil; self.lock.unlock()
        }
    }
}

#if canImport(Combine)
extension GuidelyFlagsStore: ObservableObject {}
#endif
