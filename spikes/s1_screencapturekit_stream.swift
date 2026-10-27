import Foundation
import ScreenCaptureKit

print("=== Spike S1: ScreenCaptureKit Live Proxy Streaming ===")
print("Querying shareable content...")

Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        print("Found \(content.windows.count) on-screen windows across \(content.displays.count) displays.")
        for win in content.windows.prefix(5) {
            print(" - Window [\(win.windowID)]: \(win.title ?? "<untitled>") (\(win.owningApplication?.applicationName ?? "unknown")) frame: \(win.frame)")
        }
        print("SCK is operational. Ready for stream overlay pipeline implementation.")
        exit(0)
    } catch {
        print("Error accessing SCShareableContent: \(error)")
        exit(1)
    }
}

RunLoop.main.run()
