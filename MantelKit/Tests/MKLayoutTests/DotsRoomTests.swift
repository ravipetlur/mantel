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

    @Test func aMenuThatShowsWithNoOwnIconsInTheReadCantBeTold() {
        let read = inventory([app("com.example.a", frames: [laptop: frame(300)])], bars: [laptop], chevrons: [laptop])
        #expect(DotsRoom.verdict(in: read, shownBars: [laptop]) == DotsRoom.Verdict(cantTell: [laptop: .noOwnIcons]))
    }

    @Test func withNoMenuShowingADotWithNoSlotIsSaidNotGuessed() {
        // No « is listed (macOS 27 lists none) and a dot has no slot on the bar: it may be anywhere, and nothing says where. It is said (once a
        // run, by the log), and nothing is moved.
        let read = inventory([dot("hidden"), dot("always")], bars: [laptop])
        #expect(DotsRoom.verdict(in: read, shownBars: [laptop]) == DotsRoom.Verdict(cantTell: [laptop: .dotHasNoSlot]))
        #expect(DotsRoom.mayHaveAVerdict(in: read))
        // With a slot for each there is nothing to say.
        let placed = inventory([dot("hidden", frames: [laptop: frame(800)]), dot("always", frames: [laptop: frame(840)])], bars: [laptop])
        #expect(DotsRoom.verdict(in: placed, shownBars: [laptop]) == DotsRoom.Verdict())
        #expect(!DotsRoom.mayHaveAVerdict(in: placed))
        // Nor when the bar isn't shown.
        #expect(DotsRoom.verdict(in: read, shownBars: []) == DotsRoom.Verdict())
        // Nor when the menu shows on a bar that isn't.
        let hidden = inventory([dot("hidden")], bars: [laptop], chevrons: [laptop])
        #expect(DotsRoom.verdict(in: hidden, shownBars: []) == DotsRoom.Verdict())
    }

    @Test func theWindowListIsOnlyWorthReadingForAReadWithAMenuOrATrappedDot() {
        #expect(!DotsRoom.mayHaveAVerdict(in: .empty))
        #expect(!DotsRoom.mayHaveAVerdict(in: inventory([dot("hidden", frames: [laptop: frame(800)])], bars: [laptop])))
        #expect(DotsRoom.mayHaveAVerdict(in: inventory([dot("hidden")], bars: [laptop], chevrons: [laptop])))
        // A dot that is overflowed (behind the notch) says so with no « on the bar.
        #expect(DotsRoom.mayHaveAVerdict(in: inventory([dot("hidden", overflowedOn: [laptop])], bars: [laptop])))
        // A dot with no slot on some bar is worth a look; spacer items, apps and dots that have every slot are not.
        #expect(DotsRoom.mayHaveAVerdict(in: inventory([dot("hidden")], bars: [laptop])))
        #expect(!DotsRoom.mayHaveAVerdict(in: inventory([spacer(), app("com.example.a")], bars: [laptop])))
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

    @Test func aDotKnownOnlyByItsOwnFrameNeedsTheRoomOfASlotAndNotOfTheIcon() {
        // MenuBarAgent lists no slot for an icon it isn't drawing: the dots are known by the frames they report, which are the icon's
        // (24 points) and not the slot that is wider (38). The room that is made for them is a slot's.
        func reporting(_ name: String, overflowedOn: Set<String> = []) -> MenuBarItem {
            MenuBarItem(id: ItemID(bundleID: own, key: .identifier(name)), ownerBundleID: own, appName: nil, label: nil, frames: [:],
                        overflowedOn: overflowedOn, isMantel: true, isDot: true, reportedWidth: 24)
        }
        var widths = ItemWidthCache()
        let read = inventory([reporting("hidden", overflowedOn: [laptop]), reporting("always", overflowedOn: [laptop])], bars: [laptop])
        widths.update(from: read)
        #expect(widths.width(of: read.items[0].id) == 24, "the cache knows what the dot said")
        #expect(DotsRoom.neededWidth(on: laptop, in: read, widths: widths) == 2 * DotsRoom.assumedWidth)

        // Once a dot has had a slot, the slot's width is what it takes.
        widths.update(from: inventory([dot("hidden", frames: [laptop: frame(800, width: 40)])], bars: [laptop]))
        #expect(DotsRoom.neededWidth(on: laptop, in: read, widths: widths) == 40 + DotsRoom.assumedWidth)
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

    @Test func withNoPlaceKnownForAnyAppTheOrderOfTheSlotsDecides() {
        let read = inventory(
            [dot("hidden", overflowedOn: [laptop]), app("com.example.z"), app("com.example.m"), app("com.example.a")],
            bars: [laptop], chevrons: [laptop])
        var sections = SectionModel()
        for id in ["z", "m", "a"] { sections.move(app: "com.example.\(id)", to: .shown) }
        let apps = DotsRoom.trappedBars([laptop], in: read, sections: sections, widths: ItemWidthCache(), order: BarOrder())[0].apps
        #expect(apps.map(\.bundleID) == ["com.example.z", "com.example.m", "com.example.a"])
        #expect(apps.allSatisfy { $0.width == nil })
    }

    @Test func whatIsKnownOfWhereAnAppWasIsNeverClearedByARead() {
        var order = BarOrder()
        order.update(from: inventory([app("com.example.a", frames: [laptop: frame(500)])], bars: [laptop]))
        // The app didn't answer, or its icon is in the menu now: the read says nothing of where it is drawn.
        order.update(from: inventory([], bars: [laptop]))
        order.update(from: inventory([app("com.example.a", frames: [laptop: frame(100)], overflowedOn: [laptop])], bars: [laptop]))
        #expect(order.leftEdge(ofApp: "com.example.a", on: laptop) == 500)
        // It is on the bar again, further right: that is where it was last.
        order.update(from: inventory([app("com.example.a", frames: [laptop: frame(560)])], bars: [laptop]))
        #expect(order.leftEdge(ofApp: "com.example.a", on: laptop) == 560)
        #expect(order.leftEdge(ofApp: "com.example.a", on: desk) == nil)
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

    @Test func theRoomTheDotsNeedCountsOnlyOnABarThatIsShown() {
        let read = inventory([dot("hidden", overflowedOn: [laptop]), dot("always", overflowedOn: [laptop, desk])], bars: [desk, laptop])
        let widths = ItemWidthCache()
        #expect(DotsRoom.neededWidth(on: laptop, in: read, widths: widths, shownBars: [laptop]) == 2 * DotsRoom.assumedWidth)
        #expect(DotsRoom.neededWidth(on: laptop, in: read, widths: widths, shownBars: [desk]) == 0, "a full-screen app has the laptop")
        #expect(DotsRoom.neededWidth(on: desk, in: read, widths: widths, shownBars: [desk, laptop]) == DotsRoom.assumedWidth)
        #expect(DotsRoom.neededWidth(on: laptop, in: read, widths: widths, shownBars: []) == 0)
    }

    @Test func theLogSaysWhyAnAppStaysAndWhatPushedTheDotsOut() {
        #expect(DotsRoomLog.moved("com.example.a", kind: .builtIn, pinned: true)
            == "Mantel's dots were in the « menu on the built-in display; moved com.example.a to Hidden to make room; it came back once, so it stays in Hidden until the displays change or half an hour has gone by")
        #expect(DotsRoomLog.pushedOutAgain("com.example.a", kind: .other)
            == "Mantel's dots were pushed out again on another display with com.example.a back in Shown; it goes back to Hidden and stays there until the displays change or half an hour has gone by")
        #expect(DotsRoomLog.pushedOutByATrial("com.example.a", kind: .builtIn)
            == "Mantel's dots were pushed out on the built-in display when com.example.a came back to Shown; it goes back to Hidden and stays there until the displays change or half an hour has gone by")
        var log = DotsRoomLog()
        var outcome = AutoOverflowTracker.Outcome()
        outcome.failedForDots = [.init(bundleID: "com.example.a", displayUUID: "x", wasMovedForTheDots: true),
                                 .init(bundleID: "com.example.b", displayUUID: "x", wasMovedForTheDots: false)]
        let lines = log.lines(verdict: DotsRoom.Verdict(trapped: ["x"]), outcome: outcome, automaticOverflowIsOn: true, kind: { _ in .builtIn })
        #expect(lines == [DotsRoomLog.pushedOutAgain("com.example.a", kind: .builtIn), DotsRoomLog.pushedOutByATrial("com.example.b", kind: .builtIn)])
    }

    @Test func theLogSaysWhenMovingStopsAndWhy() {
        var log = DotsRoomLog()
        var outcome = AutoOverflowTracker.Outcome()
        outcome.stoppedForDots = [.init(displayUUID: laptop, reason: .samePlace)]
        let first = log.lines(verdict: DotsRoom.Verdict(trapped: [laptop]), outcome: outcome, automaticOverflowIsOn: true, kind: { _ in .builtIn })
        #expect(first == ["Mantel's dots still report the same place after making room; Mantel stopped moving apps for them"])
        outcome.stoppedForDots = [.init(displayUUID: desk, reason: .enoughMoved)]
        #expect(log.lines(verdict: DotsRoom.Verdict(trapped: [desk]), outcome: outcome, automaticOverflowIsOn: true, kind: { _ in .other })
            == ["Mantel's dots are still out of the way on another display after the apps that were moved for them; Mantel stopped moving apps for them"])
    }

    @Test func aStopThatStartsAgainAfterTheDotsWereSeenOnTheBarIsSaidAgainOnlyWhenWhatIsHeldChanged() {
        // The tracker tells of a stop when it starts, and a read that has the dots right ends it: the next stop is a new one. The log says it
        // when what is held in Hidden for the dots has changed, and not when it is the same trap again.
        let a = "com.example.a", b = "com.example.b", c = "com.example.c"
        var tracker = AutoOverflowTracker()
        var sections = SectionModel()
        for app in [a, b, c] { sections.move(app: app, to: .shown) }
        var log = DotsRoomLog()
        func bar(_ apps: [String]) -> AutoOverflowTracker.Read {
            let places = [CGRect(x: 484, y: 2.5, width: 24, height: 24)]
            return .init(overflowedApps: [], trappedBars: [.init(displayUUID: laptop, neededWidth: 76,
                                                                 apps: apps.map { .init(bundleID: $0, width: 38) }, dotPlaces: places)])
        }
        func said(_ read: AutoOverflowTracker.Read, at seconds: Double) -> [String] {
            let now = Fixtures.date(seconds)
            let outcome = tracker.arrived(read, sections: &sections, now: now)
            return log.lines(verdict: DotsRoom.Verdict(trapped: read.trappedBars.map(\.displayUUID)), outcome: outcome, automaticOverflowIsOn: true,
                             now: now, kind: { _ in .builtIn })
        }
        let stop = "Mantel's dots still report the same place after making room; Mantel stopped moving apps for them"

        // The first cycle: a and b are moved (they need 76), and the dots say the same place after it: 76 is held.
        #expect(said(bar([a, b, c]), at: 0).isEmpty)
        #expect(said(bar([a, b, c]), at: 0.5) == [DotsRoomLog.moved(a, kind: .builtIn), DotsRoomLog.moved(b, kind: .builtIn)])
        #expect(said(bar([c]), at: 10.5) == [stop])
        #expect(said(bar([c]), at: 20.5).isEmpty, "said when it starts, and not on every read")
        // The dots are drawn: that ends the stop. The apps come back on their trial.
        #expect(said(.init(overflowedApps: []), at: 30).isEmpty)
        _ = tracker.roomMayHaveReturned(.periodic, sections: &sections, predictedFits: { _ in true }, now: Fixtures.date(90))
        #expect(said(.init(overflowedApps: []), at: 91).count == 2, "room is back, for both")

        // The second: the same trap, the same two apps are moved (and stay), and the same 76 is held: a stop that started again is not said.
        #expect(said(bar([a, b, c]), at: 100).isEmpty)
        #expect(said(bar([a, b, c]), at: 100.5).count == 2)
        #expect(said(bar([c]), at: 111).isEmpty, "the same stop, a minute and a half after it was said")
        // The dots are drawn and trapped once more, and this time b is the person's again, so b and c are moved and 114 is held at the
        // stop: a different stop, and said.
        #expect(said(.init(overflowedApps: []), at: 120).isEmpty)
        sections.move(app: b, to: .shown)
        #expect(said(bar([b, c]), at: 130).isEmpty)
        #expect(said(bar([b, c]), at: 130.5) == [DotsRoomLog.moved(b, kind: .builtIn), DotsRoomLog.moved(c, kind: .builtIn)])
        #expect(said(bar([]), at: 141) == [stop], "what is held has changed")
    }

    @Test func aStopIsSaidAgainOnlyWhenWhatIsHeldChangedOrAfterTenMinutes() {
        var log = DotsRoomLog()
        func said(held: CGFloat, on display: String? = nil, at seconds: Double) -> [String] {
            var outcome = AutoOverflowTracker.Outcome()
            outcome.stoppedForDots = [.init(displayUUID: display ?? laptop, reason: .enoughMoved, held: held)]
            return log.lines(verdict: DotsRoom.Verdict(trapped: [display ?? laptop]), outcome: outcome, automaticOverflowIsOn: true,
                             now: Fixtures.date(seconds), kind: { _ in .builtIn })
        }
        #expect(said(held: 38, at: 0).count == 1)
        #expect(said(held: 38, at: 60).isEmpty)
        #expect(said(held: 38, at: 599).isEmpty)
        #expect(said(held: 38, at: 600).count == 1, "ten minutes after it was said")
        #expect(said(held: 38, at: 601).isEmpty)
        #expect(said(held: 76, at: 602).count == 1, "what is held changed")
        #expect(said(held: 38, on: desk, at: 603).count == 1, "each display has its own")
    }

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

    @Test func theLogSaysWhatCantBeToldOnceARun() {
        var log = DotsRoomLog()
        let verdict = DotsRoom.Verdict(cantTell: [laptop: .ownIconsNotPlaced])
        let kind: (String) -> DisplayKind = { $0 == self.laptop ? .builtIn : .other }

        let first = log.lines(verdict: verdict, outcome: nil, automaticOverflowIsOn: true, kind: kind)
        #expect(first == ["the « menu is showing on the built-in display but Mantel can't tell what is in it (Mantel's own icons couldn't be placed on that bar)"])
        // Every read finds it again.
        #expect(log.lines(verdict: verdict, outcome: nil, automaticOverflowIsOn: true, kind: kind).isEmpty)
        #expect(log.lines(verdict: verdict, outcome: nil, automaticOverflowIsOn: false, kind: kind).isEmpty)
        // Dots that give one frame between them: the « isn't known to show, and the line doesn't say it does.
        let shared = log.lines(verdict: DotsRoom.Verdict(cantTell: [desk: .ownIconsShareAFrame]), outcome: nil, automaticOverflowIsOn: true, kind: kind)
        #expect(shared == ["Mantel's dot has no place on another display's bar (Mantel's own icons said they were in one and the same place)"])
        let noSlot = log.lines(verdict: DotsRoom.Verdict(cantTell: [laptop: .dotHasNoSlot]), outcome: nil, automaticOverflowIsOn: true, kind: kind)
        #expect(noSlot == ["Mantel's dot has no place on the built-in display's bar (no slot on that bar is one of Mantel's)"])
        // Another display, or another reason, is another line.
        let other = log.lines(verdict: DotsRoom.Verdict(cantTell: [desk: .noOwnIcons]), outcome: nil, automaticOverflowIsOn: true, kind: kind)
        #expect(other == ["the « menu is showing on another display but Mantel can't tell what is in it (Mantel's own icons weren't in what was read)"])
    }

    @Test func theLogSaysWhatWasDoneEveryTimeAndWhatIsSoOnceARun() {
        var log = DotsRoomLog()
        let kind: (String) -> DisplayKind = { $0 == self.laptop ? .builtIn : .other }
        var outcome = AutoOverflowTracker.Outcome()
        outcome.movedForDots = [.init(bundleID: "com.example.a", displayUUID: laptop), .init(bundleID: "com.example.b", displayUUID: desk)]
        let moved = log.lines(verdict: DotsRoom.Verdict(trapped: [laptop]), outcome: outcome, automaticOverflowIsOn: true, kind: kind)
        #expect(moved == [
            "Mantel's dots were in the « menu on the built-in display; moved com.example.a to Hidden to make room",
            "Mantel's dots were in the « menu on another display; moved com.example.b to Hidden to make room",
        ])
        // Doing it again is said again.
        #expect(log.lines(verdict: DotsRoom.Verdict(trapped: [laptop]), outcome: outcome, automaticOverflowIsOn: true, kind: kind).count == 2)

        var back = AutoOverflowTracker.Outcome()
        back.returnedForDots = [.init(bundleID: "com.example.a", displayUUID: laptop)]
        #expect(log.lines(verdict: DotsRoom.Verdict(), outcome: back, automaticOverflowIsOn: true, kind: kind)
            == ["room is back on the built-in display; com.example.a is in Shown again"])

        var none = AutoOverflowTracker.Outcome()
        none.noRoomToMakeFor = [laptop]
        let once = log.lines(verdict: DotsRoom.Verdict(trapped: [laptop]), outcome: none, automaticOverflowIsOn: true, kind: kind)
        #expect(once == ["Mantel's dots are in the « menu on the built-in display, and no Shown app is left to move to Hidden to make room"])
        #expect(log.lines(verdict: DotsRoom.Verdict(trapped: [laptop]), outcome: none, automaticOverflowIsOn: true, kind: kind).isEmpty)
    }

    @Test func withAutomaticOverflowOffTheLogOnlySaysWhereTheDotsAre() {
        var log = DotsRoomLog()
        let kind: (String) -> DisplayKind = { _ in .builtIn }
        let lines = log.lines(verdict: DotsRoom.Verdict(trapped: [laptop]), outcome: nil, automaticOverflowIsOn: false, kind: kind)
        #expect(lines == ["Mantel's dots are in the « menu on the built-in display; \"Move icons that don't fit to Hidden\" is off, so no app was moved"])
        #expect(log.lines(verdict: DotsRoom.Verdict(trapped: [laptop]), outcome: nil, automaticOverflowIsOn: false, kind: kind).isEmpty)
        // With it on, that line isn't said.
        var on = DotsRoomLog()
        #expect(on.lines(verdict: DotsRoom.Verdict(trapped: [laptop]), outcome: AutoOverflowTracker.Outcome(), automaticOverflowIsOn: true,
                         kind: kind).isEmpty)
        #expect(DisplayKind.builtIn.phrase == "the built-in display" && DisplayKind.other.phrase == "another display")
    }
}
