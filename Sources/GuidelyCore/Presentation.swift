import Foundation

// The engine is headless: it drives a `GuidelyPresenter` (UIKit/SwiftUI in the `Guidely` module, a
// fake in tests) and asks a `GuidelyTargetResolver` whether target views are on screen.

/// Handle to something the presenter rendered.
@MainActor
public final class GuidelyViewHandle {
    private var onDestroy: (() -> Void)?
    public init(onDestroy: @escaping () -> Void) { self.onDestroy = onDestroy }
    public func destroy() {
        let fn = onDestroy
        onDestroy = nil
        fn?()
    }
}

/// Theme inputs for a guide or widget: project theme (+ app overrides) and the guide's appearance.
public struct ThemeInput: Sendable, Hashable {
    public var project: ProjectTheme
    public var appearance: Appearance?
    public init(project: ProjectTheme = .default, appearance: Appearance? = nil) { self.project = project; self.appearance = appearance }

    /// Merges project theme + appearance (`resolveTheme` in guide-runtime).
    public func resolve(systemDark: Bool, reduceMotion: Bool) -> ResolvedTheme {
        let a = appearance ?? Appearance()
        let dark: Bool
        switch a.theme {
        case .auto: dark = systemDark
        case .dark: dark = true
        case .light: dark = false
        }
        return ResolvedTheme(
            primary: a.primaryColor ?? project.primaryColor,
            background: a.backgroundColor ?? (dark ? "#1f2937" : project.backgroundColor),
            text: a.textColor ?? (dark ? "#f9fafb" : project.textColor),
            radius: a.borderRadius ?? project.borderRadius,
            fontFamily: a.fontFamily ?? project.fontFamily,
            overlayOpacity: a.overlayOpacity ?? 0.5,
            isDark: dark,
            animation: reduceMotion ? (a.animation == .none ? .none : .fade) : a.animation
        )
    }
}

public struct ResolvedTheme: Sendable, Hashable {
    public var primary: String
    public var background: String
    public var text: String
    public var radius: Double
    public var fontFamily: String
    public var overlayOpacity: Double
    public var isDark: Bool
    /// With Reduce Motion on, only fades are used.
    public var animation: AnimationKind
}

/// A guide step to render.
public struct StepPresentation {
    public var guide: PublishedGuide
    public var step: GuideStep
    public var index: Int
    public var total: Int
    public var canGoBack: Bool
    /// Guidely id of the resolved target (anchored steps), nil for unanchored / modal fallback.
    public var targetId: String?
    /// Anchored step whose target was not found (`show_as_modal`).
    public var asModal: Bool
    public var theme: ThemeInput
    /// `visibleButtons(step, canGoBack)`.
    public var buttons: [StepButton]
    public var onButton: (StepButton) -> Void
    public var onClose: () -> Void

    /// How the step renders on mobile.
    public var renderStyle: StepRenderStyle {
        if asModal || targetId == nil {
            switch step.type {
            case .banner: return .banner
            case .slideout: return .slideout
            default: return .modal
            }
        }
        switch step.type {
        case .spotlight: return .spotlight
        case .hotspot: return .hotspot
        case .tooltip, .popover: return .tooltip
        case .banner: return .banner
        case .slideout: return .slideout
        default: return .modal
        }
    }
}

public enum StepRenderStyle: Sendable, Hashable {
    case modal, tooltip, spotlight, hotspot, banner, slideout
}

public struct ChecklistPresentation {
    public var guide: PublishedGuide
    public var config: ChecklistConfig
    public var progress: ChecklistProgress
    public var open: Bool
    public var showLauncher: Bool
    public var theme: ThemeInput
    public var onTaskTap: (ChecklistTask) -> Void
    public var onDismiss: () -> Void
    public var onOpen: () -> Void
    public var onClose: () -> Void
}

@MainActor
public protocol ChecklistViewHandle: AnyObject {
    func open()
    func close()
    var isOpen: Bool { get }
    func setProgress(_ progress: ChecklistProgress)
    func destroy()
}

public struct SurveyPresentation {
    public var guide: PublishedGuide
    public var config: SurveyConfig
    public var title: String
    public var theme: ThemeInput
    public var onSubmit: ([String: SurveyAnswer]) -> Void
    public var onDismiss: () -> Void
}

@MainActor
public protocol SurveyViewHandle: AnyObject {
    func showThankYou()
    func destroy()
}

public struct ResourceCenterGuideRef: Sendable, Hashable, Identifiable {
    public var id: String
    public var key: String
    public var name: String
    public var kind: GuideKind
}

