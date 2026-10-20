import Foundation

public let GuidelySDKName = "guidely-ios"
public let GuidelySDKVersion = "0.1.0"

public enum GuidelyConsent: String, Sendable, Codable {
    /// Events are sent.
    case granted
    /// Events are dropped and the queue is cleared.
    case denied
    /// Events are buffered until consent is granted.
    case pending
}

public enum GuidelyEnvironment: String, Sendable, Codable {
    case development, staging, production

    /// `pk_prod…` → production, `pk_stag…` → staging, otherwise development.
    public static func infer(fromKey key: String) -> GuidelyEnvironment {
        key.hasPrefix("pk_prod") ? .production : key.hasPrefix("pk_stag") ? .staging : .development
    }
}

public enum GuidelyStorageKind: Sendable {
    /// `UserDefaults` suite `tech.guidely.sdk` (default).
    case userDefaults
    /// Nothing persists across launches.
    case memory
}

/// The organisation / company of the current user.
public struct GuidelyAccount: Sendable, Hashable {
    public var id: String
    public var traits: [String: JSONValue]

    /// Traits accept JSON-compatible values (String, numbers, Bool, Date, arrays, dictionaries).
    public init(id: String, traits: [String: Any] = [:]) {
        self.id = id
        self.traits = JSONValue.object(from: traits)
    }

    public init(id: String, jsonTraits: [String: JSONValue]) {
        self.id = id
        self.traits = jsonTraits
    }
}

/// Theme overrides applied on top of the project theme from the dashboard. Colors are `#rrggbb`.
public struct GuidelyTheme: Sendable, Hashable {
    public var primaryColor: String?
    public var backgroundColor: String?
    public var textColor: String?
    public var borderRadius: Double?
    public var fontFamily: String?

    public init(primaryColor: String? = nil, backgroundColor: String? = nil, textColor: String? = nil, borderRadius: Double? = nil, fontFamily: String? = nil) {
        self.primaryColor = primaryColor; self.backgroundColor = backgroundColor; self.textColor = textColor
        self.borderRadius = borderRadius; self.fontFamily = fontFamily
    }
}

/// SDK configuration passed to `Guidely.configure(_:)`.
public struct GuidelyOptions {
    /// Environment public key, e.g. `pk_dev_…`. Not a secret.
    public var projectId: String
    /// Base URL of the Guidely API (`https://guidelytech.com`; `http://localhost:3000` locally).
    public var apiURL: URL
    /// Defaults to the environment implied by the key prefix.
    public var environment: GuidelyEnvironment?
    /// Logs trigger decisions and requests (`[Guidely] …`).
    public var debug: Bool
    /// Send analytics events (guides still render when false).
    public var analytics: Bool
    /// Initial consent state (`pending` buffers events until `setConsent(.granted)`).
    public var consent: GuidelyConsent
    /// Host app version for `app.version` targeting. Defaults to `CFBundleShortVersionString`.
    public var appVersion: String?
    /// Overrides for the project theme.
    public var theme: GuidelyTheme?
    /// Show the floating checklist launcher (otherwise call `openChecklist(_:)` yourself).
    public var showChecklistLauncher: Bool
    /// Show a floating resource-center launcher (off by default; call `openResourceCenter()`).
    /// Ignored when the Scout messenger is on (its Help tab replaces the resource center).
    public var showResourceCenterLauncher: Bool
    /// Show the Scout messenger's chat bubble when the messenger is enabled for iOS (default true).
    public var showMessengerLauncher: Bool
    /// Extra bottom inset for floating launchers, e.g. the height of a custom tab bar. A visible
    /// `UITabBar` is detected automatically.
    public var launcherBottomOffset: Double
    /// How often the published config is refreshed (default 5 minutes).
    public var configRefreshInterval: TimeInterval
    public var storage: GuidelyStorageKind
    /// Feature flags & experiments (on by default; `FlagsOptions(enabled: false)` turns them off).
    /// `nil` means the defaults.
    public var flags: FlagsOptions?
    /// Receives relative paths (`/Deals`) and custom-scheme deep links from buttons, checklist tasks
    /// and links. `http(s)` URLs open externally.
    public var onNavigate: ((URL) -> Void)?
    /// SDK errors (never thrown into the app).
    public var onError: ((Error) -> Void)?

