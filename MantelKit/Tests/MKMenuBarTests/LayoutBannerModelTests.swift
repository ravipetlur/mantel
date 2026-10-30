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

    @Test func availableSaysNothing() {
        #expect(LayoutBannerModel.lines(status: status(), addedAtTheEndOf: nil, refusal: nil).isEmpty)
        #expect(LayoutBannerModel.lines(status: nil, addedAtTheEndOf: nil, refusal: nil).isEmpty)
    }

    @Test func needsTheGrantOffersTheButton() {
        let lines = LayoutBannerModel.lines(status: status(.needsGrant), addedAtTheEndOf: nil, refusal: nil)
        #expect(lines == [LayoutBannerLine(text: "Grant access to reorder, or ⌘-drag in the menu bar", offersGrant: true)])
    }

    @Test func heldAndBrokenSayTheWritersReason() {
        #expect(LayoutBannerModel.lines(status: status(.held(LayoutWords.heldForAProbe)), addedAtTheEndOf: nil, refusal: nil).map(\.text)
            == [LayoutWords.heldForAProbe])
        let broken = LayoutBannerModel.lines(status: status(.broken(LayoutWords.broken)), addedAtTheEndOf: nil, refusal: nil)
        #expect(broken == [LayoutBannerLine(text: LayoutWords.broken)])
        #expect(!broken[0].offersGrant)
    }

    @Test func aWriteThatWasNotAcceptedIsSaidAndNothingElseIsWhenAvailable() {
        let lines = LayoutBannerModel.lines(status: status(error: .notAccepted), addedAtTheEndOf: nil, refusal: nil)
        #expect(lines.map(\.text) == ["macOS didn't accept the last order. Try the change again, or ⌘-drag in the menu bar."])
        // Another kind of failure is the toast's, not the banner's.
        #expect(LayoutBannerModel.lines(status: status(error: .failed("x")), addedAtTheEndOf: nil, refusal: nil).isEmpty)
    }

    @Test func ownIconsLeftUnplacedAreSaid() {
        let lines = LayoutBannerModel.lines(status: status(notPlaced: ["mantel.spacer.0000000a"]), addedAtTheEndOf: nil, refusal: nil)
        #expect(lines.map(\.text)
            == ["Some of Mantel's icons couldn't be placed among icons it can't reorder. ⌘-drag them in the menu bar."])
    }

    @Test func appsThatHadNoGapAreNotMantelsIconsLeftUnplaced() {
        // The report's list holds the apps' names too: only an own item's makes the line.
        #expect(LayoutBannerModel.lines(status: status(notPlaced: ["com.example.named"]), addedAtTheEndOf: nil, refusal: nil).isEmpty)
        let both = LayoutBannerModel.lines(status: status(notPlaced: ["com.example.named", "mantel.group.0000000b"]),
                                           addedAtTheEndOf: nil, refusal: nil)
        #expect(both.map(\.text)
            == ["Some of Mantel's icons couldn't be placed among icons it can't reorder. ⌘-drag them in the menu bar."])
    }

    @Test func aPaletteDropWithoutTheGrantSaysWhereItWent() {
        let lines = LayoutBannerModel.lines(status: status(.needsGrant), addedAtTheEndOf: .alwaysHidden, refusal: nil)
        #expect(lines.map(\.text) == ["Grant access to reorder, or ⌘-drag in the menu bar",
                                      "Added at the end of Always Hidden. ⌘-drag it into place in the menu bar."])
        // Once the file is given the writer places it: the line goes.
        #expect(LayoutBannerModel.lines(status: status(.available), addedAtTheEndOf: .alwaysHidden, refusal: nil).isEmpty)
    }

    @Test func aRefusalIsAddedUnlessALineSaysItAlready() {
        let grant = "Grant access to reorder, or ⌘-drag in the menu bar"
        #expect(LayoutBannerModel.lines(status: status(.needsGrant), addedAtTheEndOf: nil, refusal: grant).count == 1)
        #expect(LayoutBannerModel.lines(status: status(), addedAtTheEndOf: nil, refusal: "System icons keep macOS's order.").map(\.text)
            == ["System icons keep macOS's order."])
    }

    @Test func theRefusalsRowIsThereForAsLongAsSomethingIsBeingDragged() {
        let cantPlace = LayoutEditorCopy.cantPlaceThisIcon
        for availability in [LayoutWriterAvailability.available, .needsGrant, .held(LayoutWords.heldForAProbe), .broken(LayoutWords.broken)] {
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

    @Test func aRefusalToReorderUnderABrokenWriterFlashesTheBrokenLine() {
        let broken = status(.broken(LayoutWords.broken))
        let flashed = LayoutBannerModel.flashed(LayoutCopy.needsGrantBanner, status: broken)
        #expect(flashed == LayoutWords.broken)
        // It is the standing line, so the banner highlights it and gains no row.
        let lines = LayoutBannerModel.lines(status: broken, addedAtTheEndOf: nil, refusal: flashed)
        #expect(lines.map(\.text) == [LayoutWords.broken])
        // Other refusals, and other states, are said as they are.
        #expect(LayoutBannerModel.flashed(LayoutEditorCopy.cantPlaceThisIcon, status: broken) == LayoutEditorCopy.cantPlaceThisIcon)
        #expect(LayoutBannerModel.flashed(LayoutCopy.needsGrantBanner, status: status(.needsGrant)) == LayoutCopy.needsGrantBanner)
        #expect(LayoutBannerModel.flashed(LayoutCopy.needsGrantBanner, status: nil) == LayoutCopy.needsGrantBanner)
    }

    @Test func reorderingIsAllowedWhenTheWriterWillWriteSooner() {
        #expect(LayoutWriterAvailability.available.allowsReordering)
        #expect(LayoutWriterAvailability.held("x").allowsReordering)
        #expect(!LayoutWriterAvailability.needsGrant.allowsReordering)
        #expect(!LayoutWriterAvailability.broken("x").allowsReordering)
    }

    @Test func aRestoreDuringAHoldSaysTheHoldsReason() {
        let held = status(.held(LayoutWords.heldForTheSpacer))
        #expect(LayoutBannerModel.restoreFailure(.failed(LayoutWords.heldForTheSpacer), status: held) == LayoutWords.heldForTheSpacer)
        // The status the pane drew hasn't caught up with the hold (nothing was waiting to be written, so none was published): the error
        // says the reason.
        for reason in LayoutHold.reasons {
            #expect(LayoutBannerModel.restoreFailure(.failed(reason), status: status(.available)) == reason)
            #expect(LayoutBannerModel.restoreFailure(.failed(reason), status: nil) == reason)
        }
        // Or the error says nothing and the status does.
        #expect(LayoutBannerModel.restoreFailure(.failed("x"), status: held) == LayoutWords.heldForTheSpacer)
        // Otherwise what the error says; without the file, what the banner says.
        #expect(LayoutBannerModel.restoreFailure(.needsGrant, status: status(.needsGrant)) == LayoutCopy.needsGrantBanner)
        #expect(LayoutBannerModel.restoreFailure(.needsGrant, status: nil) == "Grant access to reorder, or ⌘-drag in the menu bar")
        #expect(LayoutBannerModel.restoreFailure(.failed("x"), status: status()) == LayoutWords.couldntChange)
        #expect(LayoutHold.reasons == [LayoutHold.reason(probeChangingMenuBar: true, engine: nil),
                                       LayoutHold.reason(probeChangingMenuBar: false, engine: .spacer)])
    }
}
