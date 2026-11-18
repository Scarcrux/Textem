// Generates docs/og-image.png (1200x630) — the social-share card for
// textem.scarcrux.com: the real app icon plus wordmark.
// Run: swift tools/gen-og-image.swift
import AppKit

_ = NSApplication.shared  // init graphics context for offscreen text drawing

let W = 1200, H = 630
// Draw into an sRGB bitmap. Drawing via NSImage.lockFocus used the display's
// colour space (Display P3 here) and saved the PNG untagged, so browsers read
// P3 values as sRGB and the icon came out more saturated than the app's.
let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!.retagging(with: .sRGB)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

// Background
color(0xf6f8fb).setFill()
NSRect(x: 0, y: 0, width: W, height: H).fill()

// The real app icon (Resources/AppIcon.icns), so the card matches the app.
let iconSize: CGFloat = 210
let iconRect = NSRect(x: (CGFloat(W) - iconSize) / 2, y: 340, width: iconSize, height: iconSize)
guard let appIcon = NSImage(contentsOfFile: "Resources/AppIcon.icns") else {
    FileHandle.standardError.write("Resources/AppIcon.icns not found; run from the repo root\n".data(using: .utf8)!)
    exit(1)
}
appIcon.draw(in: iconRect)

func draw(_ s: String, size: CGFloat, weight: NSFont.Weight, hex: UInt32, y: CGFloat) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color(hex),
    ]
    let sz = s.size(withAttributes: attrs)
    s.draw(at: NSPoint(x: (CGFloat(W) - sz.width) / 2, y: y), withAttributes: attrs)
}

draw("Textem", size: 96, weight: .bold, hex: 0x14181f, y: 210)
draw("A macOS wrapper for Google Messages — free & open-source", size: 34, weight: .regular, hex: 0x5b6472, y: 140)

NSGraphicsContext.restoreGraphicsState()

guard let png = canvas.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("failed to render PNG\n".data(using: .utf8)!)
    exit(1)
}
let out = URL(fileURLWithPath: "docs/og-image.png")
try! png.write(to: out)
print("wrote \(out.path) (\(png.count) bytes)")
