import Foundation

/// The "Last checked" line in Settings › About.
public enum LastChecked {
    /// "Last checked: never", "Last checked: just now" (under a minute, or a time that hasn't come because the clock
    /// moved back), or "Last checked: 5 minutes ago", "2 hours ago", "yesterday", "3 days ago". The wording of the
    /// relative time is `locale`'s.
    public static func text(lastCheck: Date?, now: Date, locale: Locale = .current) -> String {
        guard let lastCheck else { return "Last checked: never" }
        guard now.timeIntervalSince(lastCheck) >= 60 else { return "Last checked: just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return "Last checked: " + formatter.localizedString(for: lastCheck, relativeTo: now)
    }
}
