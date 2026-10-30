import CoreGraphics
import Foundation
import MKCore
import MKTestSupport
import Synchronization
import Testing

@testable import MKMenuBar

@Suite(.timeLimit(.minutes(1)))
struct ItemImageCollectorTests {
    typealias World = CollectorWorld

    private let folder = TemporaryFolder(prefix: "mantel-collector")
    private let clock = FakeClock()
    private let windows = FakeWindowList([World.barWindow()])

    private var images: URL { folder.url.appending(path: "ItemImages", directoryHint: .isDirectory) }
    private let a = World.id("a"), b = World.id("b"), c = World.id("c")

    private func store() -> ItemImageStore { ItemImageStore(folder: images, clock: clock) }

    private func collector(_ store: ItemImageStore, _ capture: FakeCapture, rules: CaptureRules = .provisional, granted: Bool = true,
                           may: @escaping @Sendable () async -> String? = { nil }) -> ItemImageCollector {
        ItemImageCollector(store: store, capture: capture, layout: { World.displayLayout() }, windows: windows,
                           screenRecordingGranted: { granted }, mayCapture: may, clock: clock, rules: rules)
    }

    private func threeItems() -> [MenuBarItem] {
        [World.item(a, bundleID: "com.example.a", slot: 0), World.item(b, bundleID: "com.example.b", slot: 1),
         World.item(c, bundleID: "com.example.c", slot: 2)]
    }

    private func painting(_ slots: Int...) -> FakeCapture {
        let capture = FakeCapture(clock: clock)
        capture.paint(slots.map { World.slot($0) })
        return capture
    }

    @Test func cropsOnlySlotsTiedToTheItem() async throws {
        let store = store()
        // A's slot is 30 points wide; its app also reports a frame, painted wider, in no slot, and C has no slot at all.
        let stray = CGRect(x: 700, y: 0, width: 80, height: 24)
        let capture = FakeCapture(clock: clock)
        capture.paint([World.slot(0), stray])
        let items = [World.item(a, bundleID: "com.example.a", slot: 0, stray: stray), World.item(c, bundleID: "com.example.c", slot: nil, stray: stray)]
        let summary = await collector(store, capture).capture(.launch, read: World.inventory(items), concealed: [])
        #expect(summary.captured == 1)
        #expect(await store.record(for: c) == nil)
        let record = try #require(await store.record(for: a))
        let size = try #require(record.variants.values.first?.pointSize)
        #expect(abs(size.width - 18) < 2, "the picture is the slot's 18 point disc, not the 68 point stray")
    }

    @Test func skipsHiddenBar() async {
        windows.set([])
        let capture = painting(0, 1, 2)
        let summary = await collector(store(), capture).capture(.launch, read: World.inventory(threeItems()), concealed: [])
        #expect(summary.captured == 0)
        #expect(summary.skipped == "The bar isn't shown")
        #expect(capture.displays.count == 0)
    }

    @Test func skipsOverflowedAndConcealed() async {
        let store = store()
        let items = [World.item(a, bundleID: "com.example.a", slot: 0, overflowed: true), World.item(b, bundleID: "com.example.b", slot: 1),
                     World.item(c, bundleID: "com.example.c", slot: 2)]
        let summary = await collector(store, painting(0, 1, 2)).capture(.launch, read: World.inventory(items), concealed: ["com.example.b"])
        #expect(summary.captured == 1)
        #expect(await store.record(for: c) != nil)
        #expect(await store.record(for: a) == nil)
        #expect(await store.record(for: b) == nil)
    }

    @Test func skipsTheAppsTheReadSaysItReadInPart() async {
        // An app that answered in part names some of its icons by their places in the read: a picture saved under such an ID isn't its
        // record's. The others in the same read are cropped.
        let store = store()
        let summary = await collector(store, painting(0, 1, 2)).capture(.launch, read: World.inventory(threeItems(), incomplete: ["com.example.b"]),
                                                                        concealed: [])
        #expect(summary.captured == 2)
        #expect(await store.record(for: b) == nil)
        #expect(await store.record(for: a) != nil)
        #expect(await store.record(for: c) != nil)
    }

