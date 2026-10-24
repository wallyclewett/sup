import AppKit
import ServiceManagement
import SwiftUI

/// The Settings window, written in SwiftUI.
///
/// `@AppStorage("key")` reads and writes a UserDefaults value directly, and redraws the view when it changes.
/// `@ObservedObject` does the same for the values in `Reminder.shared`.
struct SettingsView: View {
    var body: some View {
        Form {
            GeneralSection()
            GoalSection()
            ReminderSections()
            ForEach(Presets.all, id: \.self) { PresetSection(preset: $0) }
            Text("Leave a height empty to use the desk's own preset. A height you type here is used only by this app, "
                 + "not by the buttons on the desk. Right click always moves between preset 1 and preset 2.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 640)  // a grouped form has no height of its own; it scrolls inside this
    }
}

/// Opens the Settings window (only one) and brings it to the front.
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.setContentSize(NSSize(width: 440, height: 640))
            window.title = "Sup Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false  // keep it, so the next "Settings…" reuses it
            window.center()
            self.window = window
        }
        Reminder.shared.checkAllowed()
        // Sup has no Dock icon, so we must bring it to the front ourselves.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Sections

private struct GeneralSection: View {
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Section("General") {
            Toggle("Open Sup when you log in", isOn: $openAtLogin)
                .onChange(of: openAtLogin) { _, on in
                    try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                }
        }
    }
}

private struct GoalSection: View {
    @AppStorage(Key.standingGoalMinutes) private var goalMinutes = 120

    var body: some View {
        Section("Daily standing goal") {
            Picker("Stand for at least", selection: $goalMinutes) {
                ForEach(Goal.choices, id: \.self) { Text(Goal.text($0)).tag($0) }
            }
            Note("The menu shows your progress for today. Days that reach the goal get a ✓ in Last 7 days.")
        }
    }
}

private struct ReminderSections: View {
    @ObservedObject private var reminder = Reminder.shared

    var body: some View {
        Section("Reminder hours") {
            Picker("From", selection: $reminder.startHour) {
                ForEach(0..<24, id: \.self) { Text(Format.hour($0)).tag($0) }
            }
            Picker("To", selection: $reminder.endHour) {
                ForEach(1...24, id: \.self) { Text(Format.hour($0)).tag($0) }
            }
            Toggle("Weekdays only (Monday to Friday)", isOn: $reminder.weekdaysOnly)
            if reminder.startHour >= reminder.endHour {
                Note("\"From\" must be earlier than \"To\". No reminders will show.", warning: true)
            }
            if !reminder.allowed {
                Button("Notifications are off for Sup. Open Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                }
                .foregroundStyle(.red)
            }
        }
        Section("Stand-up reminder") {
            Toggle("Remind me to stand up at 10 minutes to the hour", isOn: $reminder.standOn)
            Picker("Stand up moves the desk to", selection: $reminder.standPreset) { presetChoices }
            Note("Shows at :50 (9:50, 10:50 …) inside your hours.")
            LabeledContent("Next reminder", value: nextText(.stand, isOn: reminder.standOn))
            Button("Test the stand-up reminder now") { reminder.test(.stand) }
        }
        Section("Sit-down reminder") {
            Toggle("Remind me to sit down on the hour", isOn: $reminder.sitOn)
            Picker("Sit down moves the desk to", selection: $reminder.sitPreset) { presetChoices }
            Note("Shows at :00 (10:00, 11:00 …) inside your hours.")
            LabeledContent("Next reminder", value: nextText(.sit, isOn: reminder.sitOn))
            Button("Test the sit-down reminder now") { reminder.test(.sit) }
        }
    }

    private var presetChoices: some View {
        ForEach(Presets.all, id: \.self) { Text("\(Presets.name($0)) (preset \($0))").tag($0) }
    }

    /// "4:50 pm" today, or "Monday 9:50 am" on another day.
    private func nextText(_ kind: Reminder.Kind, isOn: Bool) -> String {
        guard isOn else { return "Off" }
        guard let next = reminder.nextTime(kind) else { return "None in the next 8 days" }
        let day = Calendar.current.isDateInToday(next) ? "" : next.formatted(.dateTime.weekday(.wide)) + " "
        return day + next.formatted(date: .omitted, time: .shortened)
    }
}

/// One preset: its name, its height, and a button to use the desk's height now.
private struct PresetSection: View {
    let preset: Int
    @AppStorage private var name: String
    @AppStorage private var height: String

    init(preset: Int) {
        self.preset = preset
        // The keys depend on the preset number, so the property wrappers are set up here instead of inline.
        _name = AppStorage(wrappedValue: "", Key.presetName(preset))
        _height = AppStorage(wrappedValue: "", Key.customHeight(preset))
    }

    var body: some View {
        Section("Preset \(preset)") {
            TextField("Name", text: $name, prompt: Text(Presets.defaultNames[preset] ?? ""))
            HStack {
                TextField("Height (cm)", text: $height, prompt: Text(emptyHeightHint))
                Button("Use current height") {
                    if let cm = Desk.shared.heightCm { height = String(format: "%.1f", cm) }
                }
            }
            if !height.isEmpty && Presets.customHeight(preset) == nil {
                Note("Type a height from 60 to 125 cm, or leave it empty.", warning: true)
            }
        }
    }

    /// Grey text in an empty height box: the desk's own preset is used, and its height if we know it.
    private var emptyHeightHint: String {
        guard let cm = Desk.shared.deskPresetHeights[preset] else { return "Desk preset" }
        return String(format: "Desk preset (%.1f)", cm)
    }
}

/// Small grey (or red) help text under a setting.
private struct Note: View {
    let text: String
    var warning = false

    init(_ text: String, warning: Bool = false) {
        self.text = text
        self.warning = warning
    }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(warning ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
    }
}
