import Foundation
import os
import Synchronization

/// Logs to the unified log (Console.app, subsystem: the app's bundle identifier) and, once the app has installed a
/// `FileLogSink`, to Mantel's log folder. Every line goes through here; nothing in Mantel writes to a file or the console
/// of its own.
///
/// Never log clipboard contents, script output, Wi-Fi names, or the contents of the approvals or layout files: log keys
/// and counts instead.
public enum Log {
    public static let subsystem = Bundle.main.bundleIdentifier ?? "com.example.mantel"

    private static let router = LogRouter(subsystem: subsystem)

    /// An `os.Logger` for `category`, for code that wants the unified log's own interpolation and privacy controls.
    public static func logger(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }

    public static func info(_ category: String, _ message: String) {
        router.write(.info, category: category, message: message)
    }

    public static func warning(_ category: String, _ message: String) {
        router.write(.warning, category: category, message: message)
    }

    public static func error(_ category: String, _ message: String) {
        router.write(.error, category: category, message: message)
    }

    /// Installs the file the logs are written to. The app calls this once, at launch, with a sink on
    /// `MantelPaths.logs`; before that, lines go to the unified log only.
    public static func configure(sink: FileLogSink) {
        router.configure(sink: sink)
    }
}

/// What `Log` does, as a type of its own so that tests can have a router they don't share with anyone.
final class LogRouter: Sendable {
    private let subsystem: String
    private let sink = Mutex<FileLogSink?>(nil)

    init(subsystem: String) {
        self.subsystem = subsystem
    }

    func configure(sink newSink: FileLogSink) {
        sink.withLock { $0 = newSink }
    }

    func write(_ level: LogLevel, category: String, message: String) {
        let logger = Logger(subsystem: subsystem, category: category)
        switch level {
        case .info: logger.info("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
        sink.withLock { $0 }?.append(level: level, category: category, message: message)
    }
}
