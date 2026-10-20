import Foundation

// Codable mirrors of `packages/shared/src/{guide,sdk-api}.ts`. Decoding is tolerant: missing or
// malformed fields take the schema default, unknown enum values map to a fallback case, and a guide
// that cannot be decoded at all is skipped (see `SdkConfig.guides`).

// MARK: - Enums

public enum GuideKind: String, LenientStringEnum, CaseIterable {
    case flow, modal, tooltip, banner, checklist, survey, announcement, unknown
    public static var fallbackCase: GuideKind { .unknown }
}

public enum StepType: String, LenientStringEnum, CaseIterable {
    case modal, tooltip, popover, spotlight, hotspot, banner, slideout, checklist, custom, survey
    /// Unknown step types render as modals.
    case unknown
    public static var fallbackCase: StepType { .unknown }

    /// Steps anchored to a target view.
    public var isAnchored: Bool { self == .tooltip || self == .popover || self == .spotlight || self == .hotspot }
}

public enum Placement: String, LenientStringEnum, CaseIterable {
    case top, topStart = "top-start", topEnd = "top-end"
    case right, rightStart = "right-start", rightEnd = "right-end"
    case bottom, bottomStart = "bottom-start", bottomEnd = "bottom-end"
    case left, leftStart = "left-start", leftEnd = "left-end"
    case auto
    public static var fallbackCase: Placement { .auto }
}

public enum TargetFallback: String, LenientStringEnum, CaseIterable {
    case skip, showAsModal = "show_as_modal", endGuide = "end_guide", wait
    public static var fallbackCase: TargetFallback { .skip }
}

public enum ButtonAction: String, LenientStringEnum, CaseIterable {
    case next, back, dismiss, complete, skip, url, startGuide = "start_guide", event, openResourceCenter = "open_resource_center", none
    public static var fallbackCase: ButtonAction { .none }
}

public enum ButtonVariant: String, LenientStringEnum, CaseIterable {
    case primary, secondary, ghost, link
    public static var fallbackCase: ButtonVariant { .primary }
}

public enum AdvanceOn: String, LenientStringEnum, CaseIterable {
    case button, elementClick = "element_click", elementVisible = "element_visible", event, delay, any
    public static var fallbackCase: AdvanceOn { .button }
}

public enum TriggerType: String, LenientStringEnum, CaseIterable {
    case pageLoad = "page_load", urlMatch = "url_match", event, elementClick = "element_click", elementVisible = "element_visible", manual, delay, afterGuide = "after_guide", segmentEnter = "segment_enter"
    /// Unknown trigger types never fire.
    case unknown
    public static var fallbackCase: TriggerType { .unknown }
}

public enum FrequencyMode: String, LenientStringEnum, CaseIterable {
    case once, oncePerSession = "once_per_session", everyTime = "every_time", interval
    public static var fallbackCase: FrequencyMode { .once }
}

public enum ThemeMode: String, LenientStringEnum, CaseIterable {
    case light, dark, auto
    public static var fallbackCase: ThemeMode { .auto }
}

public enum AnimationKind: String, LenientStringEnum, CaseIterable {
    case fade, slide, none
    public static var fallbackCase: AnimationKind { .fade }
}

public enum StepPosition: String, LenientStringEnum, CaseIterable {
    case top, bottom, topLeft = "top-left", topRight = "top-right", bottomLeft = "bottom-left", bottomRight = "bottom-right", center
    public static var fallbackCase: StepPosition { .bottomRight }
    public var isTop: Bool { rawValue.hasPrefix("top") }
}

public enum ChecklistCompletion: String, LenientStringEnum, CaseIterable {
    case manual, event, guideCompleted = "guide_completed", urlVisited = "url_visited", click
    /// Unknown completion modes never complete automatically.
    case unknown
    public static var fallbackCase: ChecklistCompletion { .unknown }
}

public enum ChecklistTaskAction: String, LenientStringEnum, CaseIterable {
    case none, startGuide = "start_guide", url, event
    public static var fallbackCase: ChecklistTaskAction { .none }
}

public enum LauncherPosition: String, LenientStringEnum, CaseIterable {
    case bottomRight = "bottom-right", bottomLeft = "bottom-left"
    public static var fallbackCase: LauncherPosition { .bottomRight }
}

