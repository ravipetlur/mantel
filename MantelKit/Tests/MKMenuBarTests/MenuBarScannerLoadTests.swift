import CoreGraphics
import Foundation
import MKCore
import MKTestSupport
import Synchronization
import Testing

@testable import MKMenuBar

/// The scanner on a busy Mac: apps and MenuBarAgent that answer late (or not at all), on slow fakes whose time is the test's clock.
@Suite("Menu bar scanner under load", .timeLimit(.minutes(1)))
struct MenuBarScannerLoadTests {
    private let weather = InventoryFixtures.weather
    private let notes = InventoryFixtures.notes

    private struct Rig {
        let fixture = InventoryFixtures.desk()
        let clock = FakeClock()
        let slow: SlowAX
        let scanner: MenuBarScanner

        init(patient: Bool, patience: AXPatience = .standard) {
            let fixture = fixture
            let clock = clock
            slow = SlowAX(fixture.ax, clock: clock)
            let ax: any AXReading = patient
                ? PatientAX(inner: slow, patience: patience, clock: clock, pidOf: { [tree = fixture.ax] in tree.ownerPID(of: $0) ?? 0 })
                : slow
            let layout = fixture.layout
            scanner = MenuBarScanner(ax: ax, extrasReader: AXAppExtrasReader(reader: AppExtrasReader(ax: ax)), runningApps: { fixture.running },
                                     layout: { layout }, ownBundleID: InventoryFixtures.ownBundleID, isTrusted: { true }, clock: clock,
                                     patience: patience, readLimit: 8)
        }

        func pid(_ bundleID: String) -> pid_t { fixture.pid(of: bundleID)! }
    }

    @Test func anAppThatAnswersLateIsReadOnABusyMac() async {
        // The weather app's first answer takes 0.6 s: more than the quarter of a second every query used to wait.
        let plain = Rig(patient: false)
        plain.slow.setDelay(0.6, for: plain.pid(weather), forCalls: 1)
        let lost = await plain.scanner.scan()
        #expect(lost.unansweredApps.contains(weather), "as it was: the app is taken for one that didn't answer")
        #expect(!lost.items.contains { $0.ownerBundleID == weather })

        let busy = Rig(patient: true)
        busy.slow.setDelay(0.6, for: busy.pid(weather), forCalls: 1)
        let read = await busy.scanner.scan()
        #expect(!read.unansweredApps.contains(weather))
        #expect(read.items.contains { $0.ownerBundleID == weather }, "its items are in the read")
        #expect(busy.slow.calls(to: busy.pid(weather)).prefix(2).map(\.wait) == [0.25, 1], "asked again with a longer wait")
    }

    @Test func aReadWithNoBarIsTakenAgainBeforeAnythingActsOnIt() async throws {
        let rig = Rig(patient: true)
        let agent = rig.pid(MenuBarReader.menuBarAgentBundleID)
        rig.slow.hang(agent)
        let scanner = rig.scanner
        let scanning = Task { await scanner.scan() }

        // The first read found no window; MenuBarAgent is asked again after a short wait.
        #expect(await rig.clock.waitForSleepers(1, within: .seconds(5)))
        rig.slow.release(agent)
        rig.clock.advance(by: .milliseconds(250))
        let read = await scanning.value

        #expect(!read.bars.isEmpty, "the second try had the bar")
        #expect(read.problems.isEmpty)
        #expect(read.agentAnswered)
        #expect(await scanner.agentFailureStreak == 0, "an empty read that was made good isn't a failure")
    }

    @Test func quittingEndsTheWaitingOfReadsThatAreUnderWay() async {
        let rig = Rig(patient: true)
        rig.scanner.stopWaiting()
        #expect(rig.slow.stopWaitingCalls == 1)
    }

    // MARK: MenuBarAgent that is late

    // MARK: One app that hangs, on a Mac that isn't busy

    @Test func oneAppThatHangsCostsAClickOnAnotherAppsIconAQuarterOfASecondAndNotItsLadder() async throws {
        let rig = Rig(patient: true)
        let hung = rig.pid(notes)
        let item = ItemID(bundleID: weather, key: .identifier("weather.temp"))
        // Every app answers once, as on a Mac that isn't busy; then the notes app, which has an icon on the bar, hangs.
        _ = await rig.scanner.scan()
        rig.slow.hang(hung)
        let before = rig.slow.calls.count
        let began = rig.clock.now()

        _ = await rig.scanner.locate(item, on: nil, since: nil)

        let asked = rig.slow.calls.dropFirst(before).filter { $0.pid == hung }.map(\.wait)
        #expect(!asked.isEmpty, "it is asked, as a bystander whose frames claim slots")
        #expect(Set(asked) == [0.25], "with the first wait only, not 0.25, 1 and 2")
        #expect(rig.clock.now().timeIntervalSince(began) < 1, "so the click isn't held up by it")
    }

    // MARK: A read's own time

    @Test func aReadAskedForWithinAScopeHasNoMoreThanWhatIsLeftOfIt() async {
        let rig = Rig(patient: true)
        let hung = rig.pid(notes)
        _ = await rig.scanner.scan()
        rig.slow.hang(hung)
        let outer = AXReadScope(budget: 0.3, perAppBudget: 4, clock: rig.clock)
        let began = rig.clock.now()

        let frames = await AXReadScope.run(outer) { await rig.scanner.itemFrames(ofApps: [notes]) }

        #expect(frames[notes] == nil)
        #expect(rig.clock.now().timeIntervalSince(began) <= 0.6, "the check's own four seconds were cut to what the round had")
    }
}
