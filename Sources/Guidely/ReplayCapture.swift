#if canImport(UIKit)
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
#if canImport(GuidelyCore)
import GuidelyCore
#endif

/// Session replay screenshots (mobile/SPEC.md "Session replay"): draws the scene's visible windows at
/// 1× points, paints masks over sensitive views and encodes a JPEG. Touches are observed with a
/// passive recognizer on each window that never claims or delays them.
@MainActor
final class UIKitScreenCapturer: GuidelyScreenCapturer {
    static let maskColor = UIColor(red: 0.62, green: 0.62, blue: 0.62, alpha: 1)
    static let jpegQuality: CGFloat = 0.6

    private var touchHandler: (@MainActor (ReplayTouchPhase, Double, Double) -> Void)?
    private var recognizers: [ObjectIdentifier: (window: UIWindow, recognizer: ReplayTouchRecognizer)] = [:]
    private weak var baseWindow: UIWindow?
    private let targets: GuidelyTargetRegistry

    init(targets: GuidelyTargetRegistry = .shared) { self.targets = targets }

    // MARK: Frames

    func captureFrame(_ rules: ReplayMaskRules, completion: @escaping @MainActor @Sendable (ReplayFrame?) -> Void) {
        guard let image = render(rules) else { return completion(nil) }
        let box = ImageBox(image)
        let quality = Self.jpegQuality // read on the main actor; the closure below runs off it
        DispatchQueue.global(qos: .utility).async {
            let jpeg = box.image.jpegData(compressionQuality: quality)
            let frame = jpeg.map { ReplayFrame(jpeg: $0, width: Int(box.image.size.width.rounded()), height: Int(box.image.size.height.rounded())) }
            Task { @MainActor in completion(frame) }
        }
    }

    /// Draws the windows and paints the masks (main thread); encoding happens in `captureFrame`.
    private func render(_ rules: ReplayMaskRules) -> UIImage? {
        guard UIApplication.shared.applicationState != .background, let scene = Self.activeScene() else { return nil }
        let windows = scene.windows
            .filter { !$0.isHidden && $0.alpha > 0.01 && !Self.isKeyboardWindow($0) && $0.bounds.width > 0 && $0.bounds.height > 0 }
            .sorted { $0.windowLevel < $1.windowLevel }
        guard let base = windows.first(where: { $0.windowLevel == .normal && !($0 is GuidelyOverlayWindow) }) ?? windows.first else { return nil }
        baseWindow = base
        if touchHandler != nil { windows.forEach(observe) }
        let canvas = base.bounds
        var masks: [CGRect] = []
        for w in windows { collectMasks(w, base: base, rules: rules, into: &masks) }
        for id in rules.blockedIds {
            if let f = targets.frame(for: id) { masks.append(f) }
        }
        // `drawHierarchy` copies a window's pixels (transparent areas included) rather than blending,
        // so windows above the app window are rendered on their own and composited.
        let layerFormat = UIGraphicsImageRendererFormat()
        layerFormat.scale = 1
        layerFormat.opaque = false
        let upper = windows.filter { $0 !== base }.map { w -> (UIImage, CGRect) in
            let image = UIGraphicsImageRenderer(size: w.bounds.size, format: layerFormat).image { _ in
                _ = w.drawHierarchy(in: w.bounds, afterScreenUpdates: false)
            }
            return (image, w.convert(w.bounds, to: base))
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: canvas.size, format: format).image { ctx in
            UIColor.black.setFill()
            ctx.fill(canvas)
            let below = windows.filter { $0 !== base && $0.windowLevel < base.windowLevel }.count
            for (image, rect) in upper.prefix(below) { image.draw(in: rect) }
            _ = base.drawHierarchy(in: canvas, afterScreenUpdates: false)
            for (image, rect) in upper.dropFirst(below) { image.draw(in: rect) }
            Self.maskColor.setFill()
            for r in masks where r.intersects(canvas) { ctx.fill(r.insetBy(dx: -1, dy: -1)) }
        }
    }

