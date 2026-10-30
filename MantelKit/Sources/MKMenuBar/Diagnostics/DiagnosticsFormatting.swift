import Foundation
import MKCommands
import MKCore

/// One line of the Diagnostics pane: what was checked, whether it is as it should be, and one line saying how it stands.
public struct DiagnosticsCheck: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        /// As it should be.
        case ok
        /// Works, or can't be told to be wrong, but something is left to do.
        case warning
        /// Mantel can't do what it is for until this is dealt with.
        case problem
        /// Couldn't be told.
        case unknown

        /// How the status reads in text.
        public var word: String {
            switch self {
            case .ok: "OK"
            case .warning: "Needs attention"
            case .problem: "Problem"
            case .unknown: "Unknown"
            }
        }
    }

    public let title: String
    public let status: Status
    public let detail: String

    public init(title: String, status: Status, detail: String) {
        self.title = title
        self.status = status
        self.detail = detail
    }
}

/// The Diagnostics line about the journal: what quitting puts back, and what Mantel keeps.
public enum JournalSummary {
    /// "<n> to put back on quit, <m> kept." Both counts are always said, so that a journal that holds only what Mantel keeps reads as
    /// "0 to put back on quit, 2 kept."
    public static func detail(untilQuit: Int, kept: Int) -> String {
        "\(untilQuit) to put back on quit, \(kept) kept."
    }

    /// The line: a temporary change that is waiting needs attention ("Replay now" is for it); what Mantel keeps is as it should be.
    public static func check(untilQuit: Int, kept: Int) -> DiagnosticsCheck {
        DiagnosticsCheck(title: "Journal", status: untilQuit == 0 ? .ok : .warning, detail: detail(untilQuit: untilQuit, kept: kept))
    }
}

/// What "Copy diagnostics" puts on the pasteboard, and what `mantel diagnostics` answers: the checks and the blocks, with the home
/// folder written as `~`.
public enum DiagnosticsText {
    /// `text` with the home folder as `~`. A longer name that only starts like the home folder (`/Users/me2`) is left alone.
    public static func redact(_ text: String, home: String) -> String {
        guard home.count > 1 else { return text }
        let pattern = NSRegularExpression.escapedPattern(for: home) + #"(?![\w.-])"#
        return text.replacingOccurrences(of: pattern, with: "~", options: .regularExpression)
    }

    /// Every string in the value, redacted.
    public static func redact(_ value: JSONValue, home: String) -> JSONValue {
        switch value {
        case .string(let text): .string(redact(text, home: home))
        case .array(let values): .array(values.map { redact($0, home: home) })
        case .object(let values): .object(values.mapValues { redact($0, home: home) })
        case .null, .bool, .number: value
        }
    }

    /// The report as text: the checks, then each block (a title and its lines).
    public static func render(checks: [DiagnosticsCheck], blocks: [DiagnosticsBlock] = [], home: String) -> String {
        var lines = ["Mantel diagnostics", "", "Checks"]
        for check in checks {
            lines.append("\(check.title): \(check.status.word). \(check.detail)")
        }
        for block in blocks {
            lines.append("")
            lines.append(block.title)
            lines.append(contentsOf: block.lines)
        }
        return redact(lines.joined(separator: "\n") + "\n", home: home)
    }

    /// The same, as JSON: `{"checks": [{title, status, detail}], "sections": [{title, lines}]}`.
    /// There is no `sections` when there are no blocks.
    public static func json(checks: [DiagnosticsCheck], blocks: [DiagnosticsBlock] = [], home: String) -> JSONValue {
        let checkValues = checks.map { check -> JSONValue in
            .object(["title": .string(check.title), "status": .string(check.status.rawValue), "detail": .string(check.detail)])
        }
        var members: [String: JSONValue] = ["checks": .array(checkValues)]
        if !blocks.isEmpty {
            members["sections"] = .array(blocks.map { block in
                .object(["title": .string(block.title), "lines": .array(block.lines.map(JSONValue.string))])
            })
        }
        return redact(.object(members), home: home)
    }
}