public enum SurveyQuestionType: String, LenientStringEnum, CaseIterable {
    case nps, csat, thumbs, singleChoice = "single_choice", multipleChoice = "multiple_choice", text, rating
    public static var fallbackCase: SurveyQuestionType { .text }
}

public enum SurveyPosition: String, LenientStringEnum, CaseIterable {
    case bottomRight = "bottom-right", bottomLeft = "bottom-left", center
    public static var fallbackCase: SurveyPosition { .bottomRight }
}

// MARK: - Steps

public struct SelectorStrategy: Decodable, Sendable, Hashable {
    /// `guidely-id`, `id`, `css`, `data-attr`, `aria`, `text`, `xpath` (unknown kinds are ignored).
    public var kind: String
    public var value: String
    public var label: String?

    public init(kind: String, value: String, label: String? = nil) {
        self.kind = kind; self.value = value; self.label = label
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: GKey.self)
        kind = c.lenient("kind", "")
        value = try c.required("value")
        label = c.optional("label")
    }
}

public struct StepTarget: Decodable, Sendable, Hashable {
    public var selectors: [SelectorStrategy]
    public var waitMs: Int
    public var fallback: TargetFallback
    public var scrollIntoView: Bool

    public init(selectors: [SelectorStrategy], waitMs: Int = 5000, fallback: TargetFallback = .skip, scrollIntoView: Bool = true) {
        self.selectors = selectors; self.waitMs = waitMs; self.fallback = fallback; self.scrollIntoView = scrollIntoView
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: GKey.self)
        selectors = c.lossy("selectors")
        waitMs = c.lenient("waitMs", 5000)
        fallback = c.lenient("fallback", .skip)
        scrollIntoView = c.lenient("scrollIntoView", true)
    }
}

public struct StepButton: Decodable, Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String
    public var action: ButtonAction
    public var variant: ButtonVariant
    public var value: String?
    public var newTab: Bool?

    public init(id: String, label: String, action: ButtonAction, variant: ButtonVariant = .primary, value: String? = nil, newTab: Bool? = nil) {
        self.id = id; self.label = label; self.action = action; self.variant = variant; self.value = value; self.newTab = newTab
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: GKey.self)
        id = c.lenient("id", UUID().uuidString)
        label = c.lenient("label", "")
        action = c.lenient("action", .none)
        variant = c.lenient("variant", .primary)
        value = c.optional("value")
        newTab = c.optional("newTab")
    }
}

public struct StepBranch: Decodable, Sendable, Hashable {
    public var id: String
    public var when: RuleGroup
    public var goTo: String

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: GKey.self)
        id = c.lenient("id", "")
        when = c.lenient("when", RuleGroup.empty)
        goTo = try c.required("goTo")
    }
}

public struct HotspotConfig: Decodable, Sendable, Hashable {
    public var size: Int
    public var pulse: Bool
    public var openOn: String

    public init(size: Int = 14, pulse: Bool = true, openOn: String = "click") {
        self.size = size; self.pulse = pulse; self.openOn = openOn
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: GKey.self)
        size = c.lenient("size", 14)
        pulse = c.lenient("pulse", true)
        openOn = c.lenient("openOn", "click")
    }
}

public struct GuideStep: Decodable, Sendable, Hashable, Identifiable {
    public var id: String
    public var type: StepType
    public var title: String
    public var body: String
    public var imageUrl: String?
    public var buttons: [StepButton]
    public var target: StepTarget?
    public var placement: Placement
    public var offset: Int
    public var showOverlay: Bool
    public var showProgress: Bool
    public var showClose: Bool
    public var dismissOnOutsideClick: Bool
    public var spotlightPadding: Int
    public var position: StepPosition
    public var url: String?
    public var advanceOn: AdvanceOn
    public var advanceValue: String?
    public var advanceDelayMs: Int?
    public var branches: [StepBranch]
    public var width: Int?
    public var targeting: RuleGroup?
    public var hotspot: HotspotConfig?
    public var customHtml: String?

