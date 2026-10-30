import Foundation
import MKCore
import MKTestSupport
import Testing

@testable import MKCore

/// `Log` itself holds the one sink the app installs, and tests must not share that. These tests use a `LogRouter`, the
/// type behind `Log`, of their own.
@Suite("Log", .timeLimit(.minutes(2)))
struct LogTests {
    let folder = TemporaryFolder(prefix: "mantel-log")

    var directory: URL { folder.url.appending(path: "Logs", directoryHint: .isDirectory) }

    @Test func nothingIsWrittenToAFileBeforeASinkIsConfigured() throws {
        let router = LogRouter(subsystem: "com.example.mantel.tests")
        router.write(.info, category: "app", message: "before")

        let sink = FileLogSink(directory: directory)
        router.configure(sink: sink)
        #expect(!FileManager.default.fileExists(atPath: directory.path), "an early line isn't kept for later")

        router.write(.warning, category: "app", message: "after")
        let text = try String(contentsOf: sink.currentFileURL, encoding: .utf8)
        #expect(text.hasSuffix(" [WARN] [app] after\n"))
        #expect(!text.contains("before"))
    }

    @Test func configuringAgainReplacesTheSink() throws {
        let router = LogRouter(subsystem: "com.example.mantel.tests")
        let first = FileLogSink(directory: directory.appending(path: "first", directoryHint: .isDirectory))
        let second = FileLogSink(directory: directory.appending(path: "second", directoryHint: .isDirectory))
        router.configure(sink: first)
        router.write(.info, category: "app", message: "one")
        router.configure(sink: second)
        router.write(.info, category: "app", message: "two")
        #expect(try String(contentsOf: first.currentFileURL, encoding: .utf8).contains("one"))
        #expect(!(try String(contentsOf: first.currentFileURL, encoding: .utf8).contains("two")))
        #expect(try String(contentsOf: second.currentFileURL, encoding: .utf8).contains("two"))
    }
}
