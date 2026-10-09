import Foundation
import MKCore
import MKTestSupport
import Testing

@testable import MKCore

@Suite("FileLogSink")
struct FileLogSinkTests {
    /// Held by the suite for the whole test: the folder is deleted when the test is over.
    let folder = TemporaryFolder(prefix: "mantel-log")

    var directory: URL { folder.url.appending(path: "Logs", directoryHint: .isDirectory) }

    @Test func defaultsAreTheOnesMantelUses() {
        let sink = FileLogSink(directory: directory)
        #expect(sink.baseName == "mantel")
        #expect(sink.maxBytes == 5_000_000)
        #expect(sink.rotatedFilesToKeep == 2)
        #expect(sink.currentFileURL == directory.appending(path: "mantel.log"))
    }

    @Test func writesLevelCategoryAndMessage() throws {
        let sink = FileLogSink(directory: directory)
        sink.append(level: .warning, category: "settings", message: "hello", date: Date(timeIntervalSince1970: 0))
        let text = try String(contentsOf: sink.currentFileURL, encoding: .utf8)
        #expect(text == "1970-01-01T00:00:00Z [WARN] [settings] hello\n")
    }

    @Test func appendsAfterTheLinesThatAreThere() throws {
        let sink = FileLogSink(directory: directory)
        sink.append(level: .info, category: "app", message: "one", date: Date(timeIntervalSince1970: 0))
        sink.append(level: .error, category: "app", message: "two", date: Date(timeIntervalSince1970: 1))
        let text = try String(contentsOf: sink.currentFileURL, encoding: .utf8)
        #expect(text == "1970-01-01T00:00:00Z [INFO] [app] one\n1970-01-01T00:00:01Z [ERROR] [app] two\n")
    }

    /// Text from outside (an app's name, a socket client's words) can't forge a line of its own. Control characters,
    /// line breaks among them, and the Unicode line and paragraph separators are written as escapes.
    @Test func aMessageCantStartALineOfItsOwn() throws {
        let sink = FileLogSink(directory: directory)
        let forged = "probe ignores x\n1970-01-01T00:00:00Z [INFO] [app] Running pin"
            + "\r\ttab\u{1B}[31m\u{0}\u{85}\u{2028}\u{2029}end"
        sink.append(level: .info, category: "app", message: forged, date: Date(timeIntervalSince1970: 0))
        let text = try String(contentsOf: sink.currentFileURL, encoding: .utf8)
        #expect(text == "1970-01-01T00:00:00Z [INFO] [app] probe ignores x"
            + "\\n1970-01-01T00:00:00Z [INFO] [app] Running pin"
            + "\\r\\ttab\\u{1B}[31m\\u{0}\\u{85}\\u{2028}\\u{2029}end\n")
        // Everything else is written as it is.
        #expect(FileLogSink.escaped("Photo “Pro” 📸 → café") == "Photo “Pro” 📸 → café")
    }

    @Test func rotatesAndKeepsOnlyTheConfiguredNumberOfFiles() throws {
        let sink = FileLogSink(directory: directory, maxBytes: 200, rotatedFilesToKeep: 2)
        for index in 0 ..< 20 {
            sink.append(level: .info, category: "t", message: "line \(index) xxxxxxxxxxxxxxxx")
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)).sorted()
        #expect(files == ["mantel.1.log", "mantel.2.log", "mantel.log"])
        let current = try String(contentsOf: sink.currentFileURL, encoding: .utf8)
        #expect(current.contains("line 19 "))
        #expect(!current.contains("line 0 "))
        let size = try FileManager.default.attributesOfItem(atPath: sink.currentFileURL.path(percentEncoded: false))[.size] as? Int
        #expect((size ?? 0) <= 200)
    }

    /// The newest lines are in the current file and the older ones in `.1`, then `.2`.
    @Test func rotatedFilesHoldOlderLinesTheFurtherTheyAreFromTheCurrentOne() throws {
        let sink = FileLogSink(directory: directory, maxBytes: 120, rotatedFilesToKeep: 2)
        for index in 0 ..< 10 {
            sink.append(level: .info, category: "t", message: "n\(index)")
        }
        func numbers(_ url: URL) throws -> [Int] {
            try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
                .compactMap { $0.split(separator: " ").last.flatMap { Int($0.dropFirst()) } }
        }
        let second = try numbers(sink.rotatedFileURL(2))
        let first = try numbers(sink.rotatedFileURL(1))
        let current = try numbers(sink.currentFileURL)
        let all = second + first + current
        // The oldest lines have rotated away, but what is left runs in order up to the newest line.
        #expect(all.last == 9)
        #expect(zip(all, all.dropFirst()).allSatisfy { $0 + 1 == $1 })
        #expect(!second.isEmpty && !first.isEmpty && !current.isEmpty)
    }
}
