import Foundation

/// How the ribbon scrolls when focus moves to another column.
public enum CenterMode: String, Sendable, CaseIterable {
    /// Every focused column is centered in the viewport.
    case always
    /// Scroll only as far as needed to show the focused column (niri's default).
    case never
}

/// What happens to a matching window when it opens: `[[rule]]` in the config,
/// as in weft. Patterns are regular expressions.
public struct WindowRule: Sendable, Equatable {
    public var app: String?
    public var title: String?
    public var bundleID: String?
    /// Desktop label or number the window is sent to as it opens.
    public var space: String?
    /// `false` floats the window: Shuttle never tiles it.
    public var manage: Bool?

    public init(app: String? = nil, title: String? = nil, bundleID: String? = nil, space: String? = nil, manage: Bool? = nil) {
        self.app = app
        self.title = title
        self.bundleID = bundleID
        self.space = space
        self.manage = manage
    }

    /// Every pattern given matches; a rule with none matches nothing.
    public func matches(app appName: String?, title windowTitle: String?, bundleID bundle: String?) -> Bool {
        guard app != nil || title != nil || bundleID != nil else { return false }
        func ok(_ pattern: String?, _ value: String?) -> Bool {
            guard let pattern else { return true }
            guard let value else { return false }
            return value.range(of: pattern, options: .regularExpression) != nil
        }
        return ok(app, appName) && ok(title, windowTitle) && ok(bundleID, bundle)
    }
}

/// Configuration settings for Shuttle.
public struct ShuttleConfig: Sendable, Equatable {
    public var gap: Double
    public var springOmega: Double
    public var mouseModifier: String
    public var defaultColumnWidth: Double
    public var centerFocusedColumn: CenterMode
    /// A desktop's only column fills the width; a second one brings back
    /// everyone's own width.
    public var fillSingleColumn: Bool
    public var menuBarShowsSpace: Bool
    public var menuBarShowsColumns: Bool
    public var keybindings: [String: String]
    /// Key tables other than the default one (`[mode.resize]`), entered with
    /// a `mode <name>` binding.
    public var modes: [String: [String: String]]
    /// Desktop names in order: the first names desktop 1. Numbering runs
    /// through the main display's desktops, then each other display's.
    public var spaceLabels: [String]
    public var rules: [WindowRule]

    public static let gapRange: ClosedRange<Double> = 0...64
    public static let springOmegaRange: ClosedRange<Double> = 8...60
    public static let columnWidthRange: ClosedRange<Double> = 0.2...1.0
    public static let mouseModifiers = ["alt", "cmd", "ctrl", "shift", "fn"]

    public static let defaultKeybindings: [String: String] = {
        var binds: [String: String] = [
            "alt-h": "column focus-left",
            "alt-l": "column focus-right",
            "alt-left": "column focus-left",
            "alt-right": "column focus-right",
            "alt-k": "window focus-up",
            "alt-j": "window focus-down",
            "alt-up": "window focus-up",
            "alt-down": "window focus-down",
            "alt-shift-h": "column move-left",
            "alt-shift-l": "column move-right",
            "alt-shift-left": "column move-left",
            "alt-shift-right": "column move-right",
            "alt-shift-k": "window move-up",
            "alt-shift-j": "window move-down",
            "alt-shift-up": "window move-up",
            "alt-shift-down": "window move-down",
            "alt-minus": "column shrink",
            "alt-equal": "column expand",
            "alt-r": "column preset",
            "alt-f": "column maximize",
            "alt-shift-f": "window fullscreen",
            "alt-shift-space": "window float",
            "alt-0": "column center",
            "alt-s": "window split",
            "alt-bracketleft": "column consume-left",
            "alt-bracketright": "column consume-right",
            "alt-tab": "space focus recent",
            "alt-grave": "monitor focus next",
            "alt-shift-tab": "monitor move-column next",
            "alt-shift-r": "mode resize",
            "alt-shift-0": "refresh",
            "ctrl-alt-r": "reload",
        ]
        // Displays: ⌃⌥ + direction focuses the neighbouring monitor, with ⇧
        // it takes the focused column along.
        for (key, direction) in [
            ("h", "left"), ("l", "right"), ("k", "up"), ("j", "down"),
            ("left", "left"), ("right", "right"), ("up", "up"), ("down", "down"),
        ] {
            binds["ctrl-alt-\(key)"] = "monitor focus \(direction)"
            binds["ctrl-alt-shift-\(key)"] = "monitor move-column \(direction)"
        }
        for i in 1...9 {
            binds["alt-\(i)"] = "space focus \(i)"
            binds["alt-shift-\(i)"] = "space move-window \(i)"
        }
        return binds
    }()

