import AppKit
import UserNotifications

/// The two hourly popups, shown only inside your reminder hours:
/// - at :50, "Time to stand up": its button moves the desk to the stand preset;
/// - at :00, "Time to sit down": its button moves the desk to the sit preset.
///
/// We check the clock ourselves every 20 seconds, instead of asking macOS to show the popups
/// on a timetable, because a timetable cannot skip the hours outside your range.
///
/// `ObservableObject` lets the Settings window bind its switches and pickers to these values.
final class Reminder: NSObject, ObservableObject {
    static let shared = Reminder()

    enum Kind: String {
        case stand, sit
    }

    // Every setting saves itself as soon as it changes (`didSet`).
    @Published var standOn: Bool = saved(Key.standReminderOn, or: true) { didSet { save(standOn, Key.standReminderOn) } }
    @Published var standPreset: Int = saved(Key.standPreset, or: 2) { didSet { save(standPreset, Key.standPreset) } }
    @Published var sitOn: Bool = saved(Key.sitReminderOn, or: false) { didSet { save(sitOn, Key.sitReminderOn) } }
    @Published var sitPreset: Int = saved(Key.sitPreset, or: 1) { didSet { save(sitPreset, Key.sitPreset) } }
    @Published var startHour: Int = saved(Key.reminderStartHour, or: 9) { didSet { save(startHour, Key.reminderStartHour) } }
    @Published var endHour: Int = saved(Key.reminderEndHour, or: 17) { didSet { save(endHour, Key.reminderEndHour) } }
    @Published var weekdaysOnly: Bool = saved(Key.reminderWeekdaysOnly, or: true) {
        didSet { save(weekdaysOnly, Key.reminderWeekdaysOnly) }
    }

    /// False when notifications for Sup are turned off in System Settings.
    @Published private(set) var allowed = true

    private let center = UNUserNotificationCenter.current()
    private var timer: Timer?
    /// The minute of the last popup ("2026-10-24 15:50"), so each popup shows only once.
    private var lastShownMinute = ""

    override init() {
        super.init()
        center.delegate = self

        // A "category" adds a button to the popup. The button's identifier comes back in `didReceive` below.
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "STAND", actions: [UNNotificationAction(identifier: "STAND_UP", title: "Stand up")],
                                   intentIdentifiers: []),
            UNNotificationCategory(identifier: "SIT", actions: [UNNotificationAction(identifier: "SIT_DOWN", title: "Sit down")],
                                   intentIdentifiers: []),
        ])
        center.removePendingNotificationRequests(withIdentifiers: ["stand"])  // clean up the old timetable from earlier versions
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in self?.checkAllowed() }

        // `.common` mode keeps the timer running while a menu is open.
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func save(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    /// Updates `allowed` from System Settings. The answer arrives on a background thread.
    func checkAllowed() {
        center.getNotificationSettings { settings in
            let allowed = settings.authorizationStatus == .authorized
            DispatchQueue.main.async { self.allowed = allowed }
        }
    }

    // MARK: - When

    /// The popup due at this minute, if any.
    /// Stand-up: :50, from the start hour. Sit-down: :00, up to and including the end hour.
    /// With 9:00 to 17:00 that gives stand at 9:50 … 16:50 and sit at 10:00 … 17:00.
    func due(at date: Date) -> Kind? {
        let parts = Calendar.current.dateComponents([.hour, .minute, .weekday], from: date)
        guard let hour = parts.hour, let minute = parts.minute, let weekday = parts.weekday else { return nil }
        if weekdaysOnly && (weekday == 1 || weekday == 7) { return nil }  // 1 = Sunday, 7 = Saturday
        if minute == 50 && standOn && hour >= startHour && hour < endHour { return .stand }
        if minute == 0 && sitOn && hour > startHour && hour <= endHour { return .sit }
        return nil
    }

    /// When this popup will show next, within the next 8 days (for the Settings window).
    func nextTime(_ kind: Kind) -> Date? {
        guard let thisHour = Calendar.current.dateInterval(of: .hour, for: Date())?.start else { return nil }
        let minute: TimeInterval = kind == .stand ? 50 : 0
        for hoursAhead in 0..<(8 * 24) {
            let time = thisHour.addingTimeInterval(Double(hoursAhead) * 3600 + minute * 60)
            if time > Date() && due(at: time) == kind { return time }
        }
        return nil
    }

    // MARK: - Showing

    /// The test buttons in Settings.
    func test(_ kind: Kind) {
        show(kind)
    }

    private func tick() {
        let now = Date()
        let minute = Format.minuteKey(now)
        guard minute != lastShownMinute, let kind = due(at: now) else { return }
        lastShownMinute = minute
        show(kind)
    }

    private func show(_ kind: Kind) {
        let content = UNMutableNotificationContent()
        switch kind {
        case .stand:
            content.title = "Time to stand up"
            content.body = "Click Stand up to move the desk to \(Presets.name(standPreset))."
            content.categoryIdentifier = "STAND"
        case .sit:
            content.title = "Time to sit down"
            content.body = "Click Sit down to move the desk to \(Presets.name(sitPreset))."
            content.categoryIdentifier = "SIT"
        }
        content.sound = .default
        // No trigger = show now. A new identifier each time, so a new popup never replaces an old one.
        center.add(UNNotificationRequest(identifier: "\(kind.rawValue)-\(UUID().uuidString)", content: content, trigger: nil))
    }
}

// MARK: - Popup callbacks

extension Reminder: UNUserNotificationCenterDelegate {
    /// Show the popup even when Sup is the active app.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// A button on the popup was clicked.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async {
            switch response.actionIdentifier {
            case "STAND_UP": Desk.shared.goTo(preset: self.standPreset)
            case "SIT_DOWN": Desk.shared.goTo(preset: self.sitPreset)
            default: break  // the popup itself was clicked, not a button
            }
        }
        completionHandler()
    }
}
