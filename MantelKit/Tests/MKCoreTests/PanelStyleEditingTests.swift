import Foundation
import Testing

@testable import MKCore

@Suite("Panel style editing", .timeLimit(.minutes(1)))
struct PanelStyleEditingTests {
    private let color = RGBAColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1)
    private let other = RGBAColor(red: 1, green: 0, blue: 0.125, alpha: 1)

    private func style(_ background: PanelBackground) -> PanelStyle {
        PanelStyle(background: background, appearance: .dark, border: PanelBorder(color: other, width: 2), shadow: false)
    }

    @Test func kindOfEachBackground() {
        #expect(style(.matchMenuBar).backgroundKind == .matchMenuBar)
        #expect(style(.glass(tint: nil)).backgroundKind == .glass)
        #expect(style(.glass(tint: color)).backgroundKind == .glass)
        #expect(style(.material(.thick)).backgroundKind == .material)
        #expect(style(.solid(color)).backgroundKind == .solid)
        #expect(style(.gradient(from: color, to: other, angle: 90)).backgroundKind == .gradient)
        #expect(PanelBackgroundKind.allCases.count == 5)
    }

    @Test func switchingSolidToGradientKeepsTheColour() {
        let switched = style(.solid(color)).withBackgroundKind(.gradient)
        guard case .gradient(let from, _, _) = switched.background else {
            Issue.record("expected a gradient")
            return
        }
        #expect(from == color)
        #expect(switched.appearance == .dark)
        #expect(switched.border == PanelBorder(color: other, width: 2))
        #expect(switched.shadow == false)
        #expect(style(.solid(color)).withBackgroundKind(.solid) == style(.solid(color)), "the same kind changes nothing")
    }

    @Test func switchingBackKeepsFrom() {
        let gradient = style(.gradient(from: color, to: other, angle: 45))
        #expect(gradient.withBackgroundKind(.solid).background == .solid(color))
        guard case .gradient(let from, _, _) = gradient.withBackgroundKind(.solid).withBackgroundKind(.gradient).background else {
            Issue.record("expected a gradient")
            return
        }
        #expect(from == color)
        #expect(style(.material(.thin)).withBackgroundKind(.material) == style(.material(.thin)))
        #expect(style(.matchMenuBar).withBackgroundKind(.glass).background == .glass(tint: nil))
    }

    @Test func borderWidthClampsOneToFour() {
        let bordered = style(.matchMenuBar)
        #expect(bordered.withBorderWidth(3).border?.width == 3)
        #expect(bordered.withBorderWidth(0).border?.width == 1)
        #expect(bordered.withBorderWidth(-5).border?.width == 1)
        #expect(bordered.withBorderWidth(9).border?.width == 4)
        #expect(bordered.withBorderWidth(3).border?.color == other, "the colour stays")
        #expect(PanelStyle().withBorderWidth(3).border == nil, "no border of its own: nothing to widen")
    }

    @Test func aNewKindTakesItsDefaultsWhenNothingIsCarried() {
        let plain = style(.matchMenuBar)
        #expect(plain.withBackgroundKind(.material).background == .material(.regular))
        #expect(plain.withBackgroundKind(.glass).background == .glass(tint: nil))
        #expect(plain.withBackgroundKind(.solid).background == .solid(.black))
        #expect(plain.withBackgroundKind(.gradient).background == .gradient(from: .black, to: .white, angle: 0))
        #expect(style(.material(.thick)).withBackgroundKind(.solid).background == .solid(.black))
        #expect(style(.solid(color)).withBackgroundKind(.material).background == .material(.regular))
        #expect(style(.solid(color)).withBackgroundKind(.gradient).background == .gradient(from: color, to: .white, angle: 0))
        #expect(style(.gradient(from: color, to: other, angle: 45)).withBackgroundKind(.solid).background == .solid(color))
    }

    @Test func aGlassTintIsNotCarriedToSolidOrGradient() {
        let tinted = style(.glass(tint: RGBAColor(red: 0.35, green: 0.55, blue: 0.95, alpha: 0.35)))
        #expect(tinted.withBackgroundKind(.solid).background == .solid(.black))
        #expect(tinted.withBackgroundKind(.gradient).background == .gradient(from: .black, to: .white, angle: 0))
        #expect(tinted.withBackgroundKind(.glass) == tinted, "the same kind keeps its tint")
    }
}
