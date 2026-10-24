import AppKit

/// A slider inside a menu, like the volume slider in the macOS Sound menu: icon, slider, icon, value.
///
/// `onRelease` runs once, when you let go. Inside a menu, macOS does not always report the
/// mouse-up event, so we check the mouse button ourselves every 0.3 seconds while you drag.
final class MenuSlider: NSView {
    private let slider: NSSlider
    private let valueLabel = NSTextField(labelWithString: "")
    private let format: (Int) -> String
    private let onRelease: (Int) -> Void
    private var releaseCheck: DispatchWorkItem?
    /// The last value sent, so letting go on the same value does nothing.
    private var lastSent: Int?

    init(range: ClosedRange<Int>, lowIcon: String, highIcon: String,
         format: @escaping (Int) -> String, onRelease: @escaping (Int) -> Void) {
        slider = NSSlider(value: Double(range.lowerBound), minValue: Double(range.lowerBound),
                          maxValue: Double(range.upperBound), target: nil, action: nil)
        self.format = format
        self.onRelease = onRelease
        super.init(frame: NSRect(x: 0, y: 0, width: 250, height: 28))

        // Views inside a menu item use fixed frames. x = 14 lines the icon up with the other menu icons.
        let low = NSImageView(image: NSImage(systemSymbolName: lowIcon, accessibilityDescription: nil) ?? NSImage())
        let high = NSImageView(image: NSImage(systemSymbolName: highIcon, accessibilityDescription: nil) ?? NSImage())
        low.frame = NSRect(x: 14, y: 6, width: 16, height: 16)
        slider.frame = NSRect(x: 34, y: 4, width: 132, height: 20)
        high.frame = NSRect(x: 170, y: 6, width: 16, height: 16)
        valueLabel.frame = NSRect(x: 188, y: 6, width: 50, height: 16)
        valueLabel.alignment = .right
        valueLabel.textColor = .secondaryLabelColor

        slider.target = self
        slider.action = #selector(moved)
        slider.isContinuous = true  // call `moved` all the time while dragging, not only at the end
        [low, slider, high, valueLabel].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Puts the slider on a value without sending it. Call it before the menu opens.
    func show(_ value: Int) {
        slider.integerValue = value
        valueLabel.stringValue = format(value)
        lastSent = value
    }

    @objc private func moved() {
        valueLabel.stringValue = format(slider.integerValue)
        checkForReleaseSoon()
    }

    private func checkForReleaseSoon() {
        releaseCheck?.cancel()
        let check = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let leftButtonDown = NSEvent.pressedMouseButtons & 1 != 0
            if leftButtonDown {
                self.checkForReleaseSoon()  // still dragging: check again later
            } else if self.slider.integerValue != self.lastSent {
                self.lastSent = self.slider.integerValue
                self.onRelease(self.slider.integerValue)
            }
        }
        releaseCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: check)
    }
}

/// The goal row in the menu: an icon, "Goal: 1h 5m of 2h (54%)", and a progress bar under the text.
final class GoalView: NSView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 38))
        icon.frame = NSRect(x: 14, y: 18, width: 16, height: 16)
        label.frame = NSRect(x: 36, y: 18, width: 210, height: 16)
        label.textColor = .secondaryLabelColor
        bar.frame = NSRect(x: 36, y: 5, width: 200, height: 10)
        bar.style = .bar
        bar.controlSize = .small
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1  // the value is a fraction: 0.5 = half way
        [icon, label, bar].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(standingSeconds: Double, goalMinutes: Int) {
        let goalText = Goal.text(goalMinutes)
        let done = Format.duration(standingSeconds)
        let progress = min(standingSeconds / Double(goalMinutes * 60), 1)
        bar.doubleValue = progress

        if progress >= 1 {
            icon.image = NSImage(systemSymbolName: "checkmark.seal.fill", accessibilityDescription: nil)
            icon.contentTintColor = .systemGreen
            label.stringValue = "Goal reached: \(done) of \(goalText)"
        } else {
            icon.image = NSImage(systemSymbolName: "target", accessibilityDescription: nil)
            icon.contentTintColor = .secondaryLabelColor
            label.stringValue = "Goal: \(done) of \(goalText) (\(Int(progress * 100))%)"
        }
    }
}
