import Foundation
import ShuttleCore

/// Renders scroller animation transitions between ribbon offsets.
public enum RenderStrategy: Equatable, Sendable {
    /// ScreenCaptureKit live window stream texture rendering.
    case screenCaptureKit
    /// Direct Accessibility frame placement with optional throttling interval.
    case directAX(throttleMs: Double)
    /// Direct AX for settled states, throttled AX for active spring animations.
    case hybrid
}

/// Computes critically damped spring physics and manages scrolling offset transitions.
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

    public init(strategy: RenderStrategy = .hybrid, omega: Double = 26.0) {
        self.strategy = strategy
        self.omega = omega
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

    /// Applies an immediate offset delta (e.g. for trackpad scroll wheel interaction).
    public func scroll(by delta: Double) {
        lock.lock()
        defer { lock.unlock() }
        targetOffset += delta
        isSettled = false
    }

    // MARK: - Interactive Gestures & Inertia

    /// Interactive 1:1 pan (e.g. trackpad two-finger drag or mouse drag).
    public func pan(delta: Double, in strip: Strip, viewportWidth: Double, gap: Double) {
        lock.lock()
        defer { lock.unlock() }

        var newOffset = currentOffset + delta

        // Rubber-band resistance if panning beyond ribbon bounds
        if let bounds = strip.centerOffsetBounds(viewportWidth: viewportWidth, gap: gap) {
            if newOffset < bounds.min {
                let overscroll = bounds.min - newOffset
                newOffset = bounds.min - (overscroll * 0.35)
            } else if newOffset > bounds.max {
                let overscroll = newOffset - bounds.max
                newOffset = bounds.max + (overscroll * 0.35)
            }
        }

        currentOffset = newOffset
        targetOffset = newOffset
        velocity = 0.0
        isSettled = false
    }

    /// Snaps the ribbon to the nearest column center based on current offset.
    @discardableResult
    public func snapToNearest(in strip: inout Strip, viewportWidth: Double, gap: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let nearestIdx = strip.nearestColumnIndex(forRibbonOffset: currentOffset, viewportWidth: viewportWidth, gap: gap) else {
            return false
        }
        strip.focusedColumnIndex = nearestIdx
        if let target = strip.centerOffset(forColumnAt: nearestIdx, viewportWidth: viewportWidth, gap: gap) {
            targetOffset = target
            isSettled = false
            return true
        }
        return false
    }

    /// High-velocity fling with kinetic friction projection.
    public func fling(initialVelocity: Double, in strip: inout Strip, viewportWidth: Double, gap: Double) {
        lock.lock()
        defer { lock.unlock() }

        // Kinetic friction factor (~0.85 decaying over time)
        let projectedTravel = initialVelocity * 0.125
        let projectedOffset = currentOffset + projectedTravel

        if let nearestIdx = strip.nearestColumnIndex(forRibbonOffset: projectedOffset, viewportWidth: viewportWidth, gap: gap),
           let target = strip.centerOffset(forColumnAt: nearestIdx, viewportWidth: viewportWidth, gap: gap) {
            strip.focusedColumnIndex = nearestIdx
            targetOffset = target
            velocity = initialVelocity * 0.5
            isSettled = false
        } else {
            snapToColumn(at: strip.focusedColumnIndex, in: strip, viewportWidth: viewportWidth, gap: gap)
        }
    }

    // MARK: - Keyboard Column Navigation

    /// Animates focus to the column on the left.
    public func focusLeft(in strip: inout Strip, viewportWidth: Double, gap: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard strip.focusLeft() else { return false }
        if let target = strip.centerOffset(forColumnAt: strip.focusedColumnIndex, viewportWidth: viewportWidth, gap: gap) {
            targetOffset = target
            isSettled = false
        }
        return true
    }

    /// Animates focus to the column on the right.
    public func focusRight(in strip: inout Strip, viewportWidth: Double, gap: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard strip.focusRight() else { return false }
        if let target = strip.centerOffset(forColumnAt: strip.focusedColumnIndex, viewportWidth: viewportWidth, gap: gap) {
            targetOffset = target
            isSettled = false
        }
        return true
    }

    /// Animates focus to a specific column index.
    public func focusColumn(at index: Int, in strip: inout Strip, viewportWidth: Double, gap: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard strip.focusColumn(at: index) else { return false }
        if let target = strip.centerOffset(forColumnAt: strip.focusedColumnIndex, viewportWidth: viewportWidth, gap: gap) {
            targetOffset = target
            isSettled = false
        }
        return true
    }

    /// Snaps instantly or smoothly centers a column.
    public func snapToColumn(at index: Int, in strip: Strip, viewportWidth: Double, gap: Double) {
        lock.lock()
        defer { lock.unlock() }

        if let target = strip.centerOffset(forColumnAt: index, viewportWidth: viewportWidth, gap: gap) {
            targetOffset = target
            isSettled = false
        }
    }

    /// Expands focused column and smoothly centers it.
    public func expandFocusedColumn(in strip: inout Strip, by delta: Double = 0.1, viewportWidth: Double, gap: Double) {
        lock.lock()
        defer { lock.unlock() }

        strip.expandFocusedColumn(by: delta, viewportWidth: viewportWidth)
        if let target = strip.centerOffset(forColumnAt: strip.focusedColumnIndex, viewportWidth: viewportWidth, gap: gap) {
            targetOffset = target
            isSettled = false
        }
    }

    /// Shrinks focused column and smoothly centers it.
    public func shrinkFocusedColumn(in strip: inout Strip, by delta: Double = 0.1, viewportWidth: Double, gap: Double) {
        lock.lock()
        defer { lock.unlock() }

        strip.shrinkFocusedColumn(by: delta, viewportWidth: viewportWidth)
        if let target = strip.centerOffset(forColumnAt: strip.focusedColumnIndex, viewportWidth: viewportWidth, gap: gap) {
            targetOffset = target
            isSettled = false
        }
    }

    // MARK: - Simulation Tick

    /// Advances the spring simulation by dt seconds using an analytical critically damped spring solver.
    public func tick(dt: Double) {
        lock.lock()
        defer { lock.unlock() }

        guard !isSettled else { return }

        let displacement = currentOffset - targetOffset
        let c = velocity + omega * displacement
        let expTerm = exp(-omega * dt)

        let newDisplacement = (displacement + c * dt) * expTerm
        let newVelocity = (velocity - c * omega * dt) * expTerm

        currentOffset = targetOffset + newDisplacement
        velocity = newVelocity

        // Settle when within 0.25pt and velocity < 5pt/s
        if abs(newDisplacement) < 0.25 && abs(newVelocity) < 5.0 {
            currentOffset = targetOffset
            velocity = 0.0
            isSettled = true
        }
    }
}
