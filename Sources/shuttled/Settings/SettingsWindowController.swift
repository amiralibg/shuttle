import AppKit
import SwiftUI

/// The Settings window, built when opened and torn down when closed: a
/// closed window that keeps its SwiftUI tree keeps animating the previews,
/// which cost the daemon ~10% CPU doing nothing.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: SettingsModel

    init(model: SettingsModel) {
        self.model = model
    }

    func windowWillClose(_ notification: Notification) {
        if model.recordingCommand != nil { model.endRecording() }
        window?.contentViewController = nil
        window?.delegate = nil
        window = nil
    }

    func show(pane: SettingsPane = .layout) {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsRootView(model: model, pane: pane))
            let w = NSWindow(contentViewController: hosting)
            w.title = "Shuttle Settings"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.toolbarStyle = .unified
            w.setContentSize(NSSize(width: 780, height: 600))
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.setFrameAutosaveName("ShuttleSettings")
            w.center()
            window = w
        }
        // Shuttle is a menu bar app; bring it forward so the window takes keys.
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
