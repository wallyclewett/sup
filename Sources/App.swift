// Sup ("Stand-Up Paddle"): a menu bar app for a Desky standing desk.
//
// Where to start reading:
//   App.swift          - this file: starts the app and handles clicks on the menu bar icon
//   StatusMenu.swift   - builds the menu you see on a left click
//   Desk.swift         - talks to the desk over Bluetooth
//   DeskProtocol.swift - the bytes the desk understands
//   Tracker.swift      - counts standing and sitting time, writes the logs
//   Reminder.swift     - the "Time to stand up" and "Time to sit down" popups
//   SettingsView.swift - the Settings window
//   Settings.swift     - every saved setting, in one place

import AppKit

/// The app's entry point. `@main` tells Swift to start here.
///
/// We use a plain AppKit app (not a SwiftUI `App`) because a SwiftUI menu bar extra
/// cannot tell a left click from a right click, and we need both.
@main
enum Main {
    // Keep a strong reference: NSApplication only holds its delegate weakly.
    static let delegate = AppDelegate()

    static func main() {
        NSApplication.shared.delegate = delegate
        NSApplication.shared.run()
    }
}

/// Owns the icon in the menu bar.
/// - Left click: opens the menu.
/// - Right click: moves the desk (stand if it is down, sit if it is up).
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The icon in the menu bar. `squareLength` makes it as wide as it is tall.
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    /// Made on first use (in `applicationDidFinishLaunching`), after the app has started.
    private lazy var menu = StatusMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let button = statusItem.button else { return }
        button.toolTip = "Sup (right click: stand / sit)"
        button.target = self
        button.action = #selector(iconClicked)
        // By default a status item button only reports left clicks. Ask for right clicks too.
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        // Start the parts that run in the background, even before the menu is ever opened.
        Tracker.shared.start()
        _ = Reminder.shared  // creating it starts the reminder clock

        // Redraw the icon whenever the desk height changes, so it shows stand or sit.
        menu.onDeskChange = { [weak self] in self?.updateIcon() }
        updateIcon()
    }

    @objc private func iconClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            Desk.shared.toggleStandSit()
        } else {
            menu.show(from: statusItem)
        }
    }

    /// The paddle blade is filled while the desk is at a standing height, outlined while sitting.
    private func updateIcon() {
        statusItem.button?.image = PaddleIcon.image(standing: Desk.shared.isStanding)
    }
}
