import Foundation
import Testing

/// The real preferences, the real apps and the real pointer are never reached from a test: the types that do it are never made here, so
/// a test that wants their behaviour is given a fake. This reads the test sources and fails for the first one that makes them.
@Suite("No live system in tests", .timeLimit(.minutes(2)))
struct NoLiveSystemInTestsTests {
    /// The calls that make a type that changes the person's real preferences, quits real apps or posts real clicks, that make the platform
    /// the probes run on (which holds all of them), and that reach the system's preferences or notifications by themselves. Written in two
    /// parts, so that this file doesn't contain them.
    private let forbidden = ["Live" + "Preferences(", "Live" + "AppRelauncher(", "Live" + "ClickPoster(", ".live" + "(runningApps:",
                             "PreferredPositionKeys." + "count(inDomain:", "Distributed" + "NotificationCenter",
                             "Live" + "SessionState("]

    @Test func noTestMakesATypeThatReachesTheRealSystem() throws {
        let tests = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let enumerator = try #require(FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil))
        var checked = 0
        var offenders: [String] = []
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            checked += 1
            let text = try String(contentsOf: file, encoding: .utf8)
            for call in forbidden where text.contains(call) { offenders.append("\(file.lastPathComponent): \(call)") }
        }
        #expect(checked > 50, "the test sources were found")
        #expect(offenders.isEmpty, "a test must use a fake: \(offenders)")
    }
}
