import Foundation
import Testing

@testable import MKMenuBar

/// The only tests that touch macOS's private framework, and they only read it: `dlopen`, the classes, and the type encoding
/// of three methods. Nothing here activates anything.
@Suite("Shim inspect", .timeLimit(.minutes(1)),
       .enabled(if: FileManager.default.fileExists(atPath: "/System/Library/PrivateFrameworks/MenuBarClientCore.framework")))
struct ShimInspectTests {
    private static let expectedEncodings = [
        "initWithAllowedSystemItems:allowedBundleIdentifiers:": "@32@0:8@16@24",
        "activateWithConfiguration:completionHandler:": "v32@0:8@16@?24",
        "invalidate": "v16@0:8",
    ]

    @Test func inspectReturnsAReportWithoutCrashing() {
        let report = LiveAllowlist().inspect()
        // Printed, so that a run shows what this macOS has.
        print("MenuBarClientCore: loaded \(report.frameworkLoaded), classes \(report.classes), problem \(report.problem ?? "none")")
        for (selector, encoding) in report.encodings.sorted(by: { $0.key < $1.key }) {
            print("MenuBarClientCore encoding: \(selector) = \(encoding.isEmpty ? "(missing)" : encoding)")
        }

        #expect(report.frameworkLoaded)
        #expect(Set(report.encodings.keys) == Set(Self.expectedEncodings.keys), "the three selectors are always in the report")
    }

    @Test func theProblemIsNilExactlyWhenEveryEncodingMatches() {
        let report = LiveAllowlist().inspect()
        let allMatch = report.frameworkLoaded && report.configurationClassFound && report.assertionClassFound
            && report.encodings == Self.expectedEncodings
        #expect((report.problem == nil) == allMatch)
        if let problem = report.problem {
            // A mismatch names the selector it found the wrong encoding on.
            #expect(report.encodings.keys.contains { problem.contains($0) } || !report.frameworkLoaded
                || !report.configurationClassFound || !report.assertionClassFound)
        }
    }

    @Test func inspectingTwiceGivesTheSameReport() {
        // It only reads, so there is nothing for a second call to find different.
        let allowlist = LiveAllowlist()
        #expect(allowlist.inspect() == allowlist.inspect())
    }
}
