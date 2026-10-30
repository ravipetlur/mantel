import CoreGraphics
import MKCore
import Testing

@testable import MKLayout

@Suite("Layout follower", .timeLimit(.minutes(1)))
struct LayoutFollowerTests {
    private typealias F = ArrangementFixtures
    private let a = F.app("a"), b = F.app("b"), c = F.app("c"), d = F.app("d")

    private func observed(_ tokens: [LayoutToken]) -> ObservedOrder {
        ObservedOrder(tokens: tokens, source: .table)
    }

    private func follow(_ sections: SectionModel, _ now: [LayoutToken], before: [LayoutToken]? = nil, mayChange: Bool = true,
                        placement: DotsPlacement = .betweenSections) -> SectionModel {
        LayoutFollower.follow(sections, observed: observed(now), placement: placement, sectionsMayChange: mayChange,
                              before: before.map(observed))
    }

    @Test func orderFollowsWithinSection() {
        let sections = F.sections(hidden: [a, b], shown: [c, d])
        let followed = follow(sections, [.item(b), .item(a), .item(d), .item(c)])
        #expect(followed.order[.hidden] == [b, a])
        #expect(followed.order[.shown] == [d, c])
    }

    @Test func unobservedKeepPlaces() {
        let spacer = OwnItems.itemID(SpacerID(rawValue: "0000abcd"))
        let sections = F.sections(shown: [a, spacer, b, c])
        // Only a and c are observed, in the other order: they swap their places, and the spacer and b stay in theirs.
        let followed = follow(sections, [.item(c), .item(a)])
        #expect(followed.order[.shown] == [c, spacer, b, a])
        // A concealed item that isn't observed is never moved: from a bar only the drawn ones are told.
        #expect(follow(sections, []).order == sections.order)
    }

    @Test func sectionsUnchangedWithoutDrag() {
        let sections = F.sections(hidden: [a], shown: [b])
        let now: [LayoutToken] = [.item(b), .dot(.hidden), .item(a)]
        // Whatever is seen, sections change only when they may, and only with a before.
        #expect(follow(sections, now, before: [.item(a), .dot(.hidden), .item(b)], mayChange: false).apps == sections.apps)
        #expect(follow(sections, now, before: nil).apps == sections.apps)
    }

    @Test func dragLeftOfDotMovesToHidden() {
        let sections = F.sections(hidden: [a], shown: [b, c])
        let before: [LayoutToken] = [.item(a), .dot(.hidden), .item(b), .item(c)]
        let followed = follow(sections, [.item(a), .item(c), .dot(.hidden), .item(b)], before: before)
        #expect(followed.section(ofApp: c.bundleID) == .hidden)
        #expect(followed.section(ofApp: b.bundleID) == .shown)
        #expect(followed.section(ofApp: a.bundleID) == .hidden)
        #expect(followed.apps[c.bundleID]?.isAuto == false)
        // The icon is listed with its section.
        #expect(followed.order[.hidden]?.contains(c) == true)
        #expect(followed.order[.shown] == [b])
    }

    @Test func dragLeftOfDoubleDotMovesToAlwaysHidden() {
        let sections = F.sections(always: [a], hidden: [b], shown: [c])
        let before: [LayoutToken] = [.item(a), .dot(.always), .item(b), .dot(.hidden), .item(c)]
        let followed = follow(sections, [.item(c), .item(a), .dot(.always), .item(b), .dot(.hidden)], before: before)
        #expect(followed.section(ofApp: c.bundleID) == .alwaysHidden)
        #expect(followed.section(ofApp: b.bundleID) == .hidden)
        // Without •• on the bar, an app left of • is Hidden unless it is Always Hidden.
        let sections2 = F.sections(always: [a], shown: [b, c])
        let before2: [LayoutToken] = [.item(a), .dot(.hidden), .item(b), .item(c)]
        let followed2 = follow(sections2, [.item(c), .item(a), .dot(.hidden), .item(b)], before: before2)
        #expect(followed2.section(ofApp: c.bundleID) == .hidden)
        #expect(followed2.section(ofApp: a.bundleID) == .alwaysHidden)
        // An app dragged right of • is Shown.
        let followed3 = follow(sections2, [.dot(.hidden), .item(b), .item(c), .item(a)], before: before2)
        #expect(followed3.section(ofApp: a.bundleID) == .shown)
    }

