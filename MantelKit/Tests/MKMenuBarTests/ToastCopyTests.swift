import AppKit
import Foundation
import Testing

@testable import MKMenuBar

/// The words of the toasts.
@Suite("Toast copy", .timeLimit(.minutes(1)))
struct ToastCopyTests {
    private func status(error: LayoutWriteError?, pending: Bool = false, at: Date? = nil) -> LayoutStatus {
        LayoutStatus(availability: .available, lastReport: nil, lastError: error, isPending: pending, isSettling: false,
                     hasKeptChanges: false, dotsPlacementOffered: false, lastErrorAt: at)
    }

    @Test func theSameFailureIsToastedOnce() {
        let failed = status(error: .notAccepted)
        #expect(ToastCopy.layout(previous: failed, now: failed) == nil)
        // A second write that fails the same way is a new failure: the state in between was pending.
        #expect(ToastCopy.layout(previous: status(error: .notAccepted, pending: true), now: failed) != nil)
    }

    @Test func aSecondWriteThatFailsTheSameWayIsToastedWhenItWasNeverSeenPending() {
        let first = status(error: .notAccepted, at: Date(timeIntervalSinceReferenceDate: 100))
        let second = status(error: .notAccepted, at: Date(timeIntervalSinceReferenceDate: 130))
        #expect(ToastCopy.layout(previous: first, now: second) != nil)
        #expect(ToastCopy.layout(previous: second, now: second) == nil)
        let failed = status(error: .failed("the detail is for the log"), at: Date(timeIntervalSinceReferenceDate: 100))
        let failedAgain = status(error: .failed("the detail is for the log"), at: Date(timeIntervalSinceReferenceDate: 101))
        #expect(ToastCopy.layout(previous: failed, now: failedAgain) != nil)
    }

    @Test func nothingIsToastedWhileWritingOrWithoutAFailureWorthTelling() {
        #expect(ToastCopy.layout(previous: nil, now: status(error: .notAccepted, pending: true)) == nil)
        #expect(ToastCopy.layout(previous: nil, now: status(error: nil)) == nil)
        #expect(ToastCopy.layout(previous: nil, now: nil) == nil)
        // Needing the grant, or a Mac that can't be written to, are in Settings, not toasts.
        #expect(ToastCopy.layout(previous: nil, now: status(error: .needsGrant)) == nil)
        #expect(ToastCopy.layout(previous: nil, now: status(error: .broken("text"))) == nil)
    }
}
