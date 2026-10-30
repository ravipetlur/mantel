import AppKit
import Testing

@testable import MKCore

@Suite("Asking for a quit", .timeLimit(.minutes(2)))
struct QuitRequestTests {
    @Test func theRequestIsScheduledOnceForTheRunLoopNotMadeAtOnce() {
        var scheduled: [(delay: TimeInterval, modes: [RunLoop.Mode])] = []
        QuitRequest.ask { delay, modes in scheduled.append((delay, modes)) }
        #expect(scheduled.count == 1, "one request, scheduled and not made by the helper itself")
        #expect(scheduled.first?.delay == 0)
        #expect(scheduled.first?.modes == [.default, .eventTracking], "served in the default mode and while a menu is open")
    }

    /// AppKit waits for the delegate's reply to a quit in the modal-panel mode: a request served there (a second one, while a quit is under
    /// way) ends the app at once, without the cleanup.
    @Test func theRequestIsNeverServedInsideAppKitsWaitForTheReply() {
        #expect(!QuitRequest.modes.contains(.common), "the common modes include the modal-panel mode")
        #expect(!QuitRequest.modes.contains(.modalPanel), "AppKit waits for the reply to a quit in this mode")
    }

    @Test func eachAskingSchedulesItsOwnRequest() {
        var count = 0
        QuitRequest.ask { _, _ in count += 1 }
        QuitRequest.ask { _, _ in count += 1 }
        #expect(count == 2)
    }
}
