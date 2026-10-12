import CoreGraphics
import Testing

@testable import MKLayout

@Suite("Swap calculator", .timeLimit(.minutes(1)))
struct SwapCalculatorTests {
    /// Shown apps, the right-most first.
    private let shown: [(bundleID: String, width: CGFloat)] = [
        (bundleID: "com.example.right", width: 30),
        (bundleID: "com.example.middle", width: 40),
        (bundleID: "com.example.left", width: 50),
    ]

    @Test func concealsRightMostFirst() {
        #expect(SwapCalculator.appsToConceal(needed: 10, shownRightToLeft: shown, never: []) == ["com.example.right"])
        #expect(SwapCalculator.appsToConceal(needed: 31, shownRightToLeft: shown, never: [])
            == ["com.example.right", "com.example.middle"])
        #expect(SwapCalculator.maximumRounds == 3)
    }

    @Test func stopsWhenEnoughFreed() {
        // 30 is exactly enough, and so is the sum of the first two at 70.
        #expect(SwapCalculator.appsToConceal(needed: 30, shownRightToLeft: shown, never: []) == ["com.example.right"])
        #expect(SwapCalculator.appsToConceal(needed: 70, shownRightToLeft: shown, never: [])
            == ["com.example.right", "com.example.middle"])
        #expect(SwapCalculator.appsToConceal(needed: 70.5, shownRightToLeft: shown, never: []) == Set(shown.map(\.bundleID)))
        // Nothing is needed, nothing is concealed.
        #expect(SwapCalculator.appsToConceal(needed: 0, shownRightToLeft: shown, never: []).isEmpty)
        #expect(SwapCalculator.appsToConceal(needed: -5, shownRightToLeft: shown, never: []).isEmpty)
    }

    @Test func neverPicksOwnOrSystem() {
        let never: Set<String> = ["com.example.right", "com.apple.menuextra"]
        // The right-most is Mantel's own: it is passed over, and the one after it is first.
        #expect(SwapCalculator.appsToConceal(needed: 10, shownRightToLeft: shown, never: never) == ["com.example.middle"])
        #expect(SwapCalculator.appsToConceal(needed: 45, shownRightToLeft: shown, never: never)
            == ["com.example.middle", "com.example.left"])
        let withSystem = [(bundleID: "com.apple.menuextra", width: 80)] + shown
        #expect(SwapCalculator.appsToConceal(needed: 10, shownRightToLeft: withSystem, never: never) == ["com.example.middle"])
    }

    @Test func notEnoughConcealsAllItCan() {
        #expect(SwapCalculator.appsToConceal(needed: 500, shownRightToLeft: shown, never: []) == Set(shown.map(\.bundleID)))
        // Passing over the ones it may not take: all the rest, short of what was needed.
        #expect(SwapCalculator.appsToConceal(needed: 500, shownRightToLeft: shown, never: ["com.example.middle"])
            == ["com.example.right", "com.example.left"])
        #expect(SwapCalculator.appsToConceal(needed: 10, shownRightToLeft: [], never: []).isEmpty)
        #expect(SwapCalculator.appsToConceal(needed: 10, shownRightToLeft: shown, never: Set(shown.map(\.bundleID))).isEmpty)
    }
}
