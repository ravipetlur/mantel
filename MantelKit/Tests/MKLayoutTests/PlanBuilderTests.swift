import CoreGraphics
import MKCore
import MKTestSupport
import Testing

@testable import MKLayout

private let own = "com.example.mantel"
private let shownApp = "com.example.shown"
private let hiddenApp = "com.example.hidden"
private let alwaysApp = "com.example.always"
private let newApp = "com.example.new"

private let everySystemNumber = Set(VisibilityPlan.allSystemItems)

/// The sections the tests start from: one app in each section.
private func oneInEachSection() -> SectionModel {
    var sections = SectionModel()
    sections.move(app: shownApp, to: .shown)
    sections.move(app: hiddenApp, to: .hidden)
    sections.move(app: alwaysApp, to: .alwaysHidden)
    return sections
}

private let narrow = WideScreenInput(enabled: true, threshold: 3000, activeScreenWidth: 1500)
private let wide = WideScreenInput(enabled: true, threshold: 3000, activeScreenWidth: 5120)

private func planInputs(running: [String], sections: SectionModel = oneInEachSection(), reveal: RevealLevel = .off, focus: Bool = false,
                    rules: [RuleEffect] = [], allowClock: Bool = false, screen: WideScreenInput = narrow,
                    swap: Set<String> = []) -> PlanInputs {
    PlanInputs(ownBundleID: own, runningBundleIDs: running, sections: sections, reveal: reveal, focusMode: focus, rules: rules,
               allowHidingClockAndControlCenter: allowClock, wideScreen: screen, swapConcealed: swap)
}

/// One pair of layers, set up so that both have something to say about one app, and what the higher of them makes of it.
private struct MergeCase: Sendable, CustomTestStringConvertible {
    let name: String
    let inputs: PlanInputs
    /// Whether the app both layers speak of is visible in the plan.
    let contestedAppIsVisible: Bool
    let source: PlanSource

    var testDescription: String { name }
}

private let contested = "com.example.contested"

private func contestedSections(_ section: MenuBarSection) -> SectionModel {
    var sections = SectionModel()
    sections.move(app: contested, to: section)
    return sections
}

private let mergeCases: [MergeCase] = [
    // Sections are the lowest layer: each of the others overrides them.
    MergeCase(name: "rules over sections", inputs: planInputs(running: [contested], sections: contestedSections(.hidden),
                                                          rules: [.show([contested])]),
              contestedAppIsVisible: true, source: .rules),
    MergeCase(name: "wide screen over sections", inputs: planInputs(running: [contested], sections: contestedSections(.alwaysHidden), screen: wide),
              contestedAppIsVisible: true, source: .wideScreen),
    MergeCase(name: "reveal over sections", inputs: planInputs(running: [contested], sections: contestedSections(.hidden), reveal: .hidden),
              contestedAppIsVisible: true, source: .reveal(.hidden)),
    MergeCase(name: "focus over sections", inputs: planInputs(running: [contested], sections: contestedSections(.shown), focus: true),
              contestedAppIsVisible: false, source: .focusMode),
    // Rules.
    MergeCase(name: "wide screen over rules", inputs: planInputs(running: [contested], sections: contestedSections(.hidden),
                                                             rules: [.show([contested])], screen: wide),
              contestedAppIsVisible: true, source: .wideScreen),
    MergeCase(name: "reveal over rules", inputs: planInputs(running: [contested], sections: contestedSections(.hidden),
                                                        reveal: .all, rules: [.show([contested])], swap: [contested]),
              contestedAppIsVisible: false, source: .reveal(.all)),
    MergeCase(name: "focus over rules", inputs: planInputs(running: [contested], sections: contestedSections(.hidden),
                                                       focus: true, rules: [.show([contested])]),
              contestedAppIsVisible: false, source: .focusMode),
    // A wide screen.
    MergeCase(name: "reveal over wide screen", inputs: planInputs(running: [contested], sections: contestedSections(.shown),
                                                              reveal: .hidden, screen: wide, swap: [contested]),
              contestedAppIsVisible: false, source: .reveal(.hidden)),
    MergeCase(name: "focus over wide screen", inputs: planInputs(running: [contested], sections: contestedSections(.hidden),
                                                             focus: true, screen: wide),
              contestedAppIsVisible: false, source: .focusMode),
    // A reveal.
    MergeCase(name: "focus over reveal", inputs: planInputs(running: [contested], sections: contestedSections(.alwaysHidden),
                                                        reveal: .all, focus: true),
              contestedAppIsVisible: false, source: .focusMode),
]