    public init(id: String, type: StepType, title: String = "", body: String = "", buttons: [StepButton] = [], target: StepTarget? = nil, placement: Placement = .auto, showOverlay: Bool = false) {
        self.id = id; self.type = type; self.title = title; self.body = body; self.imageUrl = nil; self.buttons = buttons
        self.target = target; self.placement = placement; self.offset = 10; self.showOverlay = showOverlay; self.showProgress = true
        self.showClose = true; self.dismissOnOutsideClick = false; self.spotlightPadding = 6; self.position = .bottomRight; self.url = nil
        self.advanceOn = .button; self.advanceValue = nil; self.advanceDelayMs = nil; self.branches = []; self.width = nil
        self.targeting = nil; self.hotspot = nil; self.customHtml = nil
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: GKey.self)
        id = try c.required("id")
        type = c.lenient("type", .unknown)
        title = c.lenient("title", "")
        body = c.lenient("body", "")
        let img: String? = c.optional("imageUrl")
        imageUrl = (img?.isEmpty ?? true) ? nil : img
        buttons = c.lossy("buttons")
        target = c.optional("target")
        placement = c.lenient("placement", .auto)
        offset = c.lenient("offset", 10)
        showOverlay = c.lenient("showOverlay", false)
        showProgress = c.lenient("showProgress", true)
        showClose = c.lenient("showClose", true)
        dismissOnOutsideClick = c.lenient("dismissOnOutsideClick", false)
        spotlightPadding = c.lenient("spotlightPadding", 6)
        position = c.lenient("position", .bottomRight)
        url = c.optional("url")
        advanceOn = c.lenient("advanceOn", .button)
        advanceValue = c.optional("advanceValue")
        advanceDelayMs = c.optional("advanceDelayMs")
        branches = c.lossy("branches")
        width = c.optional("width")
        targeting = c.optional("targeting")
        hotspot = c.optional("hotspot")
        customHtml = c.optional("customHtml")
    }

    /// Anchored step with at least one selector.
    public var isAnchoredStep: Bool { type.isAnchored && !(target?.selectors.isEmpty ?? true) }
}

/// Buttons to show for a step; "back" buttons are hidden when there is no previous step.
public func visibleButtons(_ step: GuideStep, canGoBack: Bool) -> [StepButton] {
    canGoBack ? step.buttons : step.buttons.filter { $0.action != .back }
}

// MARK: - Guide config

public struct TriggerConfig: Decodable, Sendable, Hashable {
    public var type: TriggerType
    public var value: String?
    public var delayMs: Int
    public var urlPattern: String?

    public init(type: TriggerType = .pageLoad, value: String? = nil, delayMs: Int = 0, urlPattern: String? = nil) {
        self.type = type; self.value = value; self.delayMs = delayMs; self.urlPattern = urlPattern
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: GKey.self)
        type = c.contains("type") ? c.lenient("type", .unknown) : .pageLoad
        value = c.optional("value")
        delayMs = c.lenient("delayMs", 0)
        urlPattern = c.optional("urlPattern")
    }
}

public struct FrequencyConfig: Decodable, Sendable, Hashable {
    public var mode: FrequencyMode
    public var intervalHours: Double?
    public var maxImpressions: Int?
    public var cooldownHours: Double
    public var priority: Int
    public var mutuallyExclusiveWith: [String]
    public var reshowAfterDismiss: Bool

    public init(mode: FrequencyMode = .once, intervalHours: Double? = nil, maxImpressions: Int? = nil, cooldownHours: Double = 0, priority: Int = 100, mutuallyExclusiveWith: [String] = [], reshowAfterDismiss: Bool = false) {
        self.mode = mode; self.intervalHours = intervalHours; self.maxImpressions = maxImpressions; self.cooldownHours = cooldownHours
        self.priority = priority; self.mutuallyExclusiveWith = mutuallyExclusiveWith; self.reshowAfterDismiss = reshowAfterDismiss
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: GKey.self)
        mode = c.lenient("mode", .once)
        intervalHours = c.optional("intervalHours")
        maxImpressions = c.optional("maxImpressions")
        cooldownHours = c.lenient("cooldownHours", 0)
        priority = c.lenient("priority", 100)
        mutuallyExclusiveWith = c.strings("mutuallyExclusiveWith") ?? []
        reshowAfterDismiss = c.lenient("reshowAfterDismiss", false)
    }
}

