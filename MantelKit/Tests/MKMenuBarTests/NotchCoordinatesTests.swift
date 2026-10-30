import CoreGraphics
import Foundation
import Testing

@testable import MKMenuBar

@Suite("Notch coordinates", .timeLimit(.minutes(2)))
struct NotchCoordinatesTests {
    private func screen(origin: CGPoint, leftX: CGFloat, rightX: CGFloat, notched: Bool = true) -> ScreenFacts {
        ScreenFacts(uuid: "7B0E1E64-5D0F-4F5B-9A53-1C2D3E4F5A6B", frame: CGRect(origin: origin, size: CGSize(width: 1512, height: 982)),
                    safeAreaTop: notched ? 32 : 0,
                    auxiliaryTopLeft: notched ? CGRect(x: leftX, y: origin.y + 950, width: 663, height: 32) : nil,
                    auxiliaryTopRight: notched ? CGRect(x: rightX, y: origin.y + 950, width: 663, height: 32) : nil, isBuiltIn: true)
    }

    @Test func originScreenIsUndecided() {
        // At the origin the two kinds of coordinates are the same numbers.
        #expect(NotchCoordinates.verdict(screen(origin: .zero, leftX: 0, rightX: 849)) == .undecided)
    }

    @Test func offsetScreenWithOffsetAreasIsGlobal() {
        // The built-in screen, to the right of the main display, with areas that are where it is in the whole arrangement.
        #expect(NotchCoordinates.verdict(screen(origin: CGPoint(x: 3360, y: 0), leftX: 3360, rightX: 3360 + 849)) == .global)
        // A screen to the left, at a negative x.
        #expect(NotchCoordinates.verdict(screen(origin: CGPoint(x: -1512, y: 0), leftX: -1512, rightX: -1512 + 849)) == .global)
    }

    @Test func offsetScreenWithZeroBasedAreasIsScreenLocal() {
        #expect(NotchCoordinates.verdict(screen(origin: CGPoint(x: 3360, y: 0), leftX: 0, rightX: 849)) == .screenLocal)
    }

    @Test func aScreenWithoutAreasOrWithAreasThatFitNeitherIsUndecided() {
        #expect(NotchCoordinates.verdict(screen(origin: CGPoint(x: 3360, y: 0), leftX: 0, rightX: 0, notched: false)) == .undecided)
        // One area in each kind of coordinates.
        #expect(NotchCoordinates.verdict(screen(origin: CGPoint(x: 3360, y: 0), leftX: 0, rightX: 3360 + 849)) == .undecided)
        // Somewhere that is neither.
        #expect(NotchCoordinates.verdict(screen(origin: CGPoint(x: 3360, y: 0), leftX: 9000, rightX: 9849)) == .undecided)
    }

    @Test func theFactsAreWhatTheReportKeeps() throws {
        let facts = screen(origin: CGPoint(x: 3360, y: 0), leftX: 3360, rightX: 4209)
        let data = try JSONEncoder().encode(facts)
        #expect(try JSONDecoder().decode(ScreenFacts.self, from: data) == facts)
        #expect(NotchCoordinates.Verdict.screenLocal.rawValue == "screenLocal")
    }
}
