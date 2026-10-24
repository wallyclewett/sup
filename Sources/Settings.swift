import Foundation

/// Every key the app saves in UserDefaults, in one place.
///
/// UserDefaults is a small key-value store that macOS keeps for each app
/// (you can read it with `defaults read net.clewett.standup`).
/// Keeping the keys here means a typo cannot quietly create a second, empty setting.
///
/// Some names look odd ("remindersEnabled" for the stand-up reminder): they are kept
/// from older versions so settings that are already saved still work.
enum Key {
    static let lastPreset = "lastPreset"
    static let standingGoalMinutes = "standingGoalMinutes"

    // Reminders
    static let standReminderOn = "remindersEnabled"
    static let standPreset = "standPreset"
    static let sitReminderOn = "sitReminderEnabled"
    static let sitPreset = "sitPreset"
    static let reminderStartHour = "reminderStartHour"
    static let reminderEndHour = "reminderEndHour"
    static let reminderWeekdaysOnly = "reminderWeekdaysOnly"

    // Presets 1 to 4
    static func presetName(_ preset: Int) -> String { "presetName\(preset)" }
    /// A height you typed in Settings (stored as text, empty = not set).
    static func customHeight(_ preset: Int) -> String { "customHeight\(preset)" }
    /// The height of the desk's own preset, learned from the desk.
    static func deskPresetHeight(_ preset: Int) -> String { "presetHeight\(preset)" }
}

/// Read a saved value, or use `fallback` when nothing is saved yet.
/// (`UserDefaults.integer(forKey:)` returns 0 for a missing key, which we cannot tell apart from a real 0.)
func saved<T>(_ key: String, or fallback: T) -> T {
    UserDefaults.standard.object(forKey: key) as? T ?? fallback
}

// MARK: - Presets

/// The desk's 4 presets: their names and the heights they move to.
enum Presets {
    static let all = 1...4
    static let defaultNames = [1: "Sit", 2: "Stand", 3: "Preset 3", 4: "Preset 4"]

    /// The lowest and highest heights this desk can reach, in cm.
    static let heightRange = 60.0...125.0

    /// A desk height at or above this counts as standing.
    /// (The sit preset is about 63 cm; every standing preset is higher than 80 cm.)
    static let standingFromCm = 80.0

    static func name(_ preset: Int) -> String {
        let name = saved(Key.presetName(preset), or: "")
        return name.isEmpty ? defaultNames[preset] ?? "Preset \(preset)" : name
    }

    /// The height you set for this preset in Settings, or nil to use the desk's own preset.
    static func customHeight(_ preset: Int) -> Double? {
        let text = saved(Key.customHeight(preset), or: "")
        // Accept "97,5" as well as "97.5".
        guard let cm = Double(text.replacingOccurrences(of: ",", with: ".")),
              heightRange.contains(cm) else { return nil }
        return cm
    }
}

// MARK: - Goal

/// The daily standing goal, set in Settings.
enum Goal {
    /// The choices in Settings, in minutes. 0 = off.
    static let choices = [0, 30, 60, 90, 120, 150, 180, 240]

    static var minutes: Int { saved(Key.standingGoalMinutes, or: 120) }
    static var isOn: Bool { minutes > 0 }

    static func isMet(standingSeconds: Double) -> Bool {
        isOn && standingSeconds >= Double(minutes * 60)
    }

    /// "Off", "30m", "1h 30m" …
    static func text(_ minutes: Int) -> String {
        minutes == 0 ? "Off" : Format.duration(Double(minutes * 60))
    }
}
