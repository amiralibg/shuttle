# Shuttle Architecture

Shuttle is a scrolling window manager for macOS inspired by [niri](https://github.com/YaLTeR/niri) and [PaperWM](https://github.com/paperwm/PaperWM). Unlike conventional grid or binary-tree tiling window managers (like weft, yabai, or aero), Shuttle arranges windows in an infinite horizontal ribbon of columns.

## Core Concepts

1. **Horizontal Strip**:
   - Each workspace/display manages a linear sequence of columns.
   - A column contains one or more windows stacked vertically.
   - Column widths can be proportional (e.g. 1/3, 1/2, 2/3, 1/1 of viewport) or fixed point widths.
   - The viewport is a sliding window into this ribbon.

2. **Smooth Interactive Navigation**:
   - **Keyboard**: Fast column focus left/right, move window left/right, expand/shrink column width, jump between workspaces.
   - **Trackpad**: Smooth two-finger horizontal scroll with momentum, or optional three-finger swipe gesture.
   - **Mouse**: Modifier + wheel horizontal scroll, modifier + drag to grab and slide ribbon, flick with inertia and spring snap.
   - **Displays and desktops**: a ribbon (`Workspace`: a `Strip` and its own `Scroller`) per desktop per display, keyed by `(SpaceID, display UUID)`. With "Displays have separate Spaces" on, macOS gives every display its own desktops, which is niri's per-monitor workspaces; with it off, every display still gets its own ribbon on the shared desktop. Commands act on the focused display (the one holding the focused window, else the active menu-bar display). `space focus N` uses weft's bridged SkyLight switch (instant, one step), falling back to a synthetic Dock swipe. Moving a window between desktops or displays uses `NativeBridge.move`, which works for windows without a title bar.
   - **Off-screen columns**: macOS will not let a window sit left of a display (it keeps ~40pt on screen), so columns with no pixel on their display are parked at a bottom corner, 1pt visible (AeroSpace's trick). `DisplayGeometry.parkingSpot` picks the corner whose parked rectangle touches no other display. Quitting puts every window back on its display.
   - **Keeping windows in their slots**: a window moved or resized by hand or by its app is put back once things are quiet (once per slot, so an app that insists on a size is not fought); one dropped on another display joins that display's ribbon. Windows entering native fullscreen leave the ribbon until they come back.

3. **Rendering & Animation Strategy**:
   - Smooth 60Hz / 120Hz ProMotion animation during continuous gestures.
   - **Spike 1 (Live Proxies)**: ScreenCaptureKit live window streaming into CAOpenGLLayer / CAMetalLayer overlays for ultra-low latency gesture tracking without window frame thrashing.
   - **Spike 2 (Direct AX)**: Direct `AXUIElementSetAttributeValue` updates during flings/snaps as a zero-overhead fallback.

## Module Breakdown

- `WeftKit` (dependency from `weft`):
  - `SkyLightShim`: C wrapper dynamically loading private `SLS*` / `CGS*` functions.
  - `WeftPlatform`: macOS display, space control, accessibility (`AXUIElement`), window queries.
  - `WeftInput`: Global event tap manager, CGEvent interceptors, keyboard hotkey bindings.
  - `WeftIPC`: Unix domain socket protocol for daemon-client communication.

- `ShuttleCore`:
  - Pure layout engine: `Strip`, `Column`, `ColumnWidth`, viewport offset calculations, focus traversal. Zero AppKit/IO dependencies.

- `ShuttleScroller`:
  - Physics engine: spring animations, flick deceleration, boundary bounce, snap targets.
  - Gestures: trackpad continuous scroll, mouse wheel/drag accumulators.

- `shuttled`:
  - The background daemon, a menu bar app with a real `NSApplication` run loop. `DaemonController` is `@MainActor`: the event tap, IPC socket and AX observers all hop to the main thread, so commands never interleave their AX writes.
  - `Animator` drives every display's spring from one `CADisplayLink` and pauses when all are settled.
  - `WindowCoordinator` (ShuttleScroller) decides frames on the main thread and writes them on a serial queue per app, newest frame wins, so a slow app neither stalls the animation nor the other apps. Final frames are read back, retried once, and logged if the app still refuses.
  - `MenuBarController` shows the desktop number and column position; `Settings/` is the SwiftUI Settings window. Settings writes `config.toml`; `ConfigFileWatcher` reloads it, the same path a hand edit takes.

- `shuttlectl`:
  - Command-line tool communicating with `shuttled` to trigger layout changes, inspect state, and bind user scripts.