    @Test func skipsOwnItems() async {
        let store = store()
        let dot = World.item(ItemID(bundleID: "com.example.mantel", key: .identifier("dot")), bundleID: "com.example.mantel", slot: 0,
                             mantel: true, kind: .hiddenDot)
        let invisible = World.item(ItemID(bundleID: "com.example.mantel", key: .identifier("divider")), bundleID: "com.example.mantel", slot: 1,
                                   mantel: true)
        let normal = World.item(c, bundleID: "com.example.c", slot: 2)
        let summary = await collector(store, painting(0, 1, 2)).capture(.launch, read: World.inventory([dot, invisible, normal]), concealed: [])
        #expect(summary.captured == 1)
        #expect(await store.records().map(\.item) == [c])
    }

    @Test func noScreenRecordingSkipsWithReason() async {
        let capture = painting(0)
        let summary = await collector(store(), capture, granted: false).capture(.launch, read: World.inventory(threeItems()), concealed: [])
        #expect(summary == CaptureSummary(captured: 0, changed: 0, skipped: "Screen Recording is off"))
        #expect(capture.displays.count == 0)
    }

    @Test func mayCaptureNoSkipsWithItsReason() async {
        let capture = painting(0)
        let summary = await collector(store(), capture, granted: false, may: { "The layout is settling" })
            .capture(.launch, read: World.inventory(threeItems()), concealed: [])
        #expect(summary.skipped == "The layout is settling")
        #expect(capture.displays.count == 0)
    }

    @Test func perBarIntervalThrottles() async {
        let capture = painting(0, 1, 2)
        let rules = CaptureRules(moments: Set(CaptureMomentKind.allCases), perBarInterval: .seconds(2), freshFor: .zero, launchBudget: .seconds(1))
        let collector = collector(store(), capture, rules: rules)
        let read = World.inventory(threeItems())
        #expect(await collector.capture(.settingsOpened, read: read, concealed: []).captured == 3)
        clock.advance(by: .seconds(1))
        let throttled = await collector.capture(.settingsOpened, read: read, concealed: [])
        #expect(throttled.captured == 0)
        #expect(throttled.skipped == "The bar was captured a moment ago")
        #expect(capture.displays.count == 1)
        clock.advance(by: .seconds(1))
        #expect(await collector.capture(.settingsOpened, read: read, concealed: []).captured == 3)
        #expect(capture.displays.count == 2)
    }

    @Test func freshNonDynamicIsSkipped() async {
        let capture = painting(0, 1, 2)
        let collector = collector(store(), capture)
        let read = World.inventory(threeItems())
        #expect(await collector.capture(.settingsOpened, read: read, concealed: []).captured == 3)
        #expect(await collector.lastCaptureAt == clock.now())
        clock.advance(by: .seconds(10))
        let again = await collector.capture(.settingsOpened, read: read, concealed: [])
        #expect(again.captured == 0)
        #expect(again.skipped == "The pictures are recent")
        #expect(capture.displays.count == 1)
        clock.advance(by: .seconds(3600))
        #expect(await collector.capture(.settingsOpened, read: read, concealed: []).captured == 3)
    }

    @Test func dynamicIsAlwaysRecaptured() async throws {
        let store = store()
        // The picture has changed twice already.
        for colour in [imageColour(1, 0, 0), imageColour(0, 1, 0), imageColour(0, 0, 1)] {
            try await store.save(mattedDisc(colour: colour), scale: 2, for: a, appItemCount: 1)
        }
        #expect(try #require(await store.record(for: a)).isDynamic)
        let capture = painting(0)
        let collector = collector(store, capture)
        let read = World.inventory([World.item(a, bundleID: "com.example.a", slot: 0)])
        // Well inside the hour an unchanged icon would be left alone, and a dynamic one is not.
        clock.advance(by: .seconds(10))
        #expect(await collector.capture(.recapture, read: read, concealed: []).captured == 1)
        clock.advance(by: .seconds(10))
        #expect(await collector.capture(.recapture, read: read, concealed: []).captured == 1)
        #expect(capture.displays.count == 2)
    }

