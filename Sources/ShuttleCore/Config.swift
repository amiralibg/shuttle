import Foundation

/// Configuration settings for Shuttle.
public struct ShuttleConfig: Sendable, Equatable {
    public var gap: Double
    public var springOmega: Double
    public var mouseModifier: String
    public var defaultColumnWidth: Double
    public var keybindings: [String: String]

    public static let `default` = ShuttleConfig(
        gap: 16.0,
        springOmega: 26.0,
        mouseModifier: "alt",
        defaultColumnWidth: 0.5,
        keybindings: [
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
            "alt-0": "column center",
            "alt-s": "window split",
        ]
    )

    public static func defaultConfigFileURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/shuttle/config.toml")
    }

    /// Loads configuration from disk, creating default config if absent.
    public static func load(from url: URL = defaultConfigFileURL()) -> ShuttleConfig {
        let manager = FileManager.default
        let folder = url.deletingLastPathComponent()

        if !manager.fileExists(atPath: folder.path) {
            try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        if !manager.fileExists(atPath: url.path) {
            let template = defaultTemplateTOML()
            try? template.write(to: url, atomically: true, encoding: .utf8)
            return .default
        }

        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return .default
        }

        return parse(toml: content)
    }

    /// Parses a simple TOML configuration string.
    public static func parse(toml: String) -> ShuttleConfig {
        var config = ShuttleConfig.default
        var currentSection = ""

        for rawLine in toml.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                currentSection = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces).lowercased()
                continue
            }

            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let key = parts[0]
            var val = parts[1]
            if val.hasPrefix("\"") && val.hasSuffix("\"") && val.count >= 2 {
                val = String(val.dropFirst().dropLast())
            }

            switch currentSection {
            case "general":
                if key == "gap", let d = Double(val) { config.gap = d }
                else if key == "spring_omega", let d = Double(val) { config.springOmega = d }
                else if key == "mouse_modifier" { config.mouseModifier = val.lowercased() }
                else if key == "default_column_width", let d = Double(val) { config.defaultColumnWidth = d }

            case "keybindings", "keys":
                config.keybindings[key] = val

            default:
                break
            }
        }

        return config
    }

    /// Default TOML configuration template written for new users.
    public static func defaultTemplateTOML() -> String {
        return """
        # Shuttle Window Manager Configuration (~/.config/shuttle/config.toml)

        [general]
        gap = 16.0
        spring_omega = 26.0
        mouse_modifier = "alt"
        default_column_width = 0.5

        [keybindings]
        # Horizontal Column Navigation
        alt-h = "column focus-left"
        alt-l = "column focus-right"
        alt-left = "column focus-left"
        alt-right = "column focus-right"
        alt-shift-h = "column move-left"
        alt-shift-l = "column move-right"
        alt-shift-left = "column move-left"
        alt-shift-right = "column move-right"

        # Vertical Stack Navigation
        alt-k = "window focus-up"
        alt-j = "window focus-down"
        alt-up = "window focus-up"
        alt-down = "window focus-down"
        alt-shift-k = "window move-up"
        alt-shift-j = "window move-down"
        alt-shift-up = "window move-up"
        alt-shift-down = "window move-down"

        # Column Resizing & Presets
        alt-minus = "column shrink"
        alt-equal = "column expand"
        alt-r = "column preset"
        alt-f = "column maximize"
        alt-0 = "column center"

        # Stack Splitting
        alt-s = "window split"
        """
    }
}
