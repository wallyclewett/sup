import Combine
import Foundation

/// Standing and sitting seconds for one day.
struct DayTotals {
    var standing: Double = 0
    var sitting: Double = 0
}

/// Counts how long you stand and sit each day, while you are at the Mac.
///
/// - The position comes from the desk height (see `Presets.standingFromCm`).
/// - The height is read every 2 minutes, and live while the desk moves,
///   so moves made with the desk's own buttons are caught too.
/// - Time while the Mac is locked, in the screen saver or asleep is not counted.
///
/// Two log files, in `~/desk-control/`:
/// - `standup_log.json`: seconds standing and sitting per day, for example
///   `{"2026-10-24": {"standing": 660, "sitting": 540}}`
/// - `standup_sessions.csv`: one line for each stretch in one position:
///   `start,end,position,minutes`
final class Tracker {
    static let shared = Tracker()

    private let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("desk-control")
    private var dailyLogURL: URL { folder.appendingPathComponent("standup_log.json") }
    private var sessionsLogURL: URL { folder.appendingPathComponent("standup_sessions.csv") }

    /// The daily log, in the same shape as the JSON file: day → ["standing": s, "sitting": s].
    private var days: [String: [String: Double]] = [:]

    /// True = standing, false = sitting, nil = not known yet (no height report so far).
    private var standing: Bool?
    /// When the current stretch in one position started. Nil while you are away.
    private var positionSince: Date?
    private var away = false
    /// The last time we added time to the log (see `saveTimeSoFar`).
    private var lastSaved = Date()

    private var heightWatch: AnyCancellable?
    private var timer: Timer?

    init() {
        if let data = try? Data(contentsOf: dailyLogURL),
           let log = try? JSONDecoder().decode([String: [String: Double]].self, from: data) {
            days = log
        }
    }

    /// Start counting. Called once when the app starts.
    func start() {
        // Every new desk height: check if you changed position.
        heightWatch = Desk.shared.$heightCm
            .compactMap { $0 }  // skip nil (no height yet)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cm in self?.heightChanged(cm) }

        AwayWatcher.shared.start { [weak self] away in self?.awayChanged(away) }

        // Every 2 minutes: add the time so far to the log, and ask the desk for its height.
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.saveTimeSoFar()
            if !self.away { Desk.shared.refreshHeight() }
        }
    }

    // MARK: - Events

    private func heightChanged(_ cm: Double) {
        let nowStanding = cm >= Presets.standingFromCm
        guard nowStanding != standing else { return }  // same position: nothing to do
        saveTimeSoFar()   // the time until now belongs to the old position
        endStretch()
        standing = nowStanding
        positionSince = away ? nil : Date()
    }

    private func awayChanged(_ isAway: Bool) {
        saveTimeSoFar()
        if isAway { endStretch() }
        away = isAway
        // Coming back starts a new stretch, because you probably left the desk.
        positionSince = (isAway || standing == nil) ? nil : Date()
        if !isAway { Desk.shared.refreshHeight() }  // the desk may have moved while you were away
    }

    // MARK: - Reading

    /// "Standing for 12m 5s", or nil when the position is not known or you are away.
    func positionTimerText() -> String? {
        guard let since = positionSince, let standing = standing else { return nil }
        let seconds = Int(Date().timeIntervalSince(since))
        return "\(standing ? "Standing" : "Sitting") for \(Format.timer(seconds))"
    }

    /// Today's totals, up to this second.
    func todayTotals() -> DayTotals {
        saveTimeSoFar()
        return totals(for: Date())
    }

    /// The totals saved for a day.
    func totals(for date: Date) -> DayTotals {
        let day = days[Format.dayKey(date)] ?? [:]
        return DayTotals(standing: day["standing"] ?? 0, sitting: day["sitting"] ?? 0)
    }

    // MARK: - Writing

    /// Adds the time since the last save to the current position, then writes the daily log.
    private func saveTimeSoFar() {
        let now = Date()
        defer { lastSaved = now }
        guard !away, let standing = standing else { return }
        let seconds = now.timeIntervalSince(lastSaved)
        // Skip big gaps, for example when the app was not running. Saves happen at least every 2 minutes.
        guard seconds > 0, seconds < 600 else { return }
        days[Format.dayKey(now), default: [:]][standing ? "standing" : "sitting", default: 0] += seconds
        try? JSONEncoder().encode(days).write(to: dailyLogURL)
    }

    /// Ends the current stretch and adds one line to the sessions log. Stretches under 30 seconds are skipped.
    private func endStretch() {
        guard let since = positionSince, let standing = standing else { return }
        positionSince = nil
        let now = Date()
        let minutes = now.timeIntervalSince(since) / 60
        guard minutes >= 0.5 else { return }

        let line = [Format.timestamp(since), Format.timestamp(now),
                    standing ? "standing" : "sitting", String(format: "%.1f", minutes)].joined(separator: ",") + "\n"
        if !FileManager.default.fileExists(atPath: sessionsLogURL.path) {
            try? "start,end,position,minutes\n".write(to: sessionsLogURL, atomically: true, encoding: .utf8)
        }
        // Append to the end of the file, so earlier lines are never rewritten.
        if let file = try? FileHandle(forWritingTo: sessionsLogURL) {
            file.seekToEndOfFile()
            file.write(Data(line.utf8))
            try? file.close()
        }
    }
}
