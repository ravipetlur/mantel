import Testing

@testable import MKCore

/// A window being shown, with the calls it makes written down in order. What `later` is given waits until `runLater()`, as the next turn
/// of the main queue does.
@MainActor
private final class ShowingRig {
    var calls: [String] = []
    var isActive = false
    /// What a request to activate does: nothing yet (it takes a moment), or the app is active at once.
    var activationIsImmediate = false
    private var waiting: [@MainActor () -> Void] = []

    var showing: WindowShowing {
        WindowShowing(
            becomeRegular: { self.calls.append("becomeRegular") },
            later: { work in
                self.calls.append("later")
                self.waiting.append(work)
            },
            activate: {
                self.calls.append("activate")
                if self.activationIsImmediate { self.isActive = true }
            },
            isActive: { self.isActive },
            makeKeyAndOrderFront: { self.calls.append("makeKeyAndOrderFront") },
            orderFrontRegardless: { self.calls.append("orderFrontRegardless") })
    }

    func runLater() {
        let work = waiting
        waiting = []
        for item in work { item() }
    }
}

@MainActor
@Suite("Window showing", .timeLimit(.minutes(1)))
struct WindowShowingTests {
    @Test func aWindowBecomesRegularAtOnceAndNothingElseHappensBeforeTheNextTurn() {
        let rig = ShowingRig()
        rig.showing.show()
        // The menu the request came from is still tracking: nothing is activated or ordered front from inside it.
        #expect(rig.calls == ["becomeRegular", "later"])
    }

    @Test func theWindowIsActivatedThenMadeKeyInOrderOnTheNextTurn() {
        let rig = ShowingRig()
        rig.activationIsImmediate = true
        rig.showing.show()
        rig.runLater()
        #expect(rig.calls == ["becomeRegular", "later", "activate", "makeKeyAndOrderFront"])
    }

    @Test func aWindowIsOrderedFrontRegardlessWhenMantelIsStillNotActiveAfterTheRequest() {
        let rig = ShowingRig()
        rig.showing.show()
        rig.runLater()
        #expect(rig.calls == ["becomeRegular", "later", "activate", "makeKeyAndOrderFront", "orderFrontRegardless"])
    }

    @Test func aWindowIsNotOrderedFrontRegardlessWhenMantelIsActive() {
        let rig = ShowingRig()
        rig.isActive = true
        rig.showing.show()
        rig.runLater()
        #expect(!rig.calls.contains("orderFrontRegardless"))
        #expect(rig.calls.last == "makeKeyAndOrderFront")
    }

    @Test func showingAWindowTwiceMakesTheCallsTwiceInTheSameOrder() {
        let rig = ShowingRig()
        rig.showing.show()
        rig.showing.show()
        rig.runLater()
        #expect(rig.calls == ["becomeRegular", "later", "becomeRegular", "later",
                              "activate", "makeKeyAndOrderFront", "orderFrontRegardless",
                              "activate", "makeKeyAndOrderFront", "orderFrontRegardless"])
    }
}
