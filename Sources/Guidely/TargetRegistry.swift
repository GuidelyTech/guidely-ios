#if canImport(UIKit)
import SwiftUI
import UIKit
#if canImport(GuidelyCore)
import GuidelyCore
#endif

/// Registry of views tagged with a Guidely id (`.guidelyTarget("id")` / `view.guidelyId = "id"`).
/// Frames are in window (screen) coordinates.
@MainActor
public final class GuidelyTargetRegistry: GuidelyTargetResolver {
    public static let shared = GuidelyTargetRegistry()

    private final class WeakView {
        weak var view: UIView?
        init(_ v: UIView) { view = v }
    }

    private var uiViews: [String: [WeakView]] = [:]
    private var swiftUI: [String: [UUID: CGRect]] = [:]
    private var swiftUIOrder: [String: [UUID]] = [:]
    /// Called when a registered view is tapped.
    var onTap: ((String) -> Void)?

    // MARK: UIKit

    func register(_ view: UIView, id: String) {
        var list = (uiViews[id] ?? []).filter { $0.view != nil && $0.view !== view }
        list.append(WeakView(view))
        uiViews[id] = list
    }

    func unregister(_ view: UIView, id: String) {
        uiViews[id] = (uiViews[id] ?? []).filter { $0.view != nil && $0.view !== view }
    }

    // MARK: SwiftUI

    func registerSwiftUI(id: String, token: UUID, frame: CGRect) {
        if swiftUI[id]?[token] == nil { swiftUIOrder[id, default: []].append(token) }
        swiftUI[id, default: [:]][token] = frame
    }

    func unregisterSwiftUI(id: String, token: UUID) {
        swiftUI[id]?[token] = nil
        swiftUIOrder[id]?.removeAll { $0 == token }
    }

    // MARK: Lookup

    private var screenBounds: CGRect {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.coordinateSpace.bounds ?? UIScreen.main.bounds
    }

    /// Frame of the first attached, visible, non-zero, on-screen view registered under `id`.
    public func frame(for id: String) -> CGRect? {
        let screen = screenBounds
        // Most recently registered first.
        for w in (uiViews[id] ?? []).reversed() {
            guard let v = w.view, let f = Self.visibleFrame(v, screen: screen) else { continue }
            return f
        }
        for token in (swiftUIOrder[id] ?? []).reversed() {
            guard let f = swiftUI[id]?[token], f.width > 0, f.height > 0, f.intersects(screen) else { continue }
            return f
        }
        return nil
    }

    public func isTargetVisible(_ id: String) -> Bool { frame(for: id) != nil }

    /// All ids currently registered (debugging).
    public var registeredIds: [String] {
        Array(Set(uiViews.filter { $0.value.contains { $0.view != nil } }.map(\.key) + swiftUI.filter { !$0.value.isEmpty }.map(\.key))).sorted()
    }

    static func visibleFrame(_ view: UIView, screen: CGRect) -> CGRect? {
        guard let window = view.window, !window.isHidden else { return nil }
        var v: UIView? = view
        while let cur = v {
            if cur.isHidden || cur.alpha < 0.01 { return nil }
            v = cur.superview
        }
        let f = view.convert(view.bounds, to: nil)
        let inScreen = window.convert(f, to: window.screen.coordinateSpace)
        guard f.width > 0, f.height > 0, inScreen.intersects(screen.isEmpty ? window.bounds : screen) else { return nil }
        return f
    }

    func didTap(_ id: String) { onTap?(id) }

    // MARK: Window tap observation (SwiftUI targets)

    private final class WindowTapObserver: NSObject, UIGestureRecognizerDelegate {
        @objc func handle(_ r: UITapGestureRecognizer) {
            guard r.state == .ended, let window = r.view as? UIWindow else { return }
            let p = r.location(in: window)
            MainActor.assumeIsolatedOnMain { GuidelyTargetRegistry.shared.windowTapped(at: p) }
        }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool { true }
    }

    private let windowTapObserver = WindowTapObserver()
    private var observedWindows = NSHashTable<UIWindow>.weakObjects()

