import CoreGraphics
import Foundation
import MKCore
import MKLayout
import MKTestSupport
import Testing

@testable import MKMenuBar

@Suite("Spacer layout", .timeLimit(.minutes(1)))
struct SpacerLayoutTests {
    private func plan(_ sections: Set<MenuBarSection>) -> VisibilityPlan {
        EngineFixtures.plan(visible: ["com.example.a"], concealed: sections.isEmpty ? [] : ["com.example.b"], sections: sections)
    }

    @Test(arguments: [(widths: [1800.0, 3360.0], cap: 899.0), (widths: [1728.0], cap: 863.0), (widths: [3360.0, 1800.0, 2560.0], cap: 899.0),
                      (widths: [1001.0], cap: 499.0)])
    func capIsBelowHalfTheNarrowestBar(widths: [Double], cap: Double) {
        let bars = widths.map { EngineFixtures.bar(CGFloat($0)) }
        #expect(SpacerLayout.cap(for: bars) == CGFloat(cap), "half the narrowest, rounded down, less a point")
        // No spacer is as wide as half of any bar.
        for bar in bars { #expect(SpacerLayout.cap(for: bars) < bar.rect.width / 2) }
        // Every spacer the layout makes is as wide as that and no more.
        let widthsMade = SpacerLayout.widths(for: plan([.hidden]), bars: bars)
        #expect(widthsMade.divider.allSatisfy { $0 == CGFloat(cap) })
    }

    @Test func enoughSpacersForTheWidestBar() {
        // The desk: the portrait display's bar is 1800 and the main display's 3360. 3360 less 300 is 3060, which 899 goes into four times.
        let widths = SpacerLayout.widths(for: plan([.hidden]), bars: EngineFixtures.deskBars)
        #expect(widths.divider == [899, 899, 899, 899])
        #expect(widths.always == 0, "Always Hidden is behind the divider already")
        // Together they cover the widest bar but for the room that is left for the items that stay.
        #expect(widths.divider.reduce(0, +) >= 3360 - 300)
        // A single display needs fewer: 1728 is 863 a spacer, and 1428 of it is hidden.
        let one = SpacerLayout.widths(for: plan([.hidden]), bars: [EngineFixtures.bar(1728)])
        #expect(one.divider == [863, 863])
        // A bar that is no wider than the room that is kept still has its divider.
        #expect(SpacerLayout.widths(for: plan([.hidden]), bars: [EngineFixtures.bar(280)]).divider == [139])
    }

    @Test func collapsedWhenNothingConcealed() {
        let widths = SpacerLayout.widths(for: plan([]), bars: EngineFixtures.deskBars)
        #expect(widths.divider == [0, 0, 0, 0], "the spacers are there, and take no room")
        #expect(widths.always == 0)
        #expect(widths.divider.allSatisfy { $0 == 0 })
        // Without a bar to measure, there is nothing to make wide.
        let none = SpacerLayout.widths(for: plan([.hidden, .alwaysHidden]), bars: [])
        #expect(none == SpacerWidths(divider: [0], always: 0))
    }

    @Test func alwaysSpacerOnlyWhileHiddenShows() {
        let bars = EngineFixtures.deskBars
        // Hidden shows (revealed) and Always Hidden is still away: its own spacer is the one that is wide.
        let hiddenShows = SpacerLayout.widths(for: plan([.alwaysHidden]), bars: bars)
        #expect(hiddenShows.always == 899)
        #expect(hiddenShows.divider == [0, 0, 0, 0])
        // Both are away: the divider takes everything, and the second spacer isn't needed.
        let both = SpacerLayout.widths(for: plan([.hidden, .alwaysHidden]), bars: bars)
        #expect(both.always == 0)
        #expect(both.divider == [899, 899, 899, 899])
        // Hidden alone.
        #expect(SpacerLayout.widths(for: plan([.hidden]), bars: bars).always == 0)
    }

    @Test func removedMeansNoSpacersAtAll() {
        #expect(SpacerWidths.removed == SpacerWidths(divider: [], always: 0))
        #expect(SpacerWidths.removed.divider.allSatisfy { $0 == 0 })
        #expect(SpacerWidths.removed.dividerItems.isEmpty, "no item to draw a line in")
    }

    @Test func theDividerShowsALineWhileCollapsed() {
        // Icons are revealed, or nothing is hidden: the divider takes no room to hide, and the person has to see where to drag icons.
        for sections in [Set<MenuBarSection>(), [.alwaysHidden]] {
            let widths = SpacerLayout.widths(for: plan(sections), bars: EngineFixtures.deskBars)
            let items = widths.dividerItems
            #expect(items.count == widths.divider.count, "\(sections)")
            #expect(items.first == SpacerItem(length: 9, drawsLine: true), "a thin line, in an item about nine points wide")
            #expect(SpacerLayout.lineItemWidth == 9)
            // A divider that is several (a wide display) has the line once: the others take no room.
            #expect(items.dropFirst().allSatisfy { $0 == SpacerItem(length: 0, drawsLine: false) })
        }
        // Without a bar to measure the divider is collapsed too, and shows the line.
        let noBars = SpacerLayout.widths(for: plan([.hidden]), bars: [])
        #expect(noBars.dividerItems == [SpacerItem(length: 9, drawsLine: true)])
    }

    @Test func aDividerThatHidesIsWideAndDrawsNothing() {
        let widths = SpacerLayout.widths(for: plan([.hidden]), bars: EngineFixtures.deskBars)
        #expect(widths.dividerItems == widths.divider.map { SpacerItem(length: $0, drawsLine: false) })
        #expect(widths.dividerItems.allSatisfy { $0.length > 0 && !$0.drawsLine })
        // Both away: the same.
        let both = SpacerLayout.widths(for: plan([.hidden, .alwaysHidden]), bars: EngineFixtures.deskBars)
        #expect(both.dividerItems.allSatisfy { !$0.drawsLine })
    }

    @Test func theLineGoesWhenTheDividerHidesAgain() {
        let bars = EngineFixtures.deskBars
        // Revealed, then collapsed: the line comes and goes with the width.
        #expect(SpacerLayout.widths(for: plan([]), bars: bars).dividerItems.first?.drawsLine == true)
        #expect(SpacerLayout.widths(for: plan([.hidden]), bars: bars).dividerItems.first?.drawsLine == false)
        #expect(SpacerLayout.widths(for: plan([]), bars: bars).dividerItems.first?.drawsLine == true)
    }
}

@Suite("Spacer engine", .timeLimit(.minutes(1)))
struct SpacerEngineTests {
    private let hiddenPlan = EngineFixtures.plan(visible: ["com.example.a"], concealed: ["com.example.b"])
    private let nothingPlan = EngineFixtures.plan(visible: ["com.example.a", "com.example.b"])

