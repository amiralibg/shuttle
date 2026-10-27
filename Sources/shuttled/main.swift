import AppKit
import ApplicationServices
import Foundation
import ShuttleCore
import ShuttleScroller
import WeftCore
import WeftPlatform
import WeftInput
import WeftIPC

// Initialize AppKit connection
_ = NSApplication.shared

// MARK: - Daemon Controller

final class DaemonController: @unchecked Sendable {
    private let lock = NSLock()
    private var strips: [SpaceID: Strip] = [:]
    private var activeSpaceID: SpaceID
    private let scroller: Scroller
    private let coordinator: WindowCoordinator
    private var viewport: Frame

    init(initialStrip: Strip, initialSpaceID: SpaceID, scroller: Scroller, coordinator: WindowCoordinator, viewport: Frame) {
        self.strips[initialSpaceID] = initialStrip
        self.activeSpaceID = initialSpaceID
        self.scroller = scroller
        self.coordinator = coordinator
        self.viewport = viewport
    }

    private var currentStrip: Strip {
        get { strips[activeSpaceID] ?? Strip() }
        set { strips[activeSpaceID] = newValue }
    }

    func tick(dt: Double) {
        lock.lock()
        defer { lock.unlock() }
        if !scroller.isSettled {
            scroller.tick(dt: dt)
            let strip = currentStrip
            _ = coordinator.update(strip: strip, viewport: viewport)
        }
    }

    // MARK: - Interactive Mouse Gesture Tracking

    private var isDraggingRibbon = false
    private var lastDragLoc = CGPoint.zero
    private var lastDragTime = 0.0
    private var dragVelocity = 0.0

    func handleMouseGesture(_ gesture: MouseGesture) {
        lock.lock()
        defer { lock.unlock() }

        let now = CACurrentMediaTime()
        switch gesture {
        case .down(let button, let loc):
            guard button == .left else { return }
            isDraggingRibbon = true
            lastDragLoc = loc
            lastDragTime = now
            dragVelocity = 0.0

        case .drag(let button, let loc):
            guard button == .left && isDraggingRibbon else { return }
            let dt = max(0.001, now - lastDragTime)
            let dx = Double(loc.x - lastDragLoc.x)
            let instantVel = dx / dt
            dragVelocity = dragVelocity * 0.6 + instantVel * 0.4
            lastDragLoc = loc
            lastDragTime = now

            // Dragging right moves ribbon left (revealing left columns); invert dx for natural 1:1 paper feel
            scroller.pan(delta: -dx, in: currentStrip, viewportWidth: viewport.width, gap: coordinator.gap)
            _ = coordinator.update(strip: currentStrip, viewport: viewport)

        case .up(let button, _):
            guard button == .left && isDraggingRibbon else { return }
            isDraggingRibbon = false
            var strip = currentStrip
            if abs(dragVelocity) > 350.0 {
                // Natural flick with kinetic friction
                scroller.fling(initialVelocity: -dragVelocity, in: &strip, viewportWidth: viewport.width, gap: coordinator.gap)
            } else {
                scroller.snapToNearest(in: &strip, viewportWidth: viewport.width, gap: coordinator.gap)
            }
            currentStrip = strip
            _ = coordinator.update(strip: currentStrip, viewport: viewport, force: true)
        }
    }

    // MARK: - Space Management

    func allSpaceIDs() -> [SpaceID] {
        let displays = WorldReader.displaysOnly()
        return displays.flatMap(\.spaces)
    }

    func resolveSpaceID(index: Int) -> SpaceID? {
        let spaces = allSpaceIDs()
        guard index >= 1 && index <= spaces.count else { return nil }
        return spaces[index - 1]
    }

    func switchSpace(toIndex index: Int) -> String {
        guard let targetSid = resolveSpaceID(index: index) else {
            return "ERR: Space \(index) does not exist"
        }
        if targetSid == activeSpaceID {
            return "OK: Already on space \(index)"
        }
        let switched = DockSwipe.focusSpace(targetSid)
        if switched {
            handleSpaceActivated(targetSid)
            return "OK: Switched to space \(index)"
        } else {
            return "ERR: Failed to switch to space \(index)"
        }
    }

