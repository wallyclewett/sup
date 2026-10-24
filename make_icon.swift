// Draws Sup's app icon: a SUP paddle on water, in colour.
// Usage: swift make_icon.swift <output.png>   (makes one 1024 x 1024 PNG)
// build_icon.sh turns that PNG into AppIcon.icns.

import AppKit

let size: CGFloat = 1024

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    // macOS icon shape: rounded square with a small margin
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    shape.addClip()

    // Sky to sea
    NSGradient(colors: [NSColor(red: 0.47, green: 0.84, blue: 0.96, alpha: 1),
                        NSColor(red: 0.07, green: 0.42, blue: 0.75, alpha: 1)])!
        .draw(in: tile, angle: -90)

    // Two waves near the bottom
    for (offset, alpha) in [(CGFloat(0), CGFloat(0.35)), (CGFloat(-90), CGFloat(0.55))] {
        let wave = NSBezierPath()
        let y = 300 + offset
        wave.move(to: NSPoint(x: tile.minX, y: y))
        for step in 0..<4 {
            let x = tile.minX + CGFloat(step) * 206
            wave.curve(to: NSPoint(x: x + 206, y: y),
                       controlPoint1: NSPoint(x: x + 70, y: y + 60),
                       controlPoint2: NSPoint(x: x + 136, y: y - 60))
        }
        wave.line(to: NSPoint(x: tile.maxX, y: tile.minY))
        wave.line(to: NSPoint(x: tile.minX, y: tile.minY))
        wave.close()
        NSColor(red: 0.03, green: 0.25, blue: 0.55, alpha: alpha).setFill()
        wave.fill()
    }

    // The paddle: same shape as the menu bar icon (18 x 18 units), scaled up and tilted
    NSGraphicsContext.saveGraphicsState()
    let scale: CGFloat = 40
    let move = NSAffineTransform()
    move.translateX(by: size / 2, yBy: size / 2 + 10)
    move.rotate(byDegrees: -30)
    move.scale(by: scale)
    move.translateX(by: -9, yBy: -9)
    move.concat()

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 18
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()

    // T-grip and shaft: dark carbon
    NSColor(white: 0.16, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 6.6, y: 16.2, width: 4.8, height: 1.6), xRadius: 0.8, yRadius: 0.8).fill()
    NSBezierPath(rect: NSRect(x: 8.45, y: 8, width: 1.1, height: 8.6)).fill()

    // Blade: bright orange, with a lighter middle line
    let blade = NSBezierPath()
    blade.move(to: NSPoint(x: 9, y: 8.5))
    blade.curve(to: NSPoint(x: 11.4, y: 2), controlPoint1: NSPoint(x: 9.6, y: 6.5), controlPoint2: NSPoint(x: 11.4, y: 4.5))
    blade.curve(to: NSPoint(x: 6.6, y: 2), controlPoint1: NSPoint(x: 11.4, y: 0.2), controlPoint2: NSPoint(x: 6.6, y: 0.2))
    blade.curve(to: NSPoint(x: 9, y: 8.5), controlPoint1: NSPoint(x: 6.6, y: 4.5), controlPoint2: NSPoint(x: 8.4, y: 6.5))
    blade.close()
    NSColor(red: 1.0, green: 0.55, blue: 0.15, alpha: 1).setFill()
    blade.fill()
    NSShadow().set()
    NSColor(red: 1.0, green: 0.78, blue: 0.45, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(x: 8.85, y: 1.6, width: 0.3, height: 6)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return true
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
