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

    @Test func rowsForEachWriterState() {
        #expect(rows(layout: nil).first == DiagnosticsCheck(title: "Menu bar layout", status: .unknown, detail: "Not read yet."))
        #expect(rows(layout: status(report: report)).first == DiagnosticsCheck(
            title: "Menu bar layout", status: .ok, detail: "Reordering works. Last change checked at 10:15:30."))
        #expect(rows(layout: status()).first == DiagnosticsCheck(title: "Menu bar layout", status: .ok, detail: "Reordering works."))
        #expect(rows(layout: status(.needsGrant)).first == DiagnosticsCheck(
            title: "Menu bar layout", status: .warning, detail: "Grant access to reorder in Settings › Layout."))
        #expect(rows(layout: status(.broken(LayoutWords.broken))).first == DiagnosticsCheck(
            title: "Menu bar layout", status: .problem, detail: LayoutWords.broken))
        // The three rows, in this order.
        #expect(rows(layout: nil).map(\.title) == ["Menu bar layout", "Icon images", "Icon spacing"])
    }

    @Test func aWriteThatPlacedNothingIsNotReorderingThatWorks() {
        let item = ItemID(bundleID: "com.example.a", key: .index(0))
        func placed(_ count: Int?, unresolved: [ItemID] = [item], notPlaced: [String] = []) -> LayoutWriteReport {
            LayoutWriteReport(at: Date(timeIntervalSince1970: 1_793_268_930), written: 0, attempts: 1, verdict: "matches", unresolved: unresolved,
                              memory: [:], notPlaced: notPlaced, appsWritten: [], placed: count)
        }
        // Nothing placed, and apps that can't be: say so, in the pane's words for them.
        let apps = rows(layout: status(report: placed(0))).first
        #expect(apps?.status == .warning)
        #expect(apps?.detail == "The last change placed no icons (10:15:30). macOS gives Mantel no way to place these. ⌘-drag them in the menu bar.")
        // Mantel's own icons among them: the banner's words for those.
        let own = rows(layout: status(report: placed(0, notPlaced: [OwnItems.hiddenDotName]))).first
        #expect(own?.detail == "The last change placed no icons (10:15:30). Some of Mantel's icons couldn't be placed among icons it can't reorder. ⌘-drag them in the menu bar.")
        // Something placed, a report from before the count was kept, or nothing left to place: it works.
        for report in [placed(3), placed(nil), placed(0, unresolved: [])] {
            #expect(rows(layout: status(report: report)).first?.detail == "Reordering works. Last change checked at 10:15:30.")
            #expect(rows(layout: status(report: report)).first?.status == .ok)
        }
    }

    @Test func heldRow() {
        let held = rows(layout: status(.held(LayoutWords.heldForAProbe), report: report)).first
        #expect(held == DiagnosticsCheck(title: "Menu bar layout", status: .warning, detail: LayoutWords.heldForAProbe))
    }

    @Test func failedRow() {
        let notAccepted = rows(layout: status(report: report, error: .notAccepted, errorAt: error)).first
        #expect(notAccepted == DiagnosticsCheck(title: "Menu bar layout", status: .problem,
                                                detail: "macOS didn't accept the last order (11:15:30)."))
        let failed = rows(layout: status(report: report, error: .failed("the table couldn't be read"), errorAt: error)).first
        #expect(failed == DiagnosticsCheck(title: "Menu bar layout", status: .problem,
                                           detail: "Couldn't change the menu bar order (11:15:30): the table couldn't be read"))
        // The time is the failure's, not the last good write's.
        #expect(failed?.detail.contains("10:15:30") == false)
        // A failure the writer gave no time for leaves the time out.
        #expect(rows(layout: status(error: .notAccepted)).first?.detail == "macOS didn't accept the last order.")
        // A failure that is the grant's or the writer's own is said as the availability says it.
        #expect(rows(layout: status(.broken("Reordering is off."), error: .broken("Reordering is off."))).first?.detail == "Reordering is off.")
    }

    @Test func imagesRow() {
        #expect(rows(layout: nil).dropFirst().first == DiagnosticsCheck(
            title: "Icon images", status: .ok, detail: "4 icons captured, the last at 10:15:30."))
        #expect(rows(layout: nil, images: (1, at, true))[1].detail == "1 icon captured, the last at 10:15:30.")
        // Screen Recording off says so, whatever was captured while it was on.
        #expect(rows(layout: nil, images: (4, at, false))[1] == DiagnosticsCheck(
            title: "Icon images", status: .warning, detail: "Screen Recording is off, so app icons stand in."))
        #expect(rows(layout: nil, images: (0, nil, true))[1] == DiagnosticsCheck(
            title: "Icon images", status: .unknown, detail: "No icon pictures captured yet."))
    }

    @Test func imageSummaryCountsIconsWithPictures() {
        let early = Date(timeIntervalSince1970: 100)
        let late = Date(timeIntervalSince1970: 900)
        let summary = LayoutDiagnostics.imageSummary(captured: [[early, late], [], [early]])
        #expect(summary.count == 2)
        #expect(summary.last == late)
        #expect(LayoutDiagnostics.imageSummary(captured: []).count == 0)
        #expect(LayoutDiagnostics.imageSummary(captured: []).last == nil)
    }

    @Test func spacingRow() {
        #expect(rows(layout: nil)[2] == DiagnosticsCheck(title: "Icon spacing", status: .ok, detail: "macOS default."))
        let small = SpacingState(spacing: 8, padding: 8, preset: .small, original: nil)
        #expect(rows(layout: nil, spacing: small)[2].detail == "Small.")
        let odd = SpacingState(spacing: 3, padding: 9, preset: .custom, original: SpacingOriginal(spacing: nil, padding: nil))
        #expect(rows(layout: nil, spacing: odd)[2].detail == "Custom.")
        // On a Mac where macOS doesn't apply it, the row is a warning that says so, whatever the keys hold.
        #expect(rows(layout: nil, spacing: small, works: false)[2] == DiagnosticsCheck(
            title: "Icon spacing", status: .warning, detail: "macOS 27 doesn't apply icon spacing on this Mac."))
    }

    @Test func copiedRowsHaveNoNames() {
        let apps = [ItemID(bundleID: "com.example.secret", key: .identifier("Wi-Fi: Home network")), ItemID(bundleID: "com.example.other", key: .index(1))]
        let written = LayoutWriteReport(at: at, written: 2, attempts: 2, verdict: "matches", unresolved: apps, memory: [apps[0]: "key"],
                                        notPlaced: ["com.example.secret", "Battery 80%"], appsWritten: ["com.example.secret"])
        let layouts = [status(report: written), status(report: written, error: .notAccepted, errorAt: error),
                       status(.held(LayoutWords.heldForTheSpacer), report: written), status(.needsGrant, report: written)]
        for layout in layouts {
            let text = DiagnosticsText.render(checks: rows(layout: layout), probes: [:], home: "/Users/someone", timeZone: utc)
            #expect(!text.contains("com.example"))
            #expect(!text.contains("Wi-Fi"))
            #expect(!text.contains("Battery"))
            // What is copied is what the pane shows, and neither says "below".
            #expect(!text.contains("below"))
        }
        let json = DiagnosticsText.json(checks: rows(layout: layouts[1]), probes: [:], home: "/Users/someone")
        #expect(!String(decoding: (try? JSONEncoder().encode(json)) ?? Data(), as: UTF8.self).contains("com.example"))
    }

    @Test func aFailureTextWithAHomePathIsCopiedWithATilde() {
        // The writer's own words may hold a path: the copied report writes the home folder as `~`.
        let failed = status(report: report, error: .failed("couldn't write /Users/someone/Library/Preferences/layout.plist"), errorAt: error)
        let text = DiagnosticsText.render(checks: rows(layout: failed), probes: [:], home: "/Users/someone", timeZone: utc)
        #expect(text.contains("~/Library/Preferences/layout.plist"))
        #expect(!text.contains("/Users/someone"))
        let json = DiagnosticsText.json(checks: rows(layout: failed), probes: [:], home: "/Users/someone")
        #expect(!String(decoding: (try? JSONEncoder().encode(json)) ?? Data(), as: UTF8.self).contains("/Users/someone"))
    }
}
