import Foundation

/// Keeps the Backups folder from growing for ever: of the copies of one thing, the oldest and the newest are kept.
public enum BackupPruner {
    /// How a backup's time is written in its name: `yyyyMMdd-HHmmss` in UTC, then `Z` (`20261101-053000Z`). UTC, so that a change of
    /// the clock (the end of summer time repeats an hour) never puts a newer copy before an older one.
    public static func stamp(for date: Date) -> String {
        let components = Calendar(identifier: .gregorian).dateComponents(in: .gmt, from: date)
        return String(format: "%04ld%02ld%02ld-%02ld%02ld%02ldZ", components.year ?? 0, components.month ?? 0, components.day ?? 0,
                      components.hour ?? 0, components.minute ?? 0, components.second ?? 0)
    }

    /// Keeps the `keepOldest` oldest and the `keepNewest` newest of the files in `folder` named
    /// `<stem>-<yyyyMMdd-HHmmss>[Z][-n].<pathExtension>`, and deletes the rest. "Oldest" and "newest" are by the time in the name,
    /// and for two files of the same second by their number (the first one has none). A name that ends its time in `Z` is in UTC
    /// (`stamp(for:)`); one without is an earlier version's, in the local time of `localTimeZone`. A file of any other name, or with
    /// a time that isn't one, is left alone, also one that starts with the same stem (`<stem>-v1-…` is not a copy of `<stem>`).
    ///
    /// Every deletion is tried; if some failed, the first failure is thrown afterwards.
    public static func prune(in folder: URL, stem: String, pathExtension: String, keepOldest: Int, keepNewest: Int,
                             localTimeZone: TimeZone = .current) throws {
        let fileManager = FileManager.default
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return
        }

        let copies = names.compactMap { name in
            copy(named: name, stem: stem, pathExtension: pathExtension, localTimeZone: localTimeZone).map { (name: name, order: $0) }
        }
        .sorted { ($0.order.date, $0.order.number, $0.name) < ($1.order.date, $1.order.number, $1.name) }

        let oldest = max(keepOldest, 0)
        let newest = max(keepNewest, 0)
        guard copies.count > oldest + newest else { return }

        var firstFailure: (any Error)?
        for copy in copies[oldest ..< (copies.count - newest)] {
            do {
                try fileManager.removeItem(at: folder.appending(path: copy.name, directoryHint: .notDirectory))
            } catch {
                firstFailure = firstFailure ?? error
            }
        }
        if let firstFailure { throw firstFailure }
    }

    /// The time and number in the name, when the name is `<stem>-<yyyyMMdd-HHmmss>[Z][-n].<pathExtension>` exactly and the time is a
    /// real one.
    private static func copy(named name: String, stem: String, pathExtension: String,
                             localTimeZone: TimeZone) -> (date: Date, number: Int)? {
        let prefix = "\(stem)-"
        let suffix = ".\(pathExtension)"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix), name.count > prefix.count + suffix.count else { return nil }
        let middle = String(name.dropFirst(prefix.count).dropLast(suffix.count))
        guard let match = middle.wholeMatch(of: #/(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})(Z)?(?:-(\d+))?/#),
              let date = date(year: match.1, month: match.2, day: match.3, hour: match.4, minute: match.5, second: match.6,
                              in: match.7 == nil ? localTimeZone : .gmt)
        else { return nil }
        return (date, match.8.flatMap { Int($0) } ?? 1)
    }

    /// The time the digits say in `timeZone`; nil when they aren't a time (month 13, minute 61).
    private static func date(year: Substring, month: Substring, day: Substring, hour: Substring, minute: Substring, second: Substring,
                             in timeZone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = DateComponents(year: Int(year), month: Int(month), day: Int(day), hour: Int(hour), minute: Int(minute),
                                   second: Int(second))
        guard let date = calendar.date(from: parts) else { return nil }
        // `date(from:)` carries an overflowing field into the next one (day 40 of a month) instead of refusing it.
        let back = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard back.year == parts.year, back.month == parts.month, back.day == parts.day, back.hour == parts.hour,
              back.minute == parts.minute, back.second == parts.second
        else { return nil }
        return date
    }
}