@Suite("Plan builder", .timeLimit(.minutes(1)))
struct PlanBuilderTests {
    @Test(arguments: mergeCases)
    fileprivate func mergeOrderTable(_ mergeCase: MergeCase) {
        let plan = PlanBuilder.build(mergeCase.inputs)
        #expect(plan.visibleBundleIDs.contains(contested) == mergeCase.contestedAppIsVisible)
        #expect(plan.concealedBundleIDs.contains(contested) == !mergeCase.contestedAppIsVisible)
        #expect(plan.source == mergeCase.source)
        #expect(plan.visibleBundleIDs.contains(own))
    }

    @Test func mergeOrderTableCoversEveryPairOfLayers() {
        // Five layers make ten pairs, and the table has one case for each.
        #expect(mergeCases.count == 10)
        #expect(Set(mergeCases.map(\.name)).count == 10)
    }

    @Test func sectionsOnly() {
        let plan = PlanBuilder.build(planInputs(running: [own, shownApp, hiddenApp, alwaysApp, newApp]))
        #expect(plan.visibleBundleIDs == [own, shownApp, newApp])
        #expect(plan.concealedBundleIDs == [hiddenApp, alwaysApp])
        #expect(plan.concealedSections == [.hidden, .alwaysHidden])
        #expect(plan.visibleSystemItems == everySystemNumber)
        #expect(plan.source == .sections)
        #expect(!plan.concealsNothing)

        // An app that is placed and isn't running is in neither set.
        let none = PlanBuilder.build(planInputs(running: [own]))
        #expect(none.visibleBundleIDs == [own])
        #expect(none.concealedBundleIDs.isEmpty)
    }

    @Test func revealHidden() {
        let plan = PlanBuilder.build(planInputs(running: [own, shownApp, hiddenApp, alwaysApp], reveal: .hidden))
        #expect(plan.visibleBundleIDs == [own, shownApp, hiddenApp])
        #expect(plan.concealedBundleIDs == [alwaysApp])
        #expect(plan.concealedSections == [.alwaysHidden])
        #expect(plan.source == .reveal(.hidden))
    }

    @Test func revealAll() {
        let plan = PlanBuilder.build(planInputs(running: [own, shownApp, hiddenApp, alwaysApp], reveal: .all))
        #expect(plan.visibleBundleIDs == [own, shownApp, hiddenApp, alwaysApp])
        #expect(plan.concealedBundleIDs.isEmpty)
        #expect(plan.concealedSections.isEmpty)
        #expect(plan.source == .reveal(.all))
        #expect(plan.concealsNothing)
    }

    @Test func revealShowsSystemItemsOfTheRevealedSections() {
        var sections = oneInEachSection()
        sections.move(item: .system("wifi"), to: .hidden)
        sections.move(item: .system("battery"), to: .alwaysHidden)
        let none = PlanBuilder.build(planInputs(running: [], sections: sections))
        #expect(none.visibleSystemItems == everySystemNumber.subtracting([6, 0]))
        let hidden = PlanBuilder.build(planInputs(running: [], sections: sections, reveal: .hidden))
        #expect(hidden.visibleSystemItems == everySystemNumber.subtracting([0]))
        let all = PlanBuilder.build(planInputs(running: [], sections: sections, reveal: .all))
        #expect(all.visibleSystemItems == everySystemNumber)
    }

