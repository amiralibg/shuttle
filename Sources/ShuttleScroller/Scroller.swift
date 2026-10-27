import Foundation
import CoreGraphics
import ShuttleCore
import WeftCore
import WeftPlatform

/// Rendering strategy chosen based on empirical spike benchmarking.
public enum RenderStrategy: Equatable, Sendable {
    /// Direct Accessibility position writes with frame interval pacing.
    case directAX(throttleMs: Double = 16.0)
    /// Atomic WindowServer transaction batching via SkyLight private shims.
    case skyLightBatch
    /// ScreenCaptureKit live proxy streaming into overlay layers (for continuous trackpad ribbons).
    case proxyOverlay
    /// Hybrid pipeline: 0ms direct AX / SkyLight for keyboard steps + warm proxy for gestures.
    case hybrid
}

/// Manages horizontal ribbon scroll position, critically damped spring physics, and focus coordination.
public final class Scroller: @unchecked Sendable {
    public private(set) var targetOffset: Double = 0.0
    public private(set) var currentOffset: Double = 0.0
    public private(set) var velocity: Double = 0.0
    public private(set) var isSettled: Bool = true

    /// Natural frequency of the critically damped spring (higher = crisper snap, lower = looser).
    public var omega: Double = 26.0

    /// Rendering pipeline strategy.
    public var strategy: RenderStrategy = .hybrid

    private let lock = NSLock()

    public init(strategy: RenderStrategy = .hybrid) {
        self.strategy = strategy
    }

    /// Explicitly sets current and target offsets (e.g. initial setup or instant jump).
    public func setOffset(_ offset: Double) {
        lock.lock()
        defer { lock.unlock() }
        currentOffset = offset
        targetOffset = offset
        velocity = 0.0
        isSettled = true
    }

    /// Continuous scroll offset increment (e.g. from trackpad or mouse wheel event).
    public func scroll(by delta: Double) {
        lock.lock()
        defer { lock.unlock() }
        targetOffset += delta
        isSettled = false
    }

    /// Interactive 1:1 pan (e.g. trackpad two-finger drag or mouse ribbon drag).
    public func pan(delta: Double, in strip: Strip, viewportWidth: Double, gap: Double) {
        lock.lock()
        defer { lock.unlock() }

        var effectiveDelta = delta
        // Apply rubber-band resistance when pulling beyond bounds
        if let bounds = strip.centerOffsetBounds(viewportWidth: viewportWidth, gap: gap) {
            if currentOffset < bounds.min && delta < 0 {
                let overscroll = bounds.min - currentOffset
                let dampening = max(0.1, 1.0 / (1.0 + overscroll * 0.005))
                effectiveDelta *= dampening
            } else if currentOffset > bounds.max && delta > 0 {
                let overscroll = currentOffset - bounds.max
                let dampening = max(0.1, 1.0 / (1.0 + overscroll * 0.005))
                effectiveDelta *= dampening
            }
        }

        currentOffset += effectiveDelta
        targetOffset = currentOffset
        velocity = 0.0
        isSettled = false
    }

    /// Snaps ribbon to center the column closest to current viewport position.
    @discardableResult
    public func snapToNearest(in strip: inout Strip, viewportWidth: Double, gap: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let nearest = strip.nearestColumnIndex(forRibbonOffset: currentOffset, viewportWidth: viewportWidth, gap: gap) else {
            return false
        }

        _ = strip.focusColumn(at: nearest)
        if let center = strip.centerOffset(forColumnAt: nearest, viewportWidth: viewportWidth, gap: gap) {
            targetOffset = center
            isSettled = false
            return true
        }
        return false
    }

