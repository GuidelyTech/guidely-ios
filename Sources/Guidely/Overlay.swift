#if canImport(UIKit)
import SwiftUI
import UIKit
#if canImport(GuidelyCore)
import GuidelyCore
#endif

// MARK: - Items

@MainActor
final class StepItem: ObservableObject, Identifiable {
    let id = UUID()
    let presentation: StepPresentation
    @Published var hotspotOpen = false
    @Published var cardSize: CGSize = .zero
    init(_ p: StepPresentation) { presentation = p }

    var style: StepRenderStyle { presentation.renderStyle }
    var step: GuideStep { presentation.step }
    /// Dim overlay behind the card.
    var dimmed: Bool {
        switch style {
        case .modal: return step.showOverlay || presentation.asModal || (step.type.isAnchored && presentation.targetId == nil)
        case .tooltip: return step.showOverlay
        case .spotlight: return true
        default: return false
        }
    }
    /// Touches outside the card are absorbed (and dismiss when `dismissOnOutsideClick`).
    var blocksOutside: Bool {
        switch style {
        case .modal, .tooltip, .slideout: return dimmed || step.dismissOnOutsideClick
        case .spotlight: return true
        case .banner: return false
        case .hotspot: return hotspotOpen && step.dismissOnOutsideClick
        }
    }
}

@MainActor
final class ChecklistItem: ObservableObject, Identifiable, ChecklistViewHandle {
    let id: String
    let presentation: ChecklistPresentation
    @Published var progress: ChecklistProgress
    @Published var isOpen: Bool
    weak var model: OverlayModel?

    init(_ p: ChecklistPresentation, model: OverlayModel) {
        id = p.guide.id
        presentation = p
        progress = p.progress
        isOpen = false
        self.model = model
        if p.open { open() }
    }

    func open() {
        guard !isOpen else { return }
        model?.closeOtherPanels(except: id)
        withAnimation(model?.animation) { isOpen = true }
        presentation.onOpen()
        model?.objectWillChange.send()
        model?.onChange()
        model?.announce(presentation.config.launcherLabel)
    }

    func close() {
        guard isOpen else { return }
        withAnimation(model?.animation) { isOpen = false }
        presentation.onClose()
        model?.objectWillChange.send()
        model?.onChange()
    }

    func toggle() { isOpen ? close() : open() }

    func setProgress(_ progress: ChecklistProgress) {
        self.progress = progress
        model?.nudge()
    }

    func destroy() { model?.remove(checklist: self) }

    var doneCount: Int { presentation.config.tasks.filter { progress.completedTaskIds.contains($0.id) }.count }
    var total: Int { presentation.config.tasks.count }
    var isComplete: Bool { ChecklistLogic.isComplete(presentation.config, completedTaskIds: progress.completedTaskIds) }
}

@MainActor
final class SurveyItem: ObservableObject, SurveyViewHandle {
    let presentation: SurveyPresentation
    @Published var answers: [String: SurveyAnswer] = [:]
    @Published var thankYou = false
    @Published var error: String?
    @Published var text: [String: String] = [:]
    weak var model: OverlayModel?

    init(_ p: SurveyPresentation, model: OverlayModel) { presentation = p; self.model = model }

    func set(_ id: String, _ value: SurveyAnswer?) {
        var a = answers
        if let value, !(value == .string("")), !(value == .list([])) { a[id] = value } else { a[id] = nil }
        answers = SurveyLogic.pruneHidden(presentation.config.questions, answers: a)
        if error != nil { error = nil }
    }

    var visibleQuestions: [SurveyQuestion] { presentation.config.questions.filter { SurveyLogic.isQuestionVisible($0, answers: answers) } }

    func submit() {
        let missing = SurveyLogic.missingRequired(presentation.config.questions, answers: answers)
        if !missing.isEmpty {
            error = "Please answer: " + missing.map(\.title).joined(separator: ", ")
            model?.announce(error ?? "")
            return
        }
        error = nil
        model?.endEditing()
        presentation.onSubmit(answers)
    }

    func showThankYou() {
        withAnimation(model?.animation) { thankYou = true }
        model?.nudge()
        model?.announce(presentation.config.thankYouTitle)
    }

    func destroy() { model?.remove(survey: self) }
}

