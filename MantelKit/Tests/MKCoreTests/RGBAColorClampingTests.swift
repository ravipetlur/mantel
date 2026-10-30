import Foundation
import Testing

@testable import MKCore

@Suite("RGBA colour clamping", .timeLimit(.minutes(1)))
struct RGBAColorClampingTests {
    @Test func componentsOutsideZeroToOneComeBackInRange() {
        // What a saturated Display P3 pick gives in sRGB.
        let wide = RGBAColor(clamping: 1.09, green: -0.2, blue: -0.04, alpha: 1.5)
        #expect(wide == RGBAColor(red: 1, green: 0, blue: 0, alpha: 1))
        #expect(RGBAColor(clamping: 0.25, green: 0.5, blue: 0.75, alpha: 0.5) == RGBAColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 0.5), "in range stays")
    }

    @Test func aComponentThatIsNotANumberBecomesZero() {
        let color = RGBAColor(clamping: .nan, green: .infinity, blue: -.infinity, alpha: .nan)
        #expect(color == RGBAColor(red: 0, green: 1, blue: 0, alpha: 0))
    }
}
