import AppKit
import QuartzCore

/// Drives the spring at the display's refresh rate (120 Hz on ProMotion) and
/// only while something is moving. The old fixed 8 ms timer woke the CPU 120
/// times a second for the daemon's whole life, settled or not.
@MainActor
final class Animator: NSObject {
    /// Advances one frame by `dt` seconds; returns false once settled.
    var onFrame: ((Double) -> Bool)?

    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?

    func start() {
        if link == nil { makeLink() }
        guard let link, link.isPaused else { return }
        lastTimestamp = nil
        link.isPaused = false
    }

    /// Rebuilds the link against the current main screen (display changes).
    func screenChanged() {
        let running = link.map { !$0.isPaused } ?? false
        link?.invalidate()
        link = nil
        if running { start() }
    }

    private func makeLink() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let l = screen.displayLink(target: self, selector: #selector(step(_:)))
        l.isPaused = true
        // Common modes: keep animating while a menu is being tracked.
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = lastTimestamp.map { min(now - $0, 1.0 / 30.0) } ?? (link.targetTimestamp - link.timestamp)
        lastTimestamp = now
        let moving = onFrame?(max(dt, 0.001)) ?? false
        if !moving {
            link.isPaused = true
        }
    }
}
