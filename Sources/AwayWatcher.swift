import AppKit

/// Tells you when you are away from the Mac: the screen is locked, the screen saver is on, or the Mac is asleep.
///
/// The three are tracked separately, because they overlap: for example, the screen saver
/// can stop while the screen is still locked. You are "away" while any of them is true.
final class AwayWatcher {
    static let shared = AwayWatcher()

    private var locked = false
    private var screenSaver = false
    private var asleep = false
    private var wasAway = false
    private var onChange: (Bool) -> Void = { _ in }

    /// Start watching. `onChange(true)` runs when you leave, `onChange(false)` when you come back.
    func start(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange

        // Lock and screen saver events are "distributed" notifications: macOS sends them to every app.
        let events: [(name: String, apply: (AwayWatcher) -> Void)] = [
            ("com.apple.screenIsLocked", { $0.locked = true }),
            ("com.apple.screenIsUnlocked", { $0.locked = false }),
            ("com.apple.screensaver.didstart", { $0.screenSaver = true }),
            ("com.apple.screensaver.didstop", { $0.screenSaver = false }),
        ]
        for event in events {
            DistributedNotificationCenter.default().addObserver(forName: Notification.Name(event.name),
                                                                object: nil, queue: .main) { [weak self] _ in
                guard let self = self else { return }
                event.apply(self)
                self.check()
            }
        }

        // Sleep and wake come from NSWorkspace instead.
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.asleep = true
            self?.check()
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.asleep = false
            self?.check()
        }
    }

    /// Calls `onChange` only when "away" really changes.
    private func check() {
        let away = locked || screenSaver || asleep
        guard away != wasAway else { return }
        wasAway = away
        onChange(away)
    }
}
