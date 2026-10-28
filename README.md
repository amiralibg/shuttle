<img src="extra/AppIcon.png" width="128" alt="Shuttle icon">

# Shuttle

A scrolling window manager for macOS, in the style of [niri](https://github.com/YaLTeR/niri) and [PaperWM](https://github.com/paperwm/PaperWM).

Shuttle doesn't pack windows into a grid or a binary tree. It lays them out as columns on an endless horizontal ribbon. Opening a window adds a column; moving focus slides the ribbon across the screen with a spring animation.

## Features

- **Ribbon of columns**: windows sit in columns on a horizontal ribbon, one ribbon per desktop per display. A column can hold several windows stacked vertically.
- **Multiple displays**: every display has its own desktops and ribbons and animates on its own. ⌃⌥ + arrow (or H/J/K/L) focuses the display in that direction, whatever the arrangement, stacked ones included; add ⇧ to take the focused column along. Drag a window onto another display and it joins that display's ribbon.
- **Animation**: a critically damped spring driven by the display's refresh rate (120 Hz on ProMotion). It runs only while the ribbon is moving.
- **Mouse**: hold the drag modifier (⌥ by default) and drag anywhere to slide the ribbon. Flick to throw it; let go and it snaps to a column.
- **Keyboard**: focus, move, resize, stack and split columns. ⌥F maximizes a column, ⌥⇧F makes a window fullscreen, ⌥⇧Space floats one. ⌥1–9 switches desktops instantly, ⌥⇧1–9 sends the focused window to one, ⌥⇥ goes back to the last desktop. A resize mode (⌥⇧R) ships by default, and you can define your own key tables under `[mode.<name>]`.
- **Named desktops and app rules**, in weft's format: `[[space]] label = "web"` names a desktop (main display first, the way weft and yabai count), `space focus web` goes there, and `[[rule]] app = "^Zen$" space = "web"` or `manage = false` files or floats apps as they open.
- **Refresh** (⌥⇧0, or Refresh Layout in the menu): puts every window back in its column after something has knocked the layout out of shape. `refresh reset` also resets column widths.
- **Single window**: a desktop's only column is always centered. With `fill_single_column = true` it fills the screen width until a second window arrives.
- **Native desktops**: each macOS desktop is a workspace. Mission Control, the trackpad desktop swipe and native fullscreen keep working.
- **Menu bar**: shows the desktop number and one block per column, with the focused column filled in.
- **Settings window**: edit layout, scrolling, animation, shortcuts, menu bar and the login item from a window. Hand edits to `~/.config/shuttle/config.toml` reload live as well.
- **No SIP changes**: [WeftKit](https://github.com/amiralibg/weft) handles the low-level macOS work (private SkyLight window-server calls, Accessibility, event taps, IPC) with System Integrity Protection left on.

### Not built yet

- Two-finger trackpad scrolling of the ribbon. Today it's modifier + mouse drag only.
- Per-display settings, such as narrower default columns on a 4K display.
- Moving a whole desktop to another display. macOS owns desktops, so Shuttle can't do what niri does here.

## Install

Shuttle needs macOS 15 (Sequoia) or later.

### From a release

1. Download `Shuttle-<version>-macos-arm64.zip` from the [latest release](https://github.com/amiralibg/shuttle/releases/latest) and unzip it.
2. Move `Shuttle.app` to `~/Applications` (or `/Applications`).
3. The app is ad-hoc signed, not notarized, so Gatekeeper blocks it on first launch. Clear the quarantine flag:

   ```bash
   xattr -dr com.apple.quarantine ~/Applications/Shuttle.app
   ```

4. Open Shuttle, then enable it under **System Settings → Privacy & Security → Accessibility**.
5. Optional: put the bundled `shuttlectl` somewhere on your `PATH`, for example `~/.local/bin`.

Release builds are Apple silicon only. On an Intel Mac, build from source.

### From source

Shuttle depends on [weft](https://github.com/amiralibg/weft) through a local path, so clone both repositories next to each other:

```bash
git clone https://github.com/amiralibg/weft.git
git clone https://github.com/amiralibg/shuttle.git
cd shuttle
make install
```

`make install` builds a release, packages `Shuttle.app` into `~/Applications`, signs it, copies `shuttled` and `shuttlectl` into `~/.local/bin`, and launches the app. `make uninstall` removes all of that; `./scripts/uninstall.sh --purge` also deletes your config.

Ad-hoc signing gives the app a new identity on every rebuild, and macOS drops the Accessibility grant along with it. To keep the grant across rebuilds, set `SHUTTLE_SIGN_IDENTITY` to a code-signing certificate in your keychain. A self-signed one made in Keychain Access works.

## Default keys

| Keys | Action |
| --- | --- |
| ⌥H / ⌥L (or ⌥← / ⌥→) | Focus column left / right |
| ⌥K / ⌥J (or ⌥↑ / ⌥↓) | Focus window up / down in the column |
| ⌥⇧H / ⌥⇧L | Move column left / right |
| ⌥⇧K / ⌥⇧J | Move window up / down in the column |
| ⌥[ / ⌥] | Pull the column on the left / right into this one |
| ⌥S | Split the focused window out into its own column |
| ⌥− / ⌥= | Shrink / expand the column |
| ⌥R | Cycle width presets (1/3, 1/2, 2/3, full) |
| ⌥F | Maximize the column |
| ⌥⇧F | Fullscreen the window |
| ⌥⇧Space | Float / tile the window |
| ⌥0 | Center the focused column |
| ⌥1–9 | Go to desktop 1–9 |
| ⌥⇧1–9 | Send the window to desktop 1–9 |
| ⌥⇥ | Go back to the previous desktop |
| ⌥\` | Focus the next display |
| ⌥⇧⇥ | Move the column to the next display |
| ⌃⌥ + arrow or H/J/K/L | Focus the display in that direction |
| ⌃⌥⇧ + arrow or H/J/K/L | Move the column to the display in that direction |
| ⌥⇧R | Resize mode: H/L or −/= resize, ⇧H/⇧L in bigger steps, Esc or Return exits |
| ⌥⇧0 | Refresh the layout |
| ⌃⌥R | Reload the config |

Every binding can be changed or turned off in Settings or in the config file.

## Configuration

Shuttle reads `~/.config/shuttle/config.toml` and reloads it when the file is saved. The Settings window writes the same file. A short example:

```toml
[general]
gap = 16.0
spring_omega = 26.0              # spring stiffness: higher settles faster
mouse_modifier = "alt"           # alt, cmd, ctrl, shift or fn
default_column_width = 0.5       # fraction of the screen width
center_focused_column = "always" # or "never": scroll just enough to show it
fill_single_column = false

[menubar]
show_space = true
show_columns = true

[keybindings]
alt-t = "app toggle com.mitchellh.ghostty"
alt-s = "none"                   # unbind a default

[mode.resize]
h = "column shrink"
l = "column expand"
escape = "mode default"

[[space]]
label = "web"

[[space]]
label = "code"

[[rule]]
app = "^Zen$"
space = "web"

[[rule]]
app = "^System Settings$"
manage = false
```

Run `shuttlectl check` to parse the file and list problems. It doesn't need the daemon running.

## shuttlectl

`shuttlectl` talks to the running daemon over a Unix socket. Every key binding is a `shuttlectl` command, so anything you can bind you can also script:

```bash
shuttlectl status                 # desktops, columns, focus and scroller state as JSON
shuttlectl column preset
shuttlectl space focus web
shuttlectl space move 3 --follow
shuttlectl monitor move-column right
shuttlectl refresh reset
shuttlectl stop
```

Run `shuttlectl` with no arguments for the full list.

## Development

```bash
swift build
swift test
make app       # package Shuttle.app without installing the CLI tools
make icon      # redraw the app icon (scripts/make-icon.swift)
```

To work on the Settings UI without Shuttle managing any windows:

```bash
.build/debug/shuttled --settings-preview --pane shortcuts
```

After cloning, turn on the repository's git hooks once:

```bash
git config core.hooksPath .githooks
```

### Layout

```text
shuttle/
├── Sources/
│   ├── ShuttleCore/            # Ribbon layout, column math, focus, config, display geometry
│   ├── ShuttleScroller/        # Spring physics, snapping, window frame writes
│   ├── shuttled/               # Daemon, menu bar, Settings window (SwiftUI)
│   └── shuttlectl/             # CLI client
├── Tests/                      # ShuttleCore and ShuttleScroller tests
├── spikes/                     # Performance and API feasibility spikes
└── docs/ARCHITECTURE.md        # Design notes
```

[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) covers how ribbons, displays, off-screen parking and the frame-writing pipeline fit together.

## License

[MIT](LICENSE) © 2026 Amirali Beigi
