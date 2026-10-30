import Testing

@testable import MKLayout

@Suite("Own item hiding", .timeLimit(.minutes(1)))
struct OwnItemHidingTests {
    @Test func visibilityTurnsTheItemOffAndNeverCollapsesIt() {
        #expect(OwnItemHiding.visibility.presentation(onBar: true) == .init(isVisible: true, isCollapsed: false))
        #expect(OwnItemHiding.visibility.presentation(onBar: false) == .init(isVisible: false, isCollapsed: false))
    }

    @Test func zeroLengthCollapsesTheItemAndNeverTurnsItOff() {
        // Taking the item off the bar loses its place, so `isVisible` stays on for both.
        #expect(OwnItemHiding.zeroLength.presentation(onBar: true) == .init(isVisible: true, isCollapsed: false))
        #expect(OwnItemHiding.zeroLength.presentation(onBar: false) == .init(isVisible: true, isCollapsed: true))
    }

    @Test func theWaysAreNamedForTheirMechanism() {
        #expect(OwnItemHiding.visibility.rawValue == "visibility")
        #expect(OwnItemHiding.zeroLength.rawValue == "zeroLength")
        #expect(OwnItemHiding(rawValue: "zeroLength") == .zeroLength)
    }
}