    @Test func focusModeBeatsReveal() {
        let running = [own, shownApp, hiddenApp, alwaysApp, newApp]
        let plan = PlanBuilder.build(planInputs(running: running, reveal: .all, focus: true))
        #expect(plan.visibleBundleIDs == [own])
        #expect(plan.concealedBundleIDs == Set(running).subtracting([own]))
        #expect(plan.concealedSections == [.shown, .hidden, .alwaysHidden])
        #expect(plan.source == .focusMode)
    }

    @Test func focusModeKeepsClockAndControlCenter() {
        // Wi-Fi, Bluetooth, sound and battery go; the clock (2) and Control Center (8) stay, with or without the permission,
        // and wherever the person put them. The numbers the table doesn't know stay.
        let expected = everySystemNumber.subtracting([0, 1, 5, 6])
        #expect(PlanBuilder.build(planInputs(running: [own], focus: true)).visibleSystemItems == expected)
        #expect(PlanBuilder.build(planInputs(running: [own], focus: true, allowClock: true)).visibleSystemItems == expected)

        var sections = oneInEachSection()
        sections.move(item: .system("clock"), to: .alwaysHidden)
        sections.move(item: .system("controlcenter"), to: .hidden)
        #expect(PlanBuilder.build(planInputs(running: [own], sections: sections, focus: true, allowClock: true)).visibleSystemItems == expected)
    }

    @Test func ruleShowsAppBelowReveal() {
        let running = [own, shownApp, hiddenApp, alwaysApp]
        let rules: [RuleEffect] = [.show([alwaysApp])]

        // Alone, the rule shows its app and says why.
        let alone = PlanBuilder.build(planInputs(running: running, rules: rules))
        #expect(alone.visibleBundleIDs == [own, shownApp, alwaysApp])
        #expect(alone.concealedBundleIDs == [hiddenApp])
        #expect(alone.source == .rules)
        // A rule that shows one app doesn't un-conceal its section.
        #expect(alone.concealedSections == [.hidden, .alwaysHidden])

        // Under a reveal, the app is still shown, and the reveal is the reason.
        let revealing = PlanBuilder.build(planInputs(running: running, reveal: .hidden, rules: rules))
        #expect(revealing.visibleBundleIDs == [own, shownApp, hiddenApp, alwaysApp])
        #expect(revealing.source == .reveal(.hidden))

        // A rule with nothing to show isn't a reason.
        #expect(PlanBuilder.build(planInputs(running: running, rules: [.show([])])).source == .sections)
        #expect(PlanBuilder.build(planInputs(running: running, rules: [])).source == .sections)
    }

    @Test func wideScreenShowsEverythingButFocusWins() {
        var sections = oneInEachSection()
        sections.move(item: .system("wifi"), to: .hidden)
        sections.move(item: .system("clock"), to: .hidden)
        let running = [own, shownApp, hiddenApp, alwaysApp]

        let plan = PlanBuilder.build(planInputs(running: running, sections: sections, allowClock: true, screen: wide))
        #expect(plan.visibleBundleIDs == Set(running))
        #expect(plan.concealedBundleIDs.isEmpty)
        #expect(plan.visibleSystemItems == everySystemNumber)
        #expect(plan.concealedSections.isEmpty)
        #expect(plan.source == .wideScreen)
        #expect(plan.concealsNothing)

        let focused = PlanBuilder.build(planInputs(running: running, sections: sections, focus: true, screen: wide))
        #expect(focused.visibleBundleIDs == [own])
        #expect(focused.source == .focusMode)
        #expect(!focused.concealsNothing)
    }