    @Test func momentsFilteredByRules() async {
        let capture = painting(0, 1, 2)
        let quiet = CaptureRules(moments: [.launch, .settingsOpened, .recapture], launchBudget: .seconds(1), indicatorQuietPeriod: .seconds(2))
        let collector = collector(store(), capture, rules: quiet)
        let read = World.inventory(threeItems())

        let skipped = await collector.capture(.revealSeen(["com.example.a"]), read: read, concealed: [])
        #expect(skipped == CaptureSummary(captured: 0, changed: 0, skipped: "This moment doesn't capture icons"))
        let clicked = await collector.capture(.clickDrawn(location(of: a, slot: 0)), read: read, concealed: [])
        #expect(clicked.skipped == "This moment doesn't capture icons")
        #expect(capture.displays.count == 0)

        // The quiet period is the session's to keep: a capture answers at once.
        #expect(await collector.capture(.recapture, read: read, concealed: []).captured == 3)
        clock.advance(by: .seconds(5))
        #expect(await collector.capture(.launch, read: read, concealed: []).skipped == "The pictures are recent")
        #expect(capture.displays.count == 1)
    }

    @Test func overlappingCapturesTakeABarOnce() async {
        let capture = painting(0)
        capture.hang(true)
        let collector = collector(store(), capture)
        let read = World.inventory([World.item(a, bundleID: "com.example.a", slot: 0)])
        let first = Task { await collector.capture(.recapture, read: read, concealed: []) }
        await clock.waitForSleepers()
        // The first is still waiting for the strip; the second finds the bar taken.
        let second = await collector.capture(.recapture, read: read, concealed: [])
        #expect(second == CaptureSummary(captured: 0, changed: 0, skipped: "The bar was captured a moment ago"))
        clock.advance(by: .seconds(10))
        #expect(await first.value.captured == 1)
        #expect(capture.displays.count == 1)
    }

    @Test func allMomentsRulesCaptureRevealedAppsOnly() async {
        let store = store()
        let summary = await collector(store, painting(0, 1, 2)).capture(.revealSeen(["com.example.b"]), read: World.inventory(threeItems()), concealed: [])
        #expect(summary.captured == 1)
        #expect(await store.records().map(\.item) == [b])
    }

    @Test func clickDrawnCapturesOneSlot() async {
        let store = store()
        let capture = painting(0, 1, 2)
        let summary = await collector(store, capture).capture(.clickDrawn(location(of: b, slot: 1)), read: World.inventory(threeItems()), concealed: [])
        #expect(summary.captured == 1)
        #expect(await store.records().map(\.item) == [b])
        #expect(capture.displays.count == 1)
    }

    @Test func launchBudgetStopsASlowCapture() async {
        let capture = painting(0)
        capture.hang(true)
        let collector = collector(store(), capture)
        let read = World.inventory([World.item(a, bundleID: "com.example.a", slot: 0)])
        let running = Task { await collector.capture(.launch, read: read, concealed: []) }
        await clock.waitForSleepers(2)
        clock.advance(by: .seconds(1))
        let summary = await running.value
        #expect(summary == CaptureSummary(captured: 0, changed: 0, skipped: "The launch capture ran out of time"))
    }

    // MARK: Recapture

    @Test func recaptureReplacesRecentPictures() async throws {
        let store = store()
        let capture = painting(0)
        let collector = collector(store, capture)
        let read = World.inventory([World.item(a, bundleID: "com.example.a", slot: 0)])
        #expect(await collector.capture(.settingsOpened, read: read, concealed: []).captured == 1)
        let first = try #require(await store.record(for: a)).variants.values.first
        // A minute later, well inside the hour a recent picture is left alone for: it is another painting, and is taken.
        clock.advance(by: .seconds(60))
        capture.setColour(imageColour(0, 1, 0))
        #expect(await collector.capture(.settingsOpened, read: read, concealed: []).skipped == "The pictures are recent")
        let another = await collector.capture(.recapture, read: read, concealed: [])
        #expect(another == CaptureSummary(captured: 1, changed: 1, skipped: nil))
        let second = try #require(await store.record(for: a)).variants.values.first
        #expect(second?.pixelHash != first?.pixelHash)

        // The same painting: taken, not a change, and only when it was taken moves.
        clock.advance(by: .seconds(60))
        let same = await collector.capture(.recapture, read: read, concealed: [])
        #expect(same == CaptureSummary(captured: 1, changed: 0, skipped: nil))
        let record = try #require(await store.record(for: a))
        #expect(record.variants.values.first?.pixelHash == second?.pixelHash)
        #expect(record.variants.values.first?.capturedAt == clock.now())
        #expect(!record.isDynamic, "recapturing doesn't make an icon dynamic")
    }