    static func activeScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first { $0.activationState == .foregroundInactive }
    }

    /// The system keyboard (and its text effects window) is never recorded, so typed keys can't leak.
    static func isKeyboardWindow(_ w: UIWindow) -> Bool {
        let name = NSStringFromClass(type(of: w))
        return name.contains("Keyboard") || name.contains("TextEffects")
    }

    // MARK: Masks

    /// SwiftUI draws `Text` in private views (`CGDrawingView`, iOS ≤ 17) or layers (`CGDrawingLayer`,
    /// iOS 18+) rather than `UILabel`, and images in `ImageLayer`s. Matched by class name.
    private static let swiftUITextViews = ["CGDrawingView", "TextEditorTextView", "VerticalTextView", "StyledTextContentView"]
    private static let textLayers = ["CGDrawingLayer", "StyledTextLayer"]
    private static let imageLayers = ["ImageLayer"]

    private enum Kind { case none, text, image }
    /// Class-name lookups are cached per class: demangling Swift class names is slow.
    private static var kinds: [ObjectIdentifier: Kind] = [:]

    private static func kind(of cls: AnyClass, isLayer: Bool) -> Kind {
        let key = ObjectIdentifier(cls)
        if let k = kinds[key] { return k }
        let name = NSStringFromClass(cls)
        let k: Kind
        if isLayer {
            k = textLayers.contains(where: { name.contains($0) }) ? .text : imageLayers.contains(where: { name.contains($0) }) ? .image : .none
        } else {
            k = name.contains("SwiftUI") && swiftUITextViews.contains(where: { name.contains($0) }) ? .text : .none
        }
        kinds[key] = k
        return k
    }

    static func masks(_ view: UIView, _ rules: ReplayMaskRules) -> Bool {
        if view.guidelyMask || view is GuidelyMaskMarkerView { return true }
        if view is UITextField { return true }
        if let tv = view as? UITextView { return tv.isEditable || rules.maskAllText }
        if rules.maskAllText, view is UILabel || kind(of: type(of: view), isLayer: false) == .text { return true }
        if rules.maskAllImages, view is UIImageView { return true }
        return false
    }

    static func masks(_ layer: CALayer, _ rules: ReplayMaskRules) -> Bool {
        guard rules.maskAllText || rules.maskAllImages else { return false }
        if rules.maskAllText, layer is CATextLayer { return true }
        switch kind(of: type(of: layer), isLayer: true) {
        case .text: return rules.maskAllText
        case .image: return rules.maskAllImages
        case .none: return false
        }
    }

    private func collectMasks(_ view: UIView, base: UIWindow, rules: ReplayMaskRules, into rects: inout [CGRect]) {
        if view.isHidden || view.alpha < 0.01 || view.layer.opacity < 0.01 { return }
        if !(view is UIWindow), view.bounds.width > 0, view.bounds.height > 0, Self.masks(view, rules) {
            rects.append(contentsOf: Self.frames(of: view, base: base))
            return
        }
        if rules.maskAllText || rules.maskAllImages, let window = view.window {
            for layer in view.layer.sublayers ?? [] { collectLayerMasks(layer, window: window, base: base, rules: rules, into: &rects) }
        }
        for sub in view.subviews { collectMasks(sub, base: base, rules: rules, into: &rects) }
    }

    /// Layers drawn without a view of their own (SwiftUI content); layers backing subviews are left to the view walk.
    private func collectLayerMasks(_ layer: CALayer, window: UIWindow, base: UIWindow, rules: ReplayMaskRules, into rects: inout [CGRect]) {
        if layer.delegate is UIView || layer.isHidden || layer.opacity < 0.01 { return }
        if layer.bounds.width > 0, layer.bounds.height > 0, Self.masks(layer, rules) {
            rects.append(contentsOf: Self.frames(of: layer, window: window, base: base))
            return
        }
        for sub in layer.sublayers ?? [] { collectLayerMasks(sub, window: window, base: base, rules: rules, into: &rects) }
    }

    /// Model frame plus the on-screen (presentation) frame while the view is animating, so a view
    /// mid-transition is covered wherever it is drawn.
    static func frames(of view: UIView, base: UIWindow) -> [CGRect] {
        guard let window = view.window else { return [view.convert(view.bounds, to: base)] }
        return frames(of: view.layer, window: window, base: base)
    }

    static func frames(of layer: CALayer, window: UIWindow, base: UIWindow) -> [CGRect] {
        var out = [window.convert(window.layer.convert(layer.bounds, from: layer), to: base)]
        if let pl = layer.presentation(), let wl = window.layer.presentation() {
            let r = window.convert(wl.convert(pl.bounds, from: pl), to: base)
            if !r.isNull, !r.isInfinite, r != out[0] { out.append(r) }
        }
        return out
    }

    // MARK: Touches

    func observeTouches(_ handler: (@MainActor (ReplayTouchPhase, Double, Double) -> Void)?) {
        touchHandler = handler
        if handler == nil {
            for (_, entry) in recognizers { entry.window.removeGestureRecognizer(entry.recognizer) }
            recognizers.removeAll()
        } else if let scene = Self.activeScene() {
            scene.windows.filter { !Self.isKeyboardWindow($0) }.forEach(observe)
        }
    }

    private func observe(_ window: UIWindow) {
        recognizers = recognizers.filter { $0.value.recognizer.view != nil }
        guard recognizers[ObjectIdentifier(window)] == nil else { return }
        let r = ReplayTouchRecognizer()
        r.onTouch = { [weak self, weak window] phase, touch in
            guard let self, let handler = self.touchHandler, let window else { return }
            let p = touch.location(in: self.baseWindow ?? window)
            handler(phase, Double(p.x), Double(p.y))
        }
        window.addGestureRecognizer(r)
        recognizers[ObjectIdentifier(window)] = (window, r)
    }
}

