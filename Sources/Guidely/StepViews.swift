#if canImport(UIKit)
import SwiftUI
import UIKit
#if canImport(GuidelyCore)
import GuidelyCore
#endif

/// Root of the overlay window: every Guidely surface, positioned in window coordinates.
struct OverlayRootView: View {
    @ObservedObject var model: OverlayModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: model.size.width, height: model.size.height)
            ForEach(model.checklists) { ChecklistLayer(item: $0, model: model) }
            ForEach(model.steps) { StepLayer(item: $0, model: model) }
            if let survey = model.survey { SurveyLayer(item: survey, model: model) }
            if let rc = model.resourceCenter { ResourceCenterLayer(item: rc, model: model) }
            if let messenger = model.messenger { MessengerLayer(item: messenger, model: model) }
        }
        .frame(width: model.size.width, height: model.size.height, alignment: .topLeading)
        .ignoresSafeArea()
        .onPreferenceChange(InteractiveRectsKey.self) { model.interactiveRects = $0 }
        .onAppear { model.reduceMotion = reduceMotion }
        .onChange(of: reduceMotion) { model.reduceMotion = $0 }
    }
}

/// Safe content bounds in window coordinates.
extension OverlayModel {
    var safeBounds: CGRect {
        CGRect(x: safeArea.left, y: safeArea.top, width: max(0, size.width - safeArea.left - safeArea.right), height: max(0, size.height - safeArea.top - safeArea.bottom))
    }

    /// Bottom edge available to floating SDK content (above home indicator, tab bar and keyboard).
    var contentBottom: CGFloat {
        let base = size.height - safeArea.bottom - bottomBarInset
        if keyboardHeight > 0 { return min(base, size.height - keyboardHeight) }
        return base
    }
}

// MARK: - Step layer

struct StepLayer: View {
    @ObservedObject var item: StepItem
    @ObservedObject var model: OverlayModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let theme = item.presentation.theme.resolve(systemDark: scheme == .dark, reduceMotion: reduceMotion)
        let palette = GuidelyPalette(theme: theme)
        Group {
            switch item.style {
            case .modal: ModalStepView(item: item, model: model, palette: palette)
            case .tooltip: AnchoredStepView(item: item, model: model, palette: palette, spotlight: false)
            case .spotlight: AnchoredStepView(item: item, model: model, palette: palette, spotlight: true)
            case .hotspot: HotspotStepView(item: item, model: model, palette: palette)
            case .banner: BannerStepView(item: item, model: model, palette: palette)
            case .slideout: SlideoutStepView(item: item, model: model, palette: palette)
            }
        }
        .environment(\.colorScheme, palette.colorScheme)
        .transition(transition(theme))
    }

    private func transition(_ theme: ResolvedTheme) -> AnyTransition {
        guard theme.animation != .none else { return .identity }
        if theme.animation == .slide, !reduceMotion {
            switch item.style {
            case .banner: return item.step.position.isTop ? .move(edge: .top).combined(with: .opacity) : .move(edge: .bottom).combined(with: .opacity)
            case .slideout: return .move(edge: .bottom).combined(with: .opacity)
            default: break
            }
        }
        return .opacity
    }
}

/// Full-screen backdrop behind blocking steps.
struct Backdrop: View {
    let size: CGSize
    let color: Color
    let onTap: (() -> Void)?

    var body: some View {
        color
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .onTapGesture { onTap?() }
            .accessibilityHidden(onTap == nil)
            .accessibilityLabel(Text("Dismiss"))
            .accessibilityAddTraits(.isButton)
    }
}

/// Title, body, image, progress, close and buttons.
struct StepCardContent: View {
    let item: StepItem
    let palette: GuidelyPalette
    let navigate: (URL) -> Void

    private var p: StepPresentation { item.presentation }

