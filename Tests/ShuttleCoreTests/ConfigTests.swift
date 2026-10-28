import Testing
import Foundation
@testable import ShuttleCore

@Suite struct ConfigTests {
    @Test func testDefaultConfig() {
        let cfg = ShuttleConfig.default
        #expect(cfg.gap == 16.0)
        #expect(cfg.springOmega == 26.0)
        #expect(cfg.mouseModifier == "alt")
        #expect(cfg.defaultColumnWidth == 0.5)
        #expect(cfg.keybindings["alt-h"] == "column focus-left")
    }

    @Test func testParseTOML() {
        let toml = """
        # Custom config
        [general]
        gap = 24.0
        spring_omega = 30.0
        mouse_modifier = "cmd"
        default_column_width = 0.66

        [keybindings]
        ctrl-left = "column focus-left"
        ctrl-right = "column focus-right"
        """

        let cfg = ShuttleConfig.parse(toml: toml)
        #expect(cfg.gap == 24.0)
        #expect(cfg.springOmega == 30.0)
        #expect(cfg.mouseModifier == "cmd")
        #expect(cfg.defaultColumnWidth == 0.66)
        #expect(cfg.keybindings["ctrl-left"] == "column focus-left")
        #expect(cfg.keybindings["ctrl-right"] == "column focus-right")
    }
}

@Suite struct ConfigFileTests {
    @Test func inlineCommentsAndUnbinding() {
        let (cfg, warnings) = ShuttleConfig.parseReport(toml: """
        [general]
        gap = 8 # tight
        center_focused_column = "never"

        [keybindings]
        alt-h = "none"
        alt-x = "column focus-left # not a comment"
        """)
        #expect(warnings.isEmpty)
        #expect(cfg.gap == 8)
        #expect(cfg.centerFocusedColumn == .never)
        #expect(cfg.keybindings["alt-h"] == nil)
        #expect(cfg.keybindings["alt-x"] == "column focus-left # not a comment")
    }

    @Test func serializedConfigParsesBackIdentically() {
        var cfg = ShuttleConfig.default
        cfg.gap = 10
        cfg.springOmega = 33
        cfg.mouseModifier = "cmd"
        cfg.defaultColumnWidth = 0.666
        cfg.centerFocusedColumn = .never
        cfg.menuBarShowsColumns = false
        cfg.keybindings["ctrl-alt-n"] = "column focus-right"
        cfg.keybindings.removeValue(forKey: "alt-f")

        let (parsed, warnings) = ShuttleConfig.parseReport(toml: cfg.serialized())
        #expect(warnings.isEmpty)
        #expect(parsed == cfg)
    }

    @Test func outOfRangeValuesAreClampedAndReported() {
        let (cfg, warnings) = ShuttleConfig.parseReport(toml: """
        [general]
        gap = 500
        mouse_modifier = "hyper"
        typo_key = 1
        """)
        #expect(cfg.gap == ShuttleConfig.gapRange.upperBound)
        #expect(cfg.mouseModifier == "alt")
        #expect(warnings.count == 3)
    }

    @Test func spaceBindingsAreConfigurableDefaults() {
        #expect(ShuttleConfig.default.keybindings["alt-3"] == "space focus 3")
        #expect(ShuttleConfig.default.keybindings["alt-shift-9"] == "space move-window 9")
    }
}

@Suite struct WeftStyleConfigTests {
    let toml = """
    [keybindings]
    "alt-ctrl-h" = "monitor focus left"   # weft spelling
    "alt-i" = "space focus term"
    "alt-shift-r" = "mode resize"

    [mode.resize]
    "h" = "column shrink 0.05"
    "escape" = "mode default"

    [[space]]
    label = "main"
    [[space]]
    label = "term"

    [[rule]]
    app = "^Finder$"
    manage = false
    [[rule]]
    app = "^Ghostty$|^kitty$"
    space = "term"
    """

    @Test func parsesLabelsRulesModesAndCanonicalChords() {
        let (cfg, warnings) = ShuttleConfig.parseReport(toml: toml)
        #expect(warnings.isEmpty)
        #expect(cfg.keybindings["ctrl-alt-h"] == "monitor focus left")
        #expect(cfg.keybindings["alt-ctrl-h"] == nil)
        #expect(cfg.keybindings["alt-i"] == "space focus term")
        #expect(cfg.modes["resize"] == ["h": "column shrink 0.05", "escape": "mode default"])
        #expect(cfg.spaceLabels == ["main", "term"])
        #expect(cfg.desktopNumber(forLabel: "term") == 2)
        #expect(cfg.label(ofDesktop: 1) == "main")
        #expect(cfg.rules.count == 2)
        #expect(cfg.rules[0].manage == false)
        #expect(cfg.rules[1].space == "term")
    }

    @Test func roundTripsThroughSerialize() {
        let cfg = ShuttleConfig.parse(toml: toml)
        let (again, warnings) = ShuttleConfig.parseReport(toml: cfg.serialized())
        #expect(warnings.isEmpty)
        #expect(again == cfg)
    }

    @Test func rulesMatchByRegexAndNeedEveryPattern() {
        let rule = WindowRule(app: "^Brave Browser$", title: ".*Picture.in.Picture.*", manage: false)
        #expect(rule.matches(app: "Brave Browser", title: "Picture-in-Picture", bundleID: nil))
        #expect(!rule.matches(app: "Brave Browser", title: "GitHub", bundleID: nil))
        #expect(!WindowRule().matches(app: "Anything", title: nil, bundleID: nil))
    }

    @Test func canonicalChordOrdersModifiers() {
        #expect(ShuttleConfig.canonicalChord("shift-alt-ctrl-l") == "ctrl-alt-shift-l")
        #expect(ShuttleConfig.canonicalChord("cmd-opt-k") == "alt-cmd-k")
        #expect(ShuttleConfig.canonicalChord("escape") == "escape")
    }

    @Test func fillSingleColumnParses() {
        #expect(ShuttleConfig.parse(toml: "[general]\nfill_single_column = true").fillSingleColumn)
    }
}
