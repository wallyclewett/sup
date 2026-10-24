import AppKit
import Combine

/// The menu that opens on a left click of the paddle icon.
///
/// The items are made once. `refresh()` updates their text before the menu opens,
/// and again whenever the desk reports something new.
final class StatusMenu {
    /// Runs when the desk's height or status changes, so the app can redraw the menu bar icon.
    var onDeskChange: () -> Void = {}

    private let menu = NSMenu()
    private var deskWatch: AnyCancellable?

    // Info lines. They have no action, so macOS shows them in grey and you cannot click them.
    private let timerLine = NSMenuItem().icon("timer")
    private let statusLine = NSMenuItem().icon("antenna.radiowaves.left.and.right")
    private let heightLine = NSMenuItem().icon("ruler")
    private let todayLine = NSMenuItem().icon("chart.bar")
    private let historyItem = NSMenuItem(title: "Last 7 days", action: nil, keyEquivalent: "").icon("calendar")

    // Rows with their own views.
    private let goalView = GoalView()
    private let goalItem = NSMenuItem()
    private let heightSlider = MenuSlider(range: 60...125, lowIcon: "chair", highIcon: "figure.stand",
                                          format: { "\($0) cm" },
                                          onRelease: { Desk.shared.goTo(cm: Double($0)) })

    // Clickable items.
    private let presetItems = Presets.all.map { preset in
        ActionItem("") { Desk.shared.goTo(preset: preset) }.numberIcon(preset)
    }
    private let notificationsOffItem = ActionItem("Notifications are off: open Settings") {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
    }.icon("exclamationmark.triangle")

    init() {
        buildMenu()
        // Desk.objectWillChange fires just before a @Published value changes. `receive(on:)` waits
        // until the change is done, so `refresh()` reads the new values.
        deskWatch = Desk.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.refresh()
                self?.onDeskChange()
            }
    }

    private func buildMenu() {
        menu.addItem(timerLine)
        menu.addItem(.separator())
        menu.addItem(statusLine)
        menu.addItem(heightLine)
        menu.addItem(.separator())
        menu.addItem(todayLine)
        goalItem.view = goalView
        menu.addItem(goalItem)
        historyItem.submenu = NSMenu()
        menu.addItem(historyItem)
        menu.addItem(.separator())
        let sliderItem = NSMenuItem()
        sliderItem.view = heightSlider
        menu.addItem(sliderItem)
        presetItems.forEach(menu.addItem)
        menu.addItem(.separator())
        menu.addItem(notificationsOffItem)
        menu.addItem(ActionItem("Settings…") { SettingsWindow.shared.show() }.icon("gearshape"))
        menu.addItem(.separator())
        menu.addItem(ActionItem("Quit") { NSApp.terminate(nil) }.icon("xmark.circle"))
    }

    /// Opens the menu under the menu bar icon. Returns when the menu closes.
    func show(from statusItem: NSStatusItem) {
        Reminder.shared.checkAllowed()
        refresh()
        heightSlider.show(Int((Desk.shared.heightCm ?? 100).rounded()))

        // Tick the timer line every second while the menu is open.
        // `.common` mode is needed: normal timers pause while a menu is open.
        let ticker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refreshTimerLine() }
        RunLoop.main.add(ticker, forMode: .common)

        // Attaching the menu and "clicking" the button opens it. This call waits until the menu closes.
        // Then we detach it again, so the next click comes back to AppDelegate.iconClicked.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
        ticker.invalidate()
    }

    // MARK: - Updating the text

    private func refresh() {
        let desk = Desk.shared
        refreshTimerLine()
        statusLine.title = "Desk: \(desk.status.rawValue)"
        heightLine.title = "Height: " + (desk.heightCm.map(Format.height) ?? "Unknown")

        let today = Tracker.shared.todayTotals()
        todayLine.title = "Today: " + Format.summary(today)
        goalItem.isHidden = !Goal.isOn
        if Goal.isOn {
            goalView.show(standingSeconds: today.standing, goalMinutes: Goal.minutes)
        }

        refreshHistory()
        refreshPresets()
        notificationsOffItem.isHidden = Reminder.shared.allowed
    }

    /// The top line, in bold and the normal text colour, so it stands out from the grey info lines.
    private func refreshTimerLine() {
        let text = Tracker.shared.positionTimerText() ?? "Position not known yet"
        timerLine.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ])
    }

    /// One line per day for the last 7 days, with a ✓ on days that reached the goal.
    private func refreshHistory() {
        guard let submenu = historyItem.submenu else { return }
        submenu.removeAllItems()
        for daysAgo in 1...7 {
            guard let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) else { continue }
            let totals = Tracker.shared.totals(for: date)
            let tick = Goal.isMet(standingSeconds: totals.standing) ? " ✓" : ""
            submenu.addItem(NSMenuItem(title: "\(Format.dayName(date)): \(Format.summary(totals))\(tick)",
                                       action: nil, keyEquivalent: ""))
        }
    }

    /// "Sit (63.0 cm)". The number icon already shows which preset it is.
    /// The height is the one set in Settings, or else the desk's own preset height, if known.
    private func refreshPresets() {
        for (preset, item) in zip(Presets.all, presetItems) {
            let cm = Presets.customHeight(preset) ?? Desk.shared.deskPresetHeights[preset]
            item.title = Presets.name(preset) + (cm.map { " (\(Format.height($0)))" } ?? "")
        }
    }
}