    var body: some View {
        let step = p.step
        let theme = palette.theme
        VStack(alignment: .leading, spacing: 10) {
            if let img = step.imageUrl, let url = URL(string: img) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        palette.subtle
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 140)
                .clipShape(RoundedRectangle(cornerRadius: max(4, palette.radius - 4), style: .continuous))
                .accessibilityHidden(true)
            }
            let title = step.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty || step.showClose {
                HStack(alignment: .top, spacing: 8) {
                    Text(title)
                        .font(GuidelyFonts.font(.headline, theme: theme, weight: .semibold))
                        .foregroundColor(palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.isHeader)
                    if step.showClose {
                        GuidelyCloseButton(palette: palette, label: "Close guide") { p.onClose() }
                            .padding(.top, -6)
                            .padding(.trailing, -6)
                            .padding(.bottom, -6)
                    }
                }
            }
            GuidelyRichText(html: step.type == .custom ? (step.customHtml ?? step.body) : step.body, theme: theme, onLink: navigate)
            footer
        }
        .padding(16)
    }

    @ViewBuilder private var footer: some View {
        let showProgress = p.step.showProgress && p.total > 1
        let buttons = p.buttons
        if showProgress || !buttons.isEmpty {
            let progress = Text("Step \(p.index + 1) of \(p.total)")
                .font(GuidelyFonts.font(.caption, theme: palette.theme))
                .foregroundColor(palette.muted)
            if buttons.count >= 3 {
                VStack(alignment: .trailing, spacing: 8) {
                    if showProgress { progress.frame(maxWidth: .infinity, alignment: .leading) }
                    HStack(spacing: 8) { Spacer(minLength: 0); buttonViews(buttons) }
                }
                .padding(.top, 4)
            } else {
                HStack(spacing: 8) {
                    if showProgress { progress.layoutPriority(1) }
                    Spacer(minLength: 0)
                    buttonViews(buttons)
                }
                .padding(.top, 4)
            }
        }
    }

    private func buttonViews(_ buttons: [StepButton]) -> some View {
        ForEach(buttons) { b in
            Button(b.label) { p.onButton(b) }
                .buttonStyle(GuidelyButtonStyle(variant: b.variant, palette: palette))
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel(Text(b.label))
        }
    }
}

/// Card container that scrolls when its content is taller than `maxHeight`.
struct CappedCard<Content: View>: View {
    let width: CGFloat
    let maxHeight: CGFloat
    @Binding var size: CGSize
    @ViewBuilder let content: () -> Content
    @State private var natural: CGFloat = 0

    var body: some View {
        Group {
            if natural > maxHeight, maxHeight > 80 {
                ScrollView(.vertical, showsIndicators: true) {
                    content().measureSize { natural = $0.height }
                }
                .frame(width: width, height: maxHeight)
            } else {
                content()
                    .frame(width: width)
                    .fixedSize(horizontal: false, vertical: true)
                    .measureSize { natural = $0.height }
            }
        }
        .measureSize { if size != $0 { size = $0 } }
    }
}

struct ModalStepView: View {
    @ObservedObject var item: StepItem
    @ObservedObject var model: OverlayModel
    let palette: GuidelyPalette

    var body: some View {
        let width = AnchorMath.cardWidth(container: model.size.width, requested: item.step.width ?? 360)
        let bounds = model.safeBounds
        let maxH = max(120, min(bounds.height, model.contentBottom - bounds.minY) - 32)
        let h = item.cardSize.height
        let x = (model.size.width - width) / 2
        let y = max(bounds.minY + 16, bounds.minY + (min(bounds.height, model.contentBottom - bounds.minY) - h) / 2)
        ZStack(alignment: .topLeading) {
            if item.dimmed {
                Backdrop(size: model.size, color: palette.overlay, onTap: item.step.dismissOnOutsideClick ? { item.presentation.onClose() } : nil)
            } else if item.step.dismissOnOutsideClick {
                Backdrop(size: model.size, color: Color.black.opacity(0.001), onTap: { item.presentation.onClose() })
            }
            CappedCard(width: width, maxHeight: maxH, size: $item.cardSize) {
                StepCardContent(item: item, palette: palette, navigate: model.navigate)
            }
            .guidelyCard(palette)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(item.dimmed ? .isModal : [])
            .guidelyInteractive("step-\(item.id)")
            .offset(x: x, y: y)
            .opacity(h > 0 ? 1 : 0)
        }
    }
}

