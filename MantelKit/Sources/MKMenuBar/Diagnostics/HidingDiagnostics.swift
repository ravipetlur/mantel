import Foundation
import MKCommands
import MKCore

/// A titled run of lines in the report Diagnostics shows and copies: what is true, written out, with no status of its own.
public struct DiagnosticsBlock: Sendable, Equatable {
    public let title: String
    public let lines: [String]

    public init(title: String, lines: [String]) {
        self.title = title
        self.lines = lines
    }
}

/// How readily one app answered when the menu bar was read, as a line in Diagnostics.
public struct ReachRow: Sendable, Equatable, Identifiable {
    public let bundleID: String
    /// What the pane calls the app.
    public let name: String
    public let status: ReachStatus
    /// "Fine", "Slow (310 ms)", "Timed out; asked again in 30 seconds" or "Skipped".
    public let text: String

    public var id: String { bundleID }

    public init(bundleID: String, name: String, status: ReachStatus, text: String) {
        self.bundleID = bundleID
        self.name = name
        self.status = status
        self.text = text
    }
}

/// What Diagnostics says about hiding and about the read of the menu bar: how the engine in use stands, how each engine does, what hiding
/// changes in macOS, and how each app answered.
///
/// It is the one place these are worded, so that the pane and the copied report say the same. Nothing the menu bar read says of an item
/// (a label, a title) is in any of it: apps are named by their bundle ID in the copy.
public enum HidingDiagnostics {
    /// What there is to say before the menu bar has been read.
    public static let notReadYet = "Not read yet."
    public static let noReachText = "No app has been asked yet."
    /// What an engine reads while nothing is known of it.
    public static let notCheckedYet = "not checked yet"

    // MARK: The checks

    /// The "Hiding method" row.
    /// - A plan that couldn't be applied is a problem, and the row says that everything is shown.
    /// - The wide spacer is a warning: it only hides what is left of its divider.
    /// - Anything else is fine.
    public static func hidingMethodCheck(_ engine: EngineStatus?) -> DiagnosticsCheck {
        let title = "Hiding method"
        guard let engine else { return DiagnosticsCheck(title: title, status: .unknown, detail: notReadYet) }
        if let error = engine.lastError {
            return DiagnosticsCheck(title: title, status: .problem, detail: "\(sentenceEnd(error)) Mantel is showing everything.")
        }
        if engine.degraded {
            return DiagnosticsCheck(title: title, status: .warning,
                                    detail: "\(engine.kind.title) (degraded): only icons left of the divider are hidden. \(engine.reason)")
        }
        return DiagnosticsCheck(title: title, status: .ok, detail: "\(engine.kind.title). \(engine.reason)")
    }

    /// What a problem with the read is followed by in the Diagnostics pane's row, where the Refresh menu bar button is under the checks.
    public static let tryRefresh = "Try Refresh menu bar below."

    /// Whether Refresh is what puts a problem with the read right, so that the pane says to try it. Not for Accessibility not being
    /// granted (Refresh can't fix that, and the Permissions row covers it), nor for a menu bar that can't be told from another (its
    /// message already says to choose Refresh Menu Bar).
    public static func suggestsRefresh(_ problem: InventoryProblem) -> Bool {
        switch problem {
        case .agentNotRunning, .agentHasNoWindows: true
        case .accessibilityNotGranted, .ambiguousSpace: false
        }
    }

