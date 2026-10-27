# Shuttle

A scrolling window manager for macOS inspired by [niri](https://github.com/YaLTeR/niri) and [PaperWM](https://github.com/paperwm/PaperWM).

Instead of packing windows into a fixed 2D grid or binary tree, Shuttle arranges windows along an infinite horizontal ribbon. As you navigate or launch new windows, the screen smoothly pans across the strip with buttery animations.

## Key Features

- **Infinite Horizontal Strip**: Windows are organized into vertical columns on a continuous horizontal ribbon.
- **Fluid Gestures & Animations**:
  - Smooth 120Hz ProMotion panning.
  - Trackpad gestures: two-finger horizontal scroll with natural momentum, or swipe gestures.
  - Mouse wheel and click-drag ribbon movement with spring-physics centering.
- **Fast Keyboard Navigation**:
  - Column jump (`focus-column-left`, `focus-column-right`).
  - Column reordering & resize.
  - macOS spaces and desktop integration via keyboard hotkeys.
- **Engineered on WeftKit**:
  - Leverages [`WeftKit`](https://github.com/amiralibg/weft) for low-level macOS plumbing: private SkyLight window server APIs, Accessibility hooks, high-performance event taps, and IPC sockets without requiring System Integrity Protection (SIP) to be disabled.

## Project Structure

```text
shuttle/
├── Package.swift               # SwiftPM package configuration
├── Sources/
│   ├── ShuttleCore/            # Strip layout engine, column math, focus logic
│   ├── ShuttleScroller/        # Animation engine, gesture recognizers, proxy renderers
│   ├── shuttled/               # Window manager daemon
│   └── shuttlectl/             # CLI control client
├── Tests/
│   └── ShuttleCoreTests/       # Unit tests for ribbon layout
├── spikes/                     # Performance and API feasibility spikes (S1–S4)
└── docs/
    └── ARCHITECTURE.md         # Detailed architectural design & gesture pipeline
```

## Getting Started

### Prerequisites

- macOS 15.0+ (Sequoia)
- Xcode 16+ / Swift 6.0+
- Accessibility permissions enabled for terminal / test runners

### Building

```bash
swift build
swift test
```

## License

[MIT](LICENSE) © 2026 Amirali Beigi