    public static let defaultModes: [String: [String: String]] = [
        "resize": [
            "h": "column shrink",
            "l": "column expand",
            "minus": "column shrink",
            "equal": "column expand",
            "shift-h": "column shrink 0.2",
            "shift-l": "column expand 0.2",
            "r": "column preset",
            "f": "column maximize",
            "escape": "mode default",
            "return": "mode default",
        ],
    ]

    public static let `default` = ShuttleConfig(
        gap: 16.0,
        springOmega: 26.0,
        mouseModifier: "alt",
        defaultColumnWidth: 0.5,
        keybindings: defaultKeybindings
    )

    public init(
        gap: Double, springOmega: Double, mouseModifier: String, defaultColumnWidth: Double,
        centerFocusedColumn: CenterMode = .always, fillSingleColumn: Bool = false,
        menuBarShowsSpace: Bool = true, menuBarShowsColumns: Bool = true,
        keybindings: [String: String], modes: [String: [String: String]] = defaultModes,
        spaceLabels: [String] = [], rules: [WindowRule] = []
    ) {
        self.gap = gap
        self.springOmega = springOmega
        self.mouseModifier = mouseModifier
        self.defaultColumnWidth = defaultColumnWidth
        self.centerFocusedColumn = centerFocusedColumn
        self.fillSingleColumn = fillSingleColumn
        self.menuBarShowsSpace = menuBarShowsSpace
        self.menuBarShowsColumns = menuBarShowsColumns
        self.keybindings = keybindings
        self.modes = modes
        self.spaceLabels = spaceLabels
        self.rules = rules
    }

    /// Values pulled into the ranges the daemon can honour.
    public var clamped: ShuttleConfig {
        var c = self
        c.gap = min(max(gap, Self.gapRange.lowerBound), Self.gapRange.upperBound)
        c.springOmega = min(max(springOmega, Self.springOmegaRange.lowerBound), Self.springOmegaRange.upperBound)
        c.defaultColumnWidth = min(max(defaultColumnWidth, Self.columnWidthRange.lowerBound), Self.columnWidthRange.upperBound)
        if !Self.mouseModifiers.contains(c.mouseModifier) { c.mouseModifier = Self.default.mouseModifier }
        return c
    }

    /// The 1-based desktop number `label` names, if any.
    public func desktopNumber(forLabel label: String) -> Int? {
        spaceLabels.firstIndex(of: label).map { $0 + 1 }
    }

    /// The label of desktop `number`, if it has one.
    public func label(ofDesktop number: Int) -> String? {
        spaceLabels.indices.contains(number - 1) ? spaceLabels[number - 1] : nil
    }

    // MARK: - Chords

    /// One spelling per chord: modifiers in ⌃⌥⇧⌘ order, then the key.
    /// weft writes `alt-ctrl-h` where Shuttle writes `ctrl-alt-h`; without
    /// this both would be bound, to whichever command came last.
    public static func canonicalChord(_ chord: String) -> String {
        let parts = chord.lowercased().split(separator: "-").map(String.init)
        guard let key = parts.last, parts.count > 1 else { return chord.lowercased() }
        let aliases = ["opt": "alt", "option": "alt", "control": "ctrl", "command": "cmd"]
        let mods = Set(parts.dropLast().map { aliases[$0] ?? $0 })
        let order = ["ctrl", "alt", "shift", "cmd"]
        let known = order.filter(mods.contains)
        let unknown = mods.subtracting(order).sorted()
        return (known + unknown + [key]).joined(separator: "-")
    }

    // MARK: - Files