public struct Appearance: Decodable, Sendable, Hashable {
    public var theme: ThemeMode
    public var primaryColor: String?
    public var backgroundColor: String?
    public var textColor: String?
    public var borderRadius: Double?
    public var fontFamily: String?
    public var overlayOpacity: Double?
    public var animation: AnimationKind

    public init(theme: ThemeMode = .auto, primaryColor: String? = nil, backgroundColor: String? = nil, textColor: String? = nil, borderRadius: Double? = nil, fontFamily: String? = nil, overlayOpacity: Double? = nil, animation: AnimationKind = .fade) {
        self.theme = theme; self.primaryColor = primaryColor; self.backgroundColor = backgroundColor; self.textColor = textColor
        self.borderRadius = borderRadius; self.fontFamily = fontFamily; self.overlayOpacity = overlayOpacity; self.animation = animation
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: GKey.self)
        theme = c.lenient("theme", .auto)
        primaryColor = c.optional("primaryColor")
        backgroundColor = c.optional("backgroundColor")
        textColor = c.optional("textColor")
        borderRadius = c.optional("borderRadius")
        fontFamily = c.optional("fontFamily")
        overlayOpacity = c.optional("overlayOpacity")
        animation = c.lenient("animation", .fade)
    }
}

public struct ChecklistTask: Decodable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var description: String
    public var completion: ChecklistCompletion
    public var completionValue: String?
    public var action: ChecklistTaskAction
    public var actionValue: String?
    public var required: Bool

    public init(id: String, title: String, description: String = "", completion: ChecklistCompletion = .manual, completionValue: String? = nil, action: ChecklistTaskAction = .none, actionValue: String? = nil, required: Bool = true) {
        self.id = id; self.title = title; self.description = description; self.completion = completion
        self.completionValue = completionValue; self.action = action; self.actionValue = actionValue; self.required = required
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: GKey.self)
        id = try c.required("id")
        title = c.lenient("title", "")
        description = c.lenient("description", "")
        completion = c.contains("completion") ? c.lenient("completion", .unknown) : .manual
        completionValue = c.optional("completionValue")
        action = c.lenient("action", .none)
        actionValue = c.optional("actionValue")
        required = c.lenient("required", true)
    }
}

public struct ChecklistConfig: Decodable, Sendable, Hashable {
    public var tasks: [ChecklistTask]
    public var ordered: Bool
    public var launcherLabel: String
    public var position: LauncherPosition
    public var completionTitle: String
    public var completionBody: String
    public var autoOpen: Bool
    public var dismissible: Bool

    public init(tasks: [ChecklistTask], ordered: Bool = false, launcherLabel: String = "Getting started", position: LauncherPosition = .bottomRight, completionTitle: String = "You're all set!", completionBody: String = "", autoOpen: Bool = true, dismissible: Bool = true) {
        self.tasks = tasks; self.ordered = ordered; self.launcherLabel = launcherLabel; self.position = position
        self.completionTitle = completionTitle; self.completionBody = completionBody; self.autoOpen = autoOpen; self.dismissible = dismissible
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: GKey.self)
        tasks = c.lossy("tasks")
        ordered = c.lenient("ordered", false)
        launcherLabel = c.lenient("launcherLabel", "Getting started")
        position = c.lenient("position", .bottomRight)
        completionTitle = c.lenient("completionTitle", "You're all set!")
        completionBody = c.lenient("completionBody", "")
        autoOpen = c.lenient("autoOpen", true)
        dismissible = c.lenient("dismissible", true)
    }
}

public struct SurveyOption: Decodable, Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String

    public init(id: String, label: String) { self.id = id; self.label = label }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: GKey.self)
        id = try c.required("id")
        label = c.lenient("label", id)
    }
}

public struct ShowWhen: Decodable, Sendable, Hashable {
    public var questionId: String
    /// `equals`, `lte`, `gte`, `in`.
    public var op: String
    public var value: JSONValue

    public init(questionId: String, op: String, value: JSONValue) { self.questionId = questionId; self.op = op; self.value = value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: GKey.self)
        questionId = try c.required("questionId")
        op = c.lenient("op", "equals")
        value = c.lenient("value", JSONValue.null)
    }
}

