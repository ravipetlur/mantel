import CoreGraphics
import MKCore
import Testing

@testable import MKLayout

@Suite("Pointer reveal", .timeLimit(.minutes(1)))
struct PointerRevealTests {
    private let main = EmptySpace.Spot.empty(displayUUID: "display-main")
    private let other = EmptySpace.Spot.empty(displayUUID: "display-other")

    // MARK: Moving

    @Test func enteringEmptySpaceIsAnEvent() {
        for before in [EmptySpace.Spot.outsideBars, .hiddenBar, .item, .appMenus, .notch] {
            #expect(PointerReveal.moved(from: before, to: main) == [.pointerEnteredEmptySpace], "from \(before)")
        }
        // The very first place that is known counts as a move from nowhere.
        #expect(PointerReveal.moved(from: nil, to: main) == [.pointerEnteredEmptySpace])
    }

    @Test func leavingEmptySpaceIsAnEvent() {
        for after in [EmptySpace.Spot.outsideBars, .hiddenBar, .item, .appMenus, .notch] {
            #expect(PointerReveal.moved(from: main, to: after) == [.pointerLeftEmptySpace], "to \(after)")
        }
    }

    @Test func movingAboutInsideEmptySpaceOrOutsideItIsNothing() {
        #expect(PointerReveal.moved(from: main, to: main).isEmpty)
        #expect(PointerReveal.moved(from: .item, to: .appMenus).isEmpty)
        #expect(PointerReveal.moved(from: .outsideBars, to: .hiddenBar).isEmpty)
        #expect(PointerReveal.moved(from: nil, to: .outsideBars).isEmpty)
        #expect(PointerReveal.moved(from: .item, to: .outsideBars).isEmpty)
    }

    @Test func goingFromOneDisplaysEmptySpaceToAnothersLeavesAndEnters() {
        // The hover that was counting for the first bar doesn't carry over to the second: it starts again.
        #expect(PointerReveal.moved(from: main, to: other) == [.pointerLeftEmptySpace, .pointerEnteredEmptySpace])
    }

    @Test func aHiddenBarIsNeverEnteredAsEmptySpace() {
        // A full-screen app has hidden the bar: the pointer pushed against the top is on a hidden bar, which isn't empty space, so it
        // reveals nothing, and a hover that was running ends.
        #expect(PointerReveal.moved(from: .outsideBars, to: .hiddenBar).isEmpty)
        #expect(PointerReveal.moved(from: main, to: .hiddenBar) == [.pointerLeftEmptySpace])
    }

    // MARK: Clicking

    @Test func aClickInEmptySpaceIsAnEvent() {
        #expect(PointerReveal.clicked(at: main) == .emptySpaceClicked)
        #expect(PointerReveal.clicked(at: other) == .emptySpaceClicked)
    }

    @Test func aClickAnywhereElseIsNot() {
        for spot in [EmptySpace.Spot.outsideBars, .hiddenBar, .item, .appMenus, .notch] {
            #expect(PointerReveal.clicked(at: spot) == nil, "\(spot)")
        }
    }

    // MARK: Scrolling

    @Test func aScrollDownOrUpOnABarIsAnEvent() {
        // The classic direction: the hand moving down gives a negative delta.
        #expect(PointerReveal.scrolled(deltaY: -3, invertedFromDevice: false, at: main) == .scrolled(down: true))
        #expect(PointerReveal.scrolled(deltaY: 3, invertedFromDevice: false, at: main) == .scrolled(down: false))
        #expect(PointerReveal.scrolled(deltaY: -12.5, invertedFromDevice: false, at: .item) == .scrolled(down: true), "an icon is on the bar too")
        #expect(PointerReveal.scrolled(deltaY: 4, invertedFromDevice: false, at: .appMenus) == .scrolled(down: false))
        #expect(PointerReveal.scrolled(deltaY: -4, invertedFromDevice: false, at: .notch) == .scrolled(down: true))
    }

