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
/// each probe, with the home folder written as `~`.
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

    public static func render(checks: [DiagnosticsCheck], probes: [ProbeName: ProbeReport], home: String,
                              timeZone: TimeZone = .current) -> String {
        var lines = ["Mantel diagnostics", "", "Checks"]
        for check in checks {
            lines.append("\(check.title): \(check.status.word). \(check.detail)")
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
            if let data = try? JSONCoding.encoder().encode(report), let json = String(data: data, encoding: .utf8) {
                lines.append(json)
            }
        }
        return redact(lines.joined(separator: "\n") + "\n", home: home)
    }

    /// The same, as JSON: `{"checks": [{title, status, detail}], "probes": {"<probe name>": <its report>}}`.
    public static func json(checks: [DiagnosticsCheck], probes: [ProbeName: ProbeReport], home: String) -> JSONValue {
        let checkValues = checks.map { check -> JSONValue in
            .object(["title": .string(check.title), "status": .string(check.status.rawValue), "detail": .string(check.detail)])
        }
        var probeValues: [String: JSONValue] = [:]
        for (name, report) in probes { probeValues[name.rawValue] = report.json }
        return redact(.object(["checks": .array(checkValues), "probes": .object(probeValues)]), home: home)
    }
}
