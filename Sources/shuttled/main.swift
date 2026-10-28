import AppKit
import ApplicationServices
import Foundation
import ShuttleCore
import WeftCore
import WeftPlatform
import WeftInput
import WeftIPC

// MARK: - App

/// Startup, wiring and shutdown. Runs a real NSApplication event loop: a
/// process that creates NSApplication but never reads its events is one the
/// WindowServer waits on (weft measured up to half a second a call), and the
/// Settings window needs it for keyboard input anyway.
@MainActor
final class ShuttleApp: NSObject, NSApplicationDelegate {
    private let menuBar = MenuBarController()
    private var controller: DaemonController?
    private var settingsModel: SettingsModel?
    private var settingsWindow: SettingsWindowController?
    private var inputManager: InputManager?
    private var observers: ObserverSet?
    private var configWatcher: ConfigFileWatcher?
    private var ipcServer: IPCServer?
    private var permissionTimer: Timer?
    private var pruneTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []
    private var configWarnings: [String] = []

    private static let user = ProcessInfo.processInfo.environment["USER"] ?? "user"
    static let socketPath = "/tmp/shuttle-\(user).sock"

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("==================================================================")
        print("  SHUTTLE DAEMON (shuttled v\(ShuttleVersion.full))")
        print("  Infinite Horizontal Ribbon Scrolling Window Manager for macOS")
        print("==================================================================")

        installSignalHandlers()
        menuBar.quit = { [weak self] in self?.shutdown() }

        // Settings alone, no window management: for working on the UI.
        if CommandLine.arguments.contains("--settings-preview") {
            let (config, warnings) = ShuttleConfig.loadReport()
            let model = SettingsModel(config: config)
            model.loaded(config, warnings: warnings)
            settingsModel = model
            settingsWindow = SettingsWindowController(model: model)
            let args = CommandLine.arguments
            let pane = args.firstIndex(of: "--pane").flatMap { i in
                args.indices.contains(i + 1) ? SettingsPane(rawValue: args[i + 1].capitalized) : nil
            }
            settingsWindow?.show(pane: pane ?? .layout)
            return
        }

