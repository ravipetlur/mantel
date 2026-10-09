import Foundation
import MKCommands
import MKCore

/// What one run of a probe found, and what it did to get there.
public struct ProbeReport: Codable, Sendable, Equatable {
    public let name: ProbeName
    public let startedAt: Date
    public let durationMs: Double
    /// macOS build, Mac model, Mantel version, and a fingerprint of the displays: what the numbers were measured on.
    public let environment: [String: String]
    public let measurements: [String: JSONValue]
    public let notes: [String]
    /// True when the probe changed nothing, or undid everything it changed.
    public let restored: Bool
    public let errors: [String]

    public init(name: ProbeName, startedAt: Date, durationMs: Double, environment: [String: String],
                measurements: [String: JSONValue], notes: [String], restored: Bool, errors: [String]) {
        self.name = name
        self.startedAt = startedAt
        self.durationMs = durationMs
        self.environment = environment
        self.measurements = measurements
        self.notes = notes
        self.restored = restored
        self.errors = errors
    }

    /// `yyyyMMdd-HHmmss` of the start, in the time zone given (the Mac's own, in the app).
    public static func timestamp(startedAt: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: startedAt)
    }

    /// `<name>-<yyyyMMdd-HHmmss>.json`, which is where the report is saved in the Probes folder.
    public static func fileName(for name: ProbeName, startedAt: Date, timeZone: TimeZone = .current) -> String {
        "\(name.rawValue)-\(timestamp(startedAt: startedAt, timeZone: timeZone)).json"
    }

    // MARK: Reading a measurement

    public func number(_ key: String) -> Double? {
        if case .number(let value)? = measurements[key] { return value }
        return nil
    }

    public func bool(_ key: String) -> Bool? {
        if case .bool(let value)? = measurements[key] { return value }
        return nil
    }

    /// A measurement that is a list of texts; nil when it isn't one.
    public func strings(_ key: String) -> [String]? {
        guard case .array(let values)? = measurements[key] else { return nil }
        return values.compactMap { if case .string(let text) = $0 { text } else { nil } }
    }

    public func object(_ key: String) -> [String: JSONValue]? {
        if case .object(let value)? = measurements[key] { return value }
        return nil
    }

    /// The JSON as it is kept, and as it is shown on the command line: a `JSONValue` of the whole report.
    public var json: JSONValue {
        guard let data = try? JSONCoding.encoder().encode(self),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return .null }
        return value
    }
}

/// The Probes folder: reports are written there, and the latest of each probe is read back from it (Diagnostics shows them,
/// and `screen-share` compares with an earlier run), also after a relaunch.
public struct ProbeReportStore: Sendable {
    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    /// Writes the report as `<name>-<timestamp>.json`, privately and whole; a second report in the same second gets a number
    /// after the timestamp. Returns where it went.
    @discardableResult
    public func save(_ report: ProbeReport) throws -> URL {
        let url = AtomicFile.unusedURL(in: folder, base: "\(report.name.rawValue)-\(ProbeReport.timestamp(startedAt: report.startedAt))",
                                       pathExtension: "json")
        try AtomicFile.ensureFolder(folder)
        try AtomicFile.write(try JSONCoding.encoder().encode(report), to: url)
        return url
    }

    /// The newest report of a probe (by its start time), optionally only among those `matching`. Files that aren't reports
    /// are skipped.
    public func latest(_ name: ProbeName, matching: (ProbeReport) -> Bool = { _ in true }) -> ProbeReport? {
        reports(of: name).filter(matching).max { $0.startedAt < $1.startedAt }
    }

    /// The newest report of each probe that has one.
    public func all() -> [ProbeName: ProbeReport] {
        var latest: [ProbeName: ProbeReport] = [:]
        for name in ProbeName.allCases {
            if let report = self.latest(name) { latest[name] = report }
        }
        return latest
    }

    private func reports(of name: ProbeName) -> [ProbeReport] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        let prefix = "\(name.rawValue)-"
        return names.compactMap { file -> ProbeReport? in
            // `<name>-20231114-221320.json`, or with `-2` after the time; not another probe's file, not a snapshot's.
            guard file.hasPrefix(prefix), file.hasSuffix(".json") else { return nil }
            let middle = String(file.dropFirst(prefix.count).dropLast(".json".count))
            guard middle.wholeMatch(of: #/\d{8}-\d{6}(-\d+)?/#) != nil else { return nil }
            guard let data = try? Data(contentsOf: folder.appending(path: file)),
                  let report = try? JSONCoding.decoder().decode(ProbeReport.self, from: data), report.name == name else { return nil }
            return report
        }
    }
}