    /// Observes taps on the app window so SwiftUI targets report `element_click` without adding
    /// gestures to the app's views (a gesture on a `List` row button would swallow its action).
    func observeTaps(in window: UIWindow) {
        guard !observedWindows.contains(window) else { return }
        observedWindows.add(window)
        let tap = UITapGestureRecognizer(target: windowTapObserver, action: #selector(WindowTapObserver.handle(_:)))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.requiresExclusiveTouchType = false
        tap.delegate = windowTapObserver
        window.addGestureRecognizer(tap)
    }

    func windowTapped(at point: CGPoint) {
        var hits: [(String, CGFloat)] = []
        for (id, frames) in swiftUI {
            if let f = frames.values.first(where: { $0.contains(point) }) { hits.append((id, f.width * f.height)) }
        }
        // Innermost (smallest) target first, like `closest()` on the web.
        for (id, _) in hits.sorted(by: { $0.1 < $1.1 }) { didTap(id) }
    }
}

extension MainActor {
    /// Gesture callbacks arrive on the main thread; run them as main-actor isolated (iOS 15 safe).
    nonisolated static func assumeIsolatedOnMain(_ body: @MainActor @escaping () -> Void) {
        if Thread.isMainThread, #available(iOS 17.0, *) {
            MainActor.assumeIsolated { body() }
        } else {
            Task { @MainActor in body() }
        }
    }
}

// MARK: - UIKit API

// Associated-object keys; only their addresses matter. Main-actor isolated like `guidelyId`, their only user.
@MainActor private var guidelyIdKey: UInt8 = 0
@MainActor private var guidelyTapKey: UInt8 = 0

@MainActor
final class GuidelyTapObserver: NSObject, UIGestureRecognizerDelegate {
    let id: String
    weak var recognizer: UITapGestureRecognizer?
    weak var control: UIControl?
    init(id: String) { self.id = id }

    @objc func handleTap() { GuidelyTargetRegistry.shared.didTap(id) }

    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}

extension UIView {
    /// Registers this view as a Guidely target. Taps are observed without being stolen.
    @MainActor
    public var guidelyId: String? {
        get { objc_getAssociatedObject(self, &guidelyIdKey) as? String }
        set {
            if let old = guidelyId { GuidelyTargetRegistry.shared.unregister(self, id: old) }
            if let observer = objc_getAssociatedObject(self, &guidelyTapKey) as? GuidelyTapObserver {
                if let r = observer.recognizer { removeGestureRecognizer(r) }
                observer.control?.removeTarget(observer, action: #selector(GuidelyTapObserver.handleTap), for: .touchUpInside)
                objc_setAssociatedObject(self, &guidelyTapKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
            objc_setAssociatedObject(self, &guidelyIdKey, newValue, .OBJC_ASSOCIATION_COPY_NONATOMIC)
            guard let id = newValue, !id.isEmpty else { return }
            GuidelyTargetRegistry.shared.register(self, id: id)
            let observer = GuidelyTapObserver(id: id)
            if let control = self as? UIControl {
                control.addTarget(observer, action: #selector(GuidelyTapObserver.handleTap), for: .touchUpInside)
                observer.control = control
            } else {
                let tap = UITapGestureRecognizer(target: observer, action: #selector(GuidelyTapObserver.handleTap))
                tap.cancelsTouchesInView = false
                tap.delaysTouchesBegan = false
                tap.delaysTouchesEnded = false
                tap.delegate = observer
                addGestureRecognizer(tap)
                observer.recognizer = tap
            }
            objc_setAssociatedObject(self, &guidelyTapKey, observer, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}

// MARK: - SwiftUI API

struct GuidelyTargetModifier: ViewModifier {
    let id: String
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { geo in
                let frame = geo.frame(in: .global)
                Color.clear
                    .onAppear { GuidelyTargetRegistry.shared.registerSwiftUI(id: id, token: token, frame: frame) }
                    .onChange(of: frame) { GuidelyTargetRegistry.shared.registerSwiftUI(id: id, token: token, frame: $0) }
                    .onDisappear { GuidelyTargetRegistry.shared.unregisterSwiftUI(id: id, token: token) }
            })
    }
}

struct GuidelyScreenModifier: ViewModifier {
    let name: String
    func body(content: Content) -> some View {
        content.onAppear { Guidely.shared.screen(name) }
    }
}

extension View {
    /// Tags this view with a Guidely id so tooltips, spotlights and hotspots can anchor to it and
    /// `element_click` / `element_visible` triggers can observe it.
    public func guidelyTarget(_ id: String) -> some View {
        modifier(GuidelyTargetModifier(id: id))
    }

    /// Records a screen view (`Guidely.shared.screen(name)`) when this view appears.
    public func guidelyScreen(_ name: String) -> some View {
        modifier(GuidelyScreenModifier(name: name))
    }
}
#endif