    public static func defaultConfigFileURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/shuttle/config.toml")
    }

    /// Loads configuration from disk, creating the default config if absent.
    public static func load(from url: URL = defaultConfigFileURL()) -> ShuttleConfig {
        loadReport(from: url).config
    }

    /// `load`, plus every line that was ignored and why.
    public static func loadReport(from url: URL = defaultConfigFileURL()) -> (config: ShuttleConfig, warnings: [String]) {
        let manager = FileManager.default
        let folder = url.deletingLastPathComponent()

        if !manager.fileExists(atPath: folder.path) {
            try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        if !manager.fileExists(atPath: url.path) {
            try? ShuttleConfig.default.serialized().write(to: url, atomically: true, encoding: .utf8)
            return (.default, [])
        }

        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return (.default, ["Could not read \(url.path)"])
        }

        return parseReport(toml: content)
    }

    /// Writes the configuration as TOML. Comments in the old file are not kept.
    public func save(to url: URL = defaultConfigFileURL()) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try serialized().write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Parsing

    /// Parses a simple TOML configuration string.
    public static func parse(toml: String) -> ShuttleConfig {
        parseReport(toml: toml).config
    }

    /// `parse`, plus every line that was ignored and why.
    public static func parseReport(toml: String) -> (config: ShuttleConfig, warnings: [String]) {
        var config = ShuttleConfig.default
        var warnings: [String] = []
        var section = ""
        var currentMode: String?
        var labels: [String] = []
        var rules: [WindowRule] = []

        for (lineNo, rawLine) in toml.components(separatedBy: .newlines).enumerated() {
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let at = "line \(lineNo + 1)"

            if line.hasPrefix("[[") && line.hasSuffix("]]") {
                section = String(line.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces).lowercased()
                switch section {
                case "space": labels.append("")
                case "rule": rules.append(WindowRule())
                default: warnings.append("\(at): unknown table [[\(section)]]")
                }
                currentMode = nil
                continue
            }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces).lowercased()
                currentMode = nil
                if section.hasPrefix("mode.") {
                    let name = unquote(String(section.dropFirst(5)))
                    currentMode = name
                    // A mode written in the file replaces the built-in one wholesale.
                    config.modes[name] = [:]
                } else if !["general", "menubar", "keybindings", "keys"].contains(section) {
                    warnings.append("\(at): unknown section [\(section)]")
                }
                continue
            }

            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else {
                warnings.append("\(at): expected key = value")
                continue
            }
            let key = unquote(parts[0])
            let val = unquote(parts[1])

            if let mode = currentMode {
                config.modes[mode]?[canonicalChord(key)] = val
                continue
            }

            switch section {
            case "general":
                switch key {
                case "gap":
                    if let d = Double(val) { config.gap = d } else { warnings.append("\(at): gap must be a number") }
                case "spring_omega":
                    if let d = Double(val) { config.springOmega = d } else { warnings.append("\(at): spring_omega must be a number") }
                case "mouse_modifier":
                    config.mouseModifier = val.lowercased()
                    if !mouseModifiers.contains(config.mouseModifier) {
                        warnings.append("\(at): mouse_modifier must be one of \(mouseModifiers.joined(separator: ", "))")
                    }
                case "default_column_width":
                    if let d = Double(val) { config.defaultColumnWidth = d } else { warnings.append("\(at): default_column_width must be a number") }
                case "center_focused_column":
                    if let mode = CenterMode(rawValue: val.lowercased()) {
                        config.centerFocusedColumn = mode
                    } else {
                        warnings.append("\(at): center_focused_column must be \"always\" or \"never\"")
                    }
                case "fill_single_column":
                    if let b = Bool(val) { config.fillSingleColumn = b } else { warnings.append("\(at): fill_single_column must be true or false") }
                default:
                    warnings.append("\(at): unknown key \(key) in [general]")
                }

            case "menubar":
                switch key {
                case "show_space":
                    if let b = Bool(val) { config.menuBarShowsSpace = b } else { warnings.append("\(at): show_space must be true or false") }
                case "show_columns":
                    if let b = Bool(val) { config.menuBarShowsColumns = b } else { warnings.append("\(at): show_columns must be true or false") }
                default:
                    warnings.append("\(at): unknown key \(key) in [menubar]")
                }

            case "keybindings", "keys":
                let chord = canonicalChord(key)
                // "none" removes a default binding.
                if val.isEmpty || val == "none" {
                    config.keybindings.removeValue(forKey: chord)
                } else {
                    config.keybindings[chord] = val
                }

            case "space":
                if key == "label" { labels[labels.count - 1] = val } else { warnings.append("\(at): [[space]] takes only label") }

            case "rule":
                let i = rules.count - 1
                switch key {
                case "app": rules[i].app = val
                case "title": rules[i].title = val
                case "bundle-id", "bundle_id": rules[i].bundleID = val
                case "space": rules[i].space = val
                case "manage":
                    if let b = Bool(val) { rules[i].manage = b } else { warnings.append("\(at): manage must be true or false") }
                default: warnings.append("\(at): unknown key \(key) in [[rule]]")
                }

            default:
                break
            }
        }

        config.spaceLabels = labels
        config.rules = rules
        for (i, rule) in rules.enumerated() {
            for pattern in [rule.app, rule.title, rule.bundleID].compactMap({ $0 }) {
                if (try? NSRegularExpression(pattern: pattern)) == nil {
                    warnings.append("rule \(i + 1): \"\(pattern)\" is not a valid regular expression")
                }
            }
        }

        let clamped = config.clamped
        if clamped.gap != config.gap { warnings.append("gap clamped to \(clamped.gap)") }
        if clamped.springOmega != config.springOmega { warnings.append("spring_omega clamped to \(clamped.springOmega)") }
        if clamped.defaultColumnWidth != config.defaultColumnWidth {
            warnings.append("default_column_width clamped to \(clamped.defaultColumnWidth)")
        }
        return (clamped, warnings)
    }

    // MARK: - Writing

    /// The configuration as a TOML file. Removed defaults are written as "none"
    /// so they stay removed on the next load.
    public func serialized() -> String {
        func number(_ d: Double) -> String {
            d == d.rounded() ? String(format: "%.1f", d) : String(d)
        }
        func quoted(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        func bindings(_ binds: [String: String], defaults: [String: String]) -> String {
            var out = ""
            for chord in binds.keys.sorted(by: Self.chordOrder) {
                out += "\(chord) = \(quoted(binds[chord]!))\n"
            }
            for chord in defaults.keys.sorted(by: Self.chordOrder) where binds[chord] == nil {
                out += "\(chord) = \"none\"\n"
            }
            return out
        }

        var out = """
        # Shuttle Window Manager Configuration (~/.config/shuttle/config.toml)
        # Edited by hand or from Shuttle's Settings window; both reload live.

        [general]
        gap = \(number(gap))
        spring_omega = \(number(springOmega))
        mouse_modifier = "\(mouseModifier)"
        default_column_width = \(number(defaultColumnWidth))
        # "always" centers the focused column; "never" scrolls just enough to show it.
        # A desktop's only column is centered either way.
        center_focused_column = "\(centerFocusedColumn.rawValue)"
        # A desktop's only column fills the screen width.
        fill_single_column = \(fillSingleColumn)

        [menubar]
        show_space = \(menuBarShowsSpace)
        show_columns = \(menuBarShowsColumns)

        [keybindings]
        # Set a default chord to "none" to unbind it.

        """
        out += bindings(keybindings, defaults: Self.defaultKeybindings)

        for name in modes.keys.sorted() {
            out += "\n[mode.\(name)]\n"
            out += bindings(modes[name] ?? [:], defaults: [:])
        }

        if !spaceLabels.isEmpty {
            out += "\n# Desktop names, in order: the first names desktop 1.\n"
            for label in spaceLabels {
                out += "[[space]]\nlabel = \(quoted(label))\n"
            }
        }

        if !rules.isEmpty {
            out += "\n# Rules for windows as they open. Patterns are regular expressions.\n"
            for rule in rules {
                out += "[[rule]]\n"
                if let v = rule.app { out += "app = \(quoted(v))\n" }
                if let v = rule.title { out += "title = \(quoted(v))\n" }
                if let v = rule.bundleID { out += "bundle-id = \(quoted(v))\n" }
                if let v = rule.space { out += "space = \(quoted(v))\n" }
                if let v = rule.manage { out += "manage = \(v)\n" }
            }
        }
        return out
    }

    /// Shorter chords first, so plain `alt-` bindings come before `alt-shift-` ones.
    private static func chordOrder(_ a: String, _ b: String) -> Bool {
        a.count == b.count ? a < b : a.count < b.count
    }

    /// Drops a `#` comment that is not inside a quoted string.
    private static func stripComment(_ line: String) -> String {
        var inQuotes = false
        var escaped = false
        for (i, ch) in line.enumerated() {
            if escaped { escaped = false; continue }
            if ch == "\\" && inQuotes { escaped = true; continue }
            if ch == "\"" { inQuotes.toggle() }
            if ch == "#" && !inQuotes { return String(line.prefix(i)) }
        }
        return line
    }

    private static func unquote(_ s: String) -> String {
        if s.count >= 2 && s.hasPrefix("\"") && s.hasSuffix("\"") {
            return String(s.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        return s
    }
}