@MainActor
final class ResourceCenterItem: ObservableObject, ResourceCenterViewHandle {
    let presentation: ResourceCenterPresentation
    @Published var isOpen = false
    @Published var query = ""
    @Published var serverResults: [ResourceCenterArticle] = []
    @Published var article: ResourceCenterArticle?
    @Published var expandedFaqs: Set<String> = []
    private var searchSeq = 0
    private var debounce: Task<Void, Never>?
    weak var model: OverlayModel?

    init(_ p: ResourceCenterPresentation, model: OverlayModel) { presentation = p; self.model = model }

    func open() {
        guard !isOpen else { return }
        model?.closeOtherPanels(except: "rc")
        withAnimation(model?.animation) { isOpen = true }
        presentation.onOpen()
        model?.objectWillChange.send()
        model?.onChange()
        model?.announce(presentation.config.title)
    }

    func close() {
        guard isOpen else { return }
        model?.endEditing()
        withAnimation(model?.animation) {
            isOpen = false
            article = nil
        }
        presentation.onClose()
        model?.objectWillChange.send()
        model?.onChange()
    }

    func destroy() { model?.removeResourceCenter(self) }

    func search(_ q: String) {
        query = q
        article = nil
        debounce?.cancel()
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { serverResults = []; return }
        searchSeq += 1
        let seq = searchSeq
        debounce = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else { return }
            let results = await self.presentation.search(trimmed)
            guard seq == self.searchSeq else { return }
            self.serverResults = results
        }
    }

    var results: [ResourceCenterArticle] {
        presentation.results(query, server: serverResults)
    }

    func openArticle(_ a: ResourceCenterArticle) {
        if let ext = a.externalUrl, !ext.isEmpty {
            presentation.onArticleView(a)
            presentation.onOpenURL(ext)
            return
        }
        presentation.onArticleView(a)
        model?.endEditing()
        withAnimation(model?.animation) { article = a }
    }
}

@MainActor
final class MessengerItem: ObservableObject {
    let controller: MessengerController
    let presentation: MessengerPresentation
    weak var model: OverlayModel?
    private var wasOpen = false

    init(_ p: MessengerPresentation, model: OverlayModel) {
        controller = p.controller
        presentation = p
        self.model = model
        controller.onChange = { [weak self] in self?.controllerChanged() }
    }

    private func controllerChanged() {
        objectWillChange.send()
        guard let model else { return }
        if controller.isOpen != wasOpen {
            wasOpen = controller.isOpen
            if wasOpen { model.closeOtherPanels(except: "messenger"); model.announce(controller.config.name) } else { model.endEditing() }
            model.onChange()
        }
        model.nudge()
    }

    var showLauncher: Bool { presentation.showLauncher }
}

// MARK: - Model

@MainActor
final class OverlayModel: ObservableObject {
    @Published var steps: [StepItem] = []
    @Published var checklists: [ChecklistItem] = []
    @Published var survey: SurveyItem?
    @Published var resourceCenter: ResourceCenterItem?
    @Published var messenger: MessengerItem?
    /// Heights of visible checklist launchers by corner (the messenger bubble stacks above them).
    @Published var checklistLauncherHeights: [LauncherPosition: CGFloat] = [:]
    @Published var targetFrames: [String: CGRect] = [:]
    @Published var size: CGSize = UIScreen.main.bounds.size
    @Published var safeArea: UIEdgeInsets = .zero
    @Published var keyboardHeight: CGFloat = 0
    /// Height of the app's tab bar (detected) plus `launcherBottomOffset`.
    @Published var bottomBarInset: CGFloat = 0
    var interactiveRects: [String: CGRect] = [:]
    var reduceMotion = UIAccessibility.isReduceMotionEnabled
    var animation: Animation? { reduceMotion ? .easeInOut(duration: 0.15) : .easeOut(duration: 0.22) }
    var navigate: (URL) -> Void = { _ in }
    var onChange: () -> Void = {}
    var onEndEditing: () -> Void = {}

    private var nudgeScheduled = false

