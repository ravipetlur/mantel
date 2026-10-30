/// Who a running check is for. The schedule's check has no asker and says nothing unless it finds an update. A person who
/// asks while it runs (from the dots menu, from Settings, or both, one after the other) joins it, and each surface that
/// asked gets the answer: the popover and the line under Check Now, not only the one that asked last.
public struct CheckAskers: Equatable, Sendable {
    private var asked: Set<CheckSource> = []

    public init() {}

    /// `source` asked for the check that is running. Asking again changes nothing.
    public mutating func add(_ source: CheckSource) {
        asked.insert(source)
    }

    /// A person asked, so the check answers and ignores a skipped version.
    public var isManual: Bool { !asked.isEmpty }

    /// The surfaces to answer, in one fixed order (`CheckSource.allCases`), whoever asked first.
    public var sources: [CheckSource] {
        CheckSource.allCases.filter(asked.contains)
    }

    /// For the log: "background", "dots menu", "settings" or "dots menu and settings".
    public var logName: String {
        guard isManual else { return "background" }
        return sources.map(\.logName).joined(separator: " and ")
    }
}