    @Test func commandDragMovesOnlyTheDraggedApp() {
        // The table has the apps right of • where macOS had them before Mantel: b and c are in Hidden in the model, and right of •.
        let sections = F.sections(hidden: [a, b, c], shown: [d])
        let before: [LayoutToken] = [.item(a), .dot(.hidden), .item(b), .item(c), .item(d)]
        // The person drags d to the very left: a, b and c each shift one place, and none of them moved.
        let followed = follow(sections, [.item(d), .item(a), .dot(.hidden), .item(b), .item(c)], before: before)
        #expect(followed.section(ofApp: d.bundleID) == .hidden)
        #expect(followed.section(ofApp: a.bundleID) == .hidden)
        #expect(followed.section(ofApp: b.bundleID) == .hidden, "right of •, and not moved")
        #expect(followed.section(ofApp: c.bundleID) == .hidden, "right of •, and not moved")
    }

    @Test func commandDragOnePlaceMovesOnlyTheDraggedApp() {
        // Shown to Hidden: the model has a Shown, but macOS still has it left of •. The person drags b one place left, past a.
        let sections = F.sections(hidden: [b], shown: [a, c])
        let before: [LayoutToken] = [.item(a), .item(b), .dot(.hidden), .item(c)]
        let followed = follow(sections, [.item(b), .item(a), .dot(.hidden), .item(c)], before: before)
        #expect(followed.section(ofApp: a.bundleID) == .shown, "passed, and didn't cross •")
        #expect(followed.section(ofApp: b.bundleID) == .hidden)
        #expect(followed.section(ofApp: c.bundleID) == .shown)
        // Hidden to Shown: b is Hidden in the model but right of •. The person drags c one place left, past b.
        let sections2 = F.sections(hidden: [a, b], shown: [c])
        let before2: [LayoutToken] = [.item(a), .dot(.hidden), .item(b), .item(c)]
        let followed2 = follow(sections2, [.item(a), .dot(.hidden), .item(c), .item(b)], before: before2)
        #expect(followed2.section(ofApp: b.bundleID) == .hidden, "passed, and didn't cross •")
        #expect(followed2.section(ofApp: c.bundleID) == .shown, "dragged within the right of •")
        #expect(followed2.order[.hidden] == [a, b])
    }

    @Test func twoDragsPastOneAppLeaveItsSection() {
        // b is Hidden in the model and right of •. The person drags c and then d to its left, without crossing •.
        let sections = F.sections(hidden: [a, b], shown: [c, d])
        let before: [LayoutToken] = [.item(a), .dot(.hidden), .item(b), .item(c), .item(d)]
        let followed = follow(sections, [.item(a), .dot(.hidden), .item(c), .item(d), .item(b)], before: before)
        #expect(followed.section(ofApp: b.bundleID) == .hidden)
        #expect(followed.section(ofApp: c.bundleID) == .shown)
        #expect(followed.section(ofApp: d.bundleID) == .shown)
    }

    @Test func aDragTowardsTheOtherSideNeedsACrossingThatWay() {
        // d is Shown in the model but left of •, and is dragged right across it: it can't be told to be Hidden.
        let sections = F.sections(hidden: [a], shown: [d, b])
        let before: [LayoutToken] = [.item(d), .item(a), .dot(.hidden), .item(b)]
        let followed = follow(sections, [.item(a), .dot(.hidden), .item(d), .item(b)], before: before)
        #expect(followed.section(ofApp: d.bundleID) == .shown)

        // With both dots: d is Shown but left of ••, and is dragged right across •• only, to between the dots. That is Hidden's place,
        // but a move right can't make an app Hidden when it was Shown, so it stays Shown.
        let two = F.sections(always: [a], hidden: [b], shown: [d, c])
        let twoBefore: [LayoutToken] = [.item(d), .item(a), .dot(.always), .item(b), .dot(.hidden), .item(c)]
        let twoFollowed = follow(two, [.item(a), .dot(.always), .item(d), .item(b), .dot(.hidden), .item(c)], before: twoBefore)
        #expect(twoFollowed.section(ofApp: d.bundleID) == .shown)
    }

