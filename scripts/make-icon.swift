// Draws Shuttle's app icon and builds extra/AppIcon.icns.
//
//   swift scripts/make-icon.swift            # the icon
//   swift scripts/make-icon.swift --variants # every palette, for comparing
//
// The picture is the app: a ribbon of columns running off both edges, the
// focused one solid. Flat colour, no gradients or glow.

import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let extra = root.appendingPathComponent("extra")

struct Palette {
    var name: String
    var background: UInt32
    var focused: UInt32
    var others: UInt32
    var othersAlpha: CGFloat
}

let palettes = [
    Palette(name: "graphite", background: 0x1C1C1E, focused: 0xFF6B5B, others: 0xFFFFFF, othersAlpha: 0.22),
    Palette(name: "paper", background: 0xF4F3EF, focused: 0x1C1C1E, others: 0x1C1C1E, othersAlpha: 0.16),
    Palette(name: "coral", background: 0xFF6B5B, focused: 0xFFFFFF, others: 0xFFFFFF, othersAlpha: 0.35),
]
let chosen = palettes[0]

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255, alpha: alpha
    )
}

func draw(size: CGFloat, _ p: Palette) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.cgContext.scaleBy(x: size / 1024, y: size / 1024)

    // macOS icon grid: an 824pt body centered in 1024.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = 20
    shadow.shadowOffset = NSSize(width: 0, height: -8)
    shadow.set()
    color(p.background).setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    // Three columns: the focused one in the middle, its neighbours cut by
    // the edges because the ribbon goes on.
    let w: CGFloat = 300, gap: CGFloat = 60, h: CGFloat = 500, y: CGFloat = 262, r: CGFloat = 52
    for i in -1...1 {
        let x = 512 - w / 2 + CGFloat(i) * (w + gap)
        let column = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r)
        (i == 0 ? color(p.focused) : color(p.others, p.othersAlpha)).setFill()
        column.fill()
    }
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func png(_ rep: NSBitmapImageRep) -> Data { rep.representation(using: .png, properties: [:])! }

if CommandLine.arguments.contains("--variants") {
    for p in palettes {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shuttle-icon-\(p.name).png")
        try png(draw(size: 512, p)).write(to: url)
        print(url.path)
    }
    exit(0)
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Shuttle.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try png(draw(size: CGFloat(base * scale), chosen)).write(to: iconset.appendingPathComponent(name))
    }
}
try png(draw(size: 1024, chosen)).write(to: extra.appendingPathComponent("AppIcon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", extra.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote extra/AppIcon.icns and extra/AppIcon.png (\(chosen.name))" : "iconutil failed")