    func moveFocusedWindow(toSpaceIndex index: Int) -> String {
        lock.lock()
        defer { lock.unlock() }

        guard let targetSid = resolveSpaceID(index: index) else {
            return "ERR: Space \(index) does not exist"
        }
        guard let wid = currentStrip.focusedWindowId else {
            return "ERR: No window focused"
        }
        if targetSid == activeSpaceID {
            return "OK: Window is already on space \(index)"
        }

        let moved = NativeBridge.move([wid], to: targetSid)
        guard moved.verdict.complete else {
            return "ERR: NativeBridge failed to move window \(wid) to space \(index)"
        }

        // Remove from current space strip
        var cur = currentStrip
        cur.removeWindow(wid)
        coordinator.unregister(windowID: wid)
        scroller.snapToNearest(in: &cur, viewportWidth: viewport.width, gap: coordinator.gap)
        currentStrip = cur

        // Add to target space strip
        var targetStrip = strips[targetSid] ?? Strip()
        targetStrip.insertWindow(wid, asNewColumn: true)
        strips[targetSid] = targetStrip

        _ = coordinator.update(strip: currentStrip, viewport: viewport, force: true)
        return "OK: Moved window \(wid) to space \(index)"
    }

    func handleSpaceActivated(_ sid: SpaceID) {
        lock.lock()
        defer { lock.unlock() }

        guard sid != activeSpaceID else { return }
        print("🌌 Switched active space to sid=\(sid)")
        activeSpaceID = sid
        if strips[sid] == nil {
            strips[sid] = Strip()
        }
        let strip = currentStrip
        scroller.snapToColumn(at: strip.focusedColumnIndex, in: strip, viewportWidth: viewport.width, gap: coordinator.gap)
        _ = coordinator.update(strip: strip, viewport: viewport, force: true)
    }

    // MARK: - Dynamic Lifecycle Handlers

    func handleWindowCreated(pid: Int32, wid: WindowID?) {
        lock.lock()
        defer { lock.unlock() }

        var targetWid = wid
        var targetElement: AXUIElement?

        let appElement = AXUIElementCreateApplication(pid)
        if targetWid == nil {
            var focusedRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
               let win = focusedRef as! AXUIElement? {
                targetWid = PublicPaths.windowID(of: win)
                targetElement = win
            }
        } else {
            var winRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &winRef) == .success,
               let axWins = winRef as? [AXUIElement] {
                for win in axWins {
                    if PublicPaths.windowID(of: win) == targetWid {
                        targetElement = win
                        break
                    }
                }
            }
        }

        guard let validWid = targetWid, let element = targetElement else { return }

        // Check if window is already tracked in active strip
        var strip = currentStrip
        if strip.column(forWindowID: validWid) != nil { return }