    @Test func commandClickWithoutDragMovesNothing() {
        let sections = F.sections(hidden: [a, b], shown: [c])
        // The model and the bar disagree (b is right of •), but nothing was dragged.
        let same: [LayoutToken] = [.item(a), .dot(.hidden), .item(b), .item(c)]
        let followed = follow(sections, same, before: same)
        #expect(followed == sections)
    }

    @Test func besideClockUsesDivider() {
        let sections = F.sections(always: [a], hidden: [b], shown: [c, d])
        let before: [LayoutToken] = [.item(a), .item(b), .divider, .item(c), .item(d), .dot(.always), .dot(.hidden)]
        let now: [LayoutToken] = [.item(a), .item(d), .item(b), .divider, .item(c), .dot(.always), .dot(.hidden)]
        let followed = follow(sections, now, before: before, placement: .besideClock)
        #expect(followed.section(ofApp: d.bundleID) == .hidden)
        // An app that is Always Hidden stays so left of the divider.
        let now2: [LayoutToken] = [.item(b), .divider, .item(c), .item(d), .item(a), .dot(.always), .dot(.hidden)]
        #expect(follow(sections, now2, before: before, placement: .besideClock).section(ofApp: a.bundleID) == .shown)
        let now3: [LayoutToken] = [.item(b), .item(a), .divider, .item(c), .item(d), .dot(.always), .dot(.hidden)]
        #expect(follow(sections, now3, before: before, placement: .besideClock).section(ofApp: a.bundleID) == .alwaysHidden)
    }

    @Test func besideClockWithoutDividerChangesNoSection() {
        let sections = F.sections(hidden: [a], shown: [b])
        let before: [LayoutToken] = [.item(a), .item(b)]
        let followed = follow(sections, [.item(b), .item(a)], before: before, placement: .besideClock)
        #expect(followed.apps == sections.apps)
        // The order still follows.
        #expect(followed.order[.hidden] == [a] && followed.order[.shown] == [b])
        let both = F.sections(shown: [a, b])
        #expect(follow(both, [.item(b), .item(a)], before: before, placement: .besideClock).order[.shown] == [b, a])
    }

    @Test func appMovesByLeftMostItem() {
        let one = F.app("a", "one"), two = F.app("a", "two")
        let sections = F.sections(hidden: [one, two], shown: [b])
        let before: [LayoutToken] = [.item(one), .item(two), .dot(.hidden), .item(b)]
        // The app's second item is right of •, but its left-most is left of it: the app stays Hidden.
        let staying = follow(sections, [.item(one), .dot(.hidden), .item(two), .item(b)], before: before)
        #expect(staying.section(ofApp: a.bundleID) == .hidden)
        // Its left-most item is right of •: the app moves, as one.
        let moving = follow(sections, [.dot(.hidden), .item(one), .item(b), .item(two)], before: before)
        #expect(moving.section(ofApp: a.bundleID) == .shown)
        #expect(Set(moving.order[.shown] ?? []) == [one, two, b])
        #expect(moving.order[.hidden] == nil)
    }

    @Test func groupedAppsNeverMove() {
        var sections = F.sections(shown: [b])
        let group = IconGroup(id: GroupID(rawValue: "0000beef"))
        sections.groups[group.id] = group
        sections.groupOrder = [group.id]
        sections.move(app: a.bundleID, toGroup: group.id, at: 0)
        sections.groupItems[group.id] = [a]
        let before: [LayoutToken] = [.item(a), .dot(.hidden), .item(b)]
        let followed = follow(sections, [.dot(.hidden), .item(b), .item(a)], before: before)
        #expect(followed.apps[a.bundleID] == sections.apps[a.bundleID])
        #expect(followed.groupItems[group.id] == [a])
        // Own items don't either.
        let spacer = OwnItems.itemID(SpacerID(rawValue: "0000abcd"))
        var own = F.sections(hidden: [a], shown: [b])
        own.spacers[SpacerID(rawValue: "0000abcd")] = LayoutSpacer(id: SpacerID(rawValue: "0000abcd"))
        own.order[.hidden] = [a, spacer]
        let movedOwn = follow(own, [.item(a), .dot(.hidden), .item(spacer), .item(b)],
                              before: [.item(a), .item(spacer), .dot(.hidden), .item(b)])
        #expect(movedOwn.order[.hidden] == [a, spacer])
        #expect(movedOwn.order[.shown] == [b])
    }