    @Test func recaptureStillHasTheBarsThrottle() async {
        let collector = collector(store(), painting(0))
        let read = World.inventory([World.item(a, bundleID: "com.example.a", slot: 0)])
        #expect(await collector.capture(.recapture, read: read, concealed: []).captured == 1)
        clock.advance(by: .seconds(1))
        #expect(await collector.capture(.recapture, read: read, concealed: []).skipped == "The bar was captured a moment ago")
    }

    // MARK: A strip of another moment

    private func slowCollector(_ store: ItemImageStore, delay: Duration) -> (ItemImageCollector, FakeCapture) {
        let capture = painting(0)
        capture.delay(delay)
        return (collector(store, capture), capture)
    }

    @Test func aStripThatComesBackAfterTheDeadlineIsNotCropped() async throws {
        let store = store()
        let (collector, _) = slowCollector(store, delay: .milliseconds(500))
        let read = World.inventory([World.item(a, bundleID: "com.example.a", slot: 0)])
        let deadline = clock.now().addingTimeInterval(0.226)
        let running = Task { await collector.capture(.settingsOpened, read: read, concealed: [], deadline: deadline) }
        // The collector's timer and the capture are asleep.
        await clock.waitForSleepers(2)
        clock.advance(by: .milliseconds(226))

        let summary = await running.value
        #expect(summary == CaptureSummary(captured: 0, changed: 0, skipped: "The capture ran out of time"), "not named for the launch")
        clock.advance(by: .milliseconds(300))
        #expect(await store.records().isEmpty, "the capture that was let go didn't save")
    }

    /// The summary of a capture that is expected to be over, or nil when it isn't within five seconds of real time: a capture that wasn't
    /// cut off where it should have been fails its test, and doesn't hang until the suite's time limit.
    private func finished(_ running: Task<CaptureSummary, Never>) async -> CaptureSummary? {
        let clock = clock
        return await withinTimeLimit(.seconds(5)) {
            // Cancelled when the time is up: the clock is moved on so that the capture that is still going ends.
            await withTaskCancellationHandler { await running.value } onCancel: { clock.advance(by: .seconds(10)) }
        }
    }

