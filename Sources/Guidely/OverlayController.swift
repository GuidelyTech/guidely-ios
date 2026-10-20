#if canImport(UIKit)
import SwiftUI
import UIKit
#if canImport(GuidelyCore)
import GuidelyCore
#endif

/// UIKit/SwiftUI `GuidelyPresenter`: renders into a passthrough overlay window above the app.
@MainActor
final class OverlayController: GuidelyPresenter {
    let model = OverlayModel()
    private(set) var window: GuidelyOverlayWindow?
    private var host: GuidelyHostingController?
    private var displayLink: CADisplayLink?
    private var metricsTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private weak var appKeyWindow: UIWindow?
    let registry: GuidelyTargetRegistry
    var launcherBottomOffset: CGFloat
    var log: (String) -> Void = { _ in }

    init(registry: GuidelyTargetRegistry, launcherBottomOffset: CGFloat = 0) {
        self.registry = registry
        self.launcherBottomOffset = launcherBottomOffset
        model.onChange = { [weak self] in self?.contentChanged() }
        model.onEndEditing = { [weak self] in self?.endEditing() }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sceneActivated() }
        })
        observers.append(nc.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] note in
            let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            Task { @MainActor in self?.keyboardChanged(end) }
        })
        observers.append(nc.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.keyboardChanged(nil) }
        })
        observers.append(nc.addObserver(forName: UIResponder.keyboardDidHideNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.restoreKeyWindowIfIdle() }
        })
        observers.append(nc.addObserver(forName: UIWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            let w = note.object as? UIWindow
            Task { @MainActor in
                guard let self, let w, !(w is GuidelyOverlayWindow) else { return }
                self.appKeyWindow = w
            }
        })
        observers.append(nc.addObserver(forName: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.model.reduceMotion = UIAccessibility.isReduceMotionEnabled }
        })
    }

    /// Starts observing target taps on the app window and attaches the overlay if it has content.
    private func sceneActivated() {
        if let scene = activeScene(), let app = appWindow(in: scene) { registry.observeTaps(in: app) }
        contentChanged()
    }

    /// Called at configure time (the scene may already be active).
    func prepare() { sceneActivated() }

    func teardown() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        displayLink?.invalidate()
        displayLink = nil
        metricsTimer?.invalidate()
        metricsTimer = nil
        model.steps = []
        model.checklists = []
        model.survey = nil
        model.resourceCenter = nil
        model.messenger = nil
        window?.isHidden = true
        window = nil
        host = nil
    }

    // MARK: GuidelyPresenter

    func presentStep(_ presentation: StepPresentation) throws -> GuidelyViewHandle {
        let item = StepItem(presentation)
        // Frames first, so the step's first render already knows where its target is.
        if let t = presentation.targetId, let f = registry.frame(for: t) { model.targetFrames[t] = f }
        model.add(step: item)
        log("[Guidely] render step \(presentation.step.id) as \(item.style)\(presentation.targetId.map { " → \($0) \(model.targetFrames[$0].map { NSCoder.string(for: $0) } ?? "(no frame)")" } ?? "")")
        return GuidelyViewHandle { [weak self, weak item] in
            guard let self, let item else { return }
            self.model.remove(step: item)
        }
    }

    func presentChecklist(_ presentation: ChecklistPresentation) -> ChecklistViewHandle {
        let item = ChecklistItem(presentation, model: model)
        model.add(checklist: item)
        return item
    }

    func presentSurvey(_ presentation: SurveyPresentation) -> SurveyViewHandle {
        let item = SurveyItem(presentation, model: model)
        model.set(survey: item)
        model.announce(presentation.config.questions.first?.title ?? presentation.title)
        return item
    }

    func presentResourceCenter(_ presentation: ResourceCenterPresentation) -> ResourceCenterViewHandle {
        let item = ResourceCenterItem(presentation, model: model)
        model.set(resourceCenter: item)
        return item
    }

    func presentMessenger(_ presentation: MessengerPresentation) -> GuidelyViewHandle? {
        let item = MessengerItem(presentation, model: model)
        model.messenger = item
        contentChanged()
        return GuidelyViewHandle { [weak self, weak item] in
            guard let self, let item, self.model.messenger === item else { return }
            self.model.messenger = nil
            self.contentChanged()
        }
    }

    func announce(_ text: String) { model.announce(text) }

    func openExternalURL(_ url: URL) {
        UIApplication.shared.open(url, options: [:]) { [weak self] ok in
            if !ok { Task { @MainActor in self?.log("[Guidely] could not open \(url.absoluteString)") } }
        }
    }

    // MARK: Window

    private func activeScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive }
            ?? scenes.first
    }

    private func appWindow(in scene: UIWindowScene) -> UIWindow? {
        if let w = appKeyWindow, w.windowScene === scene, !(w is GuidelyOverlayWindow) { return w }
        return scene.windows.first { $0.isKeyWindow && !($0 is GuidelyOverlayWindow) }
            ?? scene.windows.first { !($0 is GuidelyOverlayWindow) && !$0.isHidden && $0.windowLevel == .normal }
    }

    private func ensureWindow() {
        if let window, window.windowScene?.activationState != .unattached { return }
        guard let scene = activeScene() else { return }
        let w = GuidelyOverlayWindow(windowScene: scene)
        w.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
        w.backgroundColor = .clear
        w.model = model
        let app = appWindow(in: scene)
        appKeyWindow = app
        if let app { registry.observeTaps(in: app) }
        w.overrideUserInterfaceStyle = app?.overrideUserInterfaceStyle ?? .unspecified
        let host = GuidelyHostingController(rootView: OverlayRootView(model: model))
        // Positions are computed from the window's safe area; keep SwiftUI from also shifting
        // content for the keyboard.
        if #available(iOS 16.4, *) { host.safeAreaRegions = [] }
        host.model = model
        host.appWindow = app
        w.rootViewController = host
        w.frame = scene.coordinateSpace.bounds
        w.isHidden = true
        self.window = w
        self.host = host
        log("[Guidely] overlay window attached to scene")
    }

    private func contentChanged() {
        model.nudge()
        if model.isEmpty {
            if window?.isKeyWindow == true { restoreKeyWindow() }
            window?.isHidden = true
            stopTimers()
            return
        }
        ensureWindow()
        guard let window else { return }
        if let scene = window.windowScene, let app = appWindow(in: scene) { registry.observeTaps(in: app) }
        if window.isHidden { window.isHidden = false }
        updateMetrics()
        updateTargetFrames()
        startTimers()
        restoreKeyWindowIfIdle()
    }

    private var needsDisplayLink: Bool { !model.neededTargetIds.isEmpty }

    private func startTimers() {
        if needsDisplayLink, displayLink == nil {
            let link = CADisplayLink(target: DisplayLinkProxy { [weak self] in self?.tick() }, selector: #selector(DisplayLinkProxy.fire))
            link.preferredFramesPerSecond = 30
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else if !needsDisplayLink, let link = displayLink {
            link.invalidate()
            displayLink = nil
        }
        if metricsTimer == nil {
            metricsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updateMetrics() }
            }
        }
    }

    private func stopTimers() {
        displayLink?.invalidate()
        displayLink = nil
        metricsTimer?.invalidate()
        metricsTimer = nil
    }

    private func tick() {
        updateTargetFrames()
    }

    func updateTargetFrames() {
        var frames: [String: CGRect] = [:]
        for id in model.neededTargetIds {
            if let f = registry.frame(for: id) { frames[id] = f.integral == f ? f : CGRect(x: f.minX.rounded(), y: f.minY.rounded(), width: f.width.rounded(), height: f.height.rounded()) }
        }
        if frames != model.targetFrames {
            model.targetFrames = frames
            model.nudge()
        }
    }

    private func updateMetrics() {
        host?.updateMetrics()
        var inset = launcherBottomOffset
        if let scene = window?.windowScene, let app = appWindow(in: scene), let tabBar = Self.findTabBar(in: app) {
            let f = tabBar.convert(tabBar.bounds, to: nil)
            let covered = app.bounds.maxY - f.minY - app.safeAreaInsets.bottom
            if covered > 0 { inset += covered }
        }
        if model.bottomBarInset != inset { model.bottomBarInset = inset }
    }

    static func findTabBar(in view: UIView) -> UITabBar? {
        if let t = view as? UITabBar, !t.isHidden, t.alpha > 0.01, t.window != nil { return t }
        for sub in view.subviews where !sub.isHidden {
            if let t = findTabBar(in: sub) { return t }
        }
        return nil
    }

    private func keyboardChanged(_ end: CGRect?) {
        guard let end, let window else {
            if model.keyboardHeight != 0 { withAnimation(model.animation) { model.keyboardHeight = 0 } }
            return
        }
        let local = window.convert(end, from: window.screen.coordinateSpace)
        let h = max(0, window.bounds.maxY - local.minY)
        if model.keyboardHeight != h { withAnimation(model.animation) { model.keyboardHeight = h } }
    }

    private func endEditing() {
        window?.endEditing(true)
        restoreKeyWindowIfIdle()
    }

    /// The overlay becomes key only while a survey / search field has keyboard focus.
    private func restoreKeyWindowIfIdle() {
        guard let window, window.isKeyWindow else { return }
        let needsInput = model.survey != nil || model.resourceCenter?.isOpen == true || model.messenger?.controller.isOpen == true
        if needsInput && model.keyboardHeight > 0 { return }
        restoreKeyWindow()
    }

    private func restoreKeyWindow() {
        guard let scene = window?.windowScene, let app = appWindow(in: scene) else { return }
        app.makeKey()
    }
}

/// Breaks the CADisplayLink → target retain cycle.
@MainActor
private final class DisplayLinkProxy: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func fire() { action() }
}
#endif
