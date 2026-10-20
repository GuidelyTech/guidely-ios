#if canImport(UIKit)
import Combine
import SwiftUI
#if canImport(GuidelyCore)
import GuidelyCore
#endif

// Feature flags & experiments on the Guidely facade. The getters are `nonisolated`: call them from
// any thread. They never throw and return `default` until flags load, for missing flags, and for
// null or wrong-type values.
//
// ```swift
// if Guidely.isFeatureEnabled("new-checkout") { … }
// let color = Guidely.featureString("checkout-button-color", default: "blue")
// struct Banner: View { @FeatureFlag("new-dashboard-banner") var showBanner; … }
// ```

extension Guidely {
    /// The flags client of the configured SDK (nil before `configure` or with `FlagsOptions(enabled: false)`).
    nonisolated public static var flags: GuidelyFlagsClient? { GuidelyFlagsStore.shared.client }

    /// Observable store behind the static getters and the SwiftUI helpers.
    nonisolated public static var flagsStore: GuidelyFlagsStore { .shared }

    /// The boolean getter: the flag's value when it is a JSON boolean, otherwise `default`.
    nonisolated public static func isFeatureEnabled(_ key: String, default defaultValue: Bool = false) -> Bool {
        GuidelyFlagsStore.shared.isEnabled(key, default: defaultValue)
    }

    /// The flag's value decoded as `T` (String, Double, Int, Bool, `JSONValue`, or any `Decodable`).
    nonisolated public static func featureValue<T: Decodable>(_ key: String, default defaultValue: T) -> T {
        GuidelyFlagsStore.shared.value(key, default: defaultValue)
    }

    nonisolated public static func featureString(_ key: String, default defaultValue: String) -> String {
        GuidelyFlagsStore.shared.string(key, default: defaultValue)
    }

    nonisolated public static func featureNumber(_ key: String, default defaultValue: Double) -> Double {
        GuidelyFlagsStore.shared.number(key, default: defaultValue)
    }

    nonisolated public static func featureBool(_ key: String, default defaultValue: Bool) -> Bool {
        GuidelyFlagsStore.shared.bool(key, default: defaultValue)
    }

    nonisolated public static func featureJSON(_ key: String, default defaultValue: JSONValue = .null) -> JSONValue {
        GuidelyFlagsStore.shared.json(key, default: defaultValue)
    }

    /// Value, reason, rule, variation and experiment assignment of a flag.
    nonisolated public static func featureDetails(_ key: String) -> FlagEvaluationResult {
        GuidelyFlagsStore.shared.details(key)
    }

    /// Every flag evaluated for the current user (does not track exposures).
    nonisolated public static func allFeatures() -> [String: FlagEvaluationResult] {
        GuidelyFlagsStore.shared.allFeatures()
    }

    /// Extra attributes for flag targeting, merged over the automatic ones (identity, traits,
    /// account, audiences, device, screen). Replaces the previous call's attributes. Accepts
    /// JSON-compatible values including `Date`. Safe to call before `configure`.
    nonisolated public static func setFlagAttributes(_ attributes: [String: Any]) {
        GuidelyFlagsStore.shared.setAttributes(attributes)
    }

    /// Local flag values (QA menus, previews, UI tests). Safe to call before `configure`.
    nonisolated public static func setFlagOverrides(_ overrides: [String: Any], behaviour: FlagOverrideBehaviour? = nil) {
        GuidelyFlagsStore.shared.setOverrides(overrides, behaviour: behaviour)
    }

    /// Re-fetches flags now (fire and forget).
    public static func refreshFlags() {
        Task { @MainActor in await GuidelyFlagsStore.shared.refresh() }
    }

    /// Re-fetches flags and waits for the answer.
    public static func refreshFlagsAsync() async {
        await GuidelyFlagsStore.shared.refresh()
    }

    /// Called on the main thread whenever flag values may have changed. Survives `configure` calls.
    @discardableResult
    nonisolated public static func onFlagsChange(_ callback: @escaping @MainActor () -> Void) -> GuidelyCancellable {
        GuidelyFlagsStore.shared.onChange(callback)
    }