    @Test func theHandMovingDownRevealsWhateverTheScrollingDirectionIs() {
        // Natural scrolling turns the sign round: the same movement gives the other delta, and the same event.
        #expect(PointerReveal.movesDown(deltaY: -5, invertedFromDevice: false))
        #expect(!PointerReveal.movesDown(deltaY: 5, invertedFromDevice: false))
        #expect(PointerReveal.movesDown(deltaY: 5, invertedFromDevice: true))
        #expect(!PointerReveal.movesDown(deltaY: -5, invertedFromDevice: true))

        #expect(PointerReveal.scrolled(deltaY: 5, invertedFromDevice: true, at: main) == .scrolled(down: true))
        #expect(PointerReveal.scrolled(deltaY: -5, invertedFromDevice: true, at: main) == .scrolled(down: false))
        #expect(PointerReveal.scrolled(deltaY: -5, invertedFromDevice: false, at: main) == .scrolled(down: true))
        #expect(PointerReveal.scrolled(deltaY: 5, invertedFromDevice: false, at: main) == .scrolled(down: false))
    }

    @Test func aSmallScrollIsNothing() {
        #expect(PointerReveal.scrollThreshold == 3)
        for inverted in [false, true] {
            #expect(PointerReveal.scrolled(deltaY: -2.9, invertedFromDevice: inverted, at: main) == nil)
            #expect(PointerReveal.scrolled(deltaY: 2.9, invertedFromDevice: inverted, at: main) == nil)
            #expect(PointerReveal.scrolled(deltaY: 0, invertedFromDevice: inverted, at: main) == nil)
        }
    }

    @Test func aScrollOffTheBarOrOnAHiddenBarIsNothing() {
        for inverted in [false, true] {
            #expect(PointerReveal.scrolled(deltaY: -10, invertedFromDevice: inverted, at: .outsideBars) == nil)
            #expect(PointerReveal.scrolled(deltaY: -10, invertedFromDevice: inverted, at: .hiddenBar) == nil)
        }
    }

    // MARK: A move is told before the click or the scroll

    @Test func aMoveIsToldBeforeAClickOrAScroll() {
        // A move alone is just the move.
        #expect(PointerReveal.events(for: .moved, from: .item, to: main) == [.pointerEnteredEmptySpace])
        #expect(PointerReveal.events(for: .moved, from: main, to: main).isEmpty)

        // A click in empty space that the pointer came to without a move being seen is an entering of it, and then the click.
        #expect(PointerReveal.events(for: .clicked, from: .item, to: main) == [.pointerEnteredEmptySpace, .emptySpaceClicked])
        #expect(PointerReveal.events(for: .clicked, from: nil, to: main) == [.pointerEnteredEmptySpace, .emptySpaceClicked])
        // Where it already was, only the click.
        #expect(PointerReveal.events(for: .clicked, from: main, to: main) == [.emptySpaceClicked])
        // A click on an icon after resting in empty space leaves it, and is not a click on empty space.
        #expect(PointerReveal.events(for: .clicked, from: main, to: .item) == [.pointerLeftEmptySpace])
        // Nothing at all for a click far from the bar.
        #expect(PointerReveal.events(for: .clicked, from: .outsideBars, to: .outsideBars).isEmpty)

        // A scroll on empty space is an entering of it if the pointer wasn't known to be there, and then the scroll.
        let down = PointerReveal.Action.scrolled(deltaY: -6, invertedFromDevice: false)
        #expect(PointerReveal.events(for: down, from: .appMenus, to: main) == [.pointerEnteredEmptySpace, .scrolled(down: true)])
        #expect(PointerReveal.events(for: down, from: main, to: main) == [.scrolled(down: true)])
        // On an icon: a scroll after resting in empty space leaves it and then scrolls.
        let up = PointerReveal.Action.scrolled(deltaY: 6, invertedFromDevice: false)
        #expect(PointerReveal.events(for: up, from: main, to: .item) == [.pointerLeftEmptySpace, .scrolled(down: false)])
        // A scroll too small to count still moves the pointer.
        let small = PointerReveal.Action.scrolled(deltaY: 1, invertedFromDevice: true)
        #expect(PointerReveal.events(for: small, from: .item, to: main) == [.pointerEnteredEmptySpace])
        // A scroll off the bar is nothing.
        #expect(PointerReveal.events(for: down, from: .outsideBars, to: .outsideBars).isEmpty)
    }

    // MARK: Hotkeys