        // Filter valid normal windows
        var sizeRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef)
        var size = CGSize.zero
        if let s = sizeRef as! AXValue? { AXValueGetValue(s, .cgSize, &size) }
        guard size.width >= 200 && size.height >= 200 && size.width < 3500 else { return }

        print("🪟 New window created: wid=\(validWid) pid=\(pid)")
        strip.insertWindow(validWid, asNewColumn: true)
        currentStrip = strip
        coordinator.register(windowID: validWid, element: element)
        scroller.snapToColumn(at: strip.focusedColumnIndex, in: strip, viewportWidth: viewport.width, gap: coordinator.gap)
        _ = coordinator.update(strip: strip, viewport: viewport, force: true)
    }

    func handleWindowDestroyed(wid: WindowID) {
        lock.lock()
        defer { lock.unlock() }

        var strip = currentStrip
        guard strip.column(forWindowID: wid) != nil else { return }
        print("🗑️  Window destroyed: wid=\(wid)")
        _ = strip.removeWindow(wid)
        coordinator.unregister(windowID: wid)
        _ = scroller.snapToNearest(in: &strip, viewportWidth: viewport.width, gap: coordinator.gap)
        currentStrip = strip
        _ = coordinator.update(strip: strip, viewport: viewport, force: true)
    }

    func handleWindowFocused(wid: WindowID?) {
        lock.lock()
        defer { lock.unlock() }

        var strip = currentStrip
        guard let wid = wid, let (colIdx, _) = strip.column(forWindowID: wid) else { return }
        if strip.focusedColumnIndex != colIdx || strip.focusedWindowId != wid {
            print("🎯 Focus changed to window wid=\(wid) (column \(colIdx))")
            strip.focusedWindowId = wid
            _ = scroller.focusColumn(at: colIdx, in: &strip, viewportWidth: viewport.width, gap: coordinator.gap)
            currentStrip = strip
            _ = coordinator.update(strip: strip, viewport: viewport, force: true)
        }
    }

    func handleAppActivated(pid: Int32) {
        lock.lock()
        defer { lock.unlock() }

        var strip = currentStrip
        let appElement = AXUIElementCreateApplication(pid)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
              let win = focusedRef as! AXUIElement?,
              let wid = PublicPaths.windowID(of: win),
              let (colIdx, _) = strip.column(forWindowID: wid) else { return }

        if strip.focusedColumnIndex != colIdx || strip.focusedWindowId != wid {
            print("📱 App activated (pid=\(pid)), centering column \(colIdx)")
            strip.focusedWindowId = wid
            _ = scroller.focusColumn(at: colIdx, in: &strip, viewportWidth: viewport.width, gap: coordinator.gap)
            currentStrip = strip
            _ = coordinator.update(strip: strip, viewport: viewport, force: true)
        }
    }

    func handleDisplayChanged() {
        lock.lock()
        defer { lock.unlock() }

        let displays = SpaceControl.displayLayout()
        if let newVp = displays.first?.visible {
            viewport = newVp
            print("🖥️  Viewport updated: \(String(format: "%.0fx%.0f", viewport.width, viewport.height))")
            let strip = currentStrip
            scroller.snapToColumn(at: strip.focusedColumnIndex, in: strip, viewportWidth: viewport.width, gap: coordinator.gap)
            _ = coordinator.update(strip: strip, viewport: viewport, force: true)
        }
    }

    // MARK: - Command Dispatcher

    func handleCommand(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ").map(String.init)
        let verb = parts.first ?? ""

        switch verb {
        case "space":
            guard parts.count >= 3 else { return "ERR: Usage: space focus <1..9> or space move-window <1..9>" }
            let action = parts[1]
            guard let n = Int(parts[2]) else { return "ERR: Invalid space number '\(parts[2])'" }
            if action == "focus" {
                return switchSpace(toIndex: n)
            } else if action == "move-window" || action == "move" {
                return moveFocusedWindow(toSpaceIndex: n)
            }
            return "ERR: Unknown space action '\(action)'"

        case "window":
            lock.lock()
            defer { lock.unlock() }
            var strip = currentStrip
            let sub = parts.dropFirst().joined(separator: " ")
            if sub == "focus-up" || sub == "up" || sub == "north" {
                let ok = strip.focusUp()
                if ok {
                    currentStrip = strip
                    if let wid = strip.focusedWindowId { coordinator.raiseAndFocus(windowID: wid) }
                }
                return ok ? "OK: Focused window \(strip.focusedWindowId ?? 0)" : "ERR: Already at top of column"
            } else if sub == "focus-down" || sub == "down" || sub == "south" {
                let ok = strip.focusDown()
                if ok {
                    currentStrip = strip
                    if let wid = strip.focusedWindowId { coordinator.raiseAndFocus(windowID: wid) }
                }
                return ok ? "OK: Focused window \(strip.focusedWindowId ?? 0)" : "ERR: Already at bottom of column"
            } else if sub == "move-up" {
                let ok = strip.moveFocusedWindowUp()
                if ok {
                    currentStrip = strip
                    _ = coordinator.update(strip: strip, viewport: viewport, force: true)
                }
                return ok ? "OK: Moved window up" : "ERR: Cannot move top window up"
            } else if sub == "move-down" {
                let ok = strip.moveFocusedWindowDown()
                if ok {
                    currentStrip = strip
                    _ = coordinator.update(strip: strip, viewport: viewport, force: true)
                }
                return ok ? "OK: Moved window down" : "ERR: Cannot move bottom window down"
            } else if sub == "split" {
                let ok = strip.splitFocusedWindowIntoNewColumn()
                if ok {
                    scroller.snapToColumn(at: strip.focusedColumnIndex, in: strip, viewportWidth: viewport.width, gap: coordinator.gap)
                    currentStrip = strip
                    _ = coordinator.update(strip: strip, viewport: viewport, force: true)
                }
                return ok ? "OK: Split window into new column" : "ERR: Column only has one window"
            }
            return "ERR: Unknown window subcommand '\(sub)'"

        case "column", "focus":
            lock.lock()
            defer { lock.unlock() }
            var strip = currentStrip
            let sub = parts.dropFirst().joined(separator: " ")
            if sub == "focus-left" || sub == "left" || sub == "west" {
                let ok = scroller.focusLeft(in: &strip, viewportWidth: viewport.width, gap: coordinator.gap)
                currentStrip = strip
                if ok {
                    _ = coordinator.update(strip: strip, viewport: viewport, force: true)
                    if let wid = strip.focusedWindowId { coordinator.raiseAndFocus(windowID: wid) }
                }
                return ok ? "OK: Focused column \(strip.focusedColumnIndex)" : "ERR: Already at leftmost column"
            } else if sub == "focus-right" || sub == "right" || sub == "east" {
                let ok = scroller.focusRight(in: &strip, viewportWidth: viewport.width, gap: coordinator.gap)
                currentStrip = strip
                if ok {
                    _ = coordinator.update(strip: strip, viewport: viewport, force: true)
                    if let wid = strip.focusedWindowId { coordinator.raiseAndFocus(windowID: wid) }
                }
                return ok ? "OK: Focused column \(strip.focusedColumnIndex)" : "ERR: Already at rightmost column"
            } else if sub == "move-left" || sub == "move west" {
                let ok = strip.moveFocusedColumnLeft()
                currentStrip = strip
                if ok {
                    scroller.snapToColumn(at: strip.focusedColumnIndex, in: strip, viewportWidth: viewport.width, gap: coordinator.gap)
                    _ = coordinator.update(strip: strip, viewport: viewport, force: true)
                }
                return ok ? "OK: Moved column left to \(strip.focusedColumnIndex)" : "ERR: Cannot move leftmost column"
            } else if sub == "move-right" || sub == "move east" {
                let ok = strip.moveFocusedColumnRight()
                currentStrip = strip
                if ok {
                    scroller.snapToColumn(at: strip.focusedColumnIndex, in: strip, viewportWidth: viewport.width, gap: coordinator.gap)
                    _ = coordinator.update(strip: strip, viewport: viewport, force: true)
                }
                return ok ? "OK: Moved column right to \(strip.focusedColumnIndex)" : "ERR: Cannot move rightmost column"
            } else if sub == "preset" || sub == "cycle" {
                strip.cycleColumnWidthPreset(viewportWidth: viewport.width)
                scroller.snapToColumn(at: strip.focusedColumnIndex, in: strip, viewportWidth: viewport.width, gap: coordinator.gap)
                currentStrip = strip
                _ = coordinator.update(strip: strip, viewport: viewport, force: true)
                return "OK: Cycled column preset width"
            } else if sub == "maximize" || sub == "fullscreen" {
                strip.toggleMaximizeColumn(viewportWidth: viewport.width)
                scroller.snapToColumn(at: strip.focusedColumnIndex, in: strip, viewportWidth: viewport.width, gap: coordinator.gap)
                currentStrip = strip
                _ = coordinator.update(strip: strip, viewport: viewport, force: true)
                return "OK: Toggled column maximize"
            } else if sub == "consume-left" {
                let ok = strip.consumeAdjacentColumnIntoStack(toRight: false)
                if ok {
                    scroller.snapToColumn(at: strip.focusedColumnIndex, in: strip, viewportWidth: viewport.width, gap: coordinator.gap)
                    currentStrip = strip
                    _ = coordinator.update(strip: strip, viewport: viewport, force: true)
                }
                return ok ? "OK: Consumed left column into stack" : "ERR: No left column to consume"
            } else if sub == "consume-right" {
                let ok = strip.consumeAdjacentColumnIntoStack(toRight: true)
                if ok {
                    scroller.snapToColumn(at: strip.focusedColumnIndex, in: strip, viewportWidth: viewport.width, gap: coordinator.gap)
                    currentStrip = strip
                    _ = coordinator.update(strip: strip, viewport: viewport, force: true)
                }
                return ok ? "OK: Consumed right column into stack" : "ERR: No right column to consume"
            } else if sub == "expand" {
                scroller.expandFocusedColumn(in: &strip, by: 0.1, viewportWidth: viewport.width, gap: coordinator.gap)
                currentStrip = strip
                _ = coordinator.update(strip: strip, viewport: viewport, force: true)
                return "OK: Expanded column \(strip.focusedColumnIndex)"
            } else if sub == "shrink" {
                scroller.shrinkFocusedColumn(in: &strip, by: 0.1, viewportWidth: viewport.width, gap: coordinator.gap)
                currentStrip = strip
                _ = coordinator.update(strip: strip, viewport: viewport, force: true)
                return "OK: Shrunk column \(strip.focusedColumnIndex)"
            } else if sub == "center" {
                scroller.snapToColumn(at: strip.focusedColumnIndex, in: strip, viewportWidth: viewport.width, gap: coordinator.gap)
                _ = coordinator.update(strip: strip, viewport: viewport, force: true)
                return "OK: Centered column \(strip.focusedColumnIndex)"
            }
            return "ERR: Unknown column subcommand '\(sub)'"

        case "pan":
            lock.lock()
            defer { lock.unlock() }
            guard parts.count >= 2, let delta = Double(parts[1]) else { return "ERR: Usage: pan <delta>" }
            scroller.pan(delta: delta, in: currentStrip, viewportWidth: viewport.width, gap: coordinator.gap)
            _ = coordinator.update(strip: currentStrip, viewport: viewport)
            return "OK: Panned \(delta)"

        case "fling":
            lock.lock()
            defer { lock.unlock() }
            var strip = currentStrip
            guard parts.count >= 2, let vel = Double(parts[1]) else { return "ERR: Usage: fling <velocity>" }
            scroller.fling(initialVelocity: vel, in: &strip, viewportWidth: viewport.width, gap: coordinator.gap)
            currentStrip = strip
            return "OK: Flung with velocity \(vel)"

        case "snap":
            lock.lock()
            defer { lock.unlock() }
            var strip = currentStrip
            let ok = scroller.snapToNearest(in: &strip, viewportWidth: viewport.width, gap: coordinator.gap)
            currentStrip = strip
            _ = coordinator.update(strip: strip, viewport: viewport, force: true)
            return ok ? "OK: Snapped to column \(strip.focusedColumnIndex)" : "ERR: No columns to snap to"

        case "scroll":
            lock.lock()
            defer { lock.unlock() }
            guard parts.count >= 2, let delta = Double(parts[1]) else { return "ERR: Usage: scroll <delta>" }
            scroller.scroll(by: delta)
            return "OK: Scrolled by \(delta)"

        case "status":
            lock.lock()
            defer { lock.unlock() }
            let strip = currentStrip
            let totalW = strip.totalWidth(viewportWidth: viewport.width, gap: coordinator.gap)
            return """
            {
              "activeSpaceID": \(activeSpaceID),
              "columns": \(strip.columns.count),
              "focusedColumnIndex": \(strip.focusedColumnIndex),
              "focusedWindowId": \(strip.focusedWindowId ?? 0),
              "currentOffset": \(scroller.currentOffset),
              "targetOffset": \(scroller.targetOffset),
              "isSettled": \(scroller.isSettled),
              "totalRibbonWidth": \(totalW),
              "viewport": {"width": \(viewport.width), "height": \(viewport.height)}
            }
            """

        default:
            return "ERR: Unknown command '\(trimmed)'"
        }
    }
}