    // Instance spellings for code that uses `Guidely.shared`.

    nonisolated public func isFeatureEnabled(_ key: String, default defaultValue: Bool = false) -> Bool { Self.isFeatureEnabled(key, default: defaultValue) }
    nonisolated public func featureValue<T: Decodable>(_ key: String, default defaultValue: T) -> T { Self.featureValue(key, default: defaultValue) }
    nonisolated public func featureDetails(_ key: String) -> FlagEvaluationResult { Self.featureDetails(key) }
    nonisolated public func allFeatures() -> [String: FlagEvaluationResult] { Self.allFeatures() }
    nonisolated public func setFlagAttributes(_ attributes: [String: Any]) { Self.setFlagAttributes(attributes) }
    nonisolated public func setFlagOverrides(_ overrides: [String: Any], behaviour: FlagOverrideBehaviour? = nil) { Self.setFlagOverrides(overrides, behaviour: behaviour) }
    public func refreshFlags() { Self.refreshFlags() }
    @discardableResult
    nonisolated public func onFlagsChange(_ callback: @escaping @MainActor () -> Void) -> GuidelyCancellable { Self.onFlagsChange(callback) }
}

// MARK: - SwiftUI

/// A boolean feature flag that re-renders the view when it changes. Non-boolean values (and missing
/// flags) give `default`.
///
/// ```swift
/// @FeatureFlag("new-dashboard-banner") var showBanner
/// ```
@MainActor
@propertyWrapper
public struct FeatureFlag: DynamicProperty {
    @ObservedObject private var store: GuidelyFlagsStore
    private let key: String
    private let defaultValue: Bool

    public init(_ key: String, default defaultValue: Bool = false, store: GuidelyFlagsStore = .shared) {
        self.key = key
        self.defaultValue = defaultValue
        _store = ObservedObject(wrappedValue: store)
    }

    public var wrappedValue: Bool { store.isEnabled(key, default: defaultValue) }

    /// `$flag`: the full evaluation (reason, variation, experiment).
    public var projectedValue: FlagEvaluationResult { store.details(key) }
}

/// A typed feature value (remote config) that re-renders the view when it changes.
///
/// ```swift
/// @FeatureValue("checkout-button-color", default: "blue") var buttonColor: String
/// ```
@MainActor
@propertyWrapper
public struct FeatureValue<Value: Decodable>: DynamicProperty {
    @ObservedObject private var store: GuidelyFlagsStore
    private let key: String
    private let defaultValue: Value

    public init(_ key: String, default defaultValue: Value, store: GuidelyFlagsStore = .shared) {
        self.key = key
        self.defaultValue = defaultValue
        _store = ObservedObject(wrappedValue: store)
    }

    public var wrappedValue: Value { store.value(key, default: defaultValue) }

    /// `$value`: the full evaluation (reason, variation, experiment).
    public var projectedValue: FlagEvaluationResult { store.details(key) }
}

/// Shows `content` when a boolean flag is `true`, otherwise `fallback` (non-boolean values count as `default`).
///
/// ```swift
/// FeatureGate("new-dashboard-banner") {
///     NewBanner()
/// } else: {
///     OldBanner()
/// }
/// ```
public struct FeatureGate<Content: View, Fallback: View>: View {
    @FeatureFlag private var enabled: Bool
    private let content: () -> Content
    private let fallback: () -> Fallback

    public init(_ key: String, default defaultValue: Bool = false, @ViewBuilder content: @escaping () -> Content, @ViewBuilder else fallback: @escaping () -> Fallback) {
        _enabled = FeatureFlag(key, default: defaultValue)
        self.content = content
        self.fallback = fallback
    }

    public var body: some View {
        if enabled { content() } else { fallback() }
    }
}

extension FeatureGate where Fallback == EmptyView {
    public init(_ key: String, default defaultValue: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.init(key, default: defaultValue, content: content, else: { EmptyView() })
    }
}
#endif