public struct SurveyQuestion: Decodable, Sendable, Hashable, Identifiable {
    public var id: String
    public var type: SurveyQuestionType
    public var title: String
    public var description: String
    public var required: Bool
    public var options: [SurveyOption]
    public var scaleMax: Int?
    public var lowLabel: String?
    public var highLabel: String?
    public var placeholder: String?
    public var showWhen: ShowWhen?

    public init(id: String, type: SurveyQuestionType, title: String, required: Bool = true, options: [SurveyOption] = [], scaleMax: Int? = nil, showWhen: ShowWhen? = nil) {
        self.id = id; self.type = type; self.title = title; self.description = ""; self.required = required; self.options = options
        self.scaleMax = scaleMax; self.lowLabel = nil; self.highLabel = nil; self.placeholder = nil; self.showWhen = showWhen
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: GKey.self)
        id = try c.required("id")
        type = c.lenient("type", .text)
        title = c.lenient("title", "")
        description = c.lenient("description", "")
        required = c.lenient("required", true)
        options = c.lossy("options")
        scaleMax = c.optional("scaleMax")
        lowLabel = c.optional("lowLabel")
        highLabel = c.optional("highLabel")
        placeholder = c.optional("placeholder")
        showWhen = c.optional("showWhen")
    }
}

public struct SurveyConfig: Decodable, Sendable, Hashable {
    public var questions: [SurveyQuestion]
    public var thankYouTitle: String
    public var thankYouBody: String
    public var position: SurveyPosition
    public var startAt: String?
    public var endAt: String?

    public init(questions: [SurveyQuestion], thankYouTitle: String = "Thanks for your feedback!", thankYouBody: String = "", position: SurveyPosition = .bottomRight, startAt: String? = nil, endAt: String? = nil) {
        self.questions = questions; self.thankYouTitle = thankYouTitle; self.thankYouBody = thankYouBody; self.position = position
        self.startAt = startAt; self.endAt = endAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: GKey.self)
        questions = c.lossy("questions")
        thankYouTitle = c.lenient("thankYouTitle", "Thanks for your feedback!")
        thankYouBody = c.lenient("thankYouBody", "")
        position = c.lenient("position", .bottomRight)
        startAt = c.optional("startAt")
        endAt = c.optional("endAt")
    }
}

public struct GuideConfig: Decodable, Sendable, Hashable {
    public var steps: [GuideStep]
    public var targeting: RuleGroup
    public var trigger: TriggerConfig
    public var frequency: FrequencyConfig
    public var appearance: Appearance
    public var checklist: ChecklistConfig?
    public var survey: SurveyConfig?
    public var urlPatterns: [String]
    /// Missing field → `["web"]` (guides published before mobile support).
    public var platforms: [String]

    public init(steps: [GuideStep] = [], targeting: RuleGroup = .empty, trigger: TriggerConfig = TriggerConfig(), frequency: FrequencyConfig = FrequencyConfig(), appearance: Appearance = Appearance(), checklist: ChecklistConfig? = nil, survey: SurveyConfig? = nil, urlPatterns: [String] = [], platforms: [String] = ["ios", "android"]) {
        self.steps = steps; self.targeting = targeting; self.trigger = trigger; self.frequency = frequency; self.appearance = appearance
        self.checklist = checklist; self.survey = survey; self.urlPatterns = urlPatterns; self.platforms = platforms
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: GKey.self)
        steps = c.lossy("steps")
        targeting = c.lenient("targeting", RuleGroup.empty)
        trigger = c.lenient("trigger", TriggerConfig())
        frequency = c.lenient("frequency", FrequencyConfig())
        appearance = c.lenient("appearance", Appearance())
        checklist = c.optional("checklist")
        survey = c.optional("survey")
        urlPatterns = c.strings("urlPatterns") ?? []
        platforms = c.strings("platforms") ?? ["web"]
    }
}

/// A published guide as delivered to the SDK.
public struct PublishedGuide: Decodable, Sendable, Hashable, Identifiable {
    public var id: String
    public var key: String
    public var name: String
    public var kind: GuideKind
    public var version: Int
    public var config: GuideConfig
    public var publishedAt: String

