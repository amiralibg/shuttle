import AppKit
import ApplicationServices
import Foundation
import QuartzCore
import ShuttleCore
import ShuttleScroller
import WeftCore
import WeftPlatform
import WeftInput

/// What the menu bar, Settings and `shuttlectl status` show.
struct StatusSnapshot: Codable, Equatable {
    struct Viewport: Codable, Equatable {
        var width: Double
        var height: Double
    }

    struct Desktop: Codable, Equatable {
        /// 1-based number across every display, main display first, as
        /// `space focus N` counts.
        var index: Int
        var label: String?
        var spaceID: SpaceID
        var windows: Int?
        var isCurrent: Bool
    }

    struct Monitor: Codable, Equatable {
        var uuid: String
        var name: String
        var isMain: Bool
        var isFocused: Bool
        var bounds: Frame
        /// 1-based position of the showing desktop; nil on a fullscreen app's space.
        var desktopIndex: Int?
        var desktops: [Desktop]
        var columns: Int
        var focusedColumnIndex: Int
        var focusedApp: String?
    }

    // The focused monitor, flattened for scripts and the menu bar.
    var activeSpaceID: SpaceID
    var spaceIndex: Int?
    var spaceCount: Int
    var desktops: [Desktop]
    var columns: Int
    var focusedColumnIndex: Int
    var focusedWindowId: UInt32
    var focusedApp: String?
    var windowsInFocusedColumn: Int
    var fullscreen: Bool
    var currentOffset: Double
    var targetOffset: Double
    var isSettled: Bool
    var totalRibbonWidth: Double
    var viewport: Viewport

    var monitors: [Monitor]
    var separateSpaces: Bool
    var centerMode: String
    var paused: Bool
}

/// One ribbon: the windows of one desktop on one display.
@MainActor
final class Workspace {
    var strip = Strip()
    let scroller: Scroller
    /// Scrolled into place at least once; before that its offset means nothing.
    var placed = false
    /// When a column last left this ribbon.
    var shrankAt = -Double.infinity

    init(config: ShuttleConfig) {
        scroller = Scroller(strategy: .hybrid, omega: config.springOmega, centerMode: config.centerFocusedColumn)
        strip.fillsWhenAlone = config.fillSingleColumn
    }
}

struct WorkspaceKey: Hashable {
    var space: SpaceID
    var display: String
}

/// A display as Shuttle tiles it.
struct Monitor: Equatable {
    var uuid: String
    var name: String
    var isMain: Bool
    var bounds: Frame
    /// What columns are laid out in: below the menu bar, clear of the Dock.
    var viewport: Frame
    /// The identifier SkyLight files this display's desktops under; "Main"
    /// for every display when they share one set of Spaces.
    var spacesID: String
    /// Ordinary desktops, Mission Control order.
    var desktops: [SpaceID]
    /// The space showing, which may be a fullscreen app's and so not tiled.
    var current: SpaceID

    var currentKey: WorkspaceKey? {
        desktops.contains(current) ? WorkspaceKey(space: current, display: uuid) : nil
    }
}

/// Owns every ribbon and is the only thing that changes them. Main thread
/// only: keyboard, mouse, IPC and observers all hop here first.
///
/// Every display has its own desktops (with "Displays have separate Spaces"
/// on, macOS's default) and every desktop its own ribbon, so each monitor
/// scrolls, switches desktops and animates on its own — niri's model. Commands
/// act on the focused monitor: the one holding the focused window.
@MainActor
final class DaemonController {
    private(set) var config: ShuttleConfig
    private var monitors: [Monitor] = []
    private var workspaces: [WorkspaceKey: Workspace] = [:]
    private var focusedDisplay: String = ""
    private let coordinator: WindowCoordinator
    private let animator = Animator()
    private var missionControlOpen = false
    /// Whether the instant SkyLight desktop switch works on this macOS. Nil
    /// until first tried; one failure falls back to the Dock swipe for the
    /// rest of the launch.
    private var bridgedSwitchWorks: Bool?
    private var geometryChecks: [WindowID: DispatchWorkItem] = [:]
    /// The requested frame a window was last snapped back to, so an app that
    /// insists on its own size is corrected once and then left alone.
    private var reasserted: [WindowID: Frame] = [:]
    /// Windows moved or resized while the mouse button was down: the user's
    /// doing, always answered, unlike an app resizing itself.
    private var draggedByUser: Set<WindowID> = []
    /// Windows Shuttle leaves alone: a `manage = false` rule, or floated by hand.
    private var floating: Set<WindowID> = []
    /// The desktop focus was on before the current one, for `space focus recent`.
    private var lastFocus: WorkspaceKey?
    private var previousFocus: WorkspaceKey?
    /// Rules that send windows to a desktop apply to windows opened after launch.
    private var launchSweepDone = false

    var onShutdown: (() -> Void)?
    /// A window was taken under management: watch it for moves, resizes,
    /// closing and minimizing, which macOS only reports per window.
    var onWindowManaged: ((WindowID, Int32) -> Void)?
    /// Fired after anything the status snapshot reports may have changed.
    var onStateChange: (() -> Void)?
    /// `reload` from shuttlectl or the menu.
    var onReloadRequested: (() -> Void)?