// MARK: - Startup

print("==================================================================")
print("  SHUTTLE DAEMON (shuttled v\(ShuttleVersion.full))")
print("  Infinite Horizontal Ribbon Scrolling Window Manager for macOS")
print("==================================================================")

guard AXIsProcessTrusted() else {
    print("❌ Accessibility permissions not granted.")
    print("Please grant Accessibility in System Settings -> Privacy & Security -> Accessibility.")
    exit(1)
}

// 1. Resolve Display Viewport and Active Space
let displays = SpaceControl.displayLayout()
let viewport: Frame = displays.first?.visible ?? Frame(x: 0, y: 0, width: 1710, height: 1112)
let currentSpaces = WorldReader.currentSpaces()
let initialSpaceID: SpaceID = currentSpaces.values.first ?? 1
print("Active Viewport: \(String(format: "%.0fx%.0f at (%.0f, %.0f)", viewport.width, viewport.height, viewport.x, viewport.y))")
print("Active Space ID: \(initialSpaceID)")

// 2. Discover Running Windows
var initialStrip = Strip()
let scroller = Scroller(strategy: .hybrid)
let coordinator = WindowCoordinator(scroller: scroller, gap: 16.0)

let runningApps = NSWorkspace.shared.runningApplications.filter {
    $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier
}

