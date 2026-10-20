#if canImport(UIKit)
import SwiftUI
import UIKit
#if canImport(GuidelyCore)
import GuidelyCore
#endif

extension Color {
    /// `#rrggbb` (or `#rgb`); invalid input → nil.
    init?(guidelyHex hex: String) {
        guard let rgb = GuidelyColor.rgb(hex) else { return nil }
        self.init(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: 1)
    }
}

enum GuidelyColor {
    static func rgb(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xff) / 255, Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255)
    }

    /// Relative luminance (WCAG).
    static func luminance(_ hex: String) -> Double {
        guard let c = rgb(hex) else { return 1 }
        func ch(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b)
    }
}

/// SwiftUI palette for a resolved theme.
struct GuidelyPalette {
    let theme: ResolvedTheme
    var primary: Color { Color(guidelyHex: theme.primary) ?? Color(red: 0.31, green: 0.27, blue: 0.9) }
    var background: Color { Color(guidelyHex: theme.background) ?? (theme.isDark ? Color(white: 0.12) : .white) }
    var text: Color { Color(guidelyHex: theme.text) ?? (theme.isDark ? .white : .black) }
    var muted: Color { text.opacity(0.62) }
    var border: Color { text.opacity(0.12) }
    var subtle: Color { text.opacity(0.06) }
    /// Text on top of the primary colour.
    var onPrimary: Color { GuidelyColor.luminance(theme.primary) > 0.55 ? Color.black : Color.white }
    var radius: CGFloat { CGFloat(max(0, min(32, theme.radius))) }
    var overlay: Color { Color.black.opacity(max(0, min(1, theme.overlayOpacity))) }
    var shadowOpacity: Double { theme.isDark ? 0.5 : 0.18 }
    var colorScheme: ColorScheme { theme.isDark ? .dark : .light }
}

/// Resolves fonts from the theme's CSS-style `fontFamily` list; falls back to the system font.
@MainActor
enum GuidelyFonts {
    private static var cache: [String: String?] = [:]

    static func family(_ list: String) -> String? {
        if let cached = cache[list] { return cached }
        let families = Set(UIFont.familyNames.map { $0.lowercased() })
        var found: String?
        for raw in list.split(separator: ",") {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            let lower = name.lowercased()
            if ["system-ui", "-apple-system", "sans-serif", "blinkmacsystemfont", "ui-sans-serif"].contains(lower) { break }
            if families.contains(lower) { found = UIFont.familyNames.first { $0.lowercased() == lower }; break }
        }
        cache[list] = found
        return found
    }

    static func font(_ style: Font.TextStyle, theme: ResolvedTheme, weight: Font.Weight = .regular) -> Font {
        if let fam = family(theme.fontFamily) {
            return Font.custom(fam, size: UIFont.preferredFont(forTextStyle: style.uiKit).pointSize, relativeTo: style).weight(weight)
        }
        return Font.system(style).weight(weight)
    }
}

extension Font.TextStyle {
    var uiKit: UIFont.TextStyle {
        switch self {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption1
        case .caption2: return .caption2
        default: return .body
        }
    }
}

/// Converts `RichText` runs to an `AttributedString` (links get `.link` so SwiftUI makes them tappable).
@MainActor
enum RichTextRenderer {
    static func attributed(_ rich: RichText, theme: ResolvedTheme, base: Font.TextStyle = .subheadline, color: Color? = nil, linkColor: Color? = nil) -> AttributedString {
        let palette = GuidelyPalette(theme: theme)
        var out = AttributedString()
        for run in rich.runs {
            var a = AttributedString(run.text)
            let style: Font.TextStyle
            switch run.heading {
            case 1: style = .title3
            case 2: style = .headline
            case 3: style = .subheadline
            default: style = base
            }
            var font: Font
            if run.code {
                font = Font.system(style, design: .monospaced)
            } else {
                font = GuidelyFonts.font(style, theme: theme, weight: run.bold || run.heading > 0 ? .semibold : .regular)
            }
            if run.italic { font = font.italic() }
            a.font = font
            a.foregroundColor = color ?? palette.text
            if run.underline { a.underlineStyle = .single }
            if run.code { a.backgroundColor = palette.subtle }
            if let link = run.link, let url = URL(string: link) ?? URL(string: link.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "") {
                a.link = url
                a.foregroundColor = linkColor ?? palette.primary
                a.underlineStyle = .single
            }
            out.append(a)
        }
        return out
    }
}

