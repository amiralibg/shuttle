import Foundation
import CoreGraphics
import QuartzCore
import ApplicationServices
import AppKit
import ShuttleCore
import WeftCore
import WeftPlatform

/// Coordinates committing layout-calculated window positions to macOS windows.
public final class WindowCoordinator: @unchecked Sendable {
    public let scroller: Scroller
    public var gap: Double = 16.0
    public var lastCommitTime: Double = 0.0

    private var axElements: [UInt32: AXUIElement] = [:]
    private var lastKnownFrames: [UInt32: Frame] = [:]
    private let lock = NSLock()

    public init(scroller: Scroller, gap: Double = 16.0) {
        self.scroller = scroller
        self.gap = gap
    }

    /// Registers an AXUIElement handle for a managed window.
    public func register(windowID: UInt32, element: AXUIElement) {
        lock.lock()
        defer { lock.unlock() }
        AXUIElementSetMessagingTimeout(element, 0.1) // 100ms max timeout to prevent hang
        axElements[windowID] = element
    }

    /// Unregisters a window.
    public func unregister(windowID: UInt32) {
        lock.lock()
        defer { lock.unlock() }
        axElements.removeValue(forKey: windowID)
        lastKnownFrames.removeValue(forKey: windowID)
    }

    /// Brings the specified window to front and sets AX focus.
    public func raiseAndFocus(windowID: UInt32) {
        lock.lock()
        let element = axElements[windowID]
        lock.unlock()

        guard let el = element else { return }
        _ = AXUIElementPerformAction(el, kAXRaiseAction as CFString)
        _ = AXUIElementSetAttributeValue(el, kAXMainAttribute as CFString, kCFBooleanTrue)

        if let pid = WorldReader.pid(of: windowID) {
            DispatchQueue.main.async {
                NSRunningApplication(processIdentifier: pid)?.activate()
            }
        }
    }

    /// Commits current ribbon layout to screen windows using the configured RenderStrategy.
    @discardableResult
    public func update(strip: Strip, viewport: Frame, force: Bool = false) -> Int {
        lock.lock()
        defer { lock.unlock() }

        let now = CACurrentMediaTime()
        let throttleMs: Double
        switch scroller.strategy {
        case .directAX(let ms):
            throttleMs = ms
        case .hybrid:
            // 0ms delay for settled states or discrete steps; 16ms throttling during active spring animation
            throttleMs = scroller.isSettled ? 0.0 : 16.0
        default:
            throttleMs = 16.0
        }

        if !force && (now - lastCommitTime) * 1000.0 < throttleMs {
            return 0
        }
        lastCommitTime = now

        let targetFrames = strip.calculateWindowFrames(
            viewport: viewport,
            ribbonOffset: scroller.currentOffset,
            gap: gap
        )

        var movedCount = 0
        for (winID, targetFrame) in targetFrames {
            guard let element = axElements[winID] else { continue }
            let prior = lastKnownFrames[winID]

            // Only issue AX calls if frame noticeably changed (epsilon > 0.5pt)
            let posDiff = prior == nil ? 999.0 : (abs(prior!.x - targetFrame.x) + abs(prior!.y - targetFrame.y))
            let sizeDiff = prior == nil ? 999.0 : (abs(prior!.width - targetFrame.width) + abs(prior!.height - targetFrame.height))

            if posDiff > 0.5 {
                var pt = CGPoint(x: targetFrame.x, y: targetFrame.y)
                if let val = AXValueCreate(.cgPoint, &pt) {
                    _ = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, val)
                }
            }

            if sizeDiff > 0.5 {
                var sz = CGSize(width: targetFrame.width, height: targetFrame.height)
                if let val = AXValueCreate(.cgSize, &sz) {
                    _ = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, val)
                }
            }

            if posDiff > 0.5 || sizeDiff > 0.5 {
                lastKnownFrames[winID] = targetFrame
                movedCount += 1
            }
        }

        return movedCount
    }
}