print("Discovering active application windows...")
var initialPids: [Int32] = []
var initialWindows: [(WindowID, Int32)] = []

for app in runningApps {
    let pid = app.processIdentifier
    initialPids.append(pid)
    let appElement = AXUIElementCreateApplication(pid)
    var winRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &winRef) == .success,
          let axWins = winRef as? [AXUIElement] else { continue }

    for win in axWins {
        var sizeRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef)
        var size = CGSize.zero
        if let s = sizeRef as! AXValue? { AXValueGetValue(s, .cgSize, &size) }
        guard size.width >= 200 && size.height >= 200 && size.width < 3500 else { continue }

        if let wid = PublicPaths.windowID(of: win) {
            initialStrip.insertWindow(wid, asNewColumn: true)
            coordinator.register(windowID: wid, element: win)
            initialWindows.append((wid, pid))
        }
    }
}
print("Initialized strip with \(initialStrip.columns.count) columns (\(initialWindows.count) windows).")

// Snap to initial column
if !initialStrip.columns.isEmpty {
    scroller.snapToColumn(at: initialStrip.focusedColumnIndex, in: initialStrip, viewportWidth: viewport.width, gap: coordinator.gap)
    _ = coordinator.update(strip: initialStrip, viewport: viewport, force: true)
}

