import Foundation
import Testing

/// `runModal()` called from a task or a queued block runs its loop inside that block, and nothing else queued on the main queue runs
/// meanwhile (a SIGTERM's own block, a quit's cleanup). So every alert the app shows from code goes through `ModalLoop`, which starts it
/// from the run loop. This reads the app's sources and fails for any that doesn't.
@Suite("Modal alerts in the app")
struct ModalSitesTests {
    /// A modal loop started by hand, however it is spelled: `x.runModal()`, `NSApp.runModal(for:)`, a modal session, `x . runModal ( )`, or
    /// a bare `runModal()`.
    private let modalStart = try! Regex(#"(?:^|[^A-Za-z0-9_])(runModal|beginModalSession)\s*\("#)
    /// The helper's own call, in its file, and the way a site asks for it, however the alert is named and split over lines.
    private let helperCall = try! Regex(#"ModalLoop\s*\.\s*run\s*\("#)

    private var appSources: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Mantel")
    }

    /// The app's Swift files, each with its `//` and `/* */` comments taken out, so that a name in a comment counts for nothing.
    private func swiftFiles() throws -> [(name: String, code: String)] {
        let enumerator = try #require(FileManager.default.enumerator(at: appSources, includingPropertiesForKeys: nil))
        var files: [(name: String, code: String)] = []
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            let withoutBlocks = text.replacing(try Regex(#"/\*[\s\S]*?\*/"#), with: "")
            let code = withoutBlocks.split(separator: "\n", omittingEmptySubsequences: false)
                .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line) }
                .joined(separator: "\n")
            files.append((file.lastPathComponent, code))
        }
        return files
    }

    private func count(_ regex: Regex<AnyRegexOutput>, in code: String) -> Int {
        code.matches(of: regex).count
    }

    @Test func noPlaceStartsAModalLoopOutsideTheHelper() throws {
        let files = try swiftFiles()
        #expect(files.count > 20, "the app's sources were found")
        let offenders = files.filter { count(modalStart, in: $0.code) > 0 && $0.name != "ModalLoop.swift" }
        #expect(offenders.isEmpty, "these start a modal loop from where they are: \(offenders.map { $0.name })")
        let helper = try #require(files.first { $0.name == "ModalLoop.swift" }, "the helper was found")
        #expect(count(modalStart, in: helper.code) == 2, "the helper starts the loop in two places: an alert's and an open panel's")
    }

    /// A SIGTERM while an alert is up: the alert is ended (answered as Cancel) before the quit is asked for, or the quit's request, which
    /// isn't served in an alert's mode, would wait for the person and the quit would end by the fallback.
    @Test func aSIGTERMEndsAnAlertThatIsUpBeforeItAsksForTheQuit() throws {
        let files = try swiftFiles()
        let delegate = try #require(files.first { $0.name == "AppDelegate.swift" })
        let abort = try #require(delegate.code.range(of: "abortModal()"), "the SIGTERM ends an alert that is up")
        let quit = try #require(delegate.code.range(of: "AppQuit.request()", range: abort.upperBound..<delegate.code.endIndex),
                                "and asks for the quit after it")
        #expect(abort.upperBound <= quit.lowerBound)
    }

    @Test func theAlertsShownFromTasksAndQueuedWorkGoThroughTheHelper() throws {
        let files = try swiftFiles()
        // The grant alert, the Reset confirmation, the move to Applications (two answers asked for, and the failure's alert), and the
        // failure of a file's grant.
        // The pictures' choosers: the open panel, and the alert that says a picture couldn't be used.
        for (name, expected) in [("GrantAlert.swift", 1), ("DiagnosticsPane.swift", 1), ("AppMover.swift", 3), ("FileGrantPanel.swift", 1),
                                 ("CosmeticsPane.swift", 2), ("SelectedIconSection.swift", 2)] {
            let file = try #require(files.first { $0.name == name }, "\(name) was found")
            #expect(count(helperCall, in: file.code) == expected, "\(name) shows its alerts through the helper \(expected) time(s)")
        }
    }

    @Test func theHelperHandsTheLoopToTheRunLoop() throws {
        let files = try swiftFiles()
        let helper = try #require(files.first { $0.name == "ModalLoop.swift" })
        #expect(helper.code.contains("ModalHandoff"), "the loop is started by the package's hand-off")
        #expect(helper.code.contains("RunLoop.main.perform"), "and served by the run loop, not a queue")
        #expect(!helper.code.contains("DispatchQueue"), "not by a queued block")
    }
}