    /// Applies inertial fling from gesture velocity, projecting rest position and snapping to the nearest column.
    public func fling(initialVelocity: Double, in strip: inout Strip, viewportWidth: Double, gap: Double) {
        lock.lock()
        defer { lock.unlock() }

        velocity = initialVelocity
        // Project stopping position assuming exponential friction deceleration
        let friction = 8.0
        let projectedOffset = currentOffset + (initialVelocity / friction)

        if let targetIdx = strip.nearestColumnIndex(forRibbonOffset: projectedOffset, viewportWidth: viewportWidth, gap: gap),
           let center = strip.centerOffset(forColumnAt: targetIdx, viewportWidth: viewportWidth, gap: gap) {
            _ = strip.focusColumn(at: targetIdx)
            targetOffset = center
            isSettled = false
        }
    }

    /// Snaps viewport target offset to center the column at `index`.
    public func snapToColumn(at index: Int, in strip: Strip, viewportWidth: Double, gap: Double) {
        lock.lock()
        defer { lock.unlock() }
        if let center = strip.centerOffset(forColumnAt: index, viewportWidth: viewportWidth, gap: gap) {
            targetOffset = center
            isSettled = false
        }
    }

    // MARK: - Keyboard Navigation Commands

    /// Navigates focus to the column on the left and animates viewport to center it.
    @discardableResult
    public func focusLeft(in strip: inout Strip, viewportWidth: Double, gap: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard strip.focusLeft() else { return false }
        if let center = strip.centerOffset(forColumnAt: strip.focusedColumnIndex, viewportWidth: viewportWidth, gap: gap) {
            targetOffset = center
            isSettled = false
        }
        return true
    }

    /// Navigates focus to the column on the right and animates viewport to center it.
    @discardableResult
    public func focusRight(in strip: inout Strip, viewportWidth: Double, gap: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard strip.focusRight() else { return false }
        if let center = strip.centerOffset(forColumnAt: strip.focusedColumnIndex, viewportWidth: viewportWidth, gap: gap) {
            targetOffset = center
            isSettled = false
        }
        return true
    }

    /// Focuses arbitrary column and animates viewport.
    @discardableResult
    public func focusColumn(at index: Int, in strip: inout Strip, viewportWidth: Double, gap: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard strip.focusColumn(at: index) else { return false }
        if let center = strip.centerOffset(forColumnAt: strip.focusedColumnIndex, viewportWidth: viewportWidth, gap: gap) {
            targetOffset = center
            isSettled = false
        }
        return true
    }

    /// Expands focused column width and recenters viewport.
    public func expandFocusedColumn(in strip: inout Strip, by delta: Double = 0.1, viewportWidth: Double, gap: Double) {
        lock.lock()
        defer { lock.unlock() }
        strip.expandFocusedColumn(by: delta, viewportWidth: viewportWidth)
        if let center = strip.centerOffset(forColumnAt: strip.focusedColumnIndex, viewportWidth: viewportWidth, gap: gap) {
            targetOffset = center
            isSettled = false
        }
    }

    /// Shrinks focused column width and recenters viewport.
    public func shrinkFocusedColumn(in strip: inout Strip, by delta: Double = 0.1, viewportWidth: Double, gap: Double) {
        lock.lock()
        defer { lock.unlock() }
        strip.shrinkFocusedColumn(by: delta, viewportWidth: viewportWidth)
        if let center = strip.centerOffset(forColumnAt: strip.focusedColumnIndex, viewportWidth: viewportWidth, gap: gap) {
            targetOffset = center
            isSettled = false
        }
    }

    // MARK: - Physics Simulation Step

    /// Advances the critically damped spring towards `targetOffset` by `dt` seconds.
    public func tick(dt: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard !isSettled else { return }

        let clampedDt = min(max(dt, 0.0), 0.05) // clamp max timestep to 50ms
        let w = omega
        let e = exp(-w * clampedDt)

        let x0 = currentOffset - targetOffset
        let c = velocity + w * x0

        let nextOffset = targetOffset + (x0 + c * clampedDt) * e
        let nextVelocity = (velocity - w * c * clampedDt) * e

        if abs(nextOffset - targetOffset) < 0.5 && abs(nextVelocity) < 2.0 {
            currentOffset = targetOffset
            velocity = 0.0
            isSettled = true
        } else {
            currentOffset = nextOffset
            velocity = nextVelocity
        }
    }
}
