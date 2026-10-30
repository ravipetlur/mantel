import CoreGraphics
import MKCore
import Testing

@testable import MKLayout

/// What a read says of Mantel's dots, and what is said of them in the log.
///
/// The bars are made up: a laptop bar with a notch, a desk bar and a portrait one, with `com.example.*` apps.
@Suite("Dots room", .timeLimit(.minutes(1)))
struct DotsRoomTests {
    private let desk = "display-desk"
    private let laptop = "display-laptop"
    private let portrait = "display-portrait"
    private let own = "com.example.mantel"

    private func bar(_ display: String, y: CGFloat = 0) -> MenuBarGeometry {
        MenuBarGeometry(displayUUID: display, rect: CGRect(x: 0, y: y, width: 1728, height: 33), notch: nil)
    }

    private func frame(_ x: CGFloat, width: CGFloat = 38) -> CGRect { CGRect(x: x, y: 0, width: width, height: 33) }

    private func dot(_ name: String, frames: [String: CGRect] = [:], overflowedOn: Set<String> = []) -> MenuBarItem {
        MenuBarItem(id: ItemID(bundleID: own, key: .identifier(name)), ownerBundleID: own, appName: nil, label: nil, frames: frames,
                    overflowedOn: overflowedOn, isMantel: true, isDot: true)
    }

    /// An item of Mantel's that is not a dot: one of the wide spacer's.
    private func spacer(frames: [String: CGRect] = [:], overflowedOn: Set<String> = []) -> MenuBarItem {
        MenuBarItem(id: ItemID(bundleID: own, key: .identifier("mantel.spacer.divider")), ownerBundleID: own, appName: nil, label: nil,
                    frames: frames, overflowedOn: overflowedOn, isMantel: true)
    }

    private func app(_ bundleID: String, frames: [String: CGRect] = [:], overflowedOn: Set<String> = []) -> MenuBarItem {
        MenuBarItem(id: ItemID(bundleID: bundleID, key: .identifier("main")), ownerBundleID: bundleID, appName: nil, label: nil,
                    frames: frames, overflowedOn: overflowedOn, isMantel: false)
    }

