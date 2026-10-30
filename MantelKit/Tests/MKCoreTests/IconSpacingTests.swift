import Testing

@testable import MKCore

@Suite("Icon spacing")
struct IconSpacingTests {
    private func values(_ spacing: Int, _ padding: Int) -> IconSpacingValues {
        IconSpacingValues(spacing: spacing, padding: padding)
    }

    @Test func presetValues() {
        let custom = values(3, 5)
        #expect(IconSpacing.values(for: .small, custom: custom) == values(8, 8))
        #expect(IconSpacing.values(for: .tiny, custom: custom) == values(4, 6))
        #expect(IconSpacing.values(for: .none, custom: custom) == values(0, 4))
        #expect(IconSpacing.values(for: .custom, custom: custom) == values(3, 5))
    }

    @Test func macOSDefaultIsNil() {
        #expect(IconSpacing.values(for: .macOSDefault, custom: values(3, 5)) == nil, "both keys are removed: there are no values")
    }

    @Test(arguments: [
        (nil, nil, IconSpacingPreset.macOSDefault),
        (8, 8, .small),
        (4, 6, .tiny),
        (0, 4, .none),
        (8, 6, .custom),
        (6, 8, .custom),
        (8, nil, .custom),
        (nil, 8, .custom),
        (0, 0, .custom),
        (20, 20, .custom),
    ] as [(Int?, Int?, IconSpacingPreset)])
    func presetFromValues(_ spacing: Int?, _ padding: Int?, _ expected: IconSpacingPreset) {
        #expect(IconSpacing.preset(spacing: spacing, padding: padding) == expected)
    }

    @Test(arguments: [IconSpacingPreset.small, .tiny, .none])
    func aPresetsValuesReadBackAsThePreset(_ preset: IconSpacingPreset) throws {
        let held = try #require(IconSpacing.values(for: preset, custom: values(1, 1)))
        #expect(IconSpacing.preset(spacing: held.spacing, padding: held.padding) == preset)
    }

    @Test func customClampsToRange() {
        #expect(IconSpacingValues.range == 0...20)
        #expect(IconSpacing.values(for: .custom, custom: values(-3, 99)) == values(0, 20))
        #expect(IconSpacing.values(for: .custom, custom: values(21, -1)) == values(20, 0))
        #expect(IconSpacing.values(for: .custom, custom: values(0, 20)) == values(0, 20), "the ends are allowed")
        #expect(IconSpacing.values(for: .custom, custom: values(7, 13)) == values(7, 13))
    }

    @Test func keysAndTitles() {
        #expect(IconSpacing.spacingKey == "NSStatusItemSpacing")
        #expect(IconSpacing.paddingKey == "NSStatusItemSelectionPadding")
        #expect(IconSpacingPreset.allCases.map(\.title) == ["macOS default", "Small", "Tiny", "None", "Custom"])
    }
}
