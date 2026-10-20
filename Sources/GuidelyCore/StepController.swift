import Foundation

// Port of `packages/guide-runtime/src/controller.ts`: walks steps, waits for targets, handles
// advancement, branches, multi-screen steps, buttons, fallbacks and cleanup. Rendering goes through
// the host's `GuidelyPresenter`; failures skip the step instead of crashing the host app.

public enum GuideEndReason: String, Sendable { case completed, dismissed, skipped, destroyed }

public enum GuideRunStatus: String, Sendable { case idle, running, waitingUrl = "waiting_url", waitingTarget = "waiting_target", ended }

struct RuntimeEvent {
    var name: SdkEventName
    var stepId: String?
    var stepIndex: Int?
    var properties: [String: JSONValue]?
}

@MainActor
protocol StepControllerHost: AnyObject {
    var presenter: GuidelyPresenter? { get }
    var targetResolver: GuidelyTargetResolver? { get }
    var scheduler: GuidelyScheduler { get }
    func currentUrl() -> String
    func targetingContext() -> TargetingContext?
    func subscribeEvent(_ name: String, _ cb: @escaping @MainActor () -> Void) -> GuidelyCancellable
    func subscribeTaps(_ cb: @escaping @MainActor (String) -> Void) -> GuidelyCancellable
}

@MainActor
final class StepController {
    let guide: PublishedGuide
    private weak var host: StepControllerHost?
    private let steps: [GuideStep]
    let total: Int
    var theme: ThemeInput
    var startAtStep: String?
    /// Poll interval while waiting for a target / visibility (seconds).
    var pollInterval: TimeInterval = 0.1

    var onEvent: (RuntimeEvent) -> Void = { _ in }
    var onNavigate: (String, Bool) -> Void = { _, _ in }
    var onAction: (ButtonAction, String?, StepButton) -> Void = { _, _, _ in }
    var onError: (Error) -> Void = { _ in }
    var onEnd: (GuideEndReason) -> Void = { _ in }

    private(set) var status: GuideRunStatus = .idle
    private(set) var index = -1
    private var pendingIndex = -1
    private var view: GuidelyViewHandle?
    private var stepCleanups: [GuidelyCancellable] = []
    private var started = false
    private var stepDone = false
    private(set) var ended = false
    private(set) var history: [Int] = []
    /// Incremented whenever the current step is torn down; stale async callbacks compare against it.
    private var generation = 0
    /// Target the current step is anchored to.
    private(set) var targetId: String?

    init(guide: PublishedGuide, host: StepControllerHost, theme: ThemeInput, startAtStep: String? = nil) {
        self.guide = guide
        self.host = host
        self.steps = guide.config.steps
        self.total = guide.config.steps.count
        self.theme = theme
        self.startAtStep = startAtStep
    }

    var stepId: String? { index >= 0 && index < total ? steps[index].id : nil }
    var currentStep: GuideStep? { index >= 0 && index < total ? steps[index] : nil }
    var canGoBack: Bool { !history.isEmpty || index > 0 }

    private func emit(_ name: SdkEventName, _ step: GuideStep? = nil, _ stepIndex: Int? = nil, _ properties: [String: JSONValue]? = nil) {
        onEvent(RuntimeEvent(name: name, stepId: step?.id, stepIndex: stepIndex.flatMap { $0 >= 0 ? $0 : nil }, properties: properties))
    }

    private func clearStep() {
        generation += 1
        stepCleanups.forEach { $0.cancel() }
        stepCleanups.removeAll()
        view?.destroy()
        view = nil
        stepDone = false
        targetId = nil
    }

    private func end(_ reason: GuideEndReason) {
        if ended { return }
        ended = true
        let step = currentStep
        clearStep()
        status = .ended
        switch reason {
        case .completed: emit(.guideCompleted, step, index)
        case .dismissed: emit(.guideDismissed, step, index)
        case .skipped: emit(.guideSkipped, step, index)
        case .destroyed: break
        }
        onEnd(reason)
    }

    private func completeStep() {
        if stepDone || index < 0 { return }
        stepDone = true
        emit(.stepCompleted, currentStep, index)
    }

