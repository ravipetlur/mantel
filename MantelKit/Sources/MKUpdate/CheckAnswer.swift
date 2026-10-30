import Foundation

/// What a manual check says, from the moment it starts to its end, in the words and marks of the surface that asked
/// (`CheckSource`): the popover under the dot, or the line under Check Now in Settings › About. Pure: the app
/// draws what this says, and decides nothing about the words.
///
/// | Outcome | Popover under the dot | Line in Settings › About |
/// |---|---|---|
/// | checking | spinner, "Checking for updates…" | spinner, "Checking…" |
/// | up to date | checkmark, "Mantel is up to date (X.Y.Z)"; closes by itself | checkmark, the same words |
/// | failed | warning, "Couldn't check for updates", the reason, OK | warning, the reason |
/// | found | nothing: it closes, and the update window opens | "Version X.Y.Z is available" |
public struct CheckAnswer: Equatable, Sendable {
    /// Where a check stands or how it ended.
    public enum Outcome: Equatable, Sendable {
        /// The check is running.
        case checking
        /// Nothing newer than this version, the one the check compared with.
        case upToDate(VersionNumber)
        /// The check didn't work.
        case failed(UpdateFailure)
        /// This version is newer, and on offer in the update window.
        case found(VersionNumber)
    }

    /// The symbol that goes with the words.
    public enum Mark: Equatable, Sendable {
        /// A small progress spinner.
        case spinner
        /// A checkmark, in the system green.
        case checkmark
        /// A warning sign, in the system orange.
        case warning
        /// A download arrow, in the accent colour.
        case available
    }

    /// How long a popover that says "up to date" stays before it closes by itself, in seconds.
    public static let upToDatePopoverLifetime: TimeInterval = 4

    public let outcome: Outcome
    public let source: CheckSource

    public init(_ outcome: Outcome, source: CheckSource) {
        self.outcome = outcome
        self.source = source
    }

    /// The check is still running.
    public var isPending: Bool {
        if case .checking = outcome { true } else { false }
    }

    /// Whether the surface shows anything. The popover has nothing for a found update: it closes, and the update window,
    /// which says it better, opens. (The title still names the version, for the log and for VoiceOver.)
    public var isShown: Bool {
        switch (source, outcome) {
        case (.dotsMenu, .found): false
        default: true
        }
    }

    /// The symbol beside the words; nil when nothing is shown.
    public var mark: Mark? {
        guard isShown else { return nil }
        switch outcome {
        case .checking: return .spinner
        case .upToDate: return .checkmark
        case .failed: return .warning
        case .found: return .available
        }
    }

    /// The first line, or the only one.
    public var title: String {
        switch (source, outcome) {
        case (.dotsMenu, .checking): "Checking for updates\u{2026}"
        case (.settings, .checking): "Checking\u{2026}"
        case (_, .upToDate(let version)): "Mantel is up to date (\(version))"
        case (.dotsMenu, .failed): "Couldn't check for updates"
        case (.settings, .failed(let failure)): failure.message
        case (_, .found(let version)): "Version \(version) is available"
        }
    }

    /// A second, smaller line under the title: the plain reason a check failed, in the popover. The line in Settings
    /// holds the reason as its only line.
    public var detail: String? {
        switch (source, outcome) {
        case (.dotsMenu, .failed(let failure)): failure.message
        default: nil
        }
    }

    /// Whether there is an OK button: only a failure in the popover, which stays until it is answered or clicked away.
    public var hasOKButton: Bool {
        switch (source, outcome) {
        case (.dotsMenu, .failed): true
        default: false
        }
    }

    /// Seconds until the surface closes by itself, or nil when it stays. Only "up to date" in the popover goes by itself:
    /// a failure stays until OK or a click elsewhere, and the line in Settings stays until the pane closes or a new check
    /// starts.
    public var autoCloseDelay: TimeInterval? {
        switch (source, outcome) {
        case (.dotsMenu, .upToDate): Self.upToDatePopoverLifetime
        default: nil
        }
    }
}
