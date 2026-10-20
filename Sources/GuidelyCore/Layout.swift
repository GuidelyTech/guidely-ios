import CoreGraphics
import Foundation

/// Which side of the target an anchored card sits on.
public enum AnchorSide: String, Sendable { case top, bottom, left, right }

public struct AnchorLayout: Sendable, Equatable {
    /// Card frame in the same coordinate space as the target.
    public var frame: CGRect
    public var side: AnchorSide
    /// Arrow center along the card edge facing the target (x for top/bottom, y for left/right), relative to the card.
    public var arrowOffset: CGFloat
}

public enum AnchorMath {
    /// Card width: `min(container − 32, step.width ?? 340)`.
    public static func cardWidth(container: CGFloat, requested: Int?) -> CGFloat {
        max(160, min(container - 32, CGFloat(requested ?? 340)))
    }

    /// Positions a card next to `target` inside `bounds` (the safe area): honours `placement` when
    /// it fits, otherwise flips; `auto` = below if it fits, else above. The card is shifted along
    /// the cross axis to stay `padding` inside the bounds.
    public static func layout(target: CGRect, cardSize: CGSize, placement: Placement, offset: CGFloat, bounds: CGRect, padding: CGFloat = 16, arrowSize: CGFloat = 8, cornerRadius: CGFloat = 12) -> AnchorLayout {
        let gap = offset + arrowSize
        let w = cardSize.width, h = cardSize.height
        let raw = placement.rawValue
        let parts = raw.split(separator: "-").map(String.init)
        let preferred: AnchorSide = placement == .auto ? .bottom : (AnchorSide(rawValue: parts.first ?? "bottom") ?? .bottom)
        let align = parts.count > 1 ? parts[1] : "center"

        func fits(_ side: AnchorSide) -> Bool {
            switch side {
            case .bottom: return target.maxY + gap + h <= bounds.maxY
            case .top: return target.minY - gap - h >= bounds.minY
            case .right: return target.maxX + gap + w <= bounds.maxX - padding / 2
            case .left: return target.minX - gap - w >= bounds.minX + padding / 2
            }
        }
        func opposite(_ s: AnchorSide) -> AnchorSide {
            switch s { case .top: return .bottom; case .bottom: return .top; case .left: return .right; case .right: return .left }
        }

        var side = preferred
        if placement == .auto {
            side = fits(.bottom) ? .bottom : (fits(.top) ? .top : ((bounds.maxY - target.maxY) >= (target.minY - bounds.minY) ? .bottom : .top))
        } else if !fits(preferred) {
            if fits(opposite(preferred)) { side = opposite(preferred) }
            else if preferred == .left || preferred == .right { side = fits(.bottom) ? .bottom : (fits(.top) ? .top : ((bounds.maxY - target.maxY) >= (target.minY - bounds.minY) ? .bottom : .top)) }
            else { side = (bounds.maxY - target.maxY) >= (target.minY - bounds.minY) ? .bottom : .top }
        }

        var x: CGFloat
        var y: CGFloat
        switch side {
        case .top, .bottom:
            switch align {
            case "start": x = target.minX
            case "end": x = target.maxX - w
            default: x = target.midX - w / 2
            }
            y = side == .bottom ? target.maxY + gap : target.minY - gap - h
        case .left, .right:
            switch align {
            case "start": y = target.minY
            case "end": y = target.maxY - h
            default: y = target.midY - h / 2
            }
            x = side == .right ? target.maxX + gap : target.minX - gap - w
        }
        // Shift inside the bounds.
        let minX = bounds.minX + padding, maxX = bounds.maxX - padding - w
        x = maxX < minX ? bounds.midX - w / 2 : min(max(x, minX), maxX)
        let minY = bounds.minY + padding / 2, maxY = bounds.maxY - padding / 2 - h
        y = maxY < minY ? minY : min(max(y, minY), maxY)

        let inset = cornerRadius + arrowSize + 2
        let arrow: CGFloat
        switch side {
        case .top, .bottom: arrow = clampArrow(target.midX - x, length: w, inset: inset)
        case .left, .right: arrow = clampArrow(target.midY - y, length: h, inset: inset)
        }
        return AnchorLayout(frame: CGRect(x: x, y: y, width: w, height: h), side: side, arrowOffset: arrow)
    }

    private static func clampArrow(_ v: CGFloat, length: CGFloat, inset: CGFloat) -> CGFloat {
        guard length > inset * 2 else { return length / 2 }
        return min(max(v, inset), length - inset)
    }

    /// Top-right corner position of a hotspot dot of `size` on `target`.
    public static func hotspotCenter(target: CGRect, size: CGFloat) -> CGPoint {
        CGPoint(x: target.maxX - size / 4, y: target.minY + size / 4)
    }
}
