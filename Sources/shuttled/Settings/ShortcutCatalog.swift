import AppKit
import WeftInput

/// Commands a binding can run, with the names Settings shows for them.
struct ShuttleAction: Identifiable, Hashable {
    enum Group: String, CaseIterable {
        case columns = "Columns"
        case windows = "Windows in a Column"
        case displays = "Displays"
        case desktops = "Desktops"
        case other = "Other"
    }

    let command: String
    let title: String
    let group: Group
    var id: String { command }

    /// Every command Settings can name, desktops by number and by label.
    static func catalog(labels: [String]) -> [ShuttleAction] {
        var actions: [ShuttleAction] = [
            .init(command: "column focus-left", title: "Focus column left", group: .columns),
            .init(command: "column focus-right", title: "Focus column right", group: .columns),
            .init(command: "column move-left", title: "Move column left", group: .columns),
            .init(command: "column move-right", title: "Move column right", group: .columns),
            .init(command: "column preset", title: "Cycle column width", group: .columns),
            .init(command: "column maximize", title: "Maximize column (full width, gaps kept)", group: .columns),
            .init(command: "column expand", title: "Widen column", group: .columns),
            .init(command: "column shrink", title: "Narrow column", group: .columns),
            .init(command: "column center", title: "Center column", group: .columns),
            .init(command: "column consume-left", title: "Pull left column into stack", group: .columns),
            .init(command: "column consume-right", title: "Pull right column into stack", group: .columns),
            .init(command: "window focus-up", title: "Focus window above", group: .windows),
            .init(command: "window focus-down", title: "Focus window below", group: .windows),
            .init(command: "window move-up", title: "Move window up", group: .windows),
            .init(command: "window move-down", title: "Move window down", group: .windows),
            .init(command: "window split", title: "Split window into its own column", group: .windows),
            .init(command: "window fullscreen", title: "Toggle fullscreen", group: .windows),
            .init(command: "window float", title: "Float or tile window", group: .windows),
        ]
        for direction in ["left", "right", "up", "down", "next", "prev"] {
            actions.append(.init(command: "monitor focus \(direction)", title: "Focus display \(direction)", group: .displays))
        }
        for direction in ["left", "right", "up", "down", "next", "prev"] {
            actions.append(.init(command: "monitor move-column \(direction)", title: "Move column to display \(direction)", group: .displays))
        }
        for direction in ["left", "right", "up", "down"] {
            actions.append(.init(command: "monitor move-window \(direction)", title: "Move window to display \(direction)", group: .displays))
        }
        actions += [
            .init(command: "space focus recent", title: "Back to previous desktop", group: .desktops),
            .init(command: "space focus next", title: "Next desktop on this display", group: .desktops),
            .init(command: "space focus prev", title: "Previous desktop on this display", group: .desktops),
        ]
        for i in 1...9 {
            let name = labels.indices.contains(i - 1) ? " (\(labels[i - 1]))" : ""
            actions.append(.init(command: "space focus \(i)", title: "Go to desktop \(i)\(name)", group: .desktops))
        }
        for label in labels where !label.isEmpty {
            actions.append(.init(command: "space focus \(label)", title: "Go to “\(label)”", group: .desktops))
        }
        for i in 1...9 {
            let name = labels.indices.contains(i - 1) ? " (\(labels[i - 1]))" : ""
            actions.append(.init(command: "space move-window \(i)", title: "Send window to desktop \(i)\(name)", group: .desktops))
        }
        for label in labels where !label.isEmpty {
            actions.append(.init(command: "space move-window \(label)", title: "Send window to “\(label)”", group: .desktops))
        }
        actions.append(.init(command: "refresh", title: "Refresh layout (put every window back)", group: .other))
        actions.append(.init(command: "refresh reset", title: "Refresh and reset column widths", group: .other))
        actions.append(.init(command: "reload", title: "Reload config", group: .other))
        actions.append(.init(command: "mode resize", title: "Enter resize mode", group: .other))
        return actions
    }

    /// A command's name in Settings, also for ones only written in the file.
    static func named(_ command: String, labels: [String] = []) -> ShuttleAction {
        if let known = catalog(labels: labels).first(where: { $0.command == command }) { return known }
        let parts = command.split(separator: " ").map(String.init)
        if parts.count == 3, parts[0] == "app", parts[1] == "toggle" {
            let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: parts[2])?
                .deletingPathExtension().lastPathComponent ?? parts[2]
            return .init(command: command, title: "Show or hide \(name)", group: .other)
        }
        return .init(command: command, title: command, group: .other)
    }
}

/// Converting between config chords (`alt-shift-h`), key presses and the
/// glyphs macOS menus use (⌥⇧H).
enum ChordFormat {
    private static let keyNames: [String] =
        (97...122).map { String(UnicodeScalar($0)!) } + (0...9).map(String.init) + [
            "minus", "equal", "bracketleft", "bracketright", "semicolon", "quote", "comma",
            "period", "slash", "backslash", "grave", "space", "tab", "return", "delete",
            "escape", "left", "right", "down", "up",
        ]

    /// Hardware keycode → config key name, built from weft's own parser so the
    /// two can never disagree.
    private static let nameByKeycode: [Int64: String] = {
        var out: [Int64: String] = [:]
        for name in keyNames {
            if let chord = try? parseChord(name) { out[chord.keycode] = name }
        }
        return out
    }()

    private static let glyphs: [String: String] = [
        "minus": "-", "equal": "=", "bracketleft": "[", "bracketright": "]", "semicolon": ";",
        "quote": "'", "comma": ",", "period": ".", "slash": "/", "backslash": "\\", "grave": "`",
        "space": "Space", "tab": "⇥", "return": "↩", "delete": "⌫", "escape": "⎋",
        "left": "←", "right": "→", "down": "↓", "up": "↑",
    ]

    static func isValid(_ chord: String) -> Bool {
        (try? parseChord(chord)) != nil
    }

    /// `alt-shift-h` → `⌃⌥⇧⌘H` order, as menus draw it.
    static func display(_ chord: String) -> String {
        let parts = chord.lowercased().split(separator: "-").map(String.init)
        guard let key = parts.last else { return chord }
        let mods = Set(parts.dropLast())
        var out = ""
        if mods.contains("ctrl") || mods.contains("control") { out += "⌃" }
        if mods.contains("alt") || mods.contains("opt") { out += "⌥" }
        if mods.contains("shift") { out += "⇧" }
        if mods.contains("cmd") || mods.contains("command") { out += "⌘" }
        return out + (glyphs[key] ?? key.uppercased())
    }

    /// A key press as a config chord, or nil for a key Shuttle cannot bind.
    static func chord(from event: NSEvent) -> String? {
        guard let key = nameByKeycode[Int64(event.keyCode)] else { return nil }
        let flags = event.modifierFlags
        var parts: [String] = []
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.option) { parts.append("alt") }
        if flags.contains(.shift) { parts.append("shift") }
        if flags.contains(.command) { parts.append("cmd") }
        // A chord with no modifier would swallow that key in every app.
        guard !parts.isEmpty else { return nil }
        return (parts + [key]).joined(separator: "-")
    }
}
