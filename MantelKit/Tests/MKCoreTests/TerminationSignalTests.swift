import Testing

@testable import MKCore

@Suite("Quitting on SIGTERM")
struct TerminationSignalTests {
    @Test func theFirstSignalStartsAQuitAndSaysSo() {
        var signal = TerminationSignal()
        #expect(signal.received() == .quit(logLine: "received SIGTERM; quitting as the Quit command does"))
    }

    @Test func aSignalWhileAQuitIsUnderWayStartsNothingAndSaysNothing() {
        var signal = TerminationSignal()
        _ = signal.received()
        for _ in 0..<3 { #expect(signal.received() == .alreadyQuitting) }
    }

    @Test func aQuitThatWasAskedForAnotherWayLeavesNothingForTheSignalToStart() {
        var signal = TerminationSignal()
        signal.quitBegan()
        #expect(signal.received() == .alreadyQuitting)
        // Said twice, it is the same.
        signal.quitBegan()
        #expect(signal.received() == .alreadyQuitting)
    }
}