private final class ImageBox: @unchecked Sendable {
    let image: UIImage
    init(_ image: UIImage) { self.image = image }
}

/// Watches the first finger of every touch sequence on a window without ever recognizing, so it
/// never cancels, delays or competes with the app's own gestures.
final class ReplayTouchRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var onTouch: ((ReplayTouchPhase, UITouch) -> Void)?
    private weak var tracked: UITouch?

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        requiresExclusiveTouchType = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if tracked == nil, let t = touches.first {
            tracked = t
            onTouch?(.began, t)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if let t = tracked, touches.contains(t) { onTouch?(.moved, t) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches, event) }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches, event) }

    private func finish(_ touches: Set<UITouch>, _ event: UIEvent) {
        if let t = tracked, touches.contains(t) {
            onTouch?(.ended, t)
            tracked = nil
        }
        // Fail once every finger is up so the recognizer resets for the next sequence.
        if (event.allTouches ?? touches).allSatisfy({ $0.phase == .ended || $0.phase == .cancelled }) { state = .failed }
    }

    override func reset() {
        super.reset()
        tracked = nil
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool { false }
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool { false }
}

// MARK: - Masking API

@MainActor private var guidelyMaskKey: UInt8 = 0

extension UIView {
    /// Hides this view (and everything inside it) in session recordings.
    @MainActor
    public var guidelyMask: Bool {
        get { (objc_getAssociatedObject(self, &guidelyMaskKey) as? Bool) ?? false }
        set { objc_setAssociatedObject(self, &guidelyMaskKey, newValue ? true : nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}

/// Transparent marker placed behind a `.guidelyMask()` view; the capturer masks its frame.
final class GuidelyMaskMarkerView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { nil }
}

struct GuidelyMaskMarker: UIViewRepresentable {
    func makeUIView(context: Context) -> GuidelyMaskMarkerView { GuidelyMaskMarkerView() }
    func updateUIView(_ uiView: GuidelyMaskMarkerView, context: Context) {}
}

extension View {
    /// Hides this view in session recordings (painted over before the screenshot leaves the device).
    public func guidelyMask(_ masked: Bool = true) -> some View {
        background(Group { if masked { GuidelyMaskMarker() } })
    }
}
#endif