    private func goNext(_ overrideStepId: String? = nil) {
        var target = -1
        if let step = currentStep, let ctx = host?.targetingContext() {
            for branch in step.branches where Targeting.evaluate(branch.when, ctx) {
                target = steps.firstIndex { $0.id == branch.goTo } ?? -1
                if target >= 0 { break }
            }
        }
        if target < 0, let o = overrideStepId, !o.isEmpty { target = steps.firstIndex { $0.id == o } ?? -1 }
        if target < 0 { target = index + 1 }
        if target >= total { return end(.completed) }
        history.append(index)
        showStep(target, 1)
    }

    private func advance() {
        if ended { return }
        completeStep()
        goNext()
    }

    func handleButton(_ b: StepButton) {
        if ended { return }
        switch b.action {
        case .next:
            completeStep()
            goNext(b.value)
        case .back:
            back()
        case .dismiss:
            end(.dismissed)
        case .complete:
            completeStep()
            end(.completed)
        case .skip:
            end(.skipped)
        case .url:
            completeStep()
            onNavigate(b.value ?? "", b.newTab ?? false)
            if index + 1 >= total { end(.completed) } else { goNext() }
        case .startGuide:
            completeStep()
            end(.completed)
            onAction(.startGuide, b.value, b)
        case .event:
            onAction(.event, b.value, b)
        case .openResourceCenter:
            onAction(.openResourceCenter, b.value, b)
        case .none:
            break
        }
    }

    private func setupAdvance(_ step: GuideStep) {
        guard let host else { return }
        let modes: [AdvanceOn] = step.advanceOn == .any ? [.elementClick, .elementVisible, .event, .delay] : [step.advanceOn]
        let gen = generation
        for mode in modes {
            switch mode {
            case .elementClick:
                guard let id = GuidelyUtils.guidelyIdFromSelector(step.advanceValue) else { continue }
                stepCleanups.append(host.subscribeTaps { [weak self] tapped in
                    guard let self, self.generation == gen, tapped == id else { return }
                    self.advance()
                })
            case .elementVisible:
                guard let id = GuidelyUtils.guidelyIdFromSelector(step.advanceValue) else { continue }
                pollVisible(id, gen)
            case .event:
                guard let name = step.advanceValue, !name.isEmpty else { continue }
                stepCleanups.append(host.subscribeEvent(name) { [weak self] in
                    guard let self, self.generation == gen else { return }
                    self.advance()
                })
            case .delay:
                let ms = Double(step.advanceDelayMs ?? 3000)
                stepCleanups.append(host.scheduler.schedule(after: ms / 1000) { [weak self] in
                    guard let self, self.generation == gen else { return }
                    self.advance()
                })
            case .button, .any:
                break
            }
        }
    }

    private func pollVisible(_ id: String, _ gen: Int) {
        guard let host, generation == gen, !ended else { return }
        if host.targetResolver?.isTargetVisible(id) == true { return advance() }
        stepCleanups.append(host.scheduler.schedule(after: max(pollInterval, 0.25)) { [weak self] in self?.pollVisible(id, gen) })
    }

    private func render(_ step: GuideStep, targetId: String?, asModal: Bool = false) {
        if ended { return }
        status = .running
        self.targetId = targetId
        let presentation = StepPresentation(
            guide: guide, step: step, index: index, total: total, canGoBack: canGoBack, targetId: targetId, asModal: asModal, theme: theme,
            buttons: visibleButtons(step, canGoBack: canGoBack),
            onButton: { [weak self] b in self?.handleButton(b) },
            onClose: { [weak self] in self?.end(.dismissed) }
        )
        do {
            guard let presenter = host?.presenter else { throw GuidelyError("[Guidely] no presenter attached; cannot render step \"\(step.id)\"") }
            view = try presenter.presentStep(presentation)
        } catch {
            onError(error)
            view = nil
            // Rendering failed: skip the step rather than leaving the guide stuck.
            if index + 1 < total { return goNext() }
            return end(.skipped)
        }
        if !started {
            started = true
            emit(.guideStarted, step, index)
        }
        emit(.stepViewed, step, index, asModal ? ["fallback": "show_as_modal"] : nil)
        let title = step.title.trimmingCharacters(in: .whitespacesAndNewlines)
        host?.presenter?.announce(title.isEmpty ? "Step \(index + 1) of \(total)" : "\(title). Step \(index + 1) of \(total)")
        setupAdvance(step)
    }