/// Triangle pointing at the target.
struct ArrowShape: Shape {
    let side: AnchorSide
    func path(in r: CGRect) -> Path {
        var p = Path()
        switch side {
        case .bottom: // card below target → arrow on top edge pointing up
            p.move(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.midX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        case .top:
            p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.midX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        case .right: // card right of target → arrow on left edge pointing left
            p.move(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX, y: r.midY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        case .left:
            p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.midY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        }
        return p
    }
}

/// Card anchored to a target, with an arrow (tooltip / popover / spotlight / open hotspot).
struct AnchoredCard: View {
    @ObservedObject var item: StepItem
    @ObservedObject var model: OverlayModel
    let palette: GuidelyPalette
    let target: CGRect

    var body: some View {
        let width = AnchorMath.cardWidth(container: model.size.width, requested: item.step.width)
        let safe = model.safeBounds
        let bounds = CGRect(x: safe.minX, y: safe.minY, width: safe.width, height: max(0, model.contentBottom - safe.minY))
        let size = CGSize(width: width, height: max(1, item.cardSize.height))
        let layout = AnchorMath.layout(target: target, cardSize: size, placement: item.step.placement, offset: CGFloat(item.step.offset), bounds: bounds, cornerRadius: palette.radius)
        let arrow: CGFloat = 8
        CappedCard(width: width, maxHeight: max(120, bounds.height - 32), size: $item.cardSize) {
            StepCardContent(item: item, palette: palette, navigate: model.navigate)
        }
        .guidelyCard(palette)
        .overlay(alignment: .topLeading) {
            arrowView(layout: layout, size: arrow)
        }
        .accessibilityElement(children: .contain)
        .guidelyInteractive("step-\(item.id)")
        .offset(x: layout.frame.minX, y: layout.frame.minY)
        .opacity(item.cardSize.height > 0 ? 1 : 0)
    }

    @ViewBuilder private func arrowView(layout: AnchorLayout, size: CGFloat) -> some View {
        let w = size * 2
        let h = size
        let shape = ArrowShape(side: layout.side)
        switch layout.side {
        case .bottom:
            shape.fill(palette.background).frame(width: w, height: h).offset(x: layout.arrowOffset - size, y: -h + 0.5)
        case .top:
            shape.fill(palette.background).frame(width: w, height: h).offset(x: layout.arrowOffset - size, y: layout.frame.height - 0.5)
        case .right:
            shape.fill(palette.background).frame(width: h, height: w).offset(x: -h + 0.5, y: layout.arrowOffset - size)
        case .left:
            shape.fill(palette.background).frame(width: h, height: w).offset(x: layout.frame.width - 0.5, y: layout.arrowOffset - size)
        }
    }
}

struct AnchoredStepView: View {
    @ObservedObject var item: StepItem
    @ObservedObject var model: OverlayModel
    let palette: GuidelyPalette
    let spotlight: Bool

    var body: some View {
        if let id = item.presentation.targetId, let target = model.targetFrames[id] {
            ZStack(alignment: .topLeading) {
                if spotlight {
                    let pad = CGFloat(item.step.spotlightPadding)
                    let hole = target.insetBy(dx: -pad, dy: -pad)
                    SpotlightShape(hole: hole, radius: min(palette.radius, 12))
                        .fill(palette.overlay, style: FillStyle(eoFill: true))
                        .frame(width: model.size.width, height: model.size.height)
                        .contentShape(SpotlightShape(hole: hole, radius: min(palette.radius, 12)), eoFill: true)
                        .onTapGesture { if item.step.dismissOnOutsideClick { item.presentation.onClose() } }
                        .accessibilityHidden(true)
                    RoundedRectangle(cornerRadius: min(palette.radius, 12), style: .continuous)
                        .stroke(palette.primary, lineWidth: 2)
                        .frame(width: hole.width, height: hole.height)
                        .offset(x: hole.minX, y: hole.minY)
                        .allowsHitTesting(false)
                } else if item.dimmed {
                    Backdrop(size: model.size, color: palette.overlay, onTap: item.step.dismissOnOutsideClick ? { item.presentation.onClose() } : nil)
                } else if item.step.dismissOnOutsideClick {
                    Backdrop(size: model.size, color: Color.black.opacity(0.001), onTap: { item.presentation.onClose() })
                }
                AnchoredCard(item: item, model: model, palette: palette, target: spotlight ? target.insetBy(dx: -CGFloat(item.step.spotlightPadding), dy: -CGFloat(item.step.spotlightPadding)) : target)
            }
        }
    }
}

/// Full-screen rect with a rounded hole (even-odd fill).
struct SpotlightShape: Shape {
    let hole: CGRect
    let radius: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addRect(rect)
        p.addRoundedRect(in: hole, cornerSize: CGSize(width: radius, height: radius), style: .continuous)
        return p
    }
}

struct HotspotStepView: View {
    @ObservedObject var item: StepItem
    @ObservedObject var model: OverlayModel
    let palette: GuidelyPalette
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let id = item.presentation.targetId, let target = model.targetFrames[id] {
            let size = CGFloat(item.step.hotspot?.size ?? 14)
            let center = AnchorMath.hotspotCenter(target: target, size: size)
            let animate = (item.step.hotspot?.pulse ?? true) && !reduceMotion
            ZStack(alignment: .topLeading) {
                if item.hotspotOpen && item.step.dismissOnOutsideClick {
                    Backdrop(size: model.size, color: Color.black.opacity(0.001), onTap: { item.hotspotOpen = false })
                }
                Button {
                    withAnimation(model.animation) { item.hotspotOpen.toggle() }
                    if item.hotspotOpen { model.announce(item.step.title) }
                } label: {
                    ZStack {
                        Circle()
                            .fill(palette.primary.opacity(0.35))
                            .frame(width: size, height: size)
                            .scaleEffect(pulse ? 2.4 : 1)
                            .opacity(pulse ? 0 : 0.8)
                        Circle()
                            .fill(palette.primary)
                            .frame(width: size, height: size)
                            .overlay(Circle().stroke(Color.white, lineWidth: 2))
                            .shadow(color: Color.black.opacity(0.25), radius: 3, x: 0, y: 1)
                    }
                    .frame(width: max(44, size * 2), height: max(44, size * 2))
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(item.step.title.isEmpty ? "Show tip" : item.step.title))
                .accessibilityHint(Text("Shows a tip about this item"))
                .guidelyInteractive("hotspot-\(item.id)")
                .offset(x: center.x - max(22, size), y: center.y - max(22, size))
                .onAppear {
                    guard animate else { return }
                    withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
                }
                if item.hotspotOpen {
                    AnchoredCard(item: item, model: model, palette: palette, target: target)
                        .transition(.opacity)
                }
            }
        }
    }
}