/// Rich text view for sanitized guide HTML. Links go through Guidely's navigation handling.
struct GuidelyRichText: View {
    let rich: RichText
    let theme: ResolvedTheme
    var base: Font.TextStyle
    var color: Color?
    var linkColor: Color?
    var onLink: (URL) -> Void

    init(html: String, theme: ResolvedTheme, base: Font.TextStyle = .subheadline, color: Color? = nil, linkColor: Color? = nil, onLink: @escaping (URL) -> Void) {
        self.init(rich: HTMLParser.parse(html), theme: theme, base: base, color: color, linkColor: linkColor, onLink: onLink)
    }

    init(rich: RichText, theme: ResolvedTheme, base: Font.TextStyle = .subheadline, color: Color? = nil, linkColor: Color? = nil, onLink: @escaping (URL) -> Void) {
        self.rich = rich; self.theme = theme; self.base = base; self.color = color; self.linkColor = linkColor; self.onLink = onLink
    }

    var body: some View {
        if !rich.isEmpty {
            Text(RichTextRenderer.attributed(rich, theme: theme, base: base, color: color, linkColor: linkColor))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.openURL, OpenURLAction { url in
                    onLink(url)
                    return .handled
                })
        }
    }
}

/// Collects frames of interactive SDK content (cards, launchers, hotspots) in global coordinates.
struct InteractiveRectsKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, b in b })
    }
}

/// Measures a view's size.
struct SizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let n = nextValue()
        if n != .zero { value = n }
    }
}

extension View {
    /// Marks this view as touchable SDK content (the overlay window passes every other touch through).
    func guidelyInteractive(_ id: String) -> some View {
        background(GeometryReader { geo in
            Color.clear.preference(key: InteractiveRectsKey.self, value: [id: geo.frame(in: .global)])
        })
    }

    func measureSize(_ onChange: @escaping (CGSize) -> Void) -> some View {
        background(GeometryReader { geo in Color.clear.preference(key: SizeKey.self, value: geo.size) })
            .onPreferenceChange(SizeKey.self, perform: onChange)
    }

    /// Card chrome: background, radius, border, shadow.
    func guidelyCard(_ p: GuidelyPalette) -> some View {
        background(
            RoundedRectangle(cornerRadius: p.radius, style: .continuous)
                .fill(p.background)
                .shadow(color: Color.black.opacity(p.shadowOpacity), radius: 20, x: 0, y: 8)
        )
        .overlay(RoundedRectangle(cornerRadius: p.radius, style: .continuous).stroke(p.border, lineWidth: 1))
    }
}

/// Close (×) button used by cards and panels.
struct GuidelyCloseButton: View {
    let palette: GuidelyPalette
    var label = "Close"
    var color: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(color ?? palette.muted)
                .frame(width: 30, height: 30)
                .background(Circle().fill((color ?? palette.text).opacity(0.08)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: 36, height: 36)
        .accessibilityLabel(Text(label))
    }
}

/// Primary / secondary / ghost / link button styles.
struct GuidelyButtonStyle: ButtonStyle {
    let variant: ButtonVariant
    let palette: GuidelyPalette
    var inverted = false

    func makeBody(configuration: Configuration) -> some View {
        let font = GuidelyFonts.font(.subheadline, theme: palette.theme, weight: .semibold)
        let fg: Color
        let bg: Color
        let stroke: Color
        switch variant {
        case .primary:
            fg = inverted ? palette.primary : palette.onPrimary
            bg = inverted ? Color.white : palette.primary
            stroke = .clear
        case .secondary:
            fg = inverted ? .white : palette.primary
            bg = .clear
            stroke = inverted ? Color.white.opacity(0.8) : palette.primary
        case .ghost:
            fg = inverted ? Color.white.opacity(0.9) : palette.muted
            bg = .clear
            stroke = .clear
        case .link:
            fg = inverted ? .white : palette.primary
            bg = .clear
            stroke = .clear
        }
        return configuration.label
            .font(font)
            .foregroundColor(fg)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, variant == .link ? 4 : 14)
            .frame(minHeight: 40)
            .background(RoundedRectangle(cornerRadius: min(palette.radius, 10), style: .continuous).fill(bg))
            .overlay(RoundedRectangle(cornerRadius: min(palette.radius, 10), style: .continuous).stroke(stroke, lineWidth: 1.5))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }
}
#endif