    init(config: ShuttleConfig) {
        self.config = config
        self.coordinator = WindowCoordinator(gap: config.gap)
        animator.onFrame = { [unowned self] dt in self.tick(dt: dt) }
        coordinator.onWriteRefused = { wid, requested, actual in
            let app = WindowDiscovery.owner(of: wid).flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName } ?? "window \(wid)"
            print(String(
                format: "⚠️  %@ kept %.0fx%.0f at (%.0f, %.0f); Shuttle asked for %.0fx%.0f at (%.0f, %.0f)",
                app, actual.width, actual.height, actual.x, actual.y,
                requested.width, requested.height, requested.x, requested.y
            ))
        }
        refreshMonitors()
        focusedDisplay = SpaceControl.activeDisplayUUID(known: Set(monitors.map(\.uuid)))
            ?? monitors.first(where: \.isMain)?.uuid ?? monitors.first?.uuid ?? ""
    }

    // MARK: - Monitors

    private func refreshMonitors() {
        let layout = SpaceControl.displayLayout()
        let areas = Dictionary(SpaceControl.tilingAreas(layout), uniquingKeysWith: { a, _ in a })
        let names = Dictionary(SpaceControl.displayIdentities().map { ($0.uuid, $0.name) }, uniquingKeysWith: { a, _ in a })
        let mainUUID = SpaceControl.mainDisplayUUID()
        let sls = WorldReader.displaysOnly()
        let current = WorldReader.currentSpaces()

        monitors = layout.map { d in
            let entry = sls.first { $0.uuid == d.uuid } ?? (sls.count == 1 ? sls.first : nil)
            let spacesID = entry?.uuid ?? d.uuid
            return Monitor(
                uuid: d.uuid,
                name: names[d.uuid] ?? "Display",
                isMain: d.uuid == mainUUID,
                bounds: d.frame,
                viewport: areas[d.uuid] ?? d.visible,
                spacesID: spacesID,
                desktops: entry?.spaces ?? [],
                current: current[spacesID] ?? entry?.currentSpace ?? 0
            )
        }
        if !monitors.contains(where: { $0.uuid == focusedDisplay }) {
            focusedDisplay = monitors.first(where: \.isMain)?.uuid ?? monitors.first?.uuid ?? ""
        }
    }

    private func monitor(_ uuid: String) -> Monitor? {
        monitors.first { $0.uuid == uuid }
    }

    private var focusedMonitor: Monitor? { monitor(focusedDisplay) ?? monitors.first }

    private func placement(for m: Monitor) -> WindowCoordinator.Placement {
        .init(viewport: m.viewport, display: m.bounds, otherDisplays: monitors.filter { $0.uuid != m.uuid }.map(\.bounds))
    }

    private func ribbonWidth(_ m: Monitor) -> Double { coordinator.layoutArea(for: m.viewport).width }
    private var gap: Double { coordinator.gap }
    private var newColumnWidth: ColumnWidth { .proportion(config.defaultColumnWidth) }

    private func workspace(_ key: WorkspaceKey) -> Workspace {
        if let ws = workspaces[key] { return ws }
        let ws = Workspace(config: config)
        workspaces[key] = ws
        return ws
    }

    private func isVisible(_ key: WorkspaceKey) -> Bool {
        monitor(key.display)?.currentKey == key
    }

    /// Where `wid` is filed, on any display and desktop.
    private func location(of wid: WindowID) -> WorkspaceKey? {
        workspaces.first { $0.value.strip.column(forWindowID: wid) != nil }?.key
    }

    /// The focused monitor's showing ribbon.
    private var current: (monitor: Monitor, key: WorkspaceKey, ws: Workspace)? {
        guard let m = focusedMonitor, let key = m.currentKey else { return nil }
        return (m, key, workspace(key))
    }

    // MARK: - Committing

    /// Writes one ribbon if it is showing, and wakes the animator if it moves.
    private func commit(_ key: WorkspaceKey) {
        guard !missionControlOpen, isVisible(key), let m = monitor(key.display), let ws = workspaces[key] else { return }
        coordinator.update(strip: ws.strip, offset: ws.scroller.currentOffset, placement: placement(for: m), settled: ws.scroller.isSettled)
        if !ws.scroller.isSettled { animator.start() }
    }

    private func commitVisible() {
        for m in monitors {
            if let key = m.currentKey { commit(key) }
        }
    }

    private func changed() {
        if let key = focusedMonitor?.currentKey, key != lastFocus {
            previousFocus = lastFocus
            lastFocus = key
        }
        onStateChange?()
    }

    private func tick(dt: Double) -> Bool {
        var moving = false
        for m in monitors {
            guard let key = m.currentKey, let ws = workspaces[key], !ws.scroller.isSettled else { continue }
            ws.scroller.tick(dt: dt)
            commit(key)
            moving = moving || !ws.scroller.isSettled
        }
        return moving
    }

    /// How long after a column goes the ribbon keeps closing up empty space.
    /// macOS picks the next window to focus just after a close, and centering
    /// on that one would open the gap again.
    private static let closeUpSeconds = 0.6

    /// Scrolls a ribbon to its focused column, at once the first time.
    private func reveal(_ key: WorkspaceKey) {
        guard let m = monitor(key.display), let ws = workspaces[key] else { return }
        if !ws.placed {
            let offset = ws.strip.centerOffset(forColumnAt: ws.strip.focusedColumnIndex, viewportWidth: ribbonWidth(m), gap: gap) ?? 0
            ws.scroller.setOffset(offset)
            ws.placed = true
        } else if CACurrentMediaTime() - ws.shrankAt < Self.closeUpSeconds {
            ws.scroller.fitColumn(at: ws.strip.focusedColumnIndex, in: ws.strip, viewportWidth: ribbonWidth(m), gap: gap)
        } else {
            ws.scroller.snapToColumn(at: ws.strip.focusedColumnIndex, in: ws.strip, viewportWidth: ribbonWidth(m), gap: gap)
        }
    }

    /// Runs `change` on a ribbon (the focused one by default); when it
    /// reports a change, scrolls the focused column into view, writes the
    /// layout and optionally focuses the focused window.
    @discardableResult
    private func mutate(_ key: WorkspaceKey? = nil, reveal shouldReveal: Bool = true, raise: Bool = false, _ change: (inout Strip) -> Bool) -> Bool {
        guard let key = key ?? current?.key else { return false }
        let ws = workspace(key)
        var strip = ws.strip
        guard change(&strip) else { return false }
        if strip.columns.count < ws.strip.columns.count { ws.shrankAt = CACurrentMediaTime() }
        ws.strip = strip
        if shouldReveal { reveal(key) }
        commit(key)
        if raise, let wid = strip.focusedWindowId {
            if let fs = strip.fullscreenWindowId, strip.focusedColumn?.windowIds.contains(fs) == true {
                coordinator.raiseAndFocus(windowID: fs)
            } else {
                coordinator.raiseAndFocus(windowID: wid)
            }
        }
        changed()
        return true
    }

    // MARK: - Config

    func apply(config newConfig: ShuttleConfig) {
        let old = config
        config = newConfig
        coordinator.gap = newConfig.gap
        let oldWidth = ColumnWidth.proportion(old.defaultColumnWidth)
        for ws in workspaces.values {
            ws.scroller.omega = newConfig.springOmega
            ws.scroller.centerMode = newConfig.centerFocusedColumn
            ws.strip.fillsWhenAlone = newConfig.fillSingleColumn
            // Columns still at the old default follow the new one; ones
            // resized by hand keep their width.
            if old.defaultColumnWidth != newConfig.defaultColumnWidth {
                for i in ws.strip.columns.indices where ws.strip.columns[i].width == oldWidth {
                    ws.strip.columns[i].width = .proportion(newConfig.defaultColumnWidth)
                }
            }
        }
        let relayout = old.gap != newConfig.gap
            || old.centerFocusedColumn != newConfig.centerFocusedColumn
            || old.fillSingleColumn != newConfig.fillSingleColumn
            || old.defaultColumnWidth != newConfig.defaultColumnWidth
        if relayout {
            for m in monitors {
                guard let key = m.currentKey, workspaces[key] != nil else { continue }
                reveal(key)
                commit(key)
            }
        }
        changed()
    }

    // MARK: - Mouse

    private var dragKey: WorkspaceKey?
    private var lastDragLoc = CGPoint.zero
    private var lastDragTime = 0.0
    private var dragVelocity = 0.0
    private var focusBeforeDrag: UInt32?

    /// The ribbon under the pointer drags, whichever monitor has focus.
    func handleMouseGesture(_ gesture: MouseGesture) {
        let now = CACurrentMediaTime()
        switch gesture {
        case .down(let button, let loc):
            guard button == .left else { return }
            let point = Frame(x: loc.x, y: loc.y, width: 1, height: 1)
            let idx = DisplayGeometry.display(containing: point, in: monitors.map(\.bounds))
            guard let key = (idx.map { monitors[$0] } ?? focusedMonitor)?.currentKey else { return }
            dragKey = key
            lastDragLoc = loc
            lastDragTime = now
            dragVelocity = 0.0
            focusBeforeDrag = workspace(key).strip.focusedWindowId

        case .drag(let button, let loc):
            guard button == .left, let key = dragKey, let m = monitor(key.display) else { return }
            let dt = max(0.001, now - lastDragTime)
            let dx = Double(loc.x - lastDragLoc.x)
            dragVelocity = dragVelocity * 0.6 + (dx / dt) * 0.4
            lastDragLoc = loc
            lastDragTime = now
            // Dragging right reveals the columns on the left, like paper.
            let ws = workspace(key)
            ws.scroller.pan(delta: -dx, in: ws.strip, viewportWidth: ribbonWidth(m), gap: gap)
            commit(key)

        case .up(let button, _):
            guard button == .left, let key = dragKey, let m = monitor(key.display) else { return }
            dragKey = nil
            let ws = workspace(key)
            var strip = ws.strip
            if abs(dragVelocity) > 350.0 {
                ws.scroller.fling(initialVelocity: -dragVelocity, in: &strip, viewportWidth: ribbonWidth(m), gap: gap)
            } else {
                ws.scroller.snapToNearest(in: &strip, viewportWidth: ribbonWidth(m), gap: gap)
            }
            ws.strip = strip
            commit(key)
            // The column the drag landed on takes focus, as in niri.
            if let wid = strip.focusedWindowId, wid != focusBeforeDrag {
                focusedDisplay = key.display
                coordinator.raiseAndFocus(windowID: wid)
            }
            changed()
        }
    }

    // MARK: - Desktops

    /// Every ordinary desktop with its display, numbered as weft and yabai
    /// number them: the main display's first, then each other display's.
    /// With displays sharing Spaces each desktop is listed once, on the main display.
    private var numberedDesktops: [(monitor: Monitor, space: SpaceID)] {
        var seen: Set<SpaceID> = []
        var out: [(Monitor, SpaceID)] = []
        for m in monitors.filter(\.isMain) + monitors.filter({ !$0.isMain }) {
            for sid in m.desktops where seen.insert(sid).inserted { out.append((m, sid)) }
        }
        return out
    }

    private func desktopNumber(of sid: SpaceID) -> Int? {
        numberedDesktops.firstIndex { $0.space == sid }.map { $0 + 1 }
    }

    /// A desktop named by number, label, `next`, `prev` or `recent`.
    private func resolveDesktop(_ token: String) -> (monitor: Monitor, space: SpaceID)? {
        let all = numberedDesktops
        switch token {
        case "recent":
            guard let key = previousFocus, let m = monitor(key.display), m.desktops.contains(key.space) else { return nil }
            return (m, key.space)
        case "next", "prev":
            guard let m = focusedMonitor, let i = m.desktops.firstIndex(of: m.current) else { return nil }
            let j = token == "next" ? i + 1 : i - 1
            return m.desktops.indices.contains(j) ? (m, m.desktops[j]) : nil
        default:
            let n = Int(token) ?? config.desktopNumber(forLabel: token)
            guard let n, all.indices.contains(n - 1) else { return nil }
            return all[n - 1]
        }
    }

    private func describe(_ token: String) -> String {
        if let n = Int(token) { return config.label(ofDesktop: n).map { "desktop \(n) (\($0))" } ?? "desktop \(n)" }
        return "“\(token)”"
    }

    /// Switches a display other than the focused one, from the menu or Settings.
    func focusSpace(onDisplay uuid: String, index: Int) -> String {
        focusDesktop("\(index)")
    }

    /// Shows a desktop and focuses its display. A desktop already showing on
    /// its display only moves focus there.
    func focusDesktop(_ token: String, raiseRibbon: Bool = true) -> String {
        guard let (m, target) = resolveDesktop(token) else {
            return token == "recent" ? "ERR: No previous desktop" : "ERR: No desktop \(describe(token))"
        }
        focusedDisplay = m.uuid
        if target != m.current {
            var landed = false
            if bridgedSwitchWorks != false, NativeBridge.missingPiece == nil {
                let result = NativeBridge.switchDisplay(m.spacesID, from: m.current, to: target, windows: false)
                landed = result.verdict.landed
                bridgedSwitchWorks = landed
            }
            if !landed {
                landed = DockSwipe.focusSpace(target)
            }
            guard landed else { return "ERR: macOS did not switch \(m.name) to \(describe(token))" }
            handleSpaceChanged()
        }
        focusedDisplay = m.uuid
        // Land with the keyboard on the window last used there.
        if raiseRibbon, let wid = current?.ws.strip.focusedWindowId { coordinator.raiseAndFocus(windowID: wid) }
        changed()
        return "OK: On \(describe(token)) of \(m.name)"
    }

    /// Sends the focused window to a desktop, on any display. It is laid out
    /// there at once if that desktop is showing; `follow` goes with it.
    func moveFocusedWindow(toDesktop token: String, follow: Bool) -> String {
        if let window = frontFloatingWindow() {
            return moveFloating(window, toDesktop: token, follow: follow)
        }
        guard let (_, sourceKey, ws) = current, let wid = ws.strip.focusedWindowId else { return "ERR: No window focused" }
        guard let (m, target) = resolveDesktop(token) else { return "ERR: No desktop \(describe(token))" }
        let targetKey = WorkspaceKey(space: target, display: m.uuid)
        if targetKey == sourceKey { return "OK: Window is already on \(describe(token))" }

        if target != sourceKey.space {
            let moved = NativeBridge.move([wid], to: target)
            guard moved.verdict.complete else { return "ERR: macOS refused to move window \(wid) to \(describe(token))" }
        }
        coordinator.invalidate(windowID: wid)
        mutate(sourceKey, raise: !follow) { $0.removeWindow(wid) }
        let width = newColumnWidth
        mutate(targetKey) { strip in
            strip.insertWindow(wid, asNewColumn: true, width: width)
            return true
        }
        if follow {
            _ = focusDesktop(token)
            coordinator.raiseAndFocus(windowID: wid)
        }
        changed()
        return "OK: Moved window \(wid) to \(describe(token))"
    }

    private struct FloatingWindow {
        var wid: WindowID
        var pid: Int32
        var element: AXUIElement
        var monitor: Monitor
    }

    /// The window the user is on, when no ribbon owns it: floating by rule or
    /// by hand, or a kind Shuttle never tiles. An app can name a focused window
    /// on a desktop that is not showing; that one is not in front of anybody.
    private func frontFloatingWindow() -> FloatingWindow? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let (wid, element) = WindowDiscovery.focusedWindow(of: pid),
              location(of: wid) == nil,
              WindowDiscovery.isWindow(element)
        else { return nil }
        let spaces = SpaceControl.spacesForWindow(wid)
        let showing = spaces.isEmpty ? focusedMonitor : monitors.first { spaces.contains($0.current) }
        // On a fullscreen app's space the window is that app's to keep.
        guard let showing, showing.currentKey != nil else { return nil }
        return FloatingWindow(wid: wid, pid: pid, element: element, monitor: showing)
    }

    /// Sends a window no ribbon owns to a desktop. It stays floating there.
    private func moveFloating(_ window: FloatingWindow, toDesktop token: String, follow: Bool) -> String {
        guard let (m, target) = resolveDesktop(token) else { return "ERR: No desktop \(describe(token))" }
        let wid = window.wid
        if SpaceControl.spacesForWindow(wid).contains(target) { return "OK: Window is already on \(describe(token))" }
        guard NativeBridge.move([wid], to: target).verdict.complete else {
            return "ERR: macOS refused to move window \(wid) to \(describe(token))"
        }
        // macOS keeps its coordinates, which are off the other display.
        if m.uuid != window.monitor.uuid, let f = WorldReader.frame(of: wid) {
            let vp = m.viewport
            let w = min(f.width, vp.width), h = min(f.height, vp.height)
            coordinator.place(window.element, pid: window.pid, frame: Frame(
                x: vp.x + (vp.width - w) / 2, y: vp.y + (vp.height - h) / 2, width: w, height: h
            ))
        }
        if follow {
            _ = focusDesktop(token, raiseRibbon: false)
            coordinator.raiseAndFocus(window.element, pid: window.pid)
        } else if let key = window.monitor.currentKey, let next = workspace(key).strip.focusedWindowId {
            // The keyboard was on the window that just left.
            coordinator.raiseAndFocus(windowID: next)
        }
        changed()
        return "OK: Moved window \(wid) to \(describe(token))"
    }

    /// The desktop showing on some display changed, by Shuttle or by
    /// anything else (swipe, ⌃←, Mission Control, ⌘-Tab).
    func handleSpaceChanged() {
        let before = Dictionary(monitors.map { ($0.uuid, $0.current) }, uniquingKeysWith: { a, _ in a })
        refreshMonitors()
        pruneVanishedDesktops()
        let switched = monitors.filter { before[$0.uuid] != $0.current }
        guard !switched.isEmpty else { return }
        // One display changed desktop: that is where the user is. Several
        // (displays sharing Spaces): ask macOS which one is active.
        if switched.count == 1 {
            focusedDisplay = switched[0].uuid
        } else if let active = SpaceControl.activeDisplayUUID(known: Set(monitors.map(\.uuid))) {
            focusedDisplay = active
        }
        discoverWindows()
        for m in switched {
            guard let key = m.currentKey else { continue }
            if !workspace(key).placed { reveal(key) }
            commit(key)
        }
        changed()
    }

    /// A desktop deleted in Mission Control hands its windows to another
    /// one. Forget its ribbon so discovery picks them up where they went.
    private func pruneVanishedDesktops() {
        let live = Set(monitors.flatMap { m in m.desktops.map { WorkspaceKey(space: $0, display: m.uuid) } })
        guard !live.isEmpty else { return }
        for (key, ws) in workspaces where !live.contains(key) {
            for wid in ws.strip.columns.flatMap(\.windowIds) { coordinator.unregister(windowID: wid) }
            workspaces.removeValue(forKey: key)
        }
    }

    // MARK: - Monitors

    func focusMonitor(_ direction: DisplayDirection) -> String {
        guard let from = monitors.firstIndex(where: { $0.uuid == focusedDisplay }),
              let to = DisplayGeometry.neighbour(of: from, direction, in: monitors.map(\.bounds))
        else { return "ERR: No display \(direction.rawValue) of this one" }
        let m = monitors[to]
        focusedDisplay = m.uuid
        if let key = m.currentKey, let wid = workspace(key).strip.focusedWindowId {
            coordinator.raiseAndFocus(windowID: wid)
        } else {
            // Nothing to give the keyboard to; the pointer makes macOS open
            // the next window on this display.
            CGWarpMouseCursorPosition(CGPoint(x: m.viewport.x + m.viewport.width / 2, y: m.viewport.y + m.viewport.height / 2))
        }
        changed()
        return "OK: Focused \(m.name)"
    }

    /// Moves the focused window, or its whole column, to the desktop showing
    /// on the neighbouring display. Focus goes with it.
    func moveToMonitor(_ direction: DisplayDirection, wholeColumn: Bool) -> String {
        guard let (_, sourceKey, sourceWs) = current,
              let wid = sourceWs.strip.focusedWindowId,
              let column = sourceWs.strip.focusedColumn,
              let from = monitors.firstIndex(where: { $0.uuid == focusedDisplay }),
              let to = DisplayGeometry.neighbour(of: from, direction, in: monitors.map(\.bounds))
        else { return "ERR: Nothing to move, or no display \(direction.rawValue) of this one" }
        let target = monitors[to]
        guard let targetKey = target.currentKey else { return "ERR: \(target.name) is showing a fullscreen app" }

        let wids = wholeColumn ? column.windowIds : [wid]
        if targetKey.space != sourceKey.space {
            let moved = NativeBridge.move(wids, to: targetKey.space)
            guard moved.verdict.complete else { return "ERR: macOS refused to move the window to \(target.name)" }
        }

        wids.forEach(coordinator.invalidate(windowID:))
        let wasFullscreen = sourceWs.strip.fullscreenWindowId.map(wids.contains) ?? false
        mutate(sourceKey) { strip in
            wids.forEach { _ = strip.removeWindow($0) }
            return true
        }

        focusedDisplay = target.uuid
        let width = column.width
        mutate(targetKey, raise: true) { strip in
            strip.insertWindow(wids[0], asNewColumn: true, width: wholeColumn ? width : self.newColumnWidth)
            for extra in wids.dropFirst() { strip.insertWindow(extra, asNewColumn: false) }
            strip.focusedWindowId = wid
            if wasFullscreen { strip.fullscreenWindowId = wid }
            return true
        }
        return "OK: Moved to \(target.name)"
    }

    // MARK: - Window lifecycle

    /// Files every tileable window AX can see (the showing desktop of every
    /// display) that no ribbon owns yet, on the display it is on. The AX
    /// sweep runs off the main thread: one slow app would otherwise stall a
    /// desktop switch for every display.
    private func discoverWindows(pids: [Int32]? = nil, only wid: WindowID? = nil) {
        let pidList = pids ?? WindowDiscovery.regularAppPIDs()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = pidList.flatMap { WindowDiscovery.windows(of: $0) }.filter { wid == nil || $0.wid == wid }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.file(found) }
            }
        }
    }

    private func file(_ found: [WindowDiscovery.Found]) {
        let separate = SystemChecks.displaysHaveSeparateSpaces()
        var touched: Set<WorkspaceKey> = []
        for window in found where !coordinator.isRegistered(window.wid) && !floating.contains(window.wid) {
            let app = NSRunningApplication(processIdentifier: window.pid)
            let matching = config.rules.filter {
                $0.matches(app: app?.localizedName, title: window.title, bundleID: app?.bundleIdentifier)
            }
            // Matching rules combine; the first to say something about a property wins.
            let ruleSpace = launchSweepDone ? matching.compactMap(\.space).first.flatMap(resolveDesktop) : nil
            if matching.compactMap(\.manage).first == false {
                // Floating, but still sent to its desktop, as weft does.
                if let (_, target) = ruleSpace { _ = NativeBridge.move([window.wid], to: target) }
                floating.insert(window.wid)
                continue
            }
            guard var key = homeKey(for: window.wid, separateSpaces: separate) else { continue }
            if let (m, target) = ruleSpace {
                let wanted = WorkspaceKey(space: target, display: m.uuid)
                if wanted != key, target == key.space || NativeBridge.move([window.wid], to: target).verdict.complete {
                    key = wanted
                }
            }
            workspace(key).strip.insertWindow(window.wid, asNewColumn: true, width: newColumnWidth)
            coordinator.register(windowID: window.wid, pid: window.pid, element: window.element)
            onWindowManaged?(window.wid, window.pid)
            touched.insert(key)
        }
        for key in touched {
            reveal(key)
            commit(key)
        }
        if !touched.isEmpty { changed() }
    }

    /// The ribbon a window belongs on: its desktop, and the display that
    /// desktop is on (or, when displays share Spaces, the one holding it).
    private func homeKey(for wid: WindowID, separateSpaces: Bool) -> WorkspaceKey? {
        let spaces = SpaceControl.spacesForWindow(wid)
        guard spaces.count <= 1 else { return nil } // sticky: on every desktop, owned by none
        var m: Monitor?
        if separateSpaces, let sid = spaces.first {
            m = monitors.first { $0.desktops.contains(sid) }
        }
        if m == nil, let frame = WorldReader.frame(of: wid),
           let idx = DisplayGeometry.display(containing: frame, in: monitors.map(\.bounds)) {
            m = monitors[idx]
        }
        guard let m else { return nil }
        let space = spaces.first ?? m.current
        guard m.desktops.contains(space) else { return nil } // a fullscreen app's space
        return WorkspaceKey(space: space, display: m.uuid)
    }

    /// Initial sweep at launch. Rules that send windows to a desktop wait
    /// for windows opened after it, so launching never rearranges desktops.
    func discoverAll() {
        discoverWindows()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.launchSweepDone = true }
    }

    func windowCount() -> Int {
        workspaces.values.reduce(0) { $0 + $1.strip.columns.reduce(0) { $0 + $1.windowIds.count } }
    }

    func handleWindowCreated(pid: Int32, wid: WindowID?) {
        guard pid != WindowDiscovery.shuttlePID else { return }
        discoverWindows(pids: [pid], only: wid)
    }

    func handleAppLaunched(pid: Int32) {
        // A launching app's first window often lands after its launch
        // notification; look again once it has had a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.handleWindowCreated(pid: pid, wid: nil)
        }
    }

    /// Closed or minimized, on any display or desktop.
    func handleWindowDestroyed(wid: WindowID) {
        floating.remove(wid)
        draggedByUser.remove(wid)
        guard coordinator.isRegistered(wid) else { return }
        coordinator.unregister(windowID: wid)
        reasserted.removeValue(forKey: wid)
        removeFromRibbons([wid])
    }

    /// Takes the focused window off its ribbon and centers it, or puts a
    /// floating window back.
    func toggleFloat() -> String {
        if let (m, key, ws) = current, let wid = ws.strip.focusedWindowId,
           let pid = coordinator.pid(of: wid), let element = coordinator.element(of: wid) {
            // Is the frontmost window this one, or a floating one in front of it?
            let front = NSWorkspace.shared.frontmostApplication.flatMap { WindowDiscovery.focusedWindow(of: $0.processIdentifier) }
            if front == nil || front?.0 == wid {
                floating.insert(wid)
                coordinator.unregister(windowID: wid)
                mutate(key) { $0.removeWindow(wid) }
                let vp = m.viewport
                let frame = Frame(x: vp.x + vp.width / 6, y: vp.y + vp.height / 6, width: vp.width * 2 / 3, height: vp.height * 2 / 3)
                coordinator.place(element, pid: pid, frame: frame)
                return "OK: Floating window \(wid)"
            }
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              let (wid, _) = WindowDiscovery.focusedWindow(of: app.processIdentifier),
              floating.contains(wid)
        else { return "ERR: No window to float or tile" }
        floating.remove(wid)
        discoverWindows(pids: [app.processIdentifier], only: wid)
        return "OK: Tiling window \(wid)"
    }

    func handleAppTerminated(pid: Int32) {
        let wids = coordinator.windows(ownedBy: pid)
        guard !wids.isEmpty else { return }
        wids.forEach(coordinator.unregister(windowID:))
        removeFromRibbons(wids)
    }

    private func removeFromRibbons(_ wids: [WindowID]) {
        for (key, ws) in workspaces {
            guard ws.strip.columns.contains(where: { $0.windowIds.contains(where: wids.contains) }) else { continue }
            mutate(key) { strip in
                wids.forEach { _ = strip.removeWindow($0) }
                return true
            }
        }
        changed()
    }

    func handleWindowFocused(wid: WindowID?) {
        // Closing a window moves focus to another one; that is often the only
        // sign of the close an app gives.
        pruneClosedWindows()
        guard let wid else { return }
        follow(focusTo: wid)
    }

    /// Clicking another app's window raises no AX focus event, only an
    /// activation; read its focused window.
    func handleAppActivated(pid: Int32) {
        pruneClosedWindows()
        guard let (wid, _) = WindowDiscovery.focusedWindow(of: pid) else { return }
        follow(focusTo: wid)
    }

    /// Focus moved to `wid` by something outside Shuttle: that display has
    /// focus now, and its ribbon scrolls to the window.
    private func follow(focusTo wid: WindowID) {
        guard let key = location(of: wid), isVisible(key) else { return }
        let displayChanged = focusedDisplay != key.display
        focusedDisplay = key.display
        let strip = workspace(key).strip
        guard let (colIdx, _) = strip.column(forWindowID: wid),
              strip.focusedColumnIndex != colIdx || strip.focusedWindowId != wid
        else {
            if displayChanged { changed() }
            return
        }
        mutate(key) { strip in
            strip.focusColumn(at: colIdx)
            strip.focusedWindowId = wid
            return true
        }
    }

    /// A window moved or resized. Ours echo back here too, so the check runs
    /// once things are quiet.
    func handleWindowGeometryChanged(wid: WindowID) {
        // A left button down outside a ribbon drag is a hand on the window.
        if NSEvent.pressedMouseButtons & 1 != 0, dragKey == nil, coordinator.isRegistered(wid) {
            draggedByUser.insert(wid)
        }
        geometryChecks[wid]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.checkGeometry(wid) }
        }
        geometryChecks[wid] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
    }

    private func checkGeometry(_ wid: WindowID) {
        geometryChecks.removeValue(forKey: wid)
        guard !missionControlOpen else { return }

        guard coordinator.isRegistered(wid) else {
            // Back from native fullscreen, or de-minimized: tile it again.
            if let pid = WindowDiscovery.owner(of: wid) { discoverWindows(pids: [pid], only: wid) }
            return
        }
        guard let key = location(of: wid), isVisible(key) else { return }

        // Still being dragged: look again when the button is up.
        if NSEvent.pressedMouseButtons != 0 {
            handleWindowGeometryChanged(wid: wid)
            return
        }

        // Native fullscreen gives the window a Space of its own. It floats
        // until it comes back.
        if let el = coordinator.element(of: wid) {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, "AXFullScreen" as CFString, &value) == .success,
               let fullscreen = value as? Bool, fullscreen {
                handleWindowDestroyed(wid: wid)
                return
            }
        }

        let ws = workspace(key)
        // Our own frames still landing: judge once they have.
        if coordinator.isWriting(wid) {
            handleWindowGeometryChanged(wid: wid)
            return
        }
        let byUser = draggedByUser.remove(wid) != nil
        guard ws.scroller.isSettled,
              let actual = WorldReader.frame(of: wid),
              let wanted = coordinator.requestedFrame(of: wid)
        else { return }
        let off = abs(actual.x - wanted.x) + abs(actual.y - wanted.y)
            + abs(actual.width - wanted.width) + abs(actual.height - wanted.height)
        guard off > 4 else { return }

        // Dropped on another display: it joins that display's ribbon.
        if let idx = DisplayGeometry.display(containing: actual, in: monitors.map(\.bounds)),
           monitors[idx].uuid != key.display, let targetKey = monitors[idx].currentKey {
            if targetKey.space != key.space {
                // macOS files a window on the desktop of the display it is dropped on.
                guard SpaceControl.spacesForWindow(wid).contains(targetKey.space) else { return }
            }
            coordinator.invalidate(windowID: wid)
            mutate(key) { $0.removeWindow(wid) }
            focusedDisplay = targetKey.display
            let width = newColumnWidth
            mutate(targetKey) { strip in
                strip.insertWindow(wid, asNewColumn: true, width: width)
                return true
            }
            return
        }

        if byUser {
            // An edge dragged: the column takes the new width, as in niri.
            // A title bar dragged: the window goes back into its slot.
            let strip = ws.strip
            if abs(actual.width - wanted.width) > 4, let (colIdx, column) = strip.column(forWindowID: wid),
               !strip.isFullscreen(column), let m = monitor(key.display) {
                let width = min(max(actual.width, 150), ribbonWidth(m))
                mutate(key) { strip in
                    strip.focusColumn(at: colIdx)
                    strip.columns[colIdx].width = .fixed(width)
                    return true
                }
            }
            coordinator.invalidate(windowID: wid)
            commit(key)
            return
        }

        // Moved or resized by the app itself: back into its slot, once per
        // slot, so an app that insists on its own size is not fought.
        guard reasserted[wid] != wanted else { return }
        reasserted[wid] = wanted
        coordinator.invalidate(windowID: wid)
        commit(key)
    }

    func handleDisplayChanged() {
        let before = Set(monitors.map(\.uuid))
        refreshMonitors()
        let after = Set(monitors.map(\.uuid))
        // A display that went away took its ribbons; macOS moved its windows
        // to the displays that are left. Let discovery file them there.
        for (key, ws) in workspaces where !after.contains(key.display) {
            for wid in ws.strip.columns.flatMap(\.windowIds) { coordinator.unregister(windowID: wid) }
            workspaces.removeValue(forKey: key)
        }
        animator.screenChanged()
        if before != after { print("🖥️  Displays now: \(monitors.map(\.name).joined(separator: ", "))") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.refreshMonitors()
            self.discoverWindows()
            for m in self.monitors {
                guard let key = m.currentKey, self.workspaces[key] != nil else { continue }
                self.reveal(key)
                self.commit(key)
            }
            self.changed()
        }
    }

    func handleMissionControl(open: Bool) {
        missionControlOpen = open
        if !open {
            // Windows may have been dragged between desktops under it.
            handleSpaceChanged()
            discoverWindows()
            commitVisible()
            changed()
        }
    }

    /// Puts everything back in order: forgets closed windows, files missed
    /// ones, re-reads displays and desktops, and rewrites every frame from its
    /// column, including windows an app was allowed to keep resizing.
    /// `resetWidths` also returns every column to the default width and
    /// leaves fullscreen.
    func refresh(resetWidths: Bool) -> String {
        refreshMonitors()
        pruneVanishedDesktops()
        animator.screenChanged()

        let gone = pruneClosedWindows()
        reasserted.removeAll()
        draggedByUser.removeAll()

        var windows = 0
        for ws in workspaces.values {
            if resetWidths {
                for i in ws.strip.columns.indices { ws.strip.columns[i].width = newColumnWidth }
                ws.strip.fullscreenWindowId = nil
            }
            for wid in ws.strip.columns.flatMap(\.windowIds) {
                coordinator.invalidate(windowID: wid)
                windows += 1
            }
        }
        for m in monitors {
            guard let key = m.currentKey, workspaces[key] != nil else { continue }
            reveal(key)
            commit(key)
        }
        discoverWindows()
        changed()
        let closed = gone.isEmpty ? "" : ", forgot \(gone.count) closed"
        return "OK: Refreshed \(windows) windows on \(monitors.count) display\(monitors.count == 1 ? "" : "s")\(closed)\(resetWidths ? ", widths reset" : "")"
    }

    /// Drops every window the WindowServer no longer has: closed without a
    /// close notification reaching Shuttle (some apps send none, and windows
    /// filed before they were watched never had one). Cheap: one window-list
    /// read for all of them, no app IPC.
    @discardableResult
    func pruneClosedWindows() -> [WindowID] {
        let tracked = workspaces.values.flatMap { $0.strip.columns.flatMap(\.windowIds) }
        guard let alive = WindowDiscovery.living(tracked + Array(floating)) else { return [] }
        floating = floating.filter(alive.contains)
        let gone = tracked.filter { !alive.contains($0) }
        guard !gone.isEmpty else { return [] }
        print("🧹 Forgot \(gone.count) closed window\(gone.count == 1 ? "" : "s")")
        gone.forEach { wid in
            coordinator.unregister(windowID: wid)
            reasserted.removeValue(forKey: wid)
            draggedByUser.remove(wid)
        }
        removeFromRibbons(gone)
        return gone
    }

    /// Hands every window back on screen before exit.
    func releaseWindows() {
        coordinator.releaseAll(into: monitors.map { ($0.viewport, $0.bounds) })
    }

    // MARK: - Status

    func status() -> StatusSnapshot {
        func appName(_ wid: WindowID?) -> String? {
            wid.flatMap { coordinator.pid(of: $0) }.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName }
        }
        let monitorStatus = monitors.map { m -> StatusSnapshot.Monitor in
            let ws = m.currentKey.flatMap { workspaces[$0] }
            return .init(
                uuid: m.uuid, name: m.name, isMain: m.isMain, isFocused: m.uuid == focusedDisplay, bounds: m.bounds,
                desktopIndex: m.desktops.contains(m.current) ? desktopNumber(of: m.current) : nil,
                desktops: m.desktops.map { sid in
                    let n = desktopNumber(of: sid) ?? 0
                    return .init(
                        index: n, label: config.label(ofDesktop: n), spaceID: sid,
                        windows: workspaces[WorkspaceKey(space: sid, display: m.uuid)].map {
                            $0.strip.columns.reduce(0) { $0 + $1.windowIds.count }
                        },
                        isCurrent: sid == m.current
                    )
                },
                columns: ws?.strip.columns.count ?? 0,
                focusedColumnIndex: ws?.strip.focusedColumnIndex ?? 0,
                focusedApp: appName(ws?.strip.focusedWindowId)
            )
        }
        let focused = current
        let strip = focused?.ws.strip ?? Strip()
        let fm = focusedMonitor
        return StatusSnapshot(
            activeSpaceID: fm?.current ?? 0,
            spaceIndex: fm.flatMap { m in m.desktops.contains(m.current) ? desktopNumber(of: m.current) : nil },
            spaceCount: numberedDesktops.count,
            desktops: monitorStatus.first(where: \.isFocused)?.desktops ?? [],
            columns: strip.columns.count,
            focusedColumnIndex: strip.focusedColumnIndex,
            focusedWindowId: strip.focusedWindowId ?? 0,
            focusedApp: appName(strip.focusedWindowId),
            windowsInFocusedColumn: strip.focusedColumn?.windowIds.count ?? 0,
            fullscreen: strip.fullscreenWindowId != nil,
            currentOffset: focused?.ws.scroller.currentOffset ?? 0,
            targetOffset: focused?.ws.scroller.targetOffset ?? 0,
            isSettled: focused?.ws.scroller.isSettled ?? true,
            totalRibbonWidth: fm.map { strip.totalWidth(viewportWidth: ribbonWidth($0), gap: gap) } ?? 0,
            viewport: .init(width: fm?.viewport.width ?? 0, height: fm?.viewport.height ?? 0),
            monitors: monitorStatus,
            separateSpaces: SystemChecks.displaysHaveSeparateSpaces(),
            centerMode: config.centerFocusedColumn.rawValue,
            paused: missionControlOpen
        )
    }

    // MARK: - Commands

    /// Short aliases for `shuttlectl`, mapped to their canonical command.
    private static let aliases: [String: String] = [
        "focus-left": "column focus-left", "left": "column focus-left", "west": "column focus-left",
        "focus-right": "column focus-right", "right": "column focus-right", "east": "column focus-right",
        "move-left": "column move-left", "move-right": "column move-right",
        "preset": "column preset", "cycle": "column preset",
        "maximize": "column maximize",
        "fullscreen": "window fullscreen",
        "expand": "column expand", "shrink": "column shrink", "center": "column center",
        "consume-left": "column consume-left", "consume-right": "column consume-right",
        "focus-up": "window focus-up", "up": "window focus-up", "north": "window focus-up",
        "focus-down": "window focus-down", "down": "window focus-down", "south": "window focus-down",
        "move-up": "window move-up", "move-down": "window move-down", "split": "window split",
    ]

    func handleCommand(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts = trimmed.split(separator: " ").map(String.init)
        guard let first = parts.first else { return "ERR: Empty command" }
        if let canonical = Self.aliases[first] {
            parts = canonical.split(separator: " ").map(String.init) + parts.dropFirst()
        }
        let verb = parts[0]
        let sub = parts.dropFirst().first ?? ""

        switch verb {
        case "stop", "quit", "exit":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.onShutdown?() }
            return "OK: Shutting down shuttled daemon..."

        case "refresh", "retile":
            return refresh(resetWidths: sub == "reset")

        case "reload":
            onReloadRequested?()
            return "OK: Reloaded \(ShuttleConfig.defaultConfigFileURL().path)"

        case "space":
            guard parts.count >= 3 else {
                return "ERR: Usage: space focus <N|label|next|prev|recent> or space move-window <N|label> [--follow]"
            }
            switch sub {
            case "focus": return focusDesktop(parts[2])
            case "move-window", "move": return moveFocusedWindow(toDesktop: parts[2], follow: parts.contains("--follow"))
            default: return "ERR: Unknown space action '\(sub)'"
            }

        case "app":
            guard parts.count >= 3, sub == "toggle" else { return "ERR: Usage: app toggle <bundle-id>" }
            return toggleApp(parts[2])

        case "mode":
            return "ERR: Modes are switched from the keyboard (bind a chord to \"mode \(sub)\")"

        case "monitor", "display":
            guard parts.count >= 3, let direction = DisplayDirection(rawValue: parts[2] == "cycle" ? "next" : parts[2]) else {
                return "ERR: Usage: monitor focus|move-window|move-column left|right|up|down|next|prev"
            }
            switch sub {
            case "focus": return focusMonitor(direction)
            case "move-window": return moveToMonitor(direction, wholeColumn: false)
            case "move-column", "move": return moveToMonitor(direction, wholeColumn: true)
            default: return "ERR: Unknown monitor action '\(sub)'"
            }

        case "window":
            return windowCommand(sub)

        case "column", "focus":
            return columnCommand(sub, amount: parts.count > 2 ? Double(parts[2]) : nil)

        case "pan", "fling", "snap", "scroll":
            return gestureCommand(verb, parts.dropFirst().first)

        case "status":
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(status()), let json = String(data: data, encoding: .utf8) else {
                return "ERR: Could not encode status"
            }
            return json

        default:
            return "ERR: Unknown command '\(trimmed)'"
        }
    }

    private func gestureCommand(_ verb: String, _ arg: String?) -> String {
        guard let (m, key, ws) = current else { return "ERR: No desktop showing" }
        let width = ribbonWidth(m)
        switch verb {
        case "pan":
            guard let delta = arg.flatMap(Double.init) else { return "ERR: Usage: pan <delta>" }
            ws.scroller.pan(delta: delta, in: ws.strip, viewportWidth: width, gap: gap)
            commit(key)
            return "OK: Panned \(delta)"
        case "fling":
            guard let vel = arg.flatMap(Double.init) else { return "ERR: Usage: fling <velocity>" }
            ws.scroller.fling(initialVelocity: vel, in: &ws.strip, viewportWidth: width, gap: gap)
            commit(key)
            changed()
            return "OK: Flung with velocity \(vel)"
        case "snap":
            let ok = ws.scroller.snapToNearest(in: &ws.strip, viewportWidth: width, gap: gap)
            commit(key)
            changed()
            return ok ? "OK: Snapped to column \(ws.strip.focusedColumnIndex)" : "ERR: No columns to snap to"
        default:
            guard let delta = arg.flatMap(Double.init) else { return "ERR: Usage: scroll <delta>" }
            ws.scroller.scroll(by: delta)
            commit(key)
            return "OK: Scrolled by \(delta)"
        }
    }

    private func windowCommand(_ sub: String) -> String {
        let focusedWid = { self.current?.ws.strip.focusedWindowId ?? 0 }
        switch sub {
        case "focus-up", "up", "north":
            return mutate(reveal: false, raise: true) { $0.focusUp() }
                ? "OK: Focused window \(focusedWid())" : "ERR: Already at top of column"
        case "focus-down", "down", "south":
            return mutate(reveal: false, raise: true) { $0.focusDown() }
                ? "OK: Focused window \(focusedWid())" : "ERR: Already at bottom of column"
        case "move-up":
            return mutate(reveal: false) { $0.moveFocusedWindowUp() } ? "OK: Moved window up" : "ERR: Cannot move top window up"
        case "move-down":
            return mutate(reveal: false) { $0.moveFocusedWindowDown() } ? "OK: Moved window down" : "ERR: Cannot move bottom window down"
        case "split":
            let width = newColumnWidth
            return mutate { $0.splitFocusedWindowIntoNewColumn(width: width) }
                ? "OK: Split window into new column" : "ERR: Column only has one window"
        case "float":
            return toggleFloat()
        case "fullscreen":
            guard mutate(raise: true, { $0.toggleFullscreenFocusedWindow() }) else { return "ERR: No window focused" }
            return current?.ws.strip.fullscreenWindowId == nil ? "OK: Left fullscreen" : "OK: Fullscreen"
        default:
            return "ERR: Unknown window subcommand '\(sub)'"
        }
    }

    /// Shows an app, hides it if it is already in front, launches it if it is not running.
    private func toggleApp(_ bundleID: String) -> String {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            if app.isActive {
                app.hide()
                return "OK: Hid \(app.localizedName ?? bundleID)"
            }
            app.unhide()
            app.activate()
            return "OK: Showed \(app.localizedName ?? bundleID)"
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return "ERR: No app with bundle id \(bundleID)"
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        return "OK: Launching \(url.deletingPathExtension().lastPathComponent)"
    }

    private func columnCommand(_ sub: String, amount: Double? = nil) -> String {
        guard let (m, key, ws) = current else { return "ERR: No desktop showing" }
        let width = ribbonWidth(m)
        let index = { ws.strip.focusedColumnIndex }
        switch sub {
        case "focus-left", "left", "west":
            return mutate(raise: true) { $0.focusLeft() } ? "OK: Focused column \(index())" : "ERR: Already at leftmost column"
        case "focus-right", "right", "east":
            return mutate(raise: true) { $0.focusRight() } ? "OK: Focused column \(index())" : "ERR: Already at rightmost column"
        case "move-left", "move west":
            return mutate { $0.moveFocusedColumnLeft() } ? "OK: Moved column left to \(index())" : "ERR: Cannot move leftmost column"
        case "move-right", "move east":
            return mutate { $0.moveFocusedColumnRight() } ? "OK: Moved column right to \(index())" : "ERR: Cannot move rightmost column"
        case "consume-left":
            return mutate { $0.consumeAdjacentColumnIntoStack(toRight: false) }
                ? "OK: Consumed left column into stack" : "ERR: No left column to consume"
        case "consume-right":
            return mutate { $0.consumeAdjacentColumnIntoStack(toRight: true) }
                ? "OK: Consumed right column into stack" : "ERR: No right column to consume"
        case "center":
            guard ws.strip.focusedColumn != nil else { return "ERR: No column focused" }
            ws.scroller.centerColumn(at: ws.strip.focusedColumnIndex, in: ws.strip, viewportWidth: width, gap: gap)
            commit(key)
            return "OK: Centered column \(index())"
        default:
            break
        }

        // Width changes: leave fullscreen first, or the change is invisible.
        let resize: ((inout Strip) -> Void)?
        switch sub {
        case "preset", "cycle": resize = { $0.cycleColumnWidthPreset(viewportWidth: width) }
        case "maximize": resize = { $0.toggleMaximizeColumn(viewportWidth: width) }
        case "expand": resize = { $0.expandFocusedColumn(by: amount ?? 0.1, viewportWidth: width) }
        case "shrink": resize = { $0.shrinkFocusedColumn(by: amount ?? 0.1, viewportWidth: width) }
        default: resize = nil
        }
        guard let resize else { return "ERR: Unknown column subcommand '\(sub)'" }
        return mutate { strip in
            guard let column = strip.focusedColumn else { return false }
            if strip.isFullscreen(column) { strip.fullscreenWindowId = nil }
            resize(&strip)
            return true
        } ? "OK: Column \(index()) is now \(sub == "maximize" ? "toggled" : "resized")" : "ERR: No column focused"
    }
}
