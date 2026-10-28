import AppKit
import Observation
import ServiceManagement
import ShuttleCore
import WeftCore
import WeftPlatform

/// What the Settings window edits. Every change is written to config.toml
/// shortly after it is made; the daemon reloads from the file like it does for
/// a hand edit, so there is one path for both.
@MainActor
@Observable
final class SettingsModel {
    var config: ShuttleConfig
    private(set) var warnings: [String] = []
    private(set) var status: StatusSnapshot?
    private(set) var saveError: String?
    private(set) var loginItemError: String?
    /// The command whose shortcut is being recorded, if any.
    var recordingCommand: String?

    @ObservationIgnored var runCommand: ((String) -> Void)?
    /// Switch a display (by uuid) to its Nth desktop.
    @ObservationIgnored var focusDesktop: ((String, Int) -> Void)?
    /// Global hotkeys are suspended while a shortcut is recorded, or the
    /// chord being typed would run its command instead of being captured.
    @ObservationIgnored var setHotkeysPaused: ((Bool) -> Void)?

    @ObservationIgnored private var lastSaved: ShuttleConfig
    @ObservationIgnored private var pendingSave: DispatchWorkItem?

    init(config: ShuttleConfig) {
        self.config = config
        self.lastSaved = config
    }

    /// Running apps with windows, for "Add a rule for…".
    var runningAppNames: [String] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.localizedName)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var configPath: String { ShuttleConfig.defaultConfigFileURL().path }

    // MARK: - Sync with the daemon

    /// The daemon loaded `config` from disk (a save from here, or a hand edit).
    func loaded(_ config: ShuttleConfig, warnings: [String]) {
        self.warnings = warnings
        // The echo of a save from here: keep what is on screen, which may
        // already hold the next few keystrokes.
        if config == lastSaved { return }
        lastSaved = config
        if self.config != config { self.config = config }
    }

    func update(status: StatusSnapshot?) {
        if self.status != status { self.status = status }
    }

    /// Called on every edit; coalesces a slider drag into one write.
    func configDidChange() {
        guard config != lastSaved else { return }
        pendingSave?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        pendingSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    private func saveNow() {
        let snapshot = config.clamped
        do {
            try snapshot.save()
            lastSaved = snapshot
            saveError = nil
        } catch {
            saveError = "Could not write \(configPath): \(error.localizedDescription)"
        }
    }

    // MARK: - Shortcuts

    func chords(for command: String) -> [String] {
        config.keybindings.filter { $0.value == command }.map(\.key).sorted()
    }

    /// Commands bound in the config that Settings has no name for.
    var customCommands: [String] {
        let known = Set(ShuttleAction.catalog(labels: config.spaceLabels).map(\.command))
        return Set(config.keybindings.values).subtracting(known).sorted()
    }

    /// The command `chord` currently runs, if any.
    func command(boundTo chord: String) -> String? {
        config.keybindings[chord]
    }

    func bind(_ chord: String, to command: String) {
        config.keybindings[chord] = command
    }

    func unbind(_ chord: String) {
        config.keybindings.removeValue(forKey: chord)
    }

    func restoreDefaultShortcuts() {
        config.keybindings = ShuttleConfig.defaultKeybindings
    }

    func beginRecording(_ command: String) {
        recordingCommand = command
        setHotkeysPaused?(true)
    }

    func endRecording() {
        recordingCommand = nil
        setHotkeysPaused?(false)
    }

    // MARK: - Login item

    var launchesAtLogin: Bool {
        get {
            access(keyPath: \.launchesAtLogin)
            return SMAppService.mainApp.status == .enabled
        }
        set {
            withMutation(keyPath: \.launchesAtLogin) {
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    loginItemError = nil
                } catch {
                    loginItemError = "macOS refused: \(error.localizedDescription). Shuttle must run from Shuttle.app."
                }
            }
        }
    }

    // MARK: - Displays

    /// The displays as macOS reports them, for when the daemon is not running
    /// (the Settings preview): arrangement and desktops, no ribbons.
    var systemMonitors: [StatusSnapshot.Monitor] {
        let layout = SpaceControl.displayLayout()
        let names = Dictionary(SpaceControl.displayIdentities().map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
        let sls = WorldReader.displaysOnly()
        return layout.map { d in
            let entry = sls.first { $0.uuid == d.uuid } ?? (sls.count == 1 ? sls.first : nil)
            let desktops = entry?.spaces ?? []
            return StatusSnapshot.Monitor(
                uuid: d.uuid, name: names[d.uuid]?.name ?? "Display", isMain: names[d.uuid]?.isMain ?? false,
                isFocused: false, bounds: d.frame,
                desktopIndex: entry.flatMap { e in desktops.firstIndex(of: e.currentSpace).map { $0 + 1 } },
                desktops: desktops.enumerated().map { i, sid in
                    .init(index: i + 1, label: nil, spaceID: sid, windows: nil, isCurrent: sid == entry?.currentSpace)
                },
                columns: 0, focusedColumnIndex: 0, focusedApp: nil
            )
        }
    }

    // MARK: - Files

    func openConfigInEditor() {
        NSWorkspace.shared.open(ShuttleConfig.defaultConfigFileURL())
    }

    func revealConfigInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([ShuttleConfig.defaultConfigFileURL()])
    }

    var accessibilityGranted: Bool { AXIsProcessTrusted() }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
