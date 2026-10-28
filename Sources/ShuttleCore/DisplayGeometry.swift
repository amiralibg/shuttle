import Foundation
import WeftCore

/// A direction between displays.
public enum DisplayDirection: String, Sendable, CaseIterable {
    case left, right, up, down, next, prev
}

/// Display arrangement maths: which display is next to which, and where a
/// hidden column can wait without showing on any of them. Pure, so it is
/// tested without a second monitor.
public enum DisplayGeometry {
    /// The display beside `from` in `direction`, among `displays` (top-left
    /// origin, as CoreGraphics reports them). For left/right/up/down: the
    /// nearest display whose center lies that way, preferring ones that
    /// overlap `from` on the other axis. `next`/`prev` cycle in `displays`'
    /// order. Nil when there is none.
    public static func neighbour(of from: Int, _ direction: DisplayDirection, in displays: [Frame]) -> Int? {
        guard displays.indices.contains(from), displays.count > 1 else { return nil }
        switch direction {
        case .next: return (from + 1) % displays.count
        case .prev: return (from - 1 + displays.count) % displays.count
        default: break
        }
        let a = displays[from]
        let ac = (x: a.x + a.width / 2, y: a.y + a.height / 2)

        var best: (index: Int, score: Double)?
        for (i, b) in displays.enumerated() where i != from {
            let bc = (x: b.x + b.width / 2, y: b.y + b.height / 2)
            let along: Double, across: Double, overlaps: Bool
            switch direction {
            case .left:
                along = ac.x - bc.x; across = abs(ac.y - bc.y)
                overlaps = b.y < a.y + a.height && b.y + b.height > a.y
            case .right:
                along = bc.x - ac.x; across = abs(ac.y - bc.y)
                overlaps = b.y < a.y + a.height && b.y + b.height > a.y
            case .up:
                along = ac.y - bc.y; across = abs(ac.x - bc.x)
                overlaps = b.x < a.x + a.width && b.x + b.width > a.x
            case .down:
                along = bc.y - ac.y; across = abs(ac.x - bc.x)
                overlaps = b.x < a.x + a.width && b.x + b.width > a.x
            case .next, .prev:
                return nil
            }
            guard along > 0 else { continue }
            // An overlapping display always beats one off at an angle.
            let score = along + across * 2 + (overlaps ? 0 : 1_000_000)
            if best == nil || score < best!.score { best = (i, score) }
        }
        return best?.index
    }

    /// Where a window of `size` parks off `display` with 1pt left on it,
    /// without any of it landing on another display. macOS keeps a window's
    /// title bar below the top edge, so only the bottom corners are usable.
    /// Bottom-right is preferred: macOS clamps windows pushed toward negative
    /// x to keep ~40pt on screen, but leaves ones pushed right alone.
    public static func parkingSpot(width: Double, height: Double, on display: Frame, others: [Frame]) -> (x: Double, y: Double) {
        let bottom = display.y + display.height - 1
        let candidates = [
            (x: display.x + display.width - 1, y: bottom),
            (x: display.x - width + 1, y: bottom),
        ]
        for c in candidates {
            let rect = Frame(x: c.x, y: c.y, width: width, height: height)
            if !others.contains(where: { intersects($0, rect) }) { return c }
        }
        return candidates[0]
    }

    public static func intersects(_ a: Frame, _ b: Frame) -> Bool {
        a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height
    }

    /// The display holding most of `frame`, or nil when it touches none.
    public static func display(containing frame: Frame, in displays: [Frame]) -> Int? {
        func area(_ d: Frame) -> Double {
            let w = min(frame.x + frame.width, d.x + d.width) - max(frame.x, d.x)
            let h = min(frame.y + frame.height, d.y + d.height) - max(frame.y, d.y)
            return w > 0 && h > 0 ? w * h : 0
        }
        let scored = displays.enumerated().map { ($0.offset, area($0.element)) }
        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return nil }
        return best.0
    }
}
