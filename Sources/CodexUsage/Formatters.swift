import Foundation

enum UsageFormatters {
    static func percent(_ value: Double?) -> String {
        guard let value else { return "--%" }
        return "\(Int(value.rounded()))%"
    }

    static func compactTokens(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }

        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }

        return "\(value)"
    }

    static func resetText(_ date: Date?) -> String {
        guard let date else { return "重置时间未知" }
        if date <= Date() {
            return "即将重置"
        }
        return "\(relativeDateString(for: date, relativeTo: Date()))后重置"
    }

    static func relativeDateString(for date: Date, relativeTo referenceDate: Date = Date()) -> String {
        let seconds = Int(abs(date.timeIntervalSince(referenceDate)).rounded())

        if seconds < 60 {
            return "\(max(1, seconds)) 秒"
        }

        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes) 分钟"
        }

        let hours = minutes / 60
        if hours < 48 {
            return "\(hours) 小时"
        }

        let days = hours / 24
        return "\(days) 天"
    }

    static func shortDay(_ date: Date) -> String {
        shortDayFormatter.string(from: date)
    }

    static func fullDate(_ date: Date) -> String {
        fullDateFormatter.string(from: date)
    }

    static func fullDateTime(_ date: Date) -> String {
        fullDateTimeFormatter.string(from: date)
    }

    private static let shortDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter
    }()

    private static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/M/d"
        return formatter
    }()

    private static let fullDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/M/d HH:mm"
        return formatter
    }()
}
