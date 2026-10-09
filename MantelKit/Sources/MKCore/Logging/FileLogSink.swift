import Foundation
import Synchronization

public enum LogLevel: String, Sendable {
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
}

/// Appends log lines to `<directory>/<baseName>.log`, rotating to `.1.log`, `.2.log`… when full.
///
/// There is no shared instance: the app builds the one it uses from `MantelPaths.logs` and installs it with
/// `Log.configure(sink:)`, and tests build theirs on a temporary folder.
public final class FileLogSink: Sendable {
    public let directory: URL
    public let baseName: String
    public let maxBytes: Int
    public let rotatedFilesToKeep: Int
    private let lock = Mutex(())

    /// The defaults keep Mantel's logs to 15 MB: the current file and two rotated ones, 5 MB each.
    public init(directory: URL, baseName: String = "mantel", maxBytes: Int = 5_000_000, rotatedFilesToKeep: Int = 2) {
        precondition(rotatedFilesToKeep >= 1)
        self.directory = directory
        self.baseName = baseName
        self.maxBytes = maxBytes
        self.rotatedFilesToKeep = rotatedFilesToKeep
    }

    public var currentFileURL: URL { directory.appending(path: "\(baseName).log") }

    func rotatedFileURL(_ index: Int) -> URL { directory.appending(path: "\(baseName).\(index).log") }

    /// Writes one line: `message` is escaped (`escaped`), so it can't break the line or start one of its own.
    public func append(level: LogLevel, category: String, message: String, date: Date = Date()) {
        let line = "\(date.formatted(.iso8601)) [\(level.rawValue)] [\(category)] \(Self.escaped(message))\n"
        let data = Data(line.utf8)
        lock.withLock { _ in
            let fileManager = FileManager.default
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = currentFileURL
            let size = (try? fileManager.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? Int) ?? 0
            if size > 0, size + data.count > maxBytes {
                rotate()
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// `message` as one log line: text from outside (an app's name, a socket client's words) could otherwise forge
    /// lines. Control characters and the Unicode line and paragraph separators are written as escapes: `\n`, `\r` and
    /// `\t`, else `\u{…}` with the code point in hex. Everything else is written as it is.
    static func escaped(_ message: String) -> String {
        guard message.unicodeScalars.contains(where: needsEscape) else { return message }
        var escaped = String.UnicodeScalarView()
        for scalar in message.unicodeScalars {
            switch scalar {
            case "\n": escaped.append(contentsOf: #"\n"#.unicodeScalars)
            case "\r": escaped.append(contentsOf: #"\r"#.unicodeScalars)
            case "\t": escaped.append(contentsOf: #"\t"#.unicodeScalars)
            case _ where needsEscape(scalar):
                escaped.append(contentsOf: #"\u{\#(String(scalar.value, radix: 16, uppercase: true))}"#.unicodeScalars)
            default: escaped.append(scalar)
            }
        }
        return String(escaped)
    }

    private static func needsEscape(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .lineSeparator, .paragraphSeparator: true
        default: false
        }
    }

    private func rotate() {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: rotatedFileURL(rotatedFilesToKeep))
        if rotatedFilesToKeep > 1 {
            for index in stride(from: rotatedFilesToKeep - 1, through: 1, by: -1) {
                try? fileManager.moveItem(at: rotatedFileURL(index), to: rotatedFileURL(index + 1))
            }
        }
        try? fileManager.moveItem(at: currentFileURL, to: rotatedFileURL(1))
    }
}