    @Test func aLaunchStripPastTheDeadlineIsCutOffThoughTheCapIsLater() async throws {
        // The cap is a second, the deadline is 226 ms, and the strip comes back at 500 ms: the launch is cut off at the deadline.
        let store = store()
        let (collector, _) = slowCollector(store, delay: .milliseconds(500))
        let read = World.inventory([World.item(a, bundleID: "com.example.a", slot: 0)])
        let deadline = clock.now().addingTimeInterval(0.226)
        let running = Task { await collector.capture(.launch, read: read, concealed: [], deadline: deadline) }
        #expect(await clock.waitForSleepers(2, within: .seconds(5)), "the collector's timer and the capture are asleep")
        clock.advance(by: .milliseconds(226))

        let summary = await finished(running)
        #expect(summary == CaptureSummary(captured: 0, changed: 0, skipped: "The launch capture ran out of time"),
                "the launch's strip is cut off at its deadline, not at the cap")
        clock.advance(by: .milliseconds(300))
        #expect(await store.records().isEmpty)
    }

    /// A capture that answers after the clock has moved past the deadline by itself, without waking the collector's timer: the strip comes
    /// back, and the check on its return is what turns it away.
    private struct LateAnswer: StripCapturing {
        let inner: FakeCapture
        let clock: SkewedClock
        let late: TimeInterval

        func capture(bar: MenuBarGeometry, display: DisplayInfo, layout: DisplayLayout) async throws -> CGImage {
            let image = try await inner.capture(bar: bar, display: display, layout: layout)
            clock.skew(by: late)
            return image
        }
    }

    @Test(arguments: [(CaptureMoment.launch, "The launch capture ran out of time"), (.settingsOpened, "The capture ran out of time")])
    func aStripThatIsBackAfterTheDeadlineIsTurnedAwayOnItsReturn(moment: CaptureMoment, text: String) async throws {
        let store = store()
        let skewed = SkewedClock(clock)
        let collector = ItemImageCollector(store: store, capture: LateAnswer(inner: painting(0), clock: skewed, late: 0.3),
                                           layout: { World.displayLayout() }, windows: windows, screenRecordingGranted: { true }, clock: skewed,
                                           rules: .provisional)
        let read = World.inventory([World.item(a, bundleID: "com.example.a", slot: 0)])

        // The timer for the deadline is never woken (the clock the timer sleeps on doesn't move): only the check on the return can say it.
        let summary = await collector.capture(moment, read: read, concealed: [], deadline: skewed.now().addingTimeInterval(0.226))

        #expect(summary == CaptureSummary(captured: 0, changed: 0, skipped: text))
        #expect(await store.records().isEmpty)
    }

    @Test func aStripThatComesBackByTheDeadlineIsCropped() async throws {
        let store = store()
        let (collector, _) = slowCollector(store, delay: .milliseconds(100))
        let read = World.inventory([World.item(a, bundleID: "com.example.a", slot: 0)])
        let deadline = clock.now().addingTimeInterval(0.226)
        let running = Task { await collector.capture(.settingsOpened, read: read, concealed: [], deadline: deadline) }
        await clock.waitForSleepers(2)
        clock.advance(by: .milliseconds(100))

        #expect(await running.value.captured == 1)
    }

    @Test func aBarThatChangedWhileTheStripWasTakenIsNotCropped() async throws {
        let store = store()
        let collector = collector(store, painting(0))
        let read = World.inventory([World.item(a, bundleID: "com.example.a", slot: 0)])

        let summary = await collector.capture(.revealSeen(["com.example.a"]), read: read, concealed: [], isCurrent: { _, _ in StillCurrentAnswer(kept: []) })

        #expect(summary == CaptureSummary(captured: 0, changed: 0, skipped: "The bar changed while it was captured"))
        #expect(await store.records().isEmpty)
        // Nothing was kept, so the bar can be taken again at once.
        #expect(await collector.capture(.revealSeen(["com.example.a"]), read: read, concealed: [], isCurrent: { _, apps in StillCurrentAnswer(kept: apps) }).captured == 1)
    }

    @Test func aCheckThatRanOutOfTimeSaysSoAndNotThatTheBarChanged() async throws {
        let store = store()
        let collector = collector(store, painting(0))
        let read = World.inventory([World.item(a, bundleID: "com.example.a", slot: 0)])

        let summary = await collector.capture(.settingsOpened, read: read, concealed: [], isCurrent: { _, _ in StillCurrentAnswer(kept: [], outOfTime: true) })

        #expect(summary == CaptureSummary(captured: 0, changed: 0, skipped: "The capture ran out of time"))
        #expect(await store.records().isEmpty)
        // Nothing was kept, so the bar can be taken again at once.
        #expect(await collector.capture(.settingsOpened, read: read, concealed: [], isCurrent: { _, apps in StillCurrentAnswer(kept: apps) }).captured == 1)
    }

    @Test func onlyTheAppsThatPassTheCheckAreKept() async throws {
        // B's frames are no longer in the slot the read gave it: its picture is not kept, A's and C's are.
        let store = store()
        let collector = collector(store, painting(0, 1, 2))
        let asked = Asked()

        let summary = await collector.capture(.settingsOpened, read: World.inventory(threeItems()), concealed: [],
                                              isCurrent: { _, apps in asked.add(apps.sorted().joined(separator: ",")); return StillCurrentAnswer(kept: apps.subtracting(["com.example.b"])) })

        #expect(summary.captured == 2)
        #expect(asked.value == ["com.example.a,com.example.b,com.example.c"], "the check is asked once, about the apps that would be cropped")
        #expect(await store.record(for: b) == nil)
        #expect(await store.record(for: a) != nil)
        #expect(await store.record(for: c) != nil)
    }

    @Test func aCaptureThatKeptNothingSaysInTheLogWhatChanged() async throws {
        let collector = collector(store(), painting(0, 1, 2))
        let changes = ["slots 3 -> 4: 1 moved 40 pt left, 1 appeared (at x 100, 30 pt wide)", "com.example.b's icons moved 44 pt right"]
        let lines = await LogCapture.lines {
            _ = await collector.capture(.settingsOpened, read: World.inventory(threeItems()), concealed: [],
                                        isCurrent: { _, _ in StillCurrentAnswer(kept: [], changes: changes) })
        }
        let line = try #require(lines.first { $0.contains("nothing captured at settingsOpened") })
        #expect(line.contains("The bar changed while it was captured (slots 3 -> 4: 1 moved 40 pt left, 1 appeared (at x 100, 30 pt wide); "
            + "com.example.b's icons moved 44 pt right); active"))
    }

    @Test func aCaptureThatKeptSomeSaysWhichAppsWereLeftOutAndWhy() async throws {
        let collector = collector(store(), painting(0, 1, 2))
        let lines = await LogCapture.lines {
            _ = await collector.capture(.settingsOpened, read: World.inventory(threeItems()), concealed: [], isCurrent: { _, apps in
                StillCurrentAnswer(kept: apps.subtracting(["com.example.a", "com.example.b"]), changes: ["slots 3 -> 4: 2 moved 40 pt left"])
            })
        }
        let line = try #require(lines.first { $0.contains("not kept: com.example.a, com.example.b") })
        #expect(line.hasSuffix("captured 1 icons, 1 changed; not kept: com.example.a, com.example.b (slots 3 -> 4: 2 moved 40 pt left)"), "\(line)")
    }

    @Test func aCaptureThatKeptEverythingSaysNothingOfWhatChanged() async throws {
        let collector = collector(store(), painting(0, 1, 2))
        let lines = await LogCapture.lines {
            _ = await collector.capture(.settingsOpened, read: World.inventory(threeItems()), concealed: [],
                                        isCurrent: { _, apps in StillCurrentAnswer(kept: apps) })
        }
        // Other tests' lines are in the capture too: this one's is the one that says three.
        #expect(lines.contains { $0.hasSuffix("captured 3 icons, 3 changed") })
        #expect(!lines.contains { $0.contains("captured 3 icons") && $0.contains("not kept") })
    }

    @Test func aCheckThatRanOutOfTimeSaysHowFarItGotInTheLog() async throws {
        let collector = collector(store(), painting(0, 1, 2))
        let lines = await LogCapture.lines {
            _ = await collector.capture(.settingsOpened, read: World.inventory(threeItems()), concealed: [], isCurrent: { _, _ in
                StillCurrentAnswer(kept: [], outOfTime: true, changes: ["after 2 rounds, a whole look in 0 of them; not judged: com.example.a"])
            })
        }
        let line = try #require(lines.first { $0.contains("nothing captured at settingsOpened") })
        #expect(line.contains("The capture ran out of time (after 2 rounds, a whole look in 0 of them; not judged: com.example.a);"), "\(line)")
    }

    @Test func moreThanFourThingsOutOfPlaceAreSaidAsFourAndHowManyMore() async throws {
        let collector = collector(store(), painting(0, 1, 2))
        let lines = await LogCapture.lines {
            _ = await collector.capture(.settingsOpened, read: World.inventory(threeItems()), concealed: [], isCurrent: { _, _ in
                StillCurrentAnswer(kept: [], changes: ["one", "two", "three", "four", "five", "six"])
            })
        }
        let line = try #require(lines.first { $0.contains("nothing captured at settingsOpened") })
        #expect(line.contains("(one; two; three; four; and 2 more);"), "\(line)")
    }

    @Test func theCheckIsOnlyAskedAboutTheAppsThatWouldBeCropped() async throws {
        let store = store()
        let collector = collector(store, painting(0, 1, 2))
        let asked = Asked()

        _ = await collector.capture(.settingsOpened, read: World.inventory(threeItems()), concealed: ["com.example.b"],
                                    isCurrent: { _, apps in asked.add(apps.sorted().joined(separator: ",")); return StillCurrentAnswer(kept: apps) })

        #expect(asked.value == ["com.example.a,com.example.c"], "a concealed app isn't cropped, and isn't asked")
    }

    @Test func aBarWhoseAppsAllFailTheCheckIsTakenAgainAtOnce() async throws {
        let store = store()
        let collector = collector(store, painting(0, 1, 2))
        let read = World.inventory(threeItems())

        let none = await collector.capture(.settingsOpened, read: read, concealed: [], isCurrent: { _, _ in StillCurrentAnswer(kept: []) })
        #expect(none.skipped == "The bar changed while it was captured")

        #expect(await collector.capture(.settingsOpened, read: read, concealed: []).captured == 3, "nothing held the bar to its throttle")
    }

    @Test func aClickDrawnSlotThatIsNotTheReadsSlotForTheItemSavesNothing() async throws {
        // The location was found in the neighbour's slot (the bar moved between the location and the read): it isn't cropped there.
        let store = store()
        let capture = painting(0, 1, 2)
        let collector = collector(store, capture)
        let read = World.inventory(threeItems())

        let summary = await collector.capture(.clickDrawn(location(of: b, slot: 2)), read: read, concealed: [])

        #expect(summary.captured == 0)
        #expect(await store.records().isEmpty, "no picture under an item that isn't the one in it")
        #expect(capture.displays.isEmpty, "and no strip was taken for it")

        // Within the tolerance it is the same slot.
        let jitter = ItemLocation(item: b, displayUUID: World.display, slotFrame: World.slot(1).offsetBy(dx: 0.4, dy: 0), tiedBy: .tie,
                                  slotWasInBaseline: true, widthAgrees: true)
        #expect(await collector.capture(.clickDrawn(jitter), read: read, concealed: []).captured == 1)
    }

    @Test func isCurrentIsAskedAboutTheBarThatWasTaken() async throws {
        let (layout, windows, bars) = twoDisplays()
        let slot = World.slot(0)
        let item = MenuBarItem(id: a, ownerBundleID: "com.example.a", appName: nil, label: nil, frames: [World.display: slot], overflowedOn: [],
                               isMantel: false, strayFrames: [:], ownKind: nil)
        let read = Inventory(capturedAt: Date(timeIntervalSince1970: 0), bars: bars, items: [item], chevrons: [:], reach: [], problems: [],
                             activeDisplay: World.display)
        let asked = Asked()
        let collector = ItemImageCollector(store: store(), capture: painting(0), layout: { layout }, windows: windows,
                                           screenRecordingGranted: { true }, clock: clock, rules: .provisional)

        _ = await collector.capture(.settingsOpened, read: read, concealed: [], isCurrent: { display, apps in asked.add(display); return StillCurrentAnswer(kept: apps) })

        #expect(asked.value == [World.display])
    }

    // MARK: One bar of two

    private let second = "D2"

    private func twoDisplays() -> (layout: DisplayLayout, windows: FakeWindowList, bars: [MenuBarGeometry]) {
        let main = World.displayLayout().displays[0]
        let other = DisplayInfo(uuid: second, name: "Other", frame: CGRect(x: 1000, y: 0, width: 1000, height: 800),
                                visibleFrame: CGRect(x: 1000, y: 0, width: 1000, height: 776), scale: 2, notch: nil, isBuiltIn: false,
                                isMain: false)
        let otherRect = CGRect(x: 1000, y: 0, width: 1000, height: 24)
        let windows = FakeWindowList([World.barWindow(),
                                      WindowInfo(number: 2, ownerPID: 50, ownerBundleID: nil, layer: WindowLevels.mainMenu, bounds: otherRect, alpha: 1)])
        let bars = [MenuBarGeometry(displayUUID: World.display, rect: World.barRect, notch: nil),
                    MenuBarGeometry(displayUUID: second, rect: otherRect, notch: nil)]
        return (DisplayLayout(displays: [main, other]), windows, bars)
    }

    /// The same item on both bars, each slot painted.
    private func capturingTwoBars(active: String?) async -> (CaptureSummary, FakeCapture) {
        let (layout, windows, bars) = twoDisplays()
        let slot = World.slot(0)
        let there = slot.offsetBy(dx: 1000, dy: 0)
        let item = MenuBarItem(id: a, ownerBundleID: "com.example.a", appName: nil, label: nil, frames: [World.display: slot, second: there],
                               overflowedOn: [], isMantel: false, strayFrames: [:], ownKind: nil)
        let read = Inventory(capturedAt: Date(timeIntervalSince1970: 0), bars: bars, items: [item], chevrons: [:], reach: [], problems: [],
                             activeDisplay: active)
        let capture = FakeCapture(clock: clock)
        capture.paint([slot, there])
        let collector = ItemImageCollector(store: store(), capture: capture, layout: { layout }, windows: windows,
                                           screenRecordingGranted: { true }, clock: clock, rules: .provisional)
        return (await collector.capture(.settingsOpened, read: read, concealed: []), capture)
    }

    @Test func onlyTheActiveDisplaysBarIsCaptured() async {
        let (summary, capture) = await capturingTwoBars(active: second)
        #expect(summary.captured == 1)
        #expect(capture.displays == [second])
    }

    @Test func theMainDisplaysBarIsCapturedWhenTheActiveOneCantBeTold() async {
        let (summary, capture) = await capturingTwoBars(active: nil)
        #expect(summary.captured == 1)
        #expect(capture.displays == [World.display], "one bar, so that two bars' pictures of an item don't replace each other")
        // An active display that has no bar here says nothing either.
        let (_, elsewhere) = await capturingTwoBars(active: "elsewhere")
        #expect(elsewhere.displays == [World.display])
    }

    @Test func aClickDrawnSlotIsCapturedFromTheBarTheClickWasOn() async {
        // The read has two bars and can't tell which is active, so the main display's would be the one chosen; the click was on the other.
        let (layout, windows, bars) = twoDisplays()
        let there = World.slot(0).offsetBy(dx: 1000, dy: 0)
        let item = MenuBarItem(id: a, ownerBundleID: "com.example.a", appName: nil, label: nil, frames: [second: there], overflowedOn: [],
                               isMantel: false, strayFrames: [:], ownKind: nil)
        let read = Inventory(capturedAt: Date(timeIntervalSince1970: 0), bars: bars, items: [item], chevrons: [:], reach: [], problems: [])
        let capture = FakeCapture(clock: clock)
        capture.paint([there])
        let collector = ItemImageCollector(store: store(), capture: capture, layout: { layout }, windows: windows,
                                           screenRecordingGranted: { true }, clock: clock, rules: .provisional)
        let clicked = ItemLocation(item: a, displayUUID: second, slotFrame: there, tiedBy: .tie, slotWasInBaseline: true, widthAgrees: true)

        let summary = await collector.capture(.clickDrawn(clicked), read: read, concealed: [])

        #expect(summary.captured == 1)
        #expect(capture.displays == [second])
    }

    private func location(of item: ItemID, slot: Int) -> ItemLocation {
        ItemLocation(item: item, displayUUID: World.display, slotFrame: World.slot(slot), tiedBy: .tie, slotWasInBaseline: true, widthAgrees: true)
    }
}

/// A clock that tells the time of another plus a skew a test can add, and sleeps on the other: time can pass for the one who asks the time
/// without any sleeper being woken.
private final class SkewedClock: Clock {
    private let inner: FakeClock
    private let skewed = Mutex<TimeInterval>(0)

    init(_ inner: FakeClock) { self.inner = inner }

    func skew(by seconds: TimeInterval) { skewed.withLock { $0 += seconds } }
    func now() -> Date { inner.now().addingTimeInterval(skewed.withLock { $0 }) }
    func sleep(for duration: Duration) async throws { try await inner.sleep(for: duration) }
}

private final class Asked: Sendable {
    private let displays = Mutex<[String]>([])

    var value: [String] { displays.withLock { $0 } }
    func add(_ display: String) { displays.withLock { $0.append(display) } }
}
