// Generates docs/og-image.png (1200x630) — the social-share card for
// textem.scarcrux.com. Matches the landing page's CSS icon + wordmark.
// Run: swift tools/gen-og-image.swift
import AppKit

_ = NSApplication.shared  // init graphics context for offscreen text drawing

let W = 1200, H = 630
let img = NSImage(size: NSSize(width: W, height: H))
img.lockFocus()

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

// Background
color(0xf6f8fb).setFill()
NSRect(x: 0, y: 0, width: W, height: H).fill()

// Icon: rounded blue square with vertical gradient
let iconSize: CGFloat = 190
let iconX = (CGFloat(W) - iconSize) / 2
let iconY: CGFloat = 350
let iconRect = NSRect(x: iconX, y: iconY, width: iconSize, height: iconSize)
let iconPath = NSBezierPath(roundedRect: iconRect, xRadius: 44, yRadius: 44)
NSGradient(starting: color(0x33a0fa), ending: color(0x1766db))!.draw(in: iconPath, angle: -90)

// White speech bubble
let bw: CGFloat = 108, bh: CGFloat = 70
let bx = iconX + (iconSize - bw) / 2
let by = iconY + (iconSize - bh) / 2
NSColor.white.setFill()
NSBezierPath(roundedRect: NSRect(x: bx, y: by, width: bw, height: bh), xRadius: 22, yRadius: 22).fill()

// Three dots
color(0x1766db).setFill()
for i in 0..<3 {
    let d: CGFloat = 13
    NSBezierPath(ovalIn: NSRect(x: bx + 26 + CGFloat(i) * 26, y: by + bh / 2 - d / 2, width: d, height: d)).fill()
}

func draw(_ s: String, size: CGFloat, weight: NSFont.Weight, hex: UInt32, y: CGFloat) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color(hex),
    ]
    let sz = s.size(withAttributes: attrs)
    s.draw(at: NSPoint(x: (CGFloat(W) - sz.width) / 2, y: y), withAttributes: attrs)
}

draw("Textem", size: 96, weight: .bold, hex: 0x14181f, y: 210)
draw("Native Google Messages for macOS — free & open-source", size: 34, weight: .regular, hex: 0x5b6472, y: 140)

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("failed to render PNG\n".data(using: .utf8)!)
    exit(1)
}
let out = URL(fileURLWithPath: "docs/og-image.png")
try! png.write(to: out)
print("wrote \(out.path) (\(png.count) bytes)")
