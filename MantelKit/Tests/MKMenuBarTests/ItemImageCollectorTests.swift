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

    // MARK: A strip of another moment

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
