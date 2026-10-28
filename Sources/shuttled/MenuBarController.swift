import AppKit
import ShuttleCore

/// The status item: which desktop is showing and where focus sits on its
/// ribbon, at a glance; the menu adds the rest.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var lastRendered: (StatusSnapshot?, Bool, Bool, String)?
    private var flashText: String?
    /// The key table in use; anything but "default" shows in the menu bar.
    var mode = "default"

    var status: (() -> StatusSnapshot?)?
    var config: (() -> ShuttleConfig)?
    var runCommand: ((String) -> Void)?
    /// Switch a display (by uuid) to its Nth desktop.
    var focusDesktop: ((String, Int) -> Void)?
    var openSettings: (() -> Void)?
    var reloadConfig: (() -> Void)?
    var configWarnings: (() -> [String])?
    var quit: (() -> Void)?

    override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.toolTip = "Shuttle"
        refresh()
    }

    /// Shown before Accessibility is granted, when there is nothing to report.
    func showWaitingForPermission() {
        statusItem.button?.image = NSImage(systemSymbolName: "lock.rectangle.stack", accessibilityDescription: "Shuttle")
        statusItem.button?.title = ""
        statusItem.button?.toolTip = "Shuttle needs Accessibility permission"
    }

    // MARK: - Button

    func refresh() {
        let snapshot = status?()
        let cfg = config?() ?? .default
        let key = (snapshot, cfg.menuBarShowsSpace, cfg.menuBarShowsColumns, mode + (flashText ?? ""))
        if let last = lastRendered, last.0 == key.0, last.1 == key.1, last.2 == key.2, last.3 == key.3 { return }
        lastRendered = key

        guard let button = statusItem.button else { return }
        guard let s = snapshot else {
            button.image = NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: "Shuttle")
            button.title = ""
            return
        }

        if cfg.menuBarShowsColumns {
            button.image = Self.ribbonImage(columns: s.columns, focused: s.focusedColumnIndex)
        } else {
            button.image = NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: "Shuttle")
        }
        var title = ""
        if cfg.menuBarShowsSpace, let index = s.spaceIndex {
            // A named desktop shows its name; others their number.
            title = " " + (cfg.label(ofDesktop: index) ?? "\(index)")
        }
        if mode != "default" { title += " · \(mode.uppercased())" }
        if let flashText { title += " \(flashText)" }
        button.title = title
        button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        button.toolTip = (["Shuttle"] + s.monitors.map { m in
            let desk = m.desktopIndex.map { "desktop \($0)" } ?? "fullscreen app"
            let cols = m.columns > 0 ? ", column \(m.focusedColumnIndex + 1) of \(m.columns)" : ""
            return "\(m.isFocused ? "▸ " : "  ")\(m.name): \(desk)\(cols)"
        }).joined(separator: "\n")
    }

    /// Shows `text` beside the desktop for a moment: the answer to a reload.
    func flash(_ text: String) {
        flashText = text
        refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated {
                self?.flashText = nil
                self?.refresh()
            }
        }
    }

    /// One block per column (up to 7), the focused one filled. A template
    /// image, so it follows the menu bar's light and dark appearance.
    static func ribbonImage(columns: Int, focused: Int) -> NSImage {
        let maxShown = 7
        let shown = max(1, min(columns, maxShown))
        let blockW: CGFloat = 4, blockH: CGFloat = 12, spacing: CGFloat = 2
        let width = CGFloat(shown) * blockW + CGFloat(shown - 1) * spacing + (columns > maxShown ? 4 : 0)
        let size = NSSize(width: max(width, blockW), height: 16)

        // Keep the focused block on screen when there are more columns than blocks.
        let firstShown = max(0, min(focused - maxShown / 2, columns - maxShown))
        let image = NSImage(size: size, flipped: false) { _ in
            let y = (size.height - blockH) / 2
            for i in 0..<shown {
                let rect = NSRect(x: CGFloat(i) * (blockW + spacing), y: y, width: blockW, height: blockH)
                let path = NSBezierPath(roundedRect: rect, xRadius: 1.2, yRadius: 1.2)
                NSColor.black.setFill()
                NSColor.black.setStroke()
                if columns == 0 {
                    path.lineWidth = 1
                    path.stroke()
                } else if firstShown + i == focused {
                    path.fill()
                } else {
                    NSColor.black.withAlphaComponent(0.35).setFill()
                    path.fill()
                }
            }
            if columns > maxShown {
                let dot = NSRect(x: size.width - 2, y: size.height / 2 - 1, width: 2, height: 2)
                NSColor.black.setFill()
                NSBezierPath(ovalIn: dot).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Column \(focused + 1) of \(columns)"
        return image
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = status?()

        if let s {
            if s.monitors.count > 1 {
                for m in s.monitors {
                    addMonitorSection(m, multiple: true)
                }
            } else if let m = s.monitors.first {
                addMonitorSection(m, multiple: false)
            }
            if s.monitors.count > 1 && !s.separateSpaces {
                menu.addItem(.separator())
                menu.addItem(Self.info("⚠︎ Turn on “Displays have separate Spaces”"))
                menu.addItem(Self.info("   for a set of desktops per display"))
            }
            if s.paused { menu.addItem(Self.info("Paused while Mission Control is open")) }
        } else {
            menu.addItem(Self.info("Waiting for Accessibility permission…"))
        }

        menu.addItem(.separator())
        menu.addItem(action("Center Focused Column", "column center"))
        menu.addItem(action("Cycle Column Width", "column preset"))
        menu.addItem(action("Maximize Column", "column maximize"))
        menu.addItem(action("Toggle Fullscreen", "window fullscreen"))
        let refresh = NSMenuItem(title: "Refresh Layout", action: #selector(runAction(_:)), keyEquivalent: "")
        refresh.target = self
        refresh.representedObject = "refresh"
        refresh.toolTip = "Put every window back into its column (⌥⇧0)"
        menu.addItem(refresh)

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let reload = NSMenuItem(title: "Reload Config", action: #selector(reload), keyEquivalent: "")
        reload.target = self
        menu.addItem(reload)
        let warnings = configWarnings?() ?? []
        if !warnings.isEmpty {
            let item = NSMenuItem(title: "⚠︎ \(warnings.count) config problem\(warnings.count == 1 ? "" : "s")", action: #selector(showSettings), keyEquivalent: "")
            item.target = self
            item.toolTip = warnings.joined(separator: "\n")
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(Self.info(ShuttleVersion.full))
        let quitItem = NSMenuItem(title: "Quit Shuttle", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    /// A display's heading, its focused column, and its desktops to switch to.
    private func addMonitorSection(_ m: StatusSnapshot.Monitor, multiple: Bool) {
        if menu.items.count > 0 { menu.addItem(.separator()) }
        let where_ = m.desktopIndex.map { "Desktop \($0) of \(m.desktops.count)" } ?? "Fullscreen app"
        menu.addItem(Self.header(multiple ? "\(m.name)\(m.isFocused ? " — focused" : "")" : where_))
        if multiple { menu.addItem(Self.info(where_)) }
        let detail = m.columns == 0
            ? "No windows"
            : "Column \(m.focusedColumnIndex + 1) of \(m.columns)" + (m.focusedApp.map { " · \($0)" } ?? "")
        menu.addItem(Self.info(detail))

        guard m.desktops.count > 1 else { return }
        let parent = NSMenuItem(title: "Switch Desktop", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for d in m.desktops {
            let count = d.windows.map { $0 == 1 ? " — 1 window" : " — \($0) windows" } ?? ""
            let name = d.label.map { "\(d.index) · \($0)" } ?? "Desktop \(d.index)"
            let item = NSMenuItem(title: "\(name)\(count)", action: #selector(focusDesktop(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = DesktopTarget(display: m.uuid, index: d.index, focused: m.isFocused)
            item.state = d.isCurrent ? .on : .off
            if d.index <= 9 {
                item.keyEquivalent = "\(d.index)"
                item.keyEquivalentModifierMask = .option
            }
            sub.addItem(item)
        }
        parent.submenu = sub
        menu.addItem(parent)
    }

    private final class DesktopTarget: NSObject {
        let display: String, index: Int, focused: Bool
        init(display: String, index: Int, focused: Bool) {
            self.display = display; self.index = index; self.focused = focused
        }
    }

    private func action(_ title: String, _ command: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = command
        item.isEnabled = (status?()?.columns ?? 0) > 0
        return item
    }

    private static func header(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) {
            return NSMenuItem.sectionHeader(title: title)
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private static func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func runAction(_ sender: NSMenuItem) {
        if let command = sender.representedObject as? String { runCommand?(command) }
    }

    @objc private func focusDesktop(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? DesktopTarget else { return }
        focusDesktop?(target.display, target.index)
    }

    @objc private func showSettings() { openSettings?() }
    @objc private func reload() { reloadConfig?() }
    @objc private func quitApp() { quit?() }
}