public struct ResourceCenterPresentation {
    public var config: ResourceCenterConfig
    public var guides: [ResourceCenterGuideRef]
    public var theme: ThemeInput
    public var showLauncher: Bool
    public var search: (String) async -> [ResourceCenterArticle]
    public var onStartGuide: (String) -> Void
    public var onOpenChecklist: (String) -> Void
    public var onArticleView: (ResourceCenterArticle) -> Void
    public var onOpenURL: (String) -> Void
    public var onOpen: () -> Void
    public var onClose: () -> Void
    /// The end user's audiences (from the last identify), for audience-targeted collections and articles.
    public var audienceIds: () -> Set<String> = { [] }

    /// Recommended guides that exist in the config.
    public var recommended: [ResourceCenterGuideRef] { config.recommendedGuideIds.compactMap { id in guides.first { $0.id == id || $0.key == id } } }
    /// Checklists that exist in the config.
    public var checklists: [ResourceCenterGuideRef] { config.checklistGuideIds.compactMap { id in guides.first { $0.id == id || $0.key == id } } }

    /// Articles matching `query` locally (title / summary), merged with server results.
    public func localResults(_ query: String) -> [ResourceCenterArticle] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        return config.articles.filter { $0.title.lowercased().contains(q) || $0.summary.lowercased().contains(q) }
    }

    public static func merge(local: [ResourceCenterArticle], server: [ResourceCenterArticle]) -> [ResourceCenterArticle] {
        let seen = Set(local.map(\.id))
        return local + server.filter { !seen.contains($0.id) }
    }

    /// Search results to show: local matches merged with `server` results, minus articles the end
    /// user's audiences don't list.
    public func results(_ query: String, server: [ResourceCenterArticle]) -> [ResourceCenterArticle] {
        let member = audienceIds()
        return Self.merge(local: localResults(query), server: server).filter { ResourceCenterLayout.isArticleListed(config.collections, $0, member: member) }
    }

    /// Sections for the home view: nested collections depth first ("Billing › Invoices"), then
    /// uncollected articles ("Articles"), filtered by the end user's audiences.
    public var articleSections: [ResourceCenterSection] {
        ResourceCenterLayout.sections(config.collections, config.articles, member: audienceIds())
    }
}

@MainActor
public protocol ResourceCenterViewHandle: AnyObject {
    func open()
    func close()
    var isOpen: Bool { get }
    func destroy()
}

/// Renders guides and widgets.
@MainActor
public protocol GuidelyPresenter: AnyObject {
    /// Throws when the step cannot be rendered (the controller then skips it).
    func presentStep(_ presentation: StepPresentation) throws -> GuidelyViewHandle
    func presentChecklist(_ presentation: ChecklistPresentation) -> ChecklistViewHandle
    func presentSurvey(_ presentation: SurveyPresentation) -> SurveyViewHandle
    func presentResourceCenter(_ presentation: ResourceCenterPresentation) -> ResourceCenterViewHandle
    /// Screen-reader announcement.
    func announce(_ text: String)
    /// Opens an `http(s)` (or other scheme without a navigation handler) URL externally.
    func openExternalURL(_ url: URL)
    /// Renders the Scout messenger.
    func presentMessenger(_ presentation: MessengerPresentation) -> GuidelyViewHandle?
}

/// The Scout messenger to render (launcher + sheet), driven by its controller.
public struct MessengerPresentation {
    public var controller: MessengerController
    public var theme: ThemeInput
    public var showLauncher: Bool
}

extension GuidelyPresenter {
    /// Presenters that do not render the messenger return nil (it then only exists headlessly).
    public func presentMessenger(_ presentation: MessengerPresentation) -> GuidelyViewHandle? { nil }
}

/// Answers whether a registered target view is attached, visible, non-zero size and on screen.
@MainActor
public protocol GuidelyTargetResolver: AnyObject {
    func isTargetVisible(_ id: String) -> Bool
}

/// Resolves `step.target.selectors` in order: `guidely-id` / `id` → registry lookup (leading `#`
/// stripped); `css` / `data-attr` → `guidelyIdFromSelector` then lookup; other kinds are ignored.
@MainActor
public func resolveTargetId(_ selectors: [SelectorStrategy], resolver: GuidelyTargetResolver?) -> String? {
    guard let resolver else { return nil }
    for s in selectors {
        var id: String?
        switch s.kind {
        case "guidely-id", "id":
            var v = s.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if v.hasPrefix("#") { v.removeFirst() }
            id = v.isEmpty ? nil : v
        case "css", "data-attr":
            id = GuidelyUtils.guidelyIdFromSelector(s.value)
        default:
            id = nil
        }
        if let id, resolver.isTargetVisible(id) { return id }
    }
    return nil
}