    public init(projectId: String, apiURL: URL = URL(string: "https://guidelytech.com")!, environment: GuidelyEnvironment? = nil, debug: Bool = false, analytics: Bool = true, consent: GuidelyConsent = .granted, appVersion: String? = nil, theme: GuidelyTheme? = nil, showChecklistLauncher: Bool = true, showResourceCenterLauncher: Bool = false, showMessengerLauncher: Bool = true, launcherBottomOffset: Double = 0, configRefreshInterval: TimeInterval = 300, storage: GuidelyStorageKind = .userDefaults, flags: FlagsOptions? = nil, onNavigate: ((URL) -> Void)? = nil, onError: ((Error) -> Void)? = nil) {
        self.projectId = projectId; self.apiURL = apiURL; self.environment = environment; self.debug = debug; self.analytics = analytics
        self.consent = consent; self.appVersion = appVersion; self.theme = theme; self.showChecklistLauncher = showChecklistLauncher
        self.showResourceCenterLauncher = showResourceCenterLauncher; self.showMessengerLauncher = showMessengerLauncher; self.launcherBottomOffset = launcherBottomOffset
        self.configRefreshInterval = configRefreshInterval; self.storage = storage; self.flags = flags; self.onNavigate = onNavigate; self.onError = onError
    }

    public var resolvedEnvironment: GuidelyEnvironment { environment ?? .infer(fromKey: projectId) }

    /// Whether the SDK loads feature flags.
    public var flagsEnabled: Bool { flags?.enabled ?? true }
}

/// An error reported by the SDK (`onError`, the `.error` listener event and debug logs).
public struct GuidelyError: Error, LocalizedError, Sendable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
    public var description: String { message }
}

/// Checklist progress (local + server merged).
public struct ChecklistProgress: Codable, Sendable, Hashable {
    public var completedTaskIds: [String]
    public var completedAt: String?
    public var dismissedAt: String?

    public init(completedTaskIds: [String] = [], completedAt: String? = nil, dismissedAt: String? = nil) {
        self.completedTaskIds = completedTaskIds; self.completedAt = completedAt; self.dismissedAt = dismissedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: GKey.self)
        completedTaskIds = c.strings("completedTaskIds") ?? []
        completedAt = c.optional("completedAt")
        dismissedAt = c.optional("dismissedAt")
    }

    public var isCompleted: Bool { !(completedAt ?? "").isEmpty }
}

/// Everything persisted per project key (`guidely:state:<key>`).
struct PersistedState: Codable {
    var guides: [String: GuideLocalState] = [:]
    var checklists: [String: ChecklistProgress] = [:]
    var surveysSubmitted: [String] = []
    var audienceIds: [String] = []
    var firstSeenAt: String?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: GKey.self)
        guides = c.lenient("guides", [:])
        checklists = c.lenient("checklists", [:])
        surveysSubmitted = c.strings("surveysSubmitted") ?? []
        audienceIds = c.strings("audienceIds") ?? []
        firstSeenAt = c.optional("firstSeenAt")
    }
}

struct StoredUser: Codable, Equatable {
    struct Account: Codable, Equatable { var id: String; var traits: [String: JSONValue]? }
    var id: String
    var traits: [String: JSONValue]?
    var account: Account?
}

struct SessionState {
    var id: String
    var startedAt: Date
    var shownGuides: [String] = []
    var events: [String] = []
    /// `experimentKey|variationId|hashValue` already tracked as `experiment_viewed` this session.
    var experimentsViewed = Set<String>()
}