    public init(id: String, key: String, name: String, kind: GuideKind, version: Int = 1, config: GuideConfig, publishedAt: String = "") {
        self.id = id; self.key = key; self.name = name; self.kind = kind; self.version = version; self.config = config; self.publishedAt = publishedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: GKey.self)
        id = try c.required("id")
        key = c.lenient("key", id)
        name = c.lenient("name", key)
        kind = c.lenient("kind", .unknown)
        version = c.lenient("version", 1)
        config = try c.required("config")
        publishedAt = c.lenient("publishedAt", "")
    }
}

// MARK: - SDK config

public struct ProjectTheme: Decodable, Sendable, Hashable {
    public var primaryColor: String
    public var backgroundColor: String
    public var textColor: String
    public var borderRadius: Double
    public var fontFamily: String
    public var logoUrl: String?
    public var brandName: String?

    public static let `default` = ProjectTheme()

    public init(primaryColor: String = "#4f46e5", backgroundColor: String = "#ffffff", textColor: String = "#111827", borderRadius: Double = 12, fontFamily: String = "Inter, system-ui, -apple-system, sans-serif", logoUrl: String? = nil, brandName: String? = nil) {
        self.primaryColor = primaryColor; self.backgroundColor = backgroundColor; self.textColor = textColor
        self.borderRadius = borderRadius; self.fontFamily = fontFamily; self.logoUrl = logoUrl; self.brandName = brandName
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: GKey.self)
        primaryColor = c.lenient("primaryColor", "#4f46e5")
        backgroundColor = c.lenient("backgroundColor", "#ffffff")
        textColor = c.lenient("textColor", "#111827")
        borderRadius = c.lenient("borderRadius", 12)
        fontFamily = c.lenient("fontFamily", "Inter, system-ui, -apple-system, sans-serif")
        logoUrl = c.optional("logoUrl")
        brandName = c.optional("brandName")
    }
}

public struct ResourceCenterArticle: Decodable, Sendable, Hashable, Identifiable {
    public var id: String
    public var slug: String
    public var title: String
    public var summary: String
    public var body: String
    public var collectionId: String?
    public var externalUrl: String?
    public var updatedAt: String
    /// Listed only for members of any of these audiences; empty means everyone.
    public var audienceIds: [String]

    public init(id: String, slug: String = "", title: String, summary: String = "", body: String = "", collectionId: String? = nil, externalUrl: String? = nil, updatedAt: String = "", audienceIds: [String] = []) {
        self.id = id; self.slug = slug; self.title = title; self.summary = summary; self.body = body
        self.collectionId = collectionId; self.externalUrl = externalUrl; self.updatedAt = updatedAt; self.audienceIds = audienceIds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: GKey.self)
        id = try c.required("id")
        slug = c.lenient("slug", "")
        title = c.lenient("title", "")
        summary = c.lenient("summary", "")
        body = c.lenient("body", "")
        collectionId = c.optional("collectionId")
        externalUrl = c.optional("externalUrl")
        updatedAt = c.lenient("updatedAt", "")
        audienceIds = c.strings("audienceIds") ?? []
    }
}

