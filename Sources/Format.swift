import Foundation

/// Turns numbers and dates into text for the menu and the log files.
///
/// Date formatters are slow to create, so we make each one once here and reuse it.
enum Format {
    /// "2026-10-24": the key for one day in the daily log.
    private static let dayKeyFormatter = formatter("yyyy-MM-dd")
    /// "Sat 24 Oct": a day in the "Last 7 days" menu.
    private static let dayNameFormatter = formatter("EEE d MMM")
    /// "2026-10-24 15:50": used so each reminder shows only once in its minute.
    private static let minuteKeyFormatter = formatter("yyyy-MM-dd HH:mm")
    /// "2026-10-24T15:50:00+10:00": start and end times in the sessions log.
    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter
    }()

    private static func formatter(_ pattern: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = pattern
        return formatter
    }

    static func dayKey(_ date: Date) -> String { dayKeyFormatter.string(from: date) }
    static func dayName(_ date: Date) -> String { dayNameFormatter.string(from: date) }
    static func minuteKey(_ date: Date) -> String { minuteKeyFormatter.string(from: date) }
    static func timestamp(_ date: Date) -> String { timestampFormatter.string(from: date) }

    /// "45m" or "1h 5m": for totals, where seconds do not matter.
    static func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    /// "12m 5s" or "1h 12m": for the live timer, which ticks every second.
    static func timer(_ seconds: Int) -> String {
        seconds >= 3600 ? "\(seconds / 3600)h \(seconds % 3600 / 60)m" : "\(seconds / 60)m \(seconds % 60)s"
    }

    /// "Standing 1h 5m, sitting 3h 40m (23%)". The % is the part of the time spent standing.
    static func summary(_ totals: DayTotals) -> String {
        let all = totals.standing + totals.sitting
        let percent = all > 0 ? Int((totals.standing / all * 100).rounded()) : 0
        return "Standing \(duration(totals.standing)), sitting \(duration(totals.sitting)) (\(percent)%)"
    }

    /// "09:00", "17:00"
    static func hour(_ hour: Int) -> String { String(format: "%02d:00", hour) }

    /// "63.1 cm"
    static func height(_ cm: Double) -> String { String(format: "%.1f cm", cm) }
}
