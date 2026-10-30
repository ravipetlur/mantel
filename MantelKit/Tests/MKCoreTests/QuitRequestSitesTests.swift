import Foundation
import Testing

/// `NSApp.terminate(nil)` called from inside a main-queue block or a main-actor task never lets the quit finish: when the delegate answers
/// "later", AppKit waits for the reply in a nested run loop inside that block, and nothing else queued on the main queue (the cleanup, the
/// quit timer that answers) runs until it returns. So every place in the app that quits goes through `AppQuit.request()`, which asks from
/// the run loop. This reads the app's sources and fails for any call that doesn't.
@Suite("Quit requests in the app", .timeLimit(.minutes(2)))
struct QuitRequestSitesTests {
    /// A direct call, however it is spelled (`NSApp.terminate(…)`, `NSApplication.shared.terminate(…)`, an optional chain), but not the
    /// selector `#selector(NSApplication.terminate(_:))` that the helper and the menus use.
    private let directCall = try! Regex(#"(NSApp|NSApplication\.shared)\s*\??\s*\.\s*terminate\s*\("#)
    /// Written in two parts, so that this file doesn't contain it.
    private let helperCall = "AppQuit." + "request()"

    private var appSources: URL {
        // This file is MantelKit/Tests/MKCoreTests/<name>.swift; the app's sources are in Mantel/ beside MantelKit/.
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Mantel")
    }

    /// The app's Swift files, each with its `//` comments taken out, so that a name in a comment counts for nothing.
    private func swiftFiles() throws -> [(name: String, code: String)] {
        let enumerator = try #require(FileManager.default.enumerator(at: appSources, includingPropertiesForKeys: nil))
        var files: [(name: String, code: String)] = []
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line) }
                .joined(separator: "\n")
            files.append((file.lastPathComponent, code))
        }
        return files
    }

    @Test func noPlaceInTheAppAsksAppKitToTerminateDirectly() throws {
        let files = try swiftFiles()
        #expect(files.count > 20, "the app's sources were found")
        let offenders = files.filter { $0.code.contains(directCall) }.map(\.name)
        #expect(offenders.isEmpty, "these quit from where they are, not through the helper: \(offenders)")
    }

    @Test func everyPlaceThatQuitsFromCodeUsesTheHelper() throws {
        let files = try swiftFiles()
        // The delegate's hand-off quit and the SIGTERM's, the coordinator's hand-off quit, the move to Applications, and the onboarding's quit.
        for (name, count) in [("AppDelegate.swift", 2), ("AppCoordinator.swift", 1), ("AppMover.swift", 1), ("OnboardingView.swift", 1)] {
            let file = try #require(files.first { $0.name == name }, "\(name) was found")
            #expect(file.code.components(separatedBy: helperCall).count - 1 == count, "\(name) quits through the helper \(count) time(s)")
        }
    }
}
