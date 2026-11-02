import Foundation
import CoreGraphics
@preconcurrency import ApplicationServices
import AppKit
import ShuttleCore
import WeftCore
import WeftPlatform

/// Commits layout frames to real windows.
///
/// Decisions are made on the main thread; the Accessibility writes are not.
/// Each app gets a serial queue, and each window holds at most one pending
/// frame that a newer one replaces: a slow app (Firefox-based browsers answer
/// AX in tens of milliseconds) receives fewer, newer frames and never stalls
/// the animation or the other apps. Final frames are read back, written again
/// once if the app did not take them, and reported if it still did not.
public final class WindowCoordinator: @unchecked Sendable {
    public var gap: Double = 16.0

    /// Where one strip is drawn: its tiling area and the display around it.
    public struct Placement: Sendable {
        /// The display's usable area (menu bar and Dock excluded).
        public var viewport: Frame
        /// The display's full bounds, for parking.
        public var display: Frame
        /// Every other display's bounds: parked windows must not land on them.
        public var otherDisplays: [Frame]

        public init(viewport: Frame, display: Frame, otherDisplays: [Frame]) {
            self.viewport = viewport
            self.display = display
            self.otherDisplays = otherDisplays
        }
    }

    /// An app ended up with a frame other than the one asked for, after a
    /// retry. Called on the main queue.
    public var onWriteRefused: ((UInt32, _ requested: Frame, _ actual: Frame) -> Void)?

    private struct Managed {
        let element: AXUIElement
        let pid: Int32
    }

    private struct Job {
        var element: AXUIElement
        var frame: Frame
        var writeSize: Bool
        var writePosition: Bool
        var verify: Bool
    }

    // Main thread only.
    private var managed: [UInt32: Managed] = [:]
    private var requested: [UInt32: Frame] = [:]
    private var queues: [Int32: DispatchQueue] = [:]

    // Shared with the app queues.
    private let lock = NSLock()
    private var pending: [UInt32: Job] = [:]
    private var draining: Set<UInt32> = []

    public init(gap: Double = 16.0) {
        self.gap = gap
    }

    // MARK: - Registry

    public func register(windowID: UInt32, pid: Int32, element: AXUIElement) {
        AXUIElementSetMessagingTimeout(element, 0.25)
        managed[windowID] = Managed(element: element, pid: pid)
    }

    public func unregister(windowID: UInt32) {
        managed.removeValue(forKey: windowID)
        requested.removeValue(forKey: windowID)
        lock.withLock { _ = pending.removeValue(forKey: windowID) }
    }

    public func isRegistered(_ windowID: UInt32) -> Bool { managed[windowID] != nil }
    public func pid(of windowID: UInt32) -> Int32? { managed[windowID]?.pid }
    public func element(of windowID: UInt32) -> AXUIElement? { managed[windowID]?.element }

    public func windows(ownedBy pid: Int32) -> [UInt32] {
        managed.filter { $0.value.pid == pid }.map(\.key)
    }

    /// Whether a frame for `wid` is still queued or being written. A move
    /// seen meanwhile may be the app catching up, not the user.
    public func isWriting(_ windowID: UInt32) -> Bool {
        lock.withLock { pending[windowID] != nil || draining.contains(windowID) }
    }

    /// The frame last asked for, parked or not.
    public func requestedFrame(of windowID: UInt32) -> Frame? { requested[windowID] }

    /// Forgets the frame last written, so the next update writes it again.
    public func invalidate(windowID: UInt32) {
        requested.removeValue(forKey: windowID)
    }

    /// The area columns are laid out in: the usable area less the outer gap.
    public func layoutArea(for viewport: Frame) -> Frame {
        Frame(
            x: viewport.x + gap, y: viewport.y + gap,
            width: max(200, viewport.width - 2 * gap), height: max(200, viewport.height - 2 * gap)
        )
    }

    // MARK: - Layout

    /// Writes `strip` scrolled to `offset` into `placement`. `settled` marks
    /// a frame the ribbon will rest at, which is checked once it lands.
    @discardableResult
    public func update(strip: Strip, offset: Double, placement: Placement, settled: Bool) -> Int {
        let viewport = placement.viewport
        let targetFrames = strip.calculateWindowFrames(
            viewport: layoutArea(for: viewport), ribbonOffset: offset, gap: gap
        )

        var count = 0
        for (winID, layoutFrame) in targetFrames {
            guard let entry = managed[winID] else { continue }
            let prior = requested[winID]

            // A column with no pixel on its display waits at a corner, at
            // whatever size it already has.
            var target = layoutFrame
            let offDisplay = layoutFrame.x + layoutFrame.width <= viewport.x
                || layoutFrame.x >= viewport.x + viewport.width
            if offDisplay {
                let w = prior?.width ?? layoutFrame.width, h = prior?.height ?? layoutFrame.height
                let spot = DisplayGeometry.parkingSpot(width: w, height: h, on: placement.display, others: placement.otherDisplays)
                target = Frame(x: spot.x, y: spot.y, width: w, height: h)
            }

            let posDiff = prior.map { abs($0.x - target.x) + abs($0.y - target.y) } ?? .infinity
            let sizeDiff = prior.map { abs($0.width - target.width) + abs($0.height - target.height) } ?? .infinity
            guard posDiff > 0.5 || sizeDiff > 0.5 else { continue }

            requested[winID] = target
            enqueue(winID, pid: entry.pid, Job(
                element: entry.element, frame: target,
                writeSize: sizeDiff > 0.5, writePosition: posDiff > 0.5,
                verify: settled && !offDisplay
            ))
            count += 1
        }
        return count
    }

