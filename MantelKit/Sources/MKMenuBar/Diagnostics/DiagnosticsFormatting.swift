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

/// One line about a probe's last report: which, when, whether what it changed is back, and how many errors.
public enum ProbeSummary {
    public static func line(for report: ProbeReport, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let errors = switch report.errors.count {
        case 0: "no errors"
        case 1: "1 error"
        case let count: "\(count) errors"
        }
        return [report.name.rawValue, formatter.string(from: report.startedAt), report.restored ? "restored" : "not restored", errors]
            .joined(separator: " · ")
    }
}

/// What "Copy diagnostics" puts on the pasteboard, and what `mantel diagnostics` answers: the checks and the last report of
/// each probe, with the home folder written as `~` and the names that were read from the menu bar left out.
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

    /// The keys under which a probe report holds names that were read from the menu bar: what an item calls itself can be a
    /// network's name, a battery level or a person's own.
    static let nameKeys: Set<String> = ["titles", "descriptions", "newDescriptions", "names", "labels"]

    /// `value` with what is under `titles`, `descriptions`, `newDescriptions`, `names` and `labels`, wherever it is, replaced by how
    /// many there were: "‹3 names›". Everything else stays, bundle IDs and Apple's own `com.apple.*` identifiers included: they
    /// say which apps and which parts of macOS, and nothing of the person.
    public static func redactNames(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let members):
            return .object(members.reduce(into: [:]) { result, member in
                result[member.key] = nameKeys.contains(member.key) ? countOfNames(in: member.value) : redactNames(member.value)
            })
        case .array(let values):
            return .array(values.map(redactNames))
        case .null, .bool, .number, .string:
            return value
        }
    }

    /// "‹N names›" for a list of names, a text (one name) or an object (one name for each member), and "‹1 name›" for one; what
    /// holds none is left as it is.
    private static func countOfNames(in value: JSONValue) -> JSONValue {
        switch value {
        case .array(let names): .string(count(names.count))
        case .object(let names): .string(count(names.count))
        case .string: .string(count(1))
        case .null, .bool, .number: value
        }
    }

    private static func count(_ names: Int) -> String {
        names == 1 ? "‹1 name›" : "‹\(names) names›"
    }

    /// The report as text: the checks, then each block (a title and its lines), then the last report of each probe.
    public static func render(checks: [DiagnosticsCheck], blocks: [DiagnosticsBlock] = [], probes: [ProbeName: ProbeReport], home: String,
                              timeZone: TimeZone = .current) -> String {
        var lines = ["Mantel diagnostics", "", "Checks"]
        for check in checks {
            lines.append("\(check.title): \(check.status.word). \(check.detail)")
        }
        for block in blocks {
            lines.append("")
            lines.append(block.title)
            lines.append(contentsOf: block.lines)
        }
        lines.append("")
        lines.append("Last probe reports")
        let reports = ProbeName.allCases.compactMap { probes[$0] }
        if reports.isEmpty {
            lines.append("No probe has been run.")
        }
        for report in reports {
            lines.append("")
            lines.append(ProbeSummary.line(for: report, timeZone: timeZone))
            if let data = try? JSONCoding.encoder().encode(redactNames(report.json)), let json = String(data: data, encoding: .utf8) {
                lines.append(json)
            }
        }
        return redact(lines.joined(separator: "\n") + "\n", home: home)
    }

    /// The same, as JSON: `{"checks": [{title, status, detail}], "sections": [{title, lines}], "probes": {"<probe name>": <its report>}}`.
    /// There is no `sections` when there are no blocks. Each report has its names left out (`redactNames`).
    public static func json(checks: [DiagnosticsCheck], blocks: [DiagnosticsBlock] = [], probes: [ProbeName: ProbeReport],
                            home: String) -> JSONValue {
        let checkValues = checks.map { check -> JSONValue in
            .object(["title": .string(check.title), "status": .string(check.status.rawValue), "detail": .string(check.detail)])
        }
        var probeValues: [String: JSONValue] = [:]
        for (name, report) in probes { probeValues[name.rawValue] = redactNames(report.json) }
        var members: [String: JSONValue] = ["checks": .array(checkValues), "probes": .object(probeValues)]
        if !blocks.isEmpty {
            members["sections"] = .array(blocks.map { block in
                .object(["title": .string(block.title), "lines": .array(block.lines.map(JSONValue.string))])
            })
        }
        return redact(.object(members), home: home)
    }
}
