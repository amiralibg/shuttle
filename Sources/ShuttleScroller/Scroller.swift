import Foundation
import ShuttleCore
import WeftCore
import WeftPlatform

/// Manages the horizontal scroll position and spring physics for a strip.
public final class Scroller: @unchecked Sendable {
    public private(set) var targetOffset: Double = 0.0
    public private(set) var currentOffset: Double = 0.0
    public var friction: Double = 0.85
    public var springTension: Double = 220.0

    public init() {}

    /// Scroll by a delta (e.g. from trackpad or mouse wheel).
    public func scroll(by delta: Double) {
        targetOffset += delta
    }

    /// Snap viewport to center the focused column.
    public func centerColumn(at index: Int, in strip: Strip, viewportWidth: Double, gap: Double) {
        let offsets = strip.columnOffsets(viewportWidth: viewportWidth, gap: gap)
        guard index >= 0 && index < offsets.count else { return }
        let colWidth = strip.columns[index].width.resolve(viewportWidth: viewportWidth)
        let colCenter = offsets[index] + (colWidth / 2.0)
        targetOffset = colCenter - (viewportWidth / 2.0)
    }

    /// Advances spring physics by delta time.
    public func tick(dt: Double) {
        let diff = targetOffset - currentOffset
        if abs(diff) < 0.5 {
            currentOffset = targetOffset
        } else {
            currentOffset += diff * min(1.0, dt * 15.0)
        }
    }
}
