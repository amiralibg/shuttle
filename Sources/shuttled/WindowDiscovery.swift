import AppKit
import ApplicationServices
import WeftCore
import WeftPlatform

/// Which windows Shuttle tiles, and finding them.
enum WindowDiscovery {
    /// An AX element is safe to hand between threads; AX serializes calls.
    struct Found: @unchecked Sendable {
        let wid: WindowID
        let pid: Int32
        let element: AXUIElement
        /// For `[[rule]] title = …`.
        let title: String?
    }

    private static let ownPID = ProcessInfo.processInfo.processIdentifier

    /// A real document window: standard subrole, resizable, not minimized,
    /// not native fullscreen, and big enough to be one. Dialogs, sheets,
    /// menu-bar panels and fixed-size widgets float.
    static func isTileable(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value) == .success,
              let subrole = value as? String, subrole == kAXStandardWindowSubrole as String
        else { return false }

        if AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &value) == .success,
           let minimized = value as? Bool, minimized {
            return false
        }
        if AXUIElementCopyAttributeValue(element, "AXFullScreen" as CFString, &value) == .success,
           let fullscreen = value as? Bool, fullscreen {
            return false
        }

        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &settable) == .success,
              settable.boolValue
        else { return false }

        var sizeRef: CFTypeRef?
        var size = CGSize.zero
        if AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
           let axSize = sizeRef, CFGetTypeID(axSize) == AXValueGetTypeID() {
            AXValueGetValue(axSize as! AXValue, .cgSize, &size)
        }
        return size.width >= 200 && size.height >= 150
    }

    /// Whether `wid` lives on `space` alone. A window just created may not
    /// report a desktop yet; AX only lists windows on the showing desktop
    /// (weft S0), so it is on this one. Sticky windows span several and are
    /// left alone.
    static func lives(_ wid: WindowID, on space: SpaceID) -> Bool {
        let spaces = SpaceControl.spacesForWindow(wid)
        return spaces.isEmpty || spaces == [space]
    }

    /// Every tileable window of `pid` that AX can see right now.
    static func windows(of pid: Int32) -> [Found] {
        guard pid != ownPID else { return [] }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
              let elements = ref as? [AXUIElement]
        else { return [] }
        return elements.compactMap { el in
            guard isTileable(el), let wid = PublicPaths.windowID(of: el) else { return nil }
            var title: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &title)
            return Found(wid: wid, pid: pid, element: el, title: title as? String)
        }
    }

    /// The focused window of `pid`, if it has one AX can name.
    static func focusedWindow(of pid: Int32) -> (WindowID, AXUIElement)? {
        guard pid != ownPID else { return nil }
        let app = AXUIElementCreateApplication(pid)
        // This runs on the main thread. Without a timeout a hung app holds it
        // for AX's default of about six seconds, and Shuttle looks frozen.
        AXUIElementSetMessagingTimeout(app, 0.15)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let raw = ref, CFGetTypeID(raw) == AXUIElementGetTypeID()
        else { return nil }
        let element = raw as! AXUIElement
        guard let wid = PublicPaths.windowID(of: element) else { return nil }
        return (wid, element)
    }

    /// Every window the WindowServer has, on any desktop, with its owner.
    ///
    /// Not `WorldReader.pid(of:)`: that call passes the window id without
    /// `.optionIncludingWindow`, so macOS ignores it, lists every window, and
    /// a closed window still "has" the first window's owner. Nor
    /// `CGWindowListCreateDescriptionFromArray`, which describes only windows
    /// on screen and would call every window on another desktop closed.
    static func allWindowOwners() -> [WindowID: Int32]? {
        guard let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return nil }
        var out: [WindowID: Int32] = [:]
        for w in info {
            guard let wid = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            else { continue }
            out[wid] = pid
        }
        return out
    }

    /// Which of `wids` still exist. Nil when the window list could not be read.
    static func living(_ wids: [WindowID]) -> Set<WindowID>? {
        guard let all = allWindowOwners() else { return nil }
        return Set(wids.filter { all[$0] != nil })
    }

    /// The process owning `wid`, or nil once the window is gone.
    static func owner(of wid: WindowID) -> Int32? {
        allWindowOwners()?[wid]
    }

    /// Regular apps other than Shuttle itself.
    static func regularAppPIDs() -> [Int32] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ownPID }
            .map(\.processIdentifier)
    }

    static var shuttlePID: Int32 { ownPID }
}