    @Test func theDotsArePlacedWhenARealReadHasThemAllOnABar() {
        let placed = [dot("mantel.dot.hidden", frames: [desk: frame(10)]), dot("mantel.dot.always", frames: [laptop: frame(10)])]
        #expect(DotsRoom.dotsArePlaced(in: inventory(placed, bars: [desk, laptop])))
        #expect(!DotsRoom.dotsArePlaced(in: inventory([], bars: [desk])), "no dots in the read")
        #expect(!DotsRoom.dotsArePlaced(in: inventory([spacer(frames: [desk: frame(10)])], bars: [desk])), "an item that isn't a dot is none")
        #expect(!DotsRoom.dotsArePlaced(in: inventory([dot("mantel.dot.hidden", frames: [desk: frame(10)]), dot("mantel.dot.always")], bars: [desk])),
                "one of the two has no slot on any bar")
        #expect(!DotsRoom.dotsArePlaced(in: inventory([dot("mantel.dot.hidden", overflowedOn: [desk])], bars: [desk])),
                "a dot that is in the « menu has no slot")
    }

    private func inventory(_ items: [MenuBarItem], bars: [String] = [], chevrons: [String] = [], unanswered: Set<String> = []) -> Inventory {
        Inventory(capturedAt: Fixtures.date(0), bars: bars.map { bar($0) }, items: items,
                  chevrons: Dictionary(uniqueKeysWithValues: chevrons.map { ($0, CGRect(x: 100, y: 1, width: 17.5, height: 30)) }),
                  reach: [], problems: [], unansweredApps: unanswered)
    }

    // MARK: Which bars have a dot in the « menu

    @Test func aDotInTheMenuOfAShownBarIsTrapped() {
        let read = inventory([dot("hidden", frames: [desk: frame(2700)], overflowedOn: [laptop]),
                              dot("always", frames: [desk: frame(2740), laptop: frame(500)])], bars: [desk, laptop], chevrons: [laptop])
        #expect(DotsRoom.verdict(in: read, shownBars: [desk, laptop]) == DotsRoom.Verdict(trapped: [laptop]))
    }

    @Test func theDotsOfASecondaryBarAreCountedWhateverTheMainBarSays() {
        // The laptop's lid is open beside the desk: its bar is the one that is short of room, and the desk's is fine.
        let read = inventory(
            [dot("hidden", frames: [desk: frame(2700), laptop: frame(700)], overflowedOn: [laptop]),
             dot("always", frames: [desk: frame(2740), laptop: frame(740)], overflowedOn: [laptop])],
            bars: [desk, laptop], chevrons: [laptop])
        let verdict = DotsRoom.verdict(in: read, shownBars: [desk, laptop])
        #expect(verdict.trapped == [laptop])
        #expect(verdict.cantTell.isEmpty)
        // Whichever display is the main one, nothing else is asked: the first of the bars is no more than the first.
        #expect(DotsRoom.verdict(in: read, shownBars: [laptop]).trapped == [laptop])
    }

    @Test func aBarThatIsNotShownHasNoDotsToMakeRoomFor() {
        // A full-screen app has the laptop's display: its bar is away, and whatever the read says of what is on it.
        let read = inventory([dot("hidden", frames: [desk: frame(2700)], overflowedOn: [laptop])], bars: [desk, laptop], chevrons: [laptop])
        #expect(DotsRoom.verdict(in: read, shownBars: [desk]) == DotsRoom.Verdict())
        #expect(DotsRoom.verdict(in: read, shownBars: []) == DotsRoom.Verdict())
    }

    @Test func dotsOnTheBarAreNotTrappedWhateverElseIsInTheMenu() {
        // The menu holds some apps; the dots are drawn.
        let read = inventory(
            [dot("hidden", frames: [laptop: frame(800)]), dot("always", frames: [laptop: frame(840)]),
             app("com.example.a", frames: [laptop: frame(300)], overflowedOn: [laptop])],
            bars: [laptop], chevrons: [laptop])
        #expect(DotsRoom.verdict(in: read, shownBars: [laptop]) == DotsRoom.Verdict())
    }

    @Test func onlyTheTwoDotsCountNotTheSpacersItems() {
        // The wide spacer's invisible items are Mantel's too, and are pushed out of the bar as a matter of course: they are no dots.
        let read = inventory(
            [dot("hidden", frames: [desk: frame(2700), laptop: frame(800)]), dot("always", frames: [desk: frame(2740), laptop: frame(840)]),
             spacer(overflowedOn: [laptop]), spacer(overflowedOn: [desk])],
            bars: [desk, laptop], chevrons: [laptop])
        #expect(DotsRoom.verdict(in: read, shownBars: [desk, laptop]) == DotsRoom.Verdict())
        #expect(!DotsRoom.mayHaveAVerdict(in: inventory([spacer(overflowedOn: [laptop])], bars: [laptop])))
        #expect(DotsRoom.neededWidth(on: laptop, in: read, widths: ItemWidthCache()) == 0)
        // And with no dot at all in the read, they are not taken for the ones that are missing either.
        let only = inventory([spacer(frames: [laptop: frame(100)])], bars: [laptop], chevrons: [laptop])
        #expect(DotsRoom.verdict(in: only, shownBars: [laptop]) == DotsRoom.Verdict(cantTell: [laptop: .noOwnIcons]))
    }

    // MARK: When it can't be told

    @Test func aMenuThatShowsWithNoPlaceForTheDotsOnTheBarCantBeTold() {
        // The « shows, and one dot has no place on this bar and isn't known to be in the « either: it could be in it.
        let read = inventory([dot("hidden", frames: [laptop: frame(800)]), dot("always")], bars: [laptop], chevrons: [laptop])
        #expect(DotsRoom.verdict(in: read, shownBars: [laptop]) == DotsRoom.Verdict(cantTell: [laptop: .ownIconsNotPlaced]))
    }

    // MARK: How much room, and from whom

    @Test func theRoomTheDotsNeedIsWhatTheTrappedOnesWereSeenToTake() {
        var widths = ItemWidthCache()
        widths.update(from: inventory([dot("hidden", frames: [laptop: frame(800, width: 30)])], bars: [laptop]))
        let read = inventory(
            [dot("hidden", overflowedOn: [laptop]), dot("always", overflowedOn: [laptop]), dot("third", frames: [laptop: frame(900)]),
             app("com.example.a", frames: [laptop: frame(300, width: 50)], overflowedOn: [desk])],
            bars: [laptop])
        // One was seen at 30 points, one never was (a status item's slot, 38), and the one that is drawn isn't short of room.
        #expect(DotsRoom.neededWidth(on: laptop, in: read, widths: widths) == 30 + DotsRoom.assumedWidth)
        #expect(DotsRoom.neededWidth(on: desk, in: read, widths: widths) == 0, "no dot is trapped there")
    }

    @Test func theShownAppsComeFromTheLeftOfTheBar() {
        let read = inventory(
            [dot("hidden", overflowedOn: [laptop]),
             app("com.example.c", frames: [laptop: frame(700)]), app("com.example.a", frames: [laptop: frame(500)]),
             app("com.example.b", frames: [laptop: frame(600, width: 50)])],
            bars: [laptop], chevrons: [laptop])
        var widths = ItemWidthCache()
        widths.update(from: read)
        var sections = SectionModel()
        for id in ["a", "b", "c"] { sections.move(app: "com.example.\(id)", to: .shown) }

        let bars = DotsRoom.trappedBars([laptop], in: read, sections: sections, widths: widths, order: BarOrder())
        #expect(bars.count == 1)
        #expect(bars[0].displayUUID == laptop)
        #expect(bars[0].apps.map(\.bundleID) == ["com.example.a", "com.example.b", "com.example.c"])
        #expect(bars[0].apps.map(\.width) == [38, 50, 38])
        #expect(bars[0].neededWidth == DotsRoom.assumedWidth)
    }

    @Test func onlyTheAppsThatHaveAPlaceOnTheBarInThisReadAreOnesToMove() {
        // Two apps have a place on the laptop's bar in this read, and one doesn't (its icons were placed on another bar only): it is not one
        // whose icons take room there, whatever the order of the slots, and whatever was seen of it before.
        let read = inventory(
            [dot("hidden", overflowedOn: [laptop]),
             app("com.example.elsewhere", frames: [desk: frame(2000)]),
             app("com.example.b", frames: [laptop: frame(700), desk: frame(2300)]), app("com.example.a", frames: [laptop: frame(500)])],
            bars: [desk, laptop], chevrons: [laptop])
        var sections = SectionModel()
        for id in ["elsewhere", "a", "b"] { sections.move(app: "com.example.\(id)", to: .shown) }
        var order = BarOrder()
        order.update(from: inventory([app("com.example.elsewhere", frames: [laptop: frame(100)])], bars: [laptop]))
        let apps = DotsRoom.trappedBars([laptop], in: read, sections: sections, widths: ItemWidthCache(), order: order)[0].apps
        #expect(apps.map(\.bundleID) == ["com.example.a", "com.example.b"])
        // When none has a place there, they are a guess: from where they were last seen, then the order of the slots.
        let none = inventory([dot("hidden", overflowedOn: [laptop]), app("com.example.a"), app("com.example.elsewhere")], bars: [laptop], chevrons: [laptop])
        let guess = DotsRoom.trappedBars([laptop], in: none, sections: sections, widths: ItemWidthCache(), order: order)[0].apps
        #expect(guess.map(\.bundleID) == ["com.example.elsewhere", "com.example.a"])
    }

    @Test func anAppThatIsNotShownOrIsInTheMenuItselfIsNotOneToMove() {
        let read = inventory(
            [dot("hidden", overflowedOn: [laptop]),
             app("com.example.shown", frames: [laptop: frame(700)]),
             app("com.example.hidden", frames: [laptop: frame(500)]),
             app("com.example.piled", frames: [laptop: frame(100)], overflowedOn: [laptop]),
             // Piled on the other bar only: it is drawn on this one.
             app("com.example.elsewhere", frames: [laptop: frame(600)], overflowedOn: [desk])],
            bars: [desk, laptop], chevrons: [laptop])
        var sections = SectionModel()
        for id in ["shown", "piled", "elsewhere"] { sections.move(app: "com.example.\(id)", to: .shown) }
        sections.move(app: "com.example.hidden", to: .hidden)

        let bars = DotsRoom.trappedBars([laptop], in: read, sections: sections, widths: ItemWidthCache(), order: BarOrder())
        #expect(bars[0].apps.map(\.bundleID) == ["com.example.elsewhere", "com.example.shown"])
    }

    @Test func whereAnAppWasLastSeenOrdersTheOnesThatHaveNoPlaceInThisRead() {
        // The read has places for none of them on the laptop (they aren't matched there); the last time, they were.
        let before = inventory(
            [app("com.example.a", frames: [laptop: frame(900)]), app("com.example.b", frames: [laptop: frame(400)]),
             app("com.example.c", frames: [laptop: frame(650)])], bars: [laptop])
        var order = BarOrder()
        order.update(from: before)
        #expect(order.leftEdge(ofApp: "com.example.b", on: laptop) == 400)

        let read = inventory(
            [dot("hidden", overflowedOn: [laptop]), app("com.example.a"), app("com.example.b"), app("com.example.c"),
             app("com.example.new")], bars: [laptop], chevrons: [laptop])
        var sections = SectionModel()
        for id in ["a", "b", "c", "new"] { sections.move(app: "com.example.\(id)", to: .shown) }
        let apps = DotsRoom.trappedBars([laptop], in: read, sections: sections, widths: ItemWidthCache(), order: order)[0].apps
        // The ones that were seen go by where; one that never was comes after them, in the order of the slots (the read's).
        #expect(apps.map(\.bundleID) == ["com.example.b", "com.example.c", "com.example.a", "com.example.new"])
    }

    @Test func systemAndOwnItemsAreNeverMoved() {
        // The bar has the clock, Control Center, Mantel's dots and two apps. Only an app can be made room from.
        let clock = MenuBarItem(id: .system("clock"), ownerBundleID: ItemID.systemBundleID, appName: nil, label: nil,
                                frames: [laptop: frame(1500)], overflowedOn: [], isMantel: false)
        let control = MenuBarItem(id: .system("controlcenter"), ownerBundleID: ItemID.systemBundleID, appName: nil, label: nil,
                                  frames: [laptop: frame(1450)], overflowedOn: [], isMantel: false)
        let read = inventory(
            [dot("hidden", overflowedOn: [laptop]), dot("always", overflowedOn: [laptop]),
             app("com.example.a", frames: [laptop: frame(900)]), app("com.example.b", frames: [laptop: frame(1000)]), control, clock],
            bars: [laptop], chevrons: [laptop])
        var widths = ItemWidthCache()
        widths.update(from: read)
        var sections = SectionModel()
        sections.move(app: "com.example.a", to: .shown)
        sections.move(app: "com.example.b", to: .shown)
        sections.systemItems["clock"] = .shown
        let before = sections.systemItems

        let bars = DotsRoom.trappedBars([laptop], in: read, sections: sections, widths: widths, order: BarOrder())
        #expect(bars[0].apps.map(\.bundleID) == ["com.example.a", "com.example.b"])

        // Even when what is needed is more than every app can give, nothing else is touched.
        var tracker = AutoOverflowTracker()
        var wide = bars[0]
        wide.neededWidth = 10_000
        _ = tracker.arrived(.init(overflowedApps: [], trappedBars: [wide]), sections: &sections, now: Fixtures.date(0))
        let outcome = tracker.arrived(.init(overflowedApps: [], trappedBars: [wide]), sections: &sections, now: Fixtures.date(1))
        #expect(outcome.movedForDots.map(\.bundleID) == ["com.example.a", "com.example.b"])
        #expect(Set(sections.apps.keys) == ["com.example.a", "com.example.b"], "no placement for Mantel or the system")
        #expect(sections.systemItems == before)
    }

    // MARK: The log

    @Test func theDotsPlacesAreTheStrayOnesOfTheDotsThatAreOutOfTheWay() {
        let places = [CGRect(x: 522, y: 2, width: 24, height: 24), CGRect(x: 484, y: 2, width: 24, height: 24)]
        let read = inventory([
            MenuBarItem(id: ItemID(bundleID: own, key: .identifier("hidden")), ownerBundleID: own, appName: nil, label: nil, frames: [:],
                        overflowedOn: [laptop], isMantel: true, isDot: true, strayFrames: [laptop: places[0]]),
            MenuBarItem(id: ItemID(bundleID: own, key: .identifier("always")), ownerBundleID: own, appName: nil, label: nil, frames: [:],
                        overflowedOn: [laptop], isMantel: true, isDot: true, strayFrames: [laptop: places[1]]),
            dot("third", frames: [laptop: frame(900)]),
        ], bars: [laptop])
        #expect(DotsRoom.dotPlaces(on: laptop, in: read) == [places[1], places[0]], "left to right")
        #expect(DotsRoom.dotPlaces(on: desk, in: read).isEmpty)
    }
}