public struct ResourceCenterConfig: Decodable, Sendable, Hashable {
    public struct Launcher: Decodable, Sendable, Hashable {
        public var position: LauncherPosition
        public var label: String
        public var showIcon: Bool
        public init(position: LauncherPosition = .bottomRight, label: String = "Help", showIcon: Bool = true) { self.position = position; self.label = label; self.showIcon = showIcon }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: GKey.self)
            position = c.lenient("position", .bottomRight)
            label = c.lenient("label", "Help")
            showIcon = c.lenient("showIcon", true)
        }
    }

    public struct Collection: Decodable, Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
        public var description: String
        public var order: Double
        /// Parent collection; nil for a top-level collection (nesting is at most `MAX_COLLECTION_DEPTH` deep).
        public var parentId: String?
        /// Shown only to members of any of these audiences; empty means everyone.
        public var audienceIds: [String]
        public init(id: String, name: String, description: String = "", order: Double = 0, parentId: String? = nil, audienceIds: [String] = []) {
            self.id = id; self.name = name; self.description = description; self.order = order; self.parentId = parentId; self.audienceIds = audienceIds
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: GKey.self)
            id = try c.required("id")
            name = c.lenient("name", "")
            description = c.lenient("description", "")
            order = c.lenient("order", 0)
            parentId = c.optional("parentId")
            audienceIds = c.strings("audienceIds") ?? []
        }
    }

    public struct Link: Decodable, Sendable, Hashable, Identifiable {
        public var id: String
        public var label: String
        public var url: String
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: GKey.self)
            id = c.lenient("id", UUID().uuidString)
            label = c.lenient("label", "")
            url = try c.required("url")
        }
    }

    public struct FAQ: Decodable, Sendable, Hashable, Identifiable {
        public var id: String
        public var question: String
        public var answer: String
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: GKey.self)
            id = c.lenient("id", UUID().uuidString)
            question = c.lenient("question", "")
            answer = c.lenient("answer", "")
        }
    }

    public var enabled: Bool
    public var title: String
    public var launcher: Launcher
    public var collections: [Collection]
    public var articles: [ResourceCenterArticle]
    public var recommendedGuideIds: [String]
    public var checklistGuideIds: [String]
    public var links: [Link]
    public var faqs: [FAQ]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: GKey.self)
        enabled = c.lenient("enabled", true)
        title = c.lenient("title", "Help")
        launcher = c.lenient("launcher", Launcher())
        collections = c.lossy("collections")
        articles = c.lossy("articles")
        recommendedGuideIds = c.strings("recommendedGuideIds") ?? []
        checklistGuideIds = c.strings("checklistGuideIds") ?? []
        links = c.lossy("links")
        faqs = c.lossy("faqs")
    }
}

public struct SdkSettings: Decodable, Sendable, Hashable {
    public var analyticsEnabled: Bool
    public var collectUrls: Bool
    public var maskSelectors: [String]
    public var sessionTimeoutMinutes: Double

    public init(analyticsEnabled: Bool = true, collectUrls: Bool = true, maskSelectors: [String] = [], sessionTimeoutMinutes: Double = 30) {
        self.analyticsEnabled = analyticsEnabled; self.collectUrls = collectUrls; self.maskSelectors = maskSelectors; self.sessionTimeoutMinutes = sessionTimeoutMinutes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: GKey.self)
        analyticsEnabled = c.lenient("analyticsEnabled", true)
        collectUrls = c.lenient("collectUrls", true)
        maskSelectors = c.strings("maskSelectors") ?? []
        sessionTimeoutMinutes = c.lenient("sessionTimeoutMinutes", 30)
    }
}

/// `GET /config` response.
public struct SdkConfig: Decodable, Sendable, Hashable {
    public var projectId: String
    public var environment: String
    public var configVersion: Int
    public var theme: ProjectTheme
    /// Guides that decoded successfully (malformed guides are skipped).
    public var guides: [PublishedGuide]
    public var resourceCenter: ResourceCenterConfig?
    /// Scout messenger settings; absent unless the messenger is on for this platform.
    public var messenger: MessengerConfig?
    public var settings: SdkSettings
    public var generatedAt: String

    public init(projectId: String = "", environment: String = "development", configVersion: Int = 1, theme: ProjectTheme = .default, guides: [PublishedGuide] = [], resourceCenter: ResourceCenterConfig? = nil, messenger: MessengerConfig? = nil, settings: SdkSettings = SdkSettings(), generatedAt: String = "") {
        self.projectId = projectId; self.environment = environment; self.configVersion = configVersion; self.theme = theme
        self.guides = guides; self.resourceCenter = resourceCenter; self.messenger = messenger; self.settings = settings; self.generatedAt = generatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: GKey.self)
        guard c.contains("guides") else { throw DecodingError.keyNotFound(GKey("guides"), .init(codingPath: c.codingPath, debugDescription: "config has no guides")) }
        projectId = c.lenient("projectId", "")
        environment = c.lenient("environment", "development")
        configVersion = c.lenient("configVersion", 0)
        theme = c.lenient("theme", ProjectTheme.default)
        guides = c.lossy("guides")
        resourceCenter = c.optional("resourceCenter")
        messenger = c.optional("messenger")
        settings = c.lenient("settings", SdkSettings())
        generatedAt = c.lenient("generatedAt", "")
    }
}
