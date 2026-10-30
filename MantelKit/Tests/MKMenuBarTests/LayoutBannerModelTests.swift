import Foundation
import MKCore
import MKLayout
import Testing

@testable import MKMenuBar

@Suite("Layout banner", .timeLimit(.minutes(1)))
struct LayoutBannerModelTests {
    private func status(_ availability: LayoutWriterAvailability = .available, error: LayoutWriteError? = nil,
                        notPlaced: [String] = []) -> LayoutStatus {
        let report = notPlaced.isEmpty ? nil : LayoutWriteReport(at: Date(timeIntervalSince1970: 0), written: 1, attempts: 1,
                                                                verdict: "matches", unresolved: [], memory: [:], notPlaced: notPlaced)
        return LayoutStatus(availability: availability, lastReport: report, lastError: error, isPending: false, isSettling: false,
                            hasKeptChanges: false, dotsPlacementOffered: false)
    }

    @Test func needsTheGrantOffersTheButton() {
        let lines = LayoutBannerModel.lines(status: status(.needsGrant), addedAtTheEndOf: nil, refusal: nil)
        #expect(lines == [LayoutBannerLine(text: "Grant access to reorder, or ⌘-drag in the menu bar", offersGrant: true)])
    }

    @Test func aWriteThatWasNotAcceptedIsSaidAndNothingElseIsWhenAvailable() {
        let lines = LayoutBannerModel.lines(status: status(error: .notAccepted), addedAtTheEndOf: nil, refusal: nil)
        #expect(lines.map(\.text) == ["macOS didn't accept the last order. Try the change again, or ⌘-drag in the menu bar."])
        // Another kind of failure is the toast's, not the banner's.
        #expect(LayoutBannerModel.lines(status: status(error: .failed("x")), addedAtTheEndOf: nil, refusal: nil).isEmpty)
    }

    @Test func appsThatHadNoGapAreNotMantelsIconsLeftUnplaced() {
        // The report's list holds the apps' names too: only an own item's makes the line.
        #expect(LayoutBannerModel.lines(status: status(notPlaced: ["com.example.named"]), addedAtTheEndOf: nil, refusal: nil).isEmpty)
        let both = LayoutBannerModel.lines(status: status(notPlaced: ["com.example.named", "mantel.group.0000000b"]),
                                           addedAtTheEndOf: nil, refusal: nil)
        #expect(both.map(\.text)
            == ["Some of Mantel's icons couldn't be placed among icons it can't reorder. ⌘-drag them in the menu bar."])
    }

    @Test func theRefusalsRowIsThereForAsLongAsSomethingIsBeingDragged() {
        let cantPlace = LayoutEditorCopy.cantPlaceThisIcon
        for availability in [LayoutWriterAvailability.available, .needsGrant, .held(LayoutWords.heldForTheSpacer), .broken(LayoutWords.broken)] {
            let standing = LayoutBannerModel.lines(status: status(availability), addedAtTheEndOf: nil, refusal: nil)
            // Nothing to say: an empty row. A refusal that is new takes its place. One a line says already is only highlighted, and the row
            // is still reserved for the one that may follow.
            let idle = LayoutBannerModel.lines(status: status(availability), addedAtTheEndOf: nil, refusal: nil, dragging: true)
            let refused = LayoutBannerModel.lines(status: status(availability), addedAtTheEndOf: nil, refusal: cantPlace, dragging: true)
            #expect(idle.count == standing.count + 1)
            #expect(idle.last == .placeholder)
            #expect(refused.count == standing.count + 1)
            #expect(refused.last == LayoutBannerLine(text: cantPlace))
            if let said = standing.first?.text {
                let highlighted = LayoutBannerModel.lines(status: status(availability), addedAtTheEndOf: nil, refusal: said, dragging: true)
                #expect(highlighted.count == standing.count + 1, "\(availability): the row count doesn't change when the refusal does")
                #expect(highlighted.last == .placeholder)
            }
            // Not dragging: as before, no placeholder.
            #expect(!LayoutBannerModel.lines(status: status(availability), addedAtTheEndOf: nil, refusal: nil).contains(.placeholder))
        }
        #expect(LayoutBannerLine.placeholder.isPlaceholder)
        #expect(LayoutBannerLine.placeholder.text.isEmpty)
    }
}
