import Testing

@testable import MKLayout

@Suite("Layout rules", .timeLimit(.minutes(1)))
struct LayoutRulesTests {
    @Test func unmeasuredIsTheWeakestOfEach() {
        let rules = LayoutRules.unmeasured
        #expect(rules.reference == .orderOnly)
        #expect(rules.keyMatch == .identifiersOnly)
        #expect(rules.needsKnownWidths)
        #expect(rules.broken == nil)
        #expect(rules.verificationWait == .seconds(3))
        #expect(rules.frames == .lag)
        #expect(!rules.dotsPlacementOffered)
    }

    @Test func measuredRulesMatchByRank() {
        // The nameless items' keys are found by count and rank; unmeasured stays with what has a name.
        #expect(LayoutRules.measured.keyMatch == .byRank)
        #expect(LayoutRules.unmeasured.keyMatch == .identifiersOnly)
    }

    @Test func measuredHoldsWhatWasFound() {
        let rules = LayoutRules.measured
        #expect(rules.reference == .orderOnly)
        #expect(rules.keyMatch == .byRank)
        #expect(!rules.needsKnownWidths)
        #expect(rules.broken == nil)
        #expect(rules.verificationWait == .milliseconds(5350))
        #expect(rules.frames == .follow)
        #expect(!rules.dotsPlacementOffered)
    }
}
