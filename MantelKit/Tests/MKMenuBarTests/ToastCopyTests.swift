import AppKit
import Foundation
import Testing

@testable import MKMenuBar

/// The words of the toasts.
@Suite("Toast copy", .timeLimit(.minutes(1)))
struct ToastCopyTests {
    @Test func eachClickFailureHasItsToast() {
        #expect(ToastCopy.click(.noRoom, app: "Weather") == ToastContent(symbol: "menubar.rectangle", text: "No room to click Weather"))
        #expect(ToastCopy.click(.refused("no"), app: "Weather") == ToastContent(symbol: "exclamationmark.triangle", text: "Couldn't click Weather"))
        #expect(ToastCopy.click(.hiddenBar, app: "Weather") == ToastContent(symbol: "menubar.rectangle", text: "The menu bar is hidden right now"))
        #expect(ToastCopy.click(.notRunning, app: "Weather") == ToastContent(symbol: "xmark.circle", text: "Weather isn't running"))
        #expect(ToastCopy.click(.unreachable, app: "Weather") == ToastContent(symbol: "questionmark.circle", text: "Couldn't reach Weather's icon"))
    }

    @Test func theSymbolsExist() {
        let symbols = ["menubar.rectangle", "exclamationmark.triangle", "xmark.circle", "questionmark.circle", "photo.on.rectangle"]
        for symbol in symbols {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, Comment(rawValue: symbol))
        }
    }

    @Test func iconsCapturedHasItsToast() {
        #expect(ToastCopy.iconsCaptured == ToastContent(symbol: "photo.on.rectangle", text: "Icons captured"))
    }

    private func status(error: LayoutWriteError?, pending: Bool = false, at: Date? = nil) -> LayoutStatus {
        LayoutStatus(availability: .available, lastReport: nil, lastError: error, isPending: pending, isSettling: false,
                     hasKeptChanges: false, dotsPlacementOffered: false, lastErrorAt: at)
    }

    @Test func aWriteThatMacOSDidntAcceptIsToasted() {
        let toast = ToastCopy.layout(previous: status(error: nil, pending: true), now: status(error: .notAccepted))
        #expect(toast == ToastContent(symbol: "exclamationmark.triangle", text: "macOS didn't accept the new order"))
    }

    @Test func aWriteThatFailedIsToasted() {
        let toast = ToastCopy.layout(previous: nil, now: status(error: .failed("the detail is for the log")))
        #expect(toast == ToastContent(symbol: "exclamationmark.triangle", text: "Couldn't change the menu bar order"))
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