    private func applyFallback(_ step: GuideStep, _ direction: Int) {
        let fallback = step.target?.fallback ?? .skip
        emit(.stepViewed, step, index, ["fallback": .string(fallback.rawValue), "targetMissing": true])
        switch fallback {
        case .showAsModal: return render(step, targetId: nil, asModal: true)
        case .endGuide: return end(.skipped)
        case .skip, .wait:
            let next = index + direction
            if next < 0 { return showStep(0, 1) }
            if next >= total { return end(.completed) }
            showStep(next, direction)
        }
    }

    private func waitForTarget(_ step: GuideStep, _ direction: Int, deadline: Date?, _ gen: Int) {
        guard let host, generation == gen, !ended, let target = step.target else { return }
        if let id = resolveTargetId(target.selectors, resolver: host.targetResolver) {
            return render(step, targetId: id)
        }
        if let deadline, host.scheduler.now >= deadline {
            return applyFallback(step, direction)
        }
        var wait = pollInterval
        if let deadline { wait = min(wait, max(0.001, deadline.timeIntervalSince(host.scheduler.now))) }
        stepCleanups.append(host.scheduler.schedule(after: wait) { [weak self] in
            self?.waitForTarget(step, direction, deadline: deadline, gen)
        })
    }

    func showStep(_ i: Int, _ direction: Int = 1) {
        if ended { return }
        clearStep()
        var i = i
        if i < 0 { i = 0 }
        if i >= total { return end(.completed) }
        index = i
        let step = steps[i]
        if let targeting = step.targeting, !targeting.rules.isEmpty, let ctx = host?.targetingContext(), !Targeting.evaluate(targeting, ctx) {
            let next = i + direction
            if next >= total { return end(.completed) }
            if next < 0 { return }
            return showStep(next, direction)
        }
        if let url = step.url, !url.isEmpty, !GuidelyUtils.urlMatches(url, host?.currentUrl() ?? "/") {
            status = .waitingUrl
            pendingIndex = i
            return
        }
        pendingIndex = -1
        if step.isAnchoredStep, let target = step.target, let host {
            status = .waitingTarget
            let timeoutMs = target.fallback == .wait ? 0 : target.waitMs
            let deadline = timeoutMs > 0 ? host.scheduler.now.addingTimeInterval(Double(timeoutMs) / 1000) : nil
            return waitForTarget(step, direction, deadline: deadline, generation)
        }
        render(step, targetId: nil)
    }

    // MARK: Controls

    func start() {
        guard status == .idle else { return }
        emit(.guideViewed)
        if total == 0 { return end(.completed) }
        var startIndex = startAtStep.flatMap { id in steps.firstIndex { $0.id == id } } ?? 0
        if startIndex < 0 { startIndex = 0 }
        showStep(startIndex, 1)
    }

    func next() {
        if ended || index < 0 { return }
        completeStep()
        goNext()
    }

    func back() {
        if ended { return }
        guard let prev = history.popLast() else {
            if index > 0 { showStep(index - 1, -1) }
            return
        }
        showStep(prev, -1)
    }

    func goTo(_ stepId: String) {
        guard let i = steps.firstIndex(where: { $0.id == stepId }), !ended else { return }
        if index >= 0 { history.append(index) }
        showStep(i, 1)
    }

    func dismiss() { end(.dismissed) }

    func complete() {
        completeStep()
        end(.completed)
    }

    func skip() { end(.skipped) }

    /// Re-evaluates a step waiting for a screen (call after `screen()`).
    func resume() {
        if ended { return }
        if status == .waitingUrl && pendingIndex >= 0 { return showStep(pendingIndex, 1) }
        // A rendered step whose screen no longer matches must wait again.
        if let step = currentStep, let url = step.url, !url.isEmpty, status == .running, !GuidelyUtils.urlMatches(url, host?.currentUrl() ?? "/") {
            showStep(index, 1)
        }
    }

    func destroy() {
        if ended { return }
        ended = true
        clearStep()
        status = .ended
        onEnd(.destroyed)
    }
}