        let options = [("AXTrustedCheckOptionPrompt" as CFString): true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            start()
        } else {
            // Wait for the grant instead of exiting: the user would otherwise
            // have to find and relaunch Shuttle after ticking the box.
            print("⏳ Waiting for Accessibility permission (System Settings → Privacy & Security → Accessibility)...")
            menuBar.showWaitingForPermission()
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard AXIsProcessTrusted() else { return }
                    self?.permissionTimer?.invalidate()
                    self?.permissionTimer = nil
                    self?.start()
                }
            }
        }
    }

    private func start() {
        let (config, warnings) = ShuttleConfig.loadReport()
        configWarnings = warnings
        warnings.forEach { print("⚠️  config: \($0)") }
        print("⚙️  Loaded configuration (gap: \(config.gap)pt, spring omega: \(config.springOmega), mouse mod: \(config.mouseModifier))")

        let controller = DaemonController(config: config)
        self.controller = controller
        controller.onShutdown = { [weak self] in self?.shutdown() }
        controller.onReloadRequested = { [weak self] in self?.reloadConfig() }
        controller.onStateChange = { [weak self] in self?.stateChanged() }
        controller.onWindowManaged = { [weak self] wid, pid in
            self?.observers?.watch(pids: [pid], windows: [(wid, pid)])
        }

        let model = SettingsModel(config: config)
        model.loaded(config, warnings: warnings)
        model.runCommand = { [weak self] cmd in _ = self?.controller?.handleCommand(cmd) }
        model.focusDesktop = { [weak self] uuid, index in _ = self?.controller?.focusSpace(onDisplay: uuid, index: index) }
        model.setHotkeysPaused = { [weak self] paused in self?.setHotkeysPaused(paused) }
        settingsModel = model
        settingsWindow = SettingsWindowController(model: model)

        menuBar.status = { [weak controller] in controller?.status() }
        menuBar.config = { [weak controller] in controller?.config ?? .default }
        menuBar.configWarnings = { [weak self] in self?.configWarnings ?? [] }
        menuBar.runCommand = { [weak self] cmd in _ = self?.controller?.handleCommand(cmd) }
        menuBar.focusDesktop = { [weak self] uuid, index in _ = self?.controller?.focusSpace(onDisplay: uuid, index: index) }
        menuBar.openSettings = { [weak self] in self?.settingsWindow?.show() }
        menuBar.reloadConfig = { [weak self] in self?.reloadConfig() }

        // Observers first: every window the sweep files is watched as it is filed.
        startObservers(controller)
        controller.discoverAll()
        // Backstop for windows that close without telling anyone: one
        // window-list read every few seconds.
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.controller?.pruneClosedWindows() }
        }
        print("Displays: \(controller.status().monitors.map(\.name).joined(separator: ", "))")

        startInput(config)
        startIPC()

        configWatcher = ConfigFileWatcher(file: ShuttleConfig.defaultConfigFileURL()) { [weak self] in
            MainActor.assumeIsolated { self?.reloadConfig() }
        }
        configWatcher?.start()

        stateChanged()
        print("\n🚀 shuttled daemon ready.")
    }

    // MARK: - Wiring

    private func startObservers(_ controller: DaemonController) {
        let observers = ObserverSet()
        observers.onEvent = { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(event) }
            }
        }
        observers.start()
        let pids = WindowDiscovery.regularAppPIDs()
        observers.watch(pids: pids, windows: [])
        self.observers = observers
        print("👁️  Window lifecycle observers attached to \(pids.count) apps.")
    }

    private func handle(_ event: ObserverEvent) {
        guard let controller else { return }
        switch event {
        case .windowCreated(let pid, let wid):
            controller.handleWindowCreated(pid: pid, wid: wid)
        case .windowDestroyed(let wid):
            observers?.forgetWindow(wid)
            controller.handleWindowDestroyed(wid: wid)
        case .windowFocused(let wid):
            controller.handleWindowFocused(wid: wid)
        case .appActivated(let pid):
            controller.handleAppActivated(pid: pid)
        case .appLaunched(let pid, _):
            guard pid != WindowDiscovery.shuttlePID else { return }
            observers?.watch(pids: [pid], windows: [])
            controller.handleAppLaunched(pid: pid)
        case .appTerminated(let pid, _):
            observers?.forgetApp(pid: pid)
            controller.handleAppTerminated(pid: pid)
        case .windowMoved(let wid), .windowResized(let wid):
            controller.handleWindowGeometryChanged(wid: wid)
        case .spaceChanged:
            controller.handleSpaceChanged()
        case .displayChanged:
            controller.handleDisplayChanged()
        case .missionControl(let open):
            controller.handleMissionControl(open: open)
        }
    }

    /// The default key table plus one per `[mode.<name>]`. A binding to
    /// `mode <name>` switches tables inside the event tap.
    private static func keymap(for config: ShuttleConfig) -> Keymap {
        func table(_ binds: [String: String]) -> [Chord: KeyAction] {
            var out: [Chord: KeyAction] = [:]
            for (chordStr, cmdStr) in binds {
                guard let chord = try? parseChord(chordStr) else {
                    print("⚠️  Ignoring keybinding with unknown chord '\(chordStr)'")
                    continue
                }
                out[chord] = cmdStr.hasPrefix("mode ") ? .mode(String(cmdStr.dropFirst(5))) : .send(cmdStr)
            }
            return out
        }
        var modes = ["default": table(config.keybindings)]
        for (name, binds) in config.modes where name != "default" {
            modes[name] = table(binds)
        }
        return Keymap(modes: modes)
    }

    private func startInput(_ config: ShuttleConfig) {
        let input = InputManager(keymap: Self.keymap(for: config))
        input.updateMouseModifier(config.mouseModifier)
        // The tap calls back on its own thread; every command runs on main.
        input.onCommand = { [weak self] cmd in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let res = self?.controller?.handleCommand(cmd) else { return }
                    print("⌨️  \(cmd) -> \(res)")
                }
            }
        }
        input.onModeChange = { [weak self] mode in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.menuBar.mode = mode
                    self?.menuBar.refresh()
                }
            }
        }
        input.onMouseGesture = { [weak self] gesture in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.controller?.handleMouseGesture(gesture) }
            }
        }
        if input.start() {
            print("✅ Keyboard & mouse navigation active (\(config.keybindings.count) bindings, drag with \(config.mouseModifier)).")
        } else {
            print("⚠️  Warning: Failed to install event tap for keyboard navigation.")
        }
        inputManager = input
    }

    private func setHotkeysPaused(_ paused: Bool) {
        guard let input = inputManager, let controller else { return }
        input.updateKeymap(paused ? Keymap(modes: ["default": [:]]) : Self.keymap(for: controller.config))
    }

    private func startIPC() {
        unlink(Self.socketPath)
        ignoreSIGPIPE()
        let server = IPCServer(path: Self.socketPath) { [weak self] line, conn in
            // The socket thread waits for main; commands never run concurrently.
            let responseText = DispatchQueue.main.sync {
                MainActor.assumeIsolated { self?.controller?.handleCommand(line) ?? "ERR: Shuttle is not running" }
            }
            let resp = IPCResponse(ok: !responseText.hasPrefix("ERR"), output: responseText)
            if let data = try? JSONEncoder().encode(resp), let json = String(data: data, encoding: .utf8) {
                conn.send(json)
            } else {
                conn.send(responseText)
            }
        }
        ipcServer = server
        DispatchQueue.global(qos: .userInteractive).async {
            server.run()
        }
        print("🔌 IPC server listening on \(Self.socketPath)")
    }

    // MARK: - Config & state

    private func reloadConfig() {
        guard let controller else { return }
        let (config, warnings) = ShuttleConfig.loadReport()
        configWarnings = warnings
        warnings.forEach { print("⚠️  config: \($0)") }
        let keysChanged = config.keybindings != controller.config.keybindings
        let modifierChanged = config.mouseModifier != controller.config.mouseModifier
        controller.apply(config: config)
        if keysChanged, settingsModel?.recordingCommand == nil {
            inputManager?.updateKeymap(Self.keymap(for: config))
        }
        if modifierChanged { inputManager?.updateMouseModifier(config.mouseModifier) }
        settingsModel?.loaded(config, warnings: warnings)
        menuBar.flash(warnings.isEmpty ? "✓" : "⚠︎")
        print("♻️  Configuration reloaded\(warnings.isEmpty ? "" : " with \(warnings.count) problem(s)").")
    }

    private func stateChanged() {
        menuBar.refresh()
        settingsModel?.update(status: controller?.status())
    }

    // MARK: - Shutdown

    private func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.shutdown() }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func shutdown() {
        print("\n🛑 Shutting down Shuttle daemon...")
        // Every parked or off-screen window comes back where it can be reached.
        controller?.releaseWindows()
        configWatcher?.stop()
        inputManager?.stop()
        observers?.stop()
        unlink(Self.socketPath)
        exit(0)
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.releaseWindows()
        unlink(Self.socketPath)
    }
}

// MARK: - Entry point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
// Run from .build there is no bundle to take the icon from.
if Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") == nil,
   let icon = NSImage(contentsOf: URL(fileURLWithPath: #filePath)
       .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
       .appendingPathComponent("extra/AppIcon.png")) {
    app.applicationIconImage = icon
}
let delegate = ShuttleApp()
app.delegate = delegate
app.run()