    @Test @MainActor func applyShowsWidths() async throws {
        let spacers = FakeSpacers()
        let engine = SpacerEngine(spacers: spacers)
        await engine.setBars(EngineFixtures.deskBars)

        try await engine.apply(hiddenPlan)

        #expect(spacers.shown.last == SpacerWidths(divider: [899, 899, 899, 899], always: 0))
        // The next plan replaces the widths.
        try await engine.apply(nothingPlan)
        #expect(spacers.shown.last == SpacerWidths(divider: [0, 0, 0, 0], always: 0))
        #expect(engine.kind == .spacer)
        #expect(await engine.availability() == .available)
    }

    @Test @MainActor func displaysChangingRemakesTheWidths() async throws {
        let spacers = FakeSpacers()
        let engine = SpacerEngine(spacers: spacers)
        try await engine.apply(hiddenPlan)
        #expect(spacers.shown.last == SpacerWidths(divider: [0], always: 0), "with no bar known yet, nothing is wide")

        await engine.setBars([EngineFixtures.bar(1728)])
        #expect(spacers.shown.last == SpacerWidths(divider: [863, 863], always: 0))
        let count = spacers.shown.count
        await engine.setBars([EngineFixtures.bar(1728)])
        #expect(spacers.shown.count == count, "the same bars change nothing")

        // Before a plan, a change of bars shows nothing.
        let idle = FakeSpacers()
        let waiting = SpacerEngine(spacers: idle)
        await waiting.setBars(EngineFixtures.deskBars)
        #expect(idle.shown.isEmpty)
    }

    @Test @MainActor func tearDownCollapses() async throws {
        let spacers = FakeSpacers()
        let engine = SpacerEngine(spacers: spacers)
        await engine.setBars(EngineFixtures.deskBars)
        try await engine.apply(hiddenPlan)

        await engine.tearDown()

        let last = try #require(spacers.shown.last)
        #expect(last == .removed, "no spacer is left, and every width there is is 0")
        #expect(last.divider.allSatisfy { $0 == 0 } && last.always == 0)
        // A change of bars after that doesn't bring them back.
        await engine.setBars([EngineFixtures.bar(1000)])
        #expect(spacers.shown.last == .removed)
    }

    @Test func theSpacerIsDegradedInTheStatus() async {
        let controller = HidingController(engines: [.spacer: SpacerEngine(spacers: FakeSpacers())], clock: SteppingClock(),
                                          confirm: { _ in .seen })
        await controller.choose(method: .wideSpacer)
        let status = await controller.status()
        #expect(status.kind == .spacer)
        #expect(status.degraded)
    }
}