    /// The "Menu bar" rows: one saying how much was read, or, when something kept the read from being whole, one for each thing, with the
    /// message of the problem as it is.
    ///
    /// `suggestingRefresh` is for the pane's own rows only: a problem that Refresh puts right then says "Try Refresh menu bar below." The
    /// copied report and the command line's answer carry the message alone, as they have no button below.
    public static func menuBarChecks(_ inventory: Inventory?, suggestingRefresh: Bool = false) -> [DiagnosticsCheck] {
        let title = "Menu bar"
        guard let inventory else { return [DiagnosticsCheck(title: title, status: .unknown, detail: notReadYet)] }
        guard inventory.problems.isEmpty else {
            return inventory.problems.map { problem in
                let suffix = suggestingRefresh && suggestsRefresh(problem) ? " \(tryRefresh)" : ""
                return DiagnosticsCheck(title: title, status: .warning, detail: problem.message + suffix)
            }
        }
        let icons = inventory.items.count == 1 ? "1 icon" : "\(inventory.items.count) icons"
        let displays = inventory.bars.count == 1 ? "1 display" : "\(inventory.bars.count) displays"
        return [DiagnosticsCheck(title: title, status: .ok, detail: "Read \(icons) on \(displays).")]
    }

    // MARK: Written out

    /// How each engine stands, one line each, as the engine says it (`available`, `needs permission: …`, `broken: …`). An engine the
    /// status says nothing of reads "not checked yet": a status may lack a kind, and that is not an error.
    public static func engineLines(_ engine: EngineStatus?) -> [String] {
        HidingEngineKind.allCases.map { kind in
            let stand = engine?.availability[kind] ?? engine?.unavailableReasons[kind].map { "can't be used: \($0)" } ?? notCheckedYet
            return "\(kind.title): \(stand)"
        }
    }

    /// What hiding changes in macOS, which the person may notice.
    public static let whatHidingChanges: [String] = [EngineNotes.sideEffects, EngineNotes.clockNote, EngineNotes.crashNote]

    // MARK: Reach

    /// One row for each app the menu bar read asked, by name. `names` are the names the pane knows the apps by; an app without one is
    /// called what the read called it, and failing that its bundle ID.
    ///
    /// An app with more than one process was asked once for each: its row is the one that went worst (the first, among equals).
    public static func reachRows(_ inventory: Inventory?, names: [String: String] = [:]) -> [ReachRow] {
        guard let inventory else { return [] }
        var worst: [String: AppReach] = [:]
        for reach in inventory.reach where severity(of: reach.status) > (worst[reach.bundleID].map { severity(of: $0.status) } ?? -1) {
            worst[reach.bundleID] = reach
        }
        let rows = worst.values.map { reach in
            ReachRow(bundleID: reach.bundleID, name: names[reach.bundleID] ?? reach.name ?? reach.bundleID, status: reach.status,
                     text: text(for: reach))
        }
        return NameOrdering.sorted(rows, name: \.name, tiebreak: \.bundleID)
    }

    /// How badly an answer went: fine, slow, left alone, no answer.
    private static func severity(of status: ReachStatus) -> Int {
        switch status {
        case .fine: 0
        case .slow: 1
        case .skipped: 2
        case .timedOut: 3
        }
    }

    static func text(for reach: AppReach) -> String {
        switch reach.status {
        case .fine: "Fine"
        case .slow: "Slow (\(Int(reach.readMs.rounded())) ms)"
        case .timedOut: "Timed out; asked again in 30 seconds"
        case .skipped: "Skipped"
        }
    }

    // MARK: The copied report

    /// What "Copy diagnostics" and `mantel diagnostics` hold besides the checks. Apps are named by their bundle ID, never by a name or a
    /// label the menu bar gave: those can hold the person's own words.
    public static func blocks(engine: EngineStatus?, inventory: Inventory?) -> [DiagnosticsBlock] {
        // Sorted as the pane sorts them (by what the read called each app), and written with the bundle ID.
        let reach = reachRows(inventory).map { "\($0.bundleID): \($0.text)" }
        return [
            DiagnosticsBlock(title: "Ways of hiding", lines: engineLines(engine)),
            DiagnosticsBlock(title: "What hiding changes", lines: whatHidingChanges),
            DiagnosticsBlock(title: "Accessibility reach", lines: reach.isEmpty ? [noReachText] : reach),
        ]
    }

    /// The text with one full stop at its end (an error may or may not have one).
    private static func sentenceEnd(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last, !".!?".contains(last) else { return trimmed }
        return trimmed + "."
    }
}