    @Test func hotkeysMapToTheEventsOfTheReveal() {
        #expect(RevealEvent.forHotkey(.showHidden) == .toggle(.hidden))
        #expect(RevealEvent.forHotkey(.showAll) == .toggle(.all))
        #expect(RevealEvent.forHotkey(.focusMode) == .toggleFocusMode)
        #expect(RevealEvent.forHotkey(.openSettings) == nil)
        #expect(RevealEvent.forHotkey(.mantelMenu) == nil)
        #expect(RevealEvent.forHotkey(.commandBar) == nil)
        #expect(RevealEvent.forHotkey(HotkeyID(rawValue: "from-a-newer-mantel")) == nil)
    }

    @Test func everyHotkeyTheHotkeysPaneListsIsHandledByTheRevealOrSettings() {
        // The pane lists `HotkeyAction.all`: an action that did nothing when pressed would be a shortcut that does nothing. (Opening
        // Mantel's menu is the dots' own: the reveal has nothing to do with it, and the second bar's is the second bar's: it opens or closes
        // the bar, which is no plain event for the machine, so it has no event here.)
        let others: [HotkeyID] = [.openSettings, .mantelMenu, .secondBar, .commandBar]
        for action in HotkeyAction.all where !others.contains(action.id) {
            #expect(RevealEvent.forHotkey(action.id) != nil, "\(action.title)")
        }
        #expect(RevealEvent.forHotkey(.secondBar) == nil)
    }

    // MARK: The dots

    /// What is on the bar with the dots as the settings have them, Always Hidden holding an app or not.
    private func shown(_ dots: DotSettings = DotSettings(), alwaysHiddenHasApps: Bool) -> OwnItemsShown {
        OwnItemsVisibility.shown(sections: SectionModel(), plan: VisibilityPlan(visibleBundleIDs: [], concealedBundleIDs: [], visibleSystemItems: [], concealedSections: [], source: .sections),
                                        dots: dots, alwaysHiddenHasApps: alwaysHiddenHasApps)
    }

    @Test func filledStatesUnchanged() {
        let everything = shown(alwaysHiddenHasApps: true)
        let collapsed = DotAppearance(reveal: .collapsed, shown: everything)
        #expect(!collapsed.hiddenDotFilled && !collapsed.alwaysDotFilled)
        let hidden = DotAppearance(reveal: .hiddenShown, shown: everything)
        #expect(hidden.hiddenDotFilled && !hidden.alwaysDotFilled)
        let all = DotAppearance(reveal: .allShown, shown: everything)
        #expect(all.hiddenDotFilled && all.alwaysDotFilled)
        // Focus Mode puts both away.
        let focus = DotAppearance(reveal: .focusMode, shown: everything)
        #expect(!focus.hiddenDotFilled && !focus.alwaysDotFilled)
    }

    @Test func theSecondDotIsThereWhileAlwaysHiddenHasApps() {
        for state in [RevealState.collapsed, .hiddenShown, .allShown, .focusMode] {
            #expect(DotAppearance(reveal: state, shown: shown(alwaysHiddenHasApps: true)).alwaysDotVisible)
            #expect(!DotAppearance(reveal: state, shown: shown(alwaysHiddenHasApps: false)).alwaysDotVisible)
            #expect(DotAppearance(reveal: state, shown: shown(alwaysHiddenHasApps: false)).hiddenDotVisible)
        }
    }

    @Test func alwaysSettingShowsDoubleDotWithNothingInAlwaysHidden() {
        var dots = DotSettings()
        dots.alwaysDot = .always
        for state in [RevealState.collapsed, .hiddenShown, .allShown, .focusMode] {
            let look = DotAppearance(reveal: state, shown: shown(dots, alwaysHiddenHasApps: false))
            #expect(look.alwaysDotVisible, "\(state)")
            #expect(look.hiddenDotVisible)
        }
    }

    @Test func hideBothDotsTakesBothOff() {
        var dots = DotSettings()
        dots.hideBothDots = true
        for always in [AlwaysDotVisibility.whenNeeded, .always] {
            dots.alwaysDot = always
            for hasApps in [true, false] {
                let look = DotAppearance(reveal: .collapsed, shown: shown(dots, alwaysHiddenHasApps: hasApps))
                #expect(!look.hiddenDotVisible && !look.alwaysDotVisible, "\(always), apps \(hasApps)")
            }
        }
    }
}