struct BannerStepView: View {
    @ObservedObject var item: StepItem
    @ObservedObject var model: OverlayModel
    let palette: GuidelyPalette

    var body: some View {
        let p = item.presentation
        let top = item.step.position.isTop
        let onPrimary = palette.onPrimary
        let h = item.cardSize.height
        let y = top ? model.safeArea.top : model.contentBottom - h
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                if !p.step.title.isEmpty {
                    Text(p.step.title)
                        .font(GuidelyFonts.font(.subheadline, theme: palette.theme, weight: .semibold))
                        .foregroundColor(onPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                GuidelyRichText(html: p.step.body, theme: palette.theme, color: onPrimary, linkColor: onPrimary, onLink: model.navigate)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(p.buttons) { b in
                Button(b.label) { p.onButton(b) }
                    .buttonStyle(GuidelyButtonStyle(variant: b.variant, palette: palette, inverted: true))
                    .fixedSize()
            }
            if p.step.showClose {
                GuidelyCloseButton(palette: palette, label: "Dismiss banner", color: onPrimary) { p.onClose() }
                    .padding(.trailing, -8)
            }
        }
        .padding(.leading, 16 + model.safeArea.left)
        .padding(.trailing, 12 + model.safeArea.right)
        .padding(.vertical, 8)
        .frame(width: model.size.width)
        .background(palette.primary.shadow(radius: 6))
        .measureSize { if item.cardSize != $0 { item.cardSize = $0 } }
        .accessibilityElement(children: .contain)
        .guidelyInteractive("banner-\(item.id)")
        .offset(x: 0, y: y)
        .opacity(h > 0 ? 1 : 0)
    }
}

struct SlideoutStepView: View {
    @ObservedObject var item: StepItem
    @ObservedObject var model: OverlayModel
    let palette: GuidelyPalette

    private func slideoutX(_ pos: StepPosition, width: CGFloat) -> CGFloat {
        switch pos {
        case .bottomLeft, .topLeft: return model.safeArea.left + 16
        case .bottomRight, .topRight: return model.size.width - model.safeArea.right - 16 - width
        default: return (model.size.width - width) / 2
        }
    }

    var body: some View {
        let width = min(model.size.width - 32 - model.safeArea.left - model.safeArea.right, CGFloat(item.step.width ?? 480))
        let h = item.cardSize.height
        let pos = item.step.position
        let x = slideoutX(pos, width: width)
        let y = pos.isTop ? model.safeArea.top + 16 : model.contentBottom - 16 - h
        ZStack(alignment: .topLeading) {
            if item.step.dismissOnOutsideClick {
                Backdrop(size: model.size, color: Color.black.opacity(0.001), onTap: { item.presentation.onClose() })
            }
            CappedCard(width: width, maxHeight: max(120, model.contentBottom - model.safeArea.top - 48), size: $item.cardSize) {
                StepCardContent(item: item, palette: palette, navigate: model.navigate)
            }
            .guidelyCard(palette)
            .accessibilityElement(children: .contain)
            .guidelyInteractive("slideout-\(item.id)")
            .offset(x: x, y: y)
            .opacity(h > 0 ? 1 : 0)
        }
    }
}
#endif
