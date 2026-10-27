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
   - **Spaces Integration**: Uses `WeftKit`'s private SkyLight / Mission Control shims to switch macOS spaces or move windows across spaces without SIP disabling.

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
  - The background daemon. Listens for window lifecycle events (creation, destruction, focus), handles hotkeys, manages socket server, drives display links.

- `shuttlectl`:
  - Command-line tool communicating with `shuttled` to trigger layout changes, inspect state, and bind user scripts.
