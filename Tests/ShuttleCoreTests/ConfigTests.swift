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
