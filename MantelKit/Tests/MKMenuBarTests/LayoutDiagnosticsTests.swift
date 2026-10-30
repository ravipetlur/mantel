import Foundation
import MKCore
import MKLayout
import Testing

@testable import MKMenuBar

@Suite("Layout diagnostics", .timeLimit(.minutes(1)))
struct LayoutDiagnosticsTests {
    private let utc = TimeZone(identifier: "UTC")!
    /// 2026-10-29 10:15:30 UTC.
    private let at = Date(timeIntervalSince1970: 1_793_268_930)
    private let error = Date(timeIntervalSince1970: 1_793_268_930 + 3600)

    private var report: LayoutWriteReport {
        LayoutWriteReport(at: at, written: 3, attempts: 1, verdict: "matches", unresolved: [], memory: [:])
    }

    private func status(_ availability: LayoutWriterAvailability = .available, report: LayoutWriteReport? = nil,
                        error: LayoutWriteError? = nil, errorAt: Date? = nil) -> LayoutStatus {
        LayoutStatus(availability: availability, lastReport: report, lastError: error, isPending: false, isSettling: false,
                     hasKeptChanges: false, dotsPlacementOffered: true, lastErrorAt: errorAt)
    }

    private let spacing = SpacingState(spacing: nil, padding: nil, preset: .macOSDefault, original: nil)
    private let images = (count: 4, last: Optional(Date(timeIntervalSince1970: 1_793_268_930)), screenRecording: true)

    private func rows(layout: LayoutStatus?, images: (count: Int, last: Date?, screenRecording: Bool)? = nil, spacing: SpacingState? = nil,
                      works: Bool = true) -> [DiagnosticsCheck] {
        LayoutDiagnostics.rows(layout: layout, images: images ?? self.images, spacing: spacing ?? self.spacing, spacingWorks: works,
                               timeZone: utc)
    }

    @Test func copiedRowsHaveNoNames() {
        let apps = [ItemID(bundleID: "com.example.secret", key: .identifier("Wi-Fi: Home network")), ItemID(bundleID: "com.example.other", key: .index(1))]
        let written = LayoutWriteReport(at: at, written: 2, attempts: 2, verdict: "matches", unresolved: apps, memory: [apps[0]: "key"],
                                        notPlaced: ["com.example.secret", "Battery 80%"], appsWritten: ["com.example.secret"])
        let layouts = [status(report: written), status(report: written, error: .notAccepted, errorAt: error),
                       status(.held(LayoutWords.heldForTheSpacer), report: written), status(.needsGrant, report: written)]
        for layout in layouts {
            let text = DiagnosticsText.render(checks: rows(layout: layout), home: "/Users/someone")
            #expect(!text.contains("com.example"))
            #expect(!text.contains("Wi-Fi"))
            #expect(!text.contains("Battery"))
            // What is copied is what the pane shows, and neither says "below".
            #expect(!text.contains("below"))
        }
        let json = DiagnosticsText.json(checks: rows(layout: layouts[1]), home: "/Users/someone")
        #expect(!String(decoding: (try? JSONEncoder().encode(json)) ?? Data(), as: UTF8.self).contains("com.example"))
    }

    @Test func aFailureTextWithAHomePathIsCopiedWithATilde() {
        // The writer's own words may hold a path: the copied report writes the home folder as `~`.
        let failed = status(report: report, error: .failed("couldn't write /Users/someone/Library/Preferences/layout.plist"), errorAt: error)
        let text = DiagnosticsText.render(checks: rows(layout: failed), home: "/Users/someone")
        #expect(text.contains("~/Library/Preferences/layout.plist"))
        #expect(!text.contains("/Users/someone"))
        let json = DiagnosticsText.json(checks: rows(layout: failed), home: "/Users/someone")
        #expect(!String(decoding: (try? JSONEncoder().encode(json)) ?? Data(), as: UTF8.self).contains("/Users/someone"))
    }
}
