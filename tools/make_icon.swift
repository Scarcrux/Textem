import AppKit

// Renders an original Textem app icon (rounded-rect + speech bubble) to a
// 1024×1024 PNG. Deliberately not derived from Google's Messages mark.
// Run: swift tools/make_icon.swift  (writes tools/icon_1024.png)

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let full = NSRect(x: 0, y: 0, width: size, height: size)
let corner = size * 0.2237
let bg = NSBezierPath(roundedRect: full, xRadius: corner, yRadius: corner)
bg.addClip()

let gradient = NSGradient(colors: [
    NSColor(red: 0.20, green: 0.62, blue: 0.98, alpha: 1),
    NSColor(red: 0.09, green: 0.40, blue: 0.86, alpha: 1),
])!
gradient.draw(in: full, angle: -90)

// Speech bubble body.
let bubble = NSRect(x: size * 0.20, y: size * 0.32, width: size * 0.60, height: size * 0.42)
let body = NSBezierPath(roundedRect: bubble, xRadius: size * 0.11, yRadius: size * 0.11)

// Tail pointing down-left.
let tail = NSBezierPath()
tail.move(to: NSPoint(x: size * 0.34, y: size * 0.34))
tail.line(to: NSPoint(x: size * 0.26, y: size * 0.20))
tail.line(to: NSPoint(x: size * 0.46, y: size * 0.34))
tail.close()

NSColor.white.setFill()
body.fill()
tail.fill()

// Three dots.
let dotY = size * 0.53
let dotR = size * 0.045
for i in 0..<3 {
    let cx = size * 0.37 + Double(i) * size * 0.13
    let dot = NSBezierPath(ovalIn: NSRect(x: cx - dotR, y: dotY - dotR, width: dotR * 2, height: dotR * 2))
    NSColor(red: 0.12, green: 0.42, blue: 0.88, alpha: 1).setFill()
    dot.fill()
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("failed to render icon\n".utf8))
    exit(1)
}
try! png.write(to: URL(fileURLWithPath: "tools/icon_1024.png"))
print("wrote tools/icon_1024.png")