    /// SwiftUI can drop a change published in the same run-loop turn as a synchronous render (for
    /// example while the host app's SwiftUI is mid-update after `screen()` in `onAppear`). A
    /// coalesced, deferred `objectWillChange` guarantees the overlay re-renders with current state.
    func nudge() {
        guard !nudgeScheduled else { return }
        nudgeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.nudgeScheduled = false
            self.objectWillChange.send()
        }
    }

    func announce(_ text: String) {
        guard !text.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            UIAccessibility.post(notification: .screenChanged, argument: text)
        }
    }

    func endEditing() { onEndEditing() }

    var isEmpty: Bool {
        let rcVisible = resourceCenter.map { $0.isOpen || $0.presentation.showLauncher } ?? false
        let messengerVisible = messenger.map { $0.controller.isOpen || $0.showLauncher } ?? false
        return steps.isEmpty && checklists.isEmpty && survey == nil && !rcVisible && !messengerVisible
    }

    /// Whether touches outside SDK content are absorbed right now.
    var blocksTouches: Bool {
        if resourceCenter?.isOpen == true || messenger?.controller.isOpen == true { return true }
        if checklists.contains(where: { $0.isOpen }) { return true }
        return steps.contains { item in
            guard item.blocksOutside else { return false }
            // Anchored steps whose target is off screen are hidden; don't block the app.
            if let t = item.presentation.targetId, item.style != .modal, targetFrames[t] == nil { return false }
            return true
        }
    }

    /// Spotlight holes: touches pass through to the highlighted view.
    var passthroughRects: [CGRect] {
        steps.compactMap { item in
            guard item.style == .spotlight, let t = item.presentation.targetId, let f = targetFrames[t] else { return nil }
            let pad = CGFloat(item.step.spotlightPadding)
            return f.insetBy(dx: -pad, dy: -pad)
        }
    }

    var neededTargetIds: Set<String> { Set(steps.compactMap { $0.presentation.targetId }) }

    func add(step: StepItem) {
        withAnimation(animation) { steps.append(step) }
        onChange()
    }

    func remove(step: StepItem) {
        withAnimation(animation) { steps.removeAll { $0 === step } }
        onChange()
    }

    func add(checklist: ChecklistItem) {
        checklists.removeAll { $0.id == checklist.id }
        withAnimation(animation) { checklists.append(checklist) }
        onChange()
    }

    func remove(checklist: ChecklistItem) {
        withAnimation(animation) { checklists.removeAll { $0 === checklist } }
        onChange()
    }

    func set(survey: SurveyItem?) {
        withAnimation(animation) { self.survey = survey }
        onChange()
    }

    func remove(survey: SurveyItem) {
        guard self.survey === survey else { return }
        endEditing()
        withAnimation(animation) { self.survey = nil }
        onChange()
    }

    func set(resourceCenter: ResourceCenterItem?) {
        self.resourceCenter = resourceCenter
        onChange()
    }

    func removeResourceCenter(_ rc: ResourceCenterItem) {
        guard resourceCenter === rc else { return }
        resourceCenter = nil
        onChange()
    }

    func closeOtherPanels(except id: String) {
        for c in checklists where c.id != id && c.isOpen { c.close() }
        if id != "rc", let rc = resourceCenter, rc.isOpen { rc.close() }
        if id != "messenger", let m = messenger, m.controller.isOpen { m.controller.close() }
    }
}

// MARK: - Window

/// Passthrough overlay window: touches outside SDK content fall through to the app.
final class GuidelyOverlayWindow: UIWindow {
    weak var model: OverlayModel?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event), let model else { return nil }
        // Something presented over the overlay (the article PDF reader) takes every touch.
        if rootViewController?.presentedViewController != nil { return hit }
        if model.interactiveRects.values.contains(where: { $0.contains(point) }) { return hit }
        if model.passthroughRects.contains(where: { $0.contains(point) }) { return nil }
        return model.blocksTouches ? hit : nil
    }
}

/// Hosts the SwiftUI overlay and forwards status-bar / orientation decisions to the app.
final class GuidelyHostingController: UIHostingController<OverlayRootView> {
    weak var model: OverlayModel?
    weak var appWindow: UIWindow?

    private var appRoot: UIViewController? {
        var vc = appWindow?.rootViewController
        while let presented = vc?.presentedViewController, !presented.isBeingDismissed { vc = presented }
        return vc
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { appRoot?.preferredStatusBarStyle ?? .default }
    override var prefersStatusBarHidden: Bool { appRoot?.prefersStatusBarHidden ?? false }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { appRoot?.supportedInterfaceOrientations ?? .all }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isOpaque = false
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateMetrics()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        updateMetrics()
    }

    func updateMetrics() {
        guard let model else { return }
        let insets = view.window?.safeAreaInsets ?? view.safeAreaInsets
        if model.safeArea != insets { model.safeArea = insets }
        if model.size != view.bounds.size, view.bounds.size != .zero { model.size = view.bounds.size }
    }
}
#endif