    /// Brings a window forward and gives it the keyboard, after any frame
    /// still queued for its app.
    public func raiseAndFocus(windowID: UInt32) {
        guard let entry = managed[windowID] else { return }
        raiseAndFocus(entry.element, pid: entry.pid)
    }

    /// The same for a window Shuttle does not lay out.
    public func raiseAndFocus(_ element: AXUIElement, pid: Int32) {
        queue(for: pid).async {
            _ = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            _ = AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
            DispatchQueue.main.async {
                NSRunningApplication(processIdentifier: pid)?.activate()
            }
        }
    }

    /// One frame for a window Shuttle does not lay out (one just floated).
    public func place(_ element: AXUIElement, pid: Int32, frame: Frame) {
        queue(for: pid).async {
            Self.write(element, frame, size: true, position: true)
        }
    }

    /// Puts every managed window back on the display it belongs to, for
    /// shutdown, and waits for the writes. Parked windows would otherwise
    /// stay where nobody can reach them. Windows on other desktops take the
    /// write too, from the element captured while they were visible.
    public func releaseAll(into displays: [(visible: Frame, bounds: Frame)]) {
        lock.withLock { pending.removeAll() }
        let group = DispatchGroup()
        for (winID, entry) in managed {
            guard let f = requested[winID] else { continue }
            let idx = DisplayGeometry.display(containing: f, in: displays.map(\.bounds)) ?? 0
            guard displays.indices.contains(idx) else { continue }
            let vp = displays[idx].visible
            let w = min(f.width, vp.width), h = min(f.height, vp.height)
            let placed = Frame(
                x: min(max(f.x, vp.x), vp.x + vp.width - w),
                y: min(max(f.y, vp.y), vp.y + vp.height - h),
                width: w, height: h
            )
            guard placed != f else { continue }
            let element = entry.element
            queue(for: entry.pid).async(group: group) {
                Self.write(element, placed, size: true, position: true)
            }
        }
        _ = group.wait(timeout: .now() + 2)
        requested.removeAll()
    }

    // MARK: - Writing

    private func queue(for pid: Int32) -> DispatchQueue {
        if let q = queues[pid] { return q }
        let q = DispatchQueue(label: "shuttle.ax.\(pid)", qos: .userInteractive)
        queues[pid] = q
        return q
    }

    private func enqueue(_ wid: UInt32, pid: Int32, _ job: Job) {
        let start: Bool = lock.withLock {
            if let old = pending[wid] {
                // The newer frame wins, but a size change it replaces still has to happen.
                var merged = job
                merged.writeSize = job.writeSize || old.writeSize
                merged.writePosition = job.writePosition || old.writePosition
                pending[wid] = merged
            } else {
                pending[wid] = job
            }
            return draining.insert(wid).inserted
        }
        if start {
            queue(for: pid).async { [weak self] in self?.drain(wid) }
        }
    }

    /// Runs on the app's queue until no frame is waiting for `wid`.
    private func drain(_ wid: UInt32) {
        while true {
            let job: Job? = lock.withLock {
                let next = pending.removeValue(forKey: wid)
                if next == nil { draining.remove(wid) }
                return next
            }
            guard let job else { return }
            Self.write(job.element, job.frame, size: job.writeSize, position: job.writePosition)
            if job.verify { verify(wid, job) }
        }
    }

    /// Reads the frame back; one more full write if it is off, then reports.
    private func verify(_ wid: UInt32, _ job: Job) {
        guard var actual = Self.read(job.element) else { return }
        if Self.matches(actual, job.frame) { return }
        // A newer frame is already waiting; it will be judged instead.
        if lock.withLock({ pending[wid] != nil }) { return }
        Self.write(job.element, job.frame, size: true, position: true)
        guard let again = Self.read(job.element) else { return }
        actual = again
        if Self.matches(actual, job.frame) { return }
        let requested = job.frame
        DispatchQueue.main.async { [weak self] in
            self?.onWriteRefused?(wid, requested, actual)
        }
    }

    /// Within 2pt: apps that size in whole character cells (terminals) land a
    /// little short, and that is the app's answer, not a failure.
    private static func matches(_ a: Frame, _ b: Frame) -> Bool {
        abs(a.x - b.x) <= 2 && abs(a.y - b.y) <= 2 && abs(a.width - b.width) <= 24 && abs(a.height - b.height) <= 24
    }

    private static func write(_ element: AXUIElement, _ frame: Frame, size: Bool, position: Bool) {
        if size { setSize(element, frame) }
        if position { setPosition(element, frame) }
        // macOS clamps a window growing toward a screen edge before it moves;
        // the second size write lands once it has.
        if size && position { setSize(element, frame) }
    }

    private static func read(_ element: AXUIElement) -> Frame? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef,
              CFGetTypeID(posRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pt)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &sz)
        return Frame(x: pt.x, y: pt.y, width: sz.width, height: sz.height)
    }

    private static func setPosition(_ element: AXUIElement, _ frame: Frame) {
        var pt = CGPoint(x: frame.x, y: frame.y)
        if let val = AXValueCreate(.cgPoint, &pt) {
            _ = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, val)
        }
    }

    private static func setSize(_ element: AXUIElement, _ frame: Frame) {
        var sz = CGSize(width: frame.width, height: frame.height)
        if let val = AXValueCreate(.cgSize, &sz) {
            _ = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, val)
        }
    }
}
