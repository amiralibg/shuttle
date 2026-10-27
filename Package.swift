// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "shuttle",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "shuttled", targets: ["shuttled"]),
        .executable(name: "shuttlectl", targets: ["shuttlectl"]),
        .library(name: "ShuttleCore", targets: ["ShuttleCore"]),
        .library(name: "ShuttleScroller", targets: ["ShuttleScroller"]),
    ],
    dependencies: [
        // Shared engine with weft: SkyLight shims, Accessibility, space controls,
        // event taps, and IPC sockets.
        .package(path: "../weft"),
    ],
    targets: [
        // Pure data structures: horizontal strip layout, column width rules,
        // viewport calculations, focus traversal. No I/O or AppKit.
        .target(
            name: "ShuttleCore",
            dependencies: [
                .product(name: "WeftKit", package: "weft"),
            ]
        ),
        // Scroller engine: animations, spring physics, ScreenCaptureKit live proxies,
        // window movement coordination, trackpad / mouse gesture recognizers.
        .target(
            name: "ShuttleScroller",
            dependencies: [
                "ShuttleCore",
                .product(name: "WeftKit", package: "weft"),
            ]
        ),
        // Daemon: event loop, window tracking, hotkeys, gesture integration, IPC server.
        .executableTarget(
            name: "shuttled",
            dependencies: [
                "ShuttleCore",
                "ShuttleScroller",
                .product(name: "WeftKit", package: "weft"),
            ]
        ),
        // CLI client: control socket commands, query layout status, inspect strip.
        .executableTarget(
            name: "shuttlectl",
            dependencies: [
                "ShuttleCore",
                .product(name: "WeftKit", package: "weft"),
            ]
        ),
        .testTarget(
            name: "ShuttleCoreTests",
            dependencies: ["ShuttleCore"]
        ),
    ]
)