let controller = DaemonController(
    initialStrip: initialStrip,
    initialSpaceID: initialSpaceID,
    scroller: scroller,
    coordinator: coordinator,
    viewport: viewport
)

// 3. Dynamic Window & Space Lifecycle Observers
let observers = ObserverSet()
observers.onEvent = { [weak controller] event in
    DispatchQueue.main.async {
        switch event {
        case .windowCreated(let pid, let wid):
            controller?.handleWindowCreated(pid: pid, wid: wid)
        case .windowDestroyed(let wid):
            controller?.handleWindowDestroyed(wid: wid)
        case .windowFocused(let wid):
            controller?.handleWindowFocused(wid: wid)
        case .appActivated(let pid):
            controller?.handleAppActivated(pid: pid)
        case .appLaunched(let pid, _):
            observers.watch(pids: [pid], windows: [])
        case .appTerminated(let pid, _):
            observers.forgetApp(pid: pid)
        case .spaceChanged:
            let curSpaces = WorldReader.currentSpaces()
            if let curSid = curSpaces.values.first {
                controller?.handleSpaceActivated(curSid)
            }
        case .displayChanged:
            controller?.handleDisplayChanged()
        default:
            break
        }
    }
}
observers.start()
observers.watch(pids: initialPids, windows: initialWindows)
print("👁️  Dynamic window lifecycle observers attached.")