    @Test func dotsFoundByOwnKind() {
        // The bar has the dots under Mantel's real bundle ID and a name of their own; they are found by what they are.
        let inventory = F.inventory([F.drawn(a, x: 170), F.own(.hiddenDot, x: 200), F.own(.alwaysDot, x: 150), F.own(.divider, x: 230), F.drawn(b, x: 300)])
        let observed = LayoutFollower.observed(fromBar: inventory, frames: .follow)
        #expect(observed.tokens == [.dot(.always), .item(a), .dot(.hidden), .divider, .item(b)])
        #expect(observed.source == .bar(displayUUID: Fixtures.display))
        let sections = F.sections(hidden: [a], shown: [b])
        let before = ObservedOrder(tokens: [.item(b), .dot(.always), .dot(.hidden), .divider, .item(a)], source: observed.source)
        // a moved from right of the dots to between them: it is Hidden now.
        var model = sections
        model.apps[a.bundleID] = AppPlacement(section: .shown, isAuto: false)
        model.order = [.shown: [a, b]]
        let followed = LayoutFollower.follow(model, observed: observed, placement: .betweenSections, sectionsMayChange: true, before: before)
        #expect(followed.section(ofApp: a.bundleID) == .hidden)
        #expect(followed.section(ofApp: b.bundleID) == .shown)
    }

    @Test func barSourceKeepsOwnSpacerPlaces() {
        // Spacers and groups' icons aren't told apart on a bar, so none is observed and each keeps its place in its list.
        let inventory = F.inventory([F.drawn(a, x: 300), F.own(.spacer, x: 200), F.drawn(b, x: 100), F.own(.group, x: 50)])
        let observed = LayoutFollower.observed(fromBar: inventory, frames: .follow)
        #expect(observed.tokens == [.item(b), .item(a)])
        let spacer = OwnItems.itemID(SpacerID(rawValue: "0000abcd"))
        let sections = F.sections(shown: [a, spacer, b])
        #expect(LayoutFollower.follow(sections, observed: observed, placement: .betweenSections, sectionsMayChange: false, before: nil)
            .order[.shown] == [b, spacer, a])
    }

    @Test func framesLagBarSourceUsesSlotOrder() {
        let nameless = F.nameless("n", 0)
        // The inventory's order is the slots'. The nameless item's frame x says it is left of everything; under lag it isn't told at all,
        // and the items that name themselves are in slot order whatever their frames say.
        let inventory = F.inventory([F.drawn(a, x: 500), F.drawn(nameless, x: 10), F.drawn(b, x: 300), F.own(.hiddenDot, x: 400)])
        #expect(LayoutFollower.observed(fromBar: inventory, frames: .lag).tokens == [.item(a), .item(b), .dot(.hidden)])
        #expect(LayoutFollower.observed(fromBar: inventory, frames: .follow).tokens == [.item(nameless), .item(b), .dot(.hidden), .item(a)])
    }

    @Test func tableOrderIsByDistanceDescending() {
        let table = F.table([F.key(a): 300, F.key(b): 100, F.key(c): 200, F.ownKey("mantel.dot.hidden"): 250])
        let resolution = LayoutKeyResolution(keys: [.item(a): F.key(a), .item(b): F.key(b), .item(c): F.key(c), .dot(.hidden): F.ownKey("mantel.dot.hidden"),
                                                    .divider: F.ownKey("mantel.divider.main")], unresolved: [], memory: [:])
        let observed = LayoutFollower.observed(from: table, resolution: resolution)
        // The divider has no key in the table yet: it isn't observed.
        #expect(observed.tokens == [.item(a), .dot(.hidden), .item(c), .item(b)])
        #expect(observed.source == .table)
    }
}