    @Test func narrowScreenOrSwitchOffDoesNothing() {
        let running = [own, shownApp, hiddenApp, alwaysApp]
        let normal = PlanBuilder.build(planInputs(running: running))

        // Wider than the threshold is wide; as wide as it, or narrower, isn't.
        let atThreshold = WideScreenInput(enabled: true, threshold: 3000, activeScreenWidth: 3000)
        #expect(PlanBuilder.build(planInputs(running: running, screen: atThreshold)) == normal)
        #expect(PlanBuilder.build(planInputs(running: running, screen: narrow)) == normal)
        let justOver = WideScreenInput(enabled: true, threshold: 3000, activeScreenWidth: 3000.5)
        #expect(PlanBuilder.build(planInputs(running: running, screen: justOver)).source == .wideScreen)

        // Wide, with the switch off.
        let off = WideScreenInput(enabled: false, threshold: 3000, activeScreenWidth: 5120)
        #expect(PlanBuilder.build(planInputs(running: running, screen: off)) == normal)
    }

    @Test func clockStaysWithoutPermission() {
        var sections = oneInEachSection()
        sections.move(item: .system("clock"), to: .hidden)
        sections.move(item: .system("controlcenter"), to: .alwaysHidden)
        let plan = PlanBuilder.build(planInputs(running: [own], sections: sections))
        #expect(plan.visibleSystemItems.contains(2))
        #expect(plan.visibleSystemItems.contains(8))
        #expect(plan.visibleSystemItems == everySystemNumber)
    }

    @Test func clockHidesWithPermission() {
        var sections = oneInEachSection()
        sections.move(item: .system("clock"), to: .hidden)
        sections.move(item: .system("controlcenter"), to: .alwaysHidden)
        let plan = PlanBuilder.build(planInputs(running: [own], sections: sections, allowClock: true))
        #expect(plan.visibleSystemItems == everySystemNumber.subtracting([2, 8]))
        #expect(!plan.concealsNothing)
        // The permission doesn't hide what is Shown.
        #expect(PlanBuilder.build(planInputs(running: [own], allowClock: true)).visibleSystemItems == everySystemNumber)
    }

    @Test func unknownSystemNumbersStayVisible() {
        var sections = oneInEachSection()
        sections.move(item: .system("wifi"), to: .hidden)
        // AirDrop is on the bar but has no number, so moving it takes nothing off the list.
        sections.move(item: .system("airdrop"), to: .alwaysHidden)
        let plan = PlanBuilder.build(planInputs(running: [own], sections: sections))
        #expect(plan.visibleSystemItems == everySystemNumber.subtracting([6]))
        for number in [3, 4, 7, 9, 100, 255] {
            #expect(plan.visibleSystemItems.contains(number))
        }
        // Even Focus Mode leaves the numbers it doesn't know.
        let focus = PlanBuilder.build(planInputs(running: [own], sections: sections, focus: true))
        #expect(focus.visibleSystemItems.isSuperset(of: everySystemNumber.subtracting([0, 1, 5, 6])))
        #expect(VisibilityPlan.allSystemItems == 0...255)
    }

    @Test func ownBundleAlwaysVisible() {
        // Mantel is Hidden in the sections (it can't be put there by the app, but a file could say so), Focus Mode is on, and its
        // bundle ID is running: it is visible, and never concealed.
        var sections = oneInEachSection()
        sections.move(app: own, to: .alwaysHidden)
        let focused = PlanBuilder.build(planInputs(running: [own, shownApp], sections: sections, focus: true))
        #expect(focused.visibleBundleIDs == [own])
        #expect(!focused.concealedBundleIDs.contains(own))

        // Not running, as in a test that has no apps at all.
        let empty = PlanBuilder.build(planInputs(running: [], sections: sections, reveal: .off))
        #expect(empty.visibleBundleIDs == [own])
        #expect(empty.concealedBundleIDs.isEmpty)
        #expect(empty.concealsNothing)

        // Even a swap can't conceal it.
        let swapped = PlanBuilder.build(planInputs(running: [own], reveal: .hidden, swap: [own]))
        #expect(swapped.visibleBundleIDs == [own])
    }