// 4. Keyboard Navigation Setup (InputManager)
var binds: [(String, String)] = [
    // Column focus
    ("alt-h", "column focus-left"),
    ("alt-l", "column focus-right"),
    ("alt-left", "column focus-left"),
    ("alt-right", "column focus-right"),

    // Vertical stack focus
    ("alt-k", "window focus-up"),
    ("alt-j", "window focus-down"),
    ("alt-up", "window focus-up"),
    ("alt-down", "window focus-down"),

    // Column move
    ("alt-shift-h", "column move-left"),
    ("alt-shift-l", "column move-right"),
    ("alt-shift-left", "column move-left"),
    ("alt-shift-right", "column move-right"),

    // Vertical stack move
    ("alt-shift-k", "window move-up"),
    ("alt-shift-j", "window move-down"),
    ("alt-shift-up", "window move-up"),
    ("alt-shift-down", "window move-down"),

    // Column width adjustment & presets
    ("alt-minus", "column shrink"),
    ("alt-equal", "column expand"),
    ("alt-r", "column preset"),
    ("alt-f", "column maximize"),
    ("alt-0", "column center"),

    // Stacking and splitting
    ("alt-s", "window split"),
]

// Spaces bindings: Alt + 1..9 (switch) & Alt + Shift + 1..9 (move window)
for i in 1...9 {
    binds.append(("alt-\(i)", "space focus \(i)"))
    binds.append(("alt-shift-\(i)", "space move-window \(i)"))
}

var chordMap: [Chord: KeyAction] = [:]
for (chordStr, cmdStr) in binds {
    if let chord = try? parseChord(chordStr) {
        chordMap[chord] = KeyAction.send(cmdStr)
    }
}

let keymap = Keymap(modes: ["default": chordMap])
let inputManager = InputManager(keymap: keymap)
inputManager.updateMouseModifier("alt")

inputManager.onCommand = { cmd in
    let res = controller.handleCommand(cmd)
    print("⌨️  Keyboard command: \(cmd) -> \(res)")
}

inputManager.onMouseGesture = { gesture in
    controller.handleMouseGesture(gesture)
}

if inputManager.start() {
    print("✅ Keyboard & mouse ribbon navigation active:")
    print("   • Alt + H/L or Left/Right:     Focus column left / right")
    print("   • Alt + J/K or Down/Up:        Focus window down / up in stack")
    print("   • Alt + Shift + H/L:           Move column left / right")
    print("   • Alt + Shift + J/K:           Move window down / up in stack")
    print("   • Alt + R:                     Cycle preset width (1/3 -> 1/2 -> 2/3 -> 1.0)")
    print("   • Alt + F:                     Toggle maximize column width")
    print("   • Alt + S:                     Split focused window into new column")
    print("   • Alt + 0:                     Center current column")
    print("   • Alt + 1..9:                  Switch to Space 1..9")
    print("   • Alt + Shift + 1..9:          Move focused window to Space 1..9")
    print("   • Alt + Left-Drag:             Grab & slide ribbon with flick momentum")
} else {
    print("⚠️  Warning: Failed to install event tap for keyboard navigation.")
}

// 5. IPC Server for Remote Control (shuttlectl)
let user = ProcessInfo.processInfo.environment["USER"] ?? "user"
let socketPath = "/tmp/shuttle-\(user).sock"
ignoreSIGPIPE()

let ipcServer = IPCServer(path: socketPath) { [controller] line, conn in
    let responseText = controller.handleCommand(line)
    let resp = IPCResponse(ok: !responseText.hasPrefix("ERR"), output: responseText)
    if let data = try? JSONEncoder().encode(resp),
       let jsonStr = String(data: data, encoding: .utf8) {
        conn.send(jsonStr)
    } else {
        conn.send(responseText)
    }
}

DispatchQueue.global(qos: .userInteractive).async {
    print("🔌 IPC server listening on \(socketPath)")
    ipcServer.run()
}

// 6. 120Hz/60Hz Animation Simulation Timer
let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
timer.schedule(deadline: .now(), repeating: .milliseconds(8)) // ~120Hz tick
var lastTick = CACurrentMediaTime()

timer.setEventHandler { [controller] in
    let now = CACurrentMediaTime()
    let dt = now - lastTick
    lastTick = now
    controller.tick(dt: dt)
}
timer.resume()

print("\n🚀 shuttled daemon ready. Running event loop...")
RunLoop.main.run()
