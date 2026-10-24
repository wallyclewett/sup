import AppKit

/// The menu bar icon: a tilted stand-up paddle (T-grip, shaft and blade).
/// The app icon in `make_icon.swift` uses the same shape, in colour.
enum PaddleIcon {
    /// Made once and reused, because the icon is redrawn many times.
    private static let standingImage = draw(standing: true)
    private static let sittingImage = draw(standing: false)

    /// The blade is filled while standing and outlined while sitting.
    static func image(standing: Bool) -> NSImage {
        standing ? standingImage : sittingImage
    }

    /// Draws the paddle in an 18 x 18 point box. (0, 0) is the bottom left corner.
    private static func draw(standing: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            // Tilt everything 30 degrees around the centre of the box.
            let tilt = NSAffineTransform()
            tilt.translateX(by: 9, yBy: 9)
            tilt.rotate(byDegrees: -30)
            tilt.translateX(by: -9, yBy: -9)
            tilt.concat()

            NSColor.black.set()
            // T-grip at the top, then the shaft.
            NSBezierPath(roundedRect: NSRect(x: 6.6, y: 16.2, width: 4.8, height: 1.6), xRadius: 0.8, yRadius: 0.8).fill()
            NSBezierPath(rect: NSRect(x: 8.4, y: 8, width: 1.2, height: 8.6)).fill()

            // Blade: narrow at the neck, widest near the tip.
            let blade = NSBezierPath()
            blade.move(to: NSPoint(x: 9, y: 8.5))
            blade.curve(to: NSPoint(x: 11.4, y: 2), controlPoint1: NSPoint(x: 9.6, y: 6.5), controlPoint2: NSPoint(x: 11.4, y: 4.5))
            blade.curve(to: NSPoint(x: 6.6, y: 2), controlPoint1: NSPoint(x: 11.4, y: 0.2), controlPoint2: NSPoint(x: 6.6, y: 0.2))
            blade.curve(to: NSPoint(x: 9, y: 8.5), controlPoint1: NSPoint(x: 6.6, y: 4.5), controlPoint2: NSPoint(x: 8.4, y: 6.5))
            blade.close()
            blade.lineWidth = 1.3
            blade.stroke()
            if standing { blade.fill() }
            return true
        }
        // A template image: macOS colours it to suit light and dark menu bars.
        image.isTemplate = true
        return image
    }
}