    @Test func unassignedRunningAppUsesNewItems() {
        var sections = oneInEachSection()
        let shownByDefault = PlanBuilder.build(planInputs(running: [own, newApp], sections: sections))
        #expect(shownByDefault.visibleBundleIDs.contains(newApp))

        sections.newItems = .hidden
        let hiddenByDefault = PlanBuilder.build(planInputs(running: [own, newApp], sections: sections))
        #expect(hiddenByDefault.concealedBundleIDs == [newApp])
        // The placed apps are where they were put.
        let placed = PlanBuilder.build(planInputs(running: [own, shownApp], sections: sections))
        #expect(placed.visibleBundleIDs == [own, shownApp])

        sections.newItems = .alwaysHidden
        let revealed = PlanBuilder.build(planInputs(running: [own, newApp], sections: sections, reveal: .hidden))
        #expect(revealed.concealedBundleIDs == [newApp])
        #expect(PlanBuilder.build(planInputs(running: [own, newApp], sections: sections, reveal: .all)).visibleBundleIDs.contains(newApp))
    }

    @Test func swapConcealsOnlyDuringReveal() {
        let running = [own, shownApp, hiddenApp]
        let swap: Set<String> = [shownApp]

        // The swap is a part of a reveal: with nothing revealed, it is left out.
        let idle = PlanBuilder.build(planInputs(running: running, swap: swap))
        #expect(idle.visibleBundleIDs == [own, shownApp])
        #expect(idle.source == .sections)

        let revealing = PlanBuilder.build(planInputs(running: running, reveal: .hidden, swap: swap))
        #expect(revealing.visibleBundleIDs == [own, hiddenApp])
        #expect(revealing.concealedBundleIDs == [shownApp])
        #expect(revealing.source == .reveal(.hidden))
        // The swap conceals one app, not the section it is in.
        #expect(!revealing.concealedSections.contains(.shown))
    }

    @Test func concealsNothingWhenAllShown() {
        var sections = SectionModel()
        sections.move(app: shownApp, to: .shown)
        #expect(PlanBuilder.build(planInputs(running: [own, shownApp, newApp], sections: sections)).concealsNothing)

        // A concealed app, or a concealed system item, is something.
        sections.move(app: hiddenApp, to: .hidden)
        #expect(!PlanBuilder.build(planInputs(running: [own, shownApp, hiddenApp], sections: sections)).concealsNothing)
        // A Hidden app that isn't running conceals nothing.
        #expect(PlanBuilder.build(planInputs(running: [own, shownApp], sections: sections)).concealsNothing)
        sections.move(item: .system("wifi"), to: .hidden)
        #expect(!PlanBuilder.build(planInputs(running: [own], sections: sections)).concealsNothing)
    }

    @Test func backgroundOnlyAppsStayVisible() {
        // The apps with no windows and no Dock icon are running apps all the same, and may have an icon in the menu bar.
        let apps: [RunningApp] = [.fake(1, own, "Mantel"), .fake(2, "com.example.agent", "Agent", backgroundOnly: true),
                                  .fake(3, shownApp, "Shown"), .fake(4, hiddenApp, "Hidden", backgroundOnly: true),
                                  .fake(5, nil, "No bundle ID")]
        let plan = PlanBuilder.build(planInputs(running: apps.compactMap(\.bundleID)))
        #expect(plan.visibleBundleIDs == [own, "com.example.agent", shownApp])
        #expect(plan.concealedBundleIDs == [hiddenApp])
    }

    @Test func explanationsAreInPlainWords() {
        #expect(PlanSource.sections.explanation == "Your sections")
        #expect(PlanSource.focusMode.explanation == "Focus Mode is on")
        #expect(PlanSource.reveal(.hidden).explanation == "Showing hidden icons")
        #expect(PlanSource.reveal(.all).explanation == "Showing all icons")
        #expect(PlanSource.wideScreen.explanation == "This screen is wide, so everything shows")
        #expect(PlanSource.rules.explanation == "A rule is showing icons")
    }
}