/// Types of listener events (`on(_:_:)`).
public enum GuidelyEventType: String, Sendable, CaseIterable {
    case ready
    case config
    case guideStart = "guide:start"
    case guideStep = "guide:step"
    case guideComplete = "guide:complete"
    case guideDismiss = "guide:dismiss"
    case guideSkip = "guide:skip"
    case checklistTask = "checklist:task"
    case checklistComplete = "checklist:complete"
    case surveySubmit = "survey:submit"
    case resourceCenterOpen = "resource-center:open"
    case messengerOpen = "messenger:open"
    case conversationMessage = "conversation:message"
    case error
    case track
    case identify
}

/// Payload delivered to listeners.
public enum GuidelyEvent: Sendable {
    case ready(SdkConfig)
    case config(SdkConfig)
    case guideStart(PublishedGuide)
    case guideStep(PublishedGuide, stepId: String, stepIndex: Int)
    case guideComplete(PublishedGuide)
    case guideDismiss(PublishedGuide)
    case guideSkip(PublishedGuide)
    case checklistTask(PublishedGuide, task: ChecklistTask, progress: ChecklistProgress)
    case checklistComplete(PublishedGuide)
    case surveySubmit(PublishedGuide, answers: [String: JSONValue], responseId: String)
    case resourceCenterOpen
    case messengerOpen
    /// A Scout or team message received in the messenger.
    case conversationMessage(MessengerMessage, conversation: MessengerConversation)
    case error(GuidelyError)
    case track(SdkEvent)
    case identify(userId: String?, anonymousId: String)

    public var type: GuidelyEventType {
        switch self {
        case .ready: return .ready
        case .config: return .config
        case .guideStart: return .guideStart
        case .guideStep: return .guideStep
        case .guideComplete: return .guideComplete
        case .guideDismiss: return .guideDismiss
        case .guideSkip: return .guideSkip
        case .checklistTask: return .checklistTask
        case .checklistComplete: return .checklistComplete
        case .surveySubmit: return .surveySubmit
        case .resourceCenterOpen: return .resourceCenterOpen
        case .messengerOpen: return .messengerOpen
        case .conversationMessage: return .conversationMessage
        case .error: return .error
        case .track: return .track
        case .identify: return .identify
        }
    }

    /// The guide this event refers to, if any.
    public var guide: PublishedGuide? {
        switch self {
        case .guideStart(let g), .guideComplete(let g), .guideDismiss(let g), .guideSkip(let g), .checklistComplete(let g): return g
        case .guideStep(let g, _, _), .checklistTask(let g, _, _), .surveySubmit(let g, _, _): return g
        default: return nil
        }
    }
}

/// Returned by `on(_:_:)`; pass to `off(_:)`.
public struct GuidelyListenerToken: Hashable, Sendable {
    public let id: UUID
    public let type: GuidelyEventType
    public init(id: UUID = UUID(), type: GuidelyEventType) { self.id = id; self.type = type }
}

/// Host-app information used for targeting.
public struct GuidelyHostInfo: Sendable {
    public var platform: String
    public var device: DeviceInfo
    public var locale: String?
    public var appVersion: String?
    /// Operating system version (`17.4.1`), the `osVersion` flag attribute.
    public var osVersion: String?

    public init(platform: String = "ios", device: DeviceInfo = DeviceInfo(), locale: String? = nil, appVersion: String? = nil, osVersion: String? = GuidelyHostInfo.currentOSVersion) {
        self.platform = platform; self.device = device; self.locale = locale; self.appVersion = appVersion; self.osVersion = osVersion
    }

    public static var currentOSVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// BCP 47 tag of the user's preferred language (`en-GB`).
    public static var currentLocale: String {
        (Locale.preferredLanguages.first ?? Locale.current.identifier).replacingOccurrences(of: "_", with: "-")
    }

    public static var bundleVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
}
