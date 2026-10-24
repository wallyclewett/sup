import AppKit

/// A menu item that runs a closure when you click it.
///
/// A normal NSMenuItem needs a `target` object and a `#selector`. This class is its own target,
/// so you can write `ActionItem("Quit") { NSApp.terminate(nil) }` instead.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}

extension NSMenuItem {
    /// Adds an SF Symbol icon on the left, and returns the item, so you can write `NSMenuItem().icon("timer")`.
    /// Browse the symbols in Apple's free "SF Symbols" app.
    @discardableResult
    func icon(_ symbol: String) -> Self {
        setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: nil))
        return self
    }

    /// Uses a bold number as the icon. The SF Symbol numbers in circles are too small to read in a menu.
    @discardableResult
    func numberIcon(_ number: Int) -> Self {
        let text = NSAttributedString(string: "\(number)", attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .bold),
            .foregroundColor: NSColor.black,
        ])
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let size = text.size()
            text.draw(at: NSPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2))
            return true
        }
        // A "template" image is drawn in the menu's text colour (black, white when highlighted).
        image.isTemplate = true
        setImage(image)
        return self
    }

    /// macOS 27 hides menu item images unless the item asks to show them.
    private func setImage(_ newImage: NSImage?) {
        image = newImage
        if #available(macOS 27.0, *) {
            preferredImageVisibility = .visible
        }
    }
}
