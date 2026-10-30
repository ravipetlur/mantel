import CoreGraphics
import Foundation
import MKCommands
import MKCore
import MKTestSupport
import Synchronization
import Testing

@testable import MKMenuBar

private let fixtureID = ProbeHarness.fixtureID
private let main = DisplayFixtures.deskMain.uuid
private let spacingKey = IconSpacing.spacingKey
private let paddingKey = IconSpacing.paddingKey

/// How wide the test item's items are drawn: what the preferences say when the test item is opened again.
private final class IconWidth: Sendable {
    let value: Mutex<CGFloat>

    init(_ width: CGFloat) { value = Mutex(width) }
    var current: CGFloat { value.withLock { $0 } }
    func set(_ width: CGFloat) { value.withLock { $0 = width } }
}

/// The test item's items are drawn in the main display's bar, each as wide as `width` says now, 60 points apart.
private func drawn(_ names: [String], in harness: ProbeHarness, width: IconWidth) {
    for (index, name) in names.enumerated() {
        let item = ItemID(bundleID: fixtureID, key: .identifier("mantel.fixture.\(name)"))
        let x = 3000 + CGFloat(index) * 60
        harness.locator.answer(for: item) { _ in
            FakeItemLocator.location(of: item, slot: CGRect(x: x, y: 0, width: width.current, height: 31))
        }
    }
}

/// What the spacing key held each time the test item was opened.
private final class SpacingWhenOpened: Sendable {
    let values = Mutex<[PlistValue?]>([])
    var all: [PlistValue?] { values.withLock { $0 } }
}

/// What opening the test item again does in the fake world: its items are as wide as the spacing says (Small makes them 10 narrower),
/// and the preferences are noted as they were when it was asked.
@discardableResult
private func opensWithTheSpacing(_ harness: ProbeHarness, width: IconWidth) -> SpacingWhenOpened {
    let preferences = harness.preferences
    let seen = SpacingWhenOpened()
    harness.relauncher.onRelaunch { _ in
        let spacing = preferences.held(spacingKey)
        seen.values.withLock { $0.append(spacing) }
        width.set(spacing == .integer(8) ? 30 : 40)
    }
    return seen
}

@Suite("Spacing probe", .timeLimit(.minutes(1)))
struct SpacingProbeTests {
    private func desk(width: CGFloat = 40) throws -> (harness: ProbeHarness, width: IconWidth) {
        let harness = try ProbeHarness.make()
        let widths = IconWidth(width)
        drawn(["one", "two"], in: harness, width: widths)
        return (harness, widths)
    }

    private func widthOf(_ report: ProbeReport, _ key: String, of name: String, on display: String = main) -> Double? {
        guard case .object(let displays)? = report.measurements[key], case .object(let one)? = displays[display],
              case .object(let items)? = one["testItem"], case .number(let width)? = items[name] else { return nil }
        return width
    }

    // MARK: Who is relaunched

    @Test func spacingRelaunchesOnlyTheTestItem() async throws {
        let (harness, width) = try desk()
        opensWithTheSpacing(harness, width: width)

        // The options name another app, and allow any: the probe still relaunches the test item alone, and opens it as it was.
        let report = await harness.run(.spacing, ["app": ProbeHarness.otherID, "allow-any": "true"])

        #expect(report.errors.isEmpty)
        let asked = harness.relauncher.asked
        #expect(asked.count == 2)
        #expect(asked.allSatisfy { $0.id == fixtureID && $0.pid == 300 && $0.name == "MantelTestItem" })
        #expect(asked.allSatisfy { $0.bundleURL == URL(filePath: "/Applications/MantelTestItem.app", directoryHint: .isDirectory) })
        #expect(asked.allSatisfy { $0.arguments.isEmpty }, "the plain test item has two items and takes no argument")
        #expect(harness.poster.clicks.isEmpty && harness.presser.pressed.isEmpty && harness.allowlist.calls.isEmpty)
    }

    @Test func theSecondRelaunchAsksForTheProcessTheTestItemIsNow() async throws {
        // Once the test item has been relaunched it is another process: asking the old one to quit finds nothing, and opening the app only
        // brings the new one forward, which draws the spacing it had.
        let processes = Mutex<pid_t>(300)
        let harness = try ProbeHarness.make { platform in
            let known = platform.runningApps
            platform.runningApps = {
                known().map { app in
                    app.bundleID == fixtureID
                        ? RunningApp(pid: processes.withLock { $0 }, bundleID: app.bundleID, name: app.name, bundleURL: app.bundleURL, isBackgroundOnly: false)
                        : app
                }
            }
        }
        let width = IconWidth(40)
        drawn(["one", "two"], in: harness, width: width)
        harness.relauncher.onRelaunch { _ in processes.withLock { $0 += 100 } }

        let report = await harness.run(.spacing)

        #expect(report.errors.isEmpty)
        #expect(harness.relauncher.asked.map(\.pid) == [300, 400], "the second is asked for the process the first one made")
        #expect(harness.relauncher.asked.allSatisfy { $0.id == fixtureID })
    }

    @Test func theTestItemIsOpenedAgainWithTheItemsItHas() async throws {
        let (harness, width) = try desk()
        // Four items: two and two extras.
        harness.ax.addApp(pid: 300, extras: (0..<4).map { index in
            .init(title: "item \(index)", frame: CGRect(x: 3000 + CGFloat(index) * 60, y: 0, width: 40, height: 31))
        })
        drawn(["one", "two", "extra.1", "extra.2"], in: harness, width: width)

        let report = await harness.run(.spacing)

        #expect(report.errors.isEmpty)
        #expect(harness.relauncher.asked.map(\.arguments) == [["--extra", "2"], ["--extra", "2"]])
        #expect(report.measurements["testItemItems"] == .number(4))

        // And one item opens as `--single`.
        let single = try ProbeHarness.make()
        single.ax.addApp(pid: 300, extras: [.init(title: "one", frame: CGRect(x: 3000, y: 0, width: 40, height: 31))])
        drawn(["one"], in: single, width: IconWidth(40))
        _ = await single.run(.spacing)
        #expect(single.relauncher.asked.map(\.arguments) == [["--single"], ["--single"]])
    }

    @Test func theTestItemMustBeRunningAndHaveAnApp() async throws {
        let notRunning = try ProbeHarness.make { platform in
            let known = platform.runningApps
            platform.runningApps = { known().filter { $0.bundleID != fixtureID } }
        }
        let report = await notRunning.run(.spacing)
        #expect(report.errors == ["MantelTestItem isn't running, or has no items in the menu bar. Open it first."])
        #expect(notRunning.relauncher.asked.isEmpty && notRunning.preferences.writes.isEmpty)

        let noApp = try ProbeHarness.make { platform in
            let known = platform.runningApps
            platform.runningApps = {
                known().map { $0.bundleID == fixtureID ? RunningApp(pid: $0.pid, bundleID: $0.bundleID, name: $0.name, bundleURL: nil, isBackgroundOnly: false) : $0 }
            }
        }
        let missing = await noApp.run(.spacing)
        #expect(missing.errors == ["MantelTestItem has no app to open again. Open it from /Applications first."])
        #expect(noApp.preferences.writes.isEmpty, "nothing was changed")
    }

    // MARK: What it changes and puts back

    @Test func spacingWritesSmallToTheGlobalPreferencesForThisMac() async throws {
        let (harness, width) = try desk()
        opensWithTheSpacing(harness, width: width)

        let report = await harness.run(.spacing)

        #expect(report.errors.isEmpty)
        let writes = harness.preferences.writes
        #expect(writes.filter { $0.value != nil }.map(\.key).sorted() == [paddingKey, spacingKey])
        #expect(writes.allSatisfy { $0.domain == .globalCurrentHost })
        #expect(writes.first { $0.key == spacingKey }?.value == .integer(8), "Small is 8 and 8")
        #expect(writes.first { $0.key == paddingKey }?.value == .integer(8))
    }

    @Test func spacingUndoesAndRelaunchesAgain() async throws {
        let (harness, width) = try desk()
        let seen = opensWithTheSpacing(harness, width: width)
        harness.preferences.change(spacingKey, to: .integer(10))
        harness.preferences.change(paddingKey, to: .integer(12))

        let report = await harness.run(.spacing)

        #expect(report.errors.isEmpty)
        #expect(report.restored)
        #expect(seen.all == [.integer(8), .integer(10)], "Small when it was opened the first time; what it was the second")
        #expect(harness.preferences.held(spacingKey) == .integer(10))
        #expect(harness.preferences.held(paddingKey) == .integer(12))
        #expect(await harness.journal.records().isEmpty, "and nothing is left in the journal")
        #expect(harness.relauncher.asked.count == 2)
        #expect(report.measurements["restoredWidthsMatch"] == .bool(true))
        #expect(report.strings("relaunches") == ["relaunched", "relaunched"])
    }

    @Test func keysThatWereNotThereAreRemovedAgain() async throws {
        let (harness, width) = try desk()
        opensWithTheSpacing(harness, width: width)
        let report = await harness.run(.spacing)
        #expect(report.restored)
        #expect(harness.preferences.held(spacingKey) == nil)
        #expect(harness.preferences.held(paddingKey) == nil)
        #expect(report.measurements["before"] == .object(["spacing": .null, "padding": .null]), "absent is null")
    }

    @Test func beforeIsWhatTheKeysHold() async throws {
        let (harness, _) = try desk()
        harness.preferences.change(spacingKey, to: .integer(10))
        harness.preferences.change(paddingKey, to: .string("12"))
        let report = await harness.run(.spacing)
        #expect(report.measurements["before"] == .object(["spacing": .number(10), "padding": .number(12)]), "a number that is text is the number")
    }

    @Test func aTestItemThatDoesNotQuitIsNotForcedAndTheSpacingIsPutBackAllTheSame() async throws {
        let (harness, width) = try desk()
        opensWithTheSpacing(harness, width: width)
        harness.relauncher.respond(with: .didNotQuit)

        let report = await harness.run(.spacing)

        #expect(report.restored)
        #expect(harness.preferences.held(spacingKey) == nil)
        #expect(report.strings("relaunches") == ["didNotQuit", "didNotQuit"])
        #expect(report.notes.contains { $0.contains("didn't relaunch") })
        #expect(harness.relauncher.asked.count == 2, "asked twice, never more: nothing is forced")
    }

    @Test func spacingAlreadySmallCantBeMeasured() async throws {
        let (harness, _) = try desk()
        harness.preferences.change(spacingKey, to: .integer(8))
        harness.preferences.change(paddingKey, to: .integer(8))
        let report = await harness.run(.spacing)
        #expect(report.errors == ["The icon spacing is Small already, so a change to it can't be measured. Set it to something else first."])
        #expect(harness.relauncher.asked.isEmpty && harness.preferences.writes.isEmpty)
    }

    @Test func spacingMantelKeepsIsNotChanged() async throws {
        let (harness, _) = try desk()
        // The person set the spacing in Settings: a change that is kept.
        try await harness.defaults.write(.integer(4), forKey: spacingKey, in: .globalCurrentHost, lifetime: .kept)
        let writesBefore = harness.preferences.writes.count

        let report = await harness.run(.spacing)

        #expect(report.errors == ["Mantel keeps the icon spacing it was given in Settings, so this probe won't change it. Use Restore original spacing first."])
        #expect(harness.preferences.writes.count == writesBefore, "nothing was written")
        #expect(harness.preferences.held(spacingKey) == .integer(4))
        #expect(harness.relauncher.asked.isEmpty)
        #expect(await harness.journal.keptRecords().count == 1, "and what is kept is kept")
    }

    @Test func aChangeThePreferencesDontKeepIsAnErrorAndNothingIsRelaunched() async throws {
        let (harness, _) = try desk()
        harness.preferences.behave(.refuses, forKey: spacingKey)
        let report = await harness.run(.spacing)
        #expect(report.errors.count == 1 && report.errors[0].contains("NSStatusItemSpacing"))
        #expect(harness.relauncher.asked.isEmpty)
        #expect(await harness.journal.records().isEmpty)
        #expect(report.restored)
    }

    @Test func cutShortItIsPutBack() async throws {
        let clock = FakeClock()
        let harness = try ProbeHarness.make(clock: clock)
        let width = IconWidth(40)
        drawn(["one", "two"], in: harness, width: width)
        // The items are slow to come back after the test item is opened: the probe waits on its clock.
        let preferences = harness.preferences
        harness.locator.answer(for: ItemID(bundleID: fixtureID, key: .identifier("mantel.fixture.one"))) { _ in
            preferences.held(spacingKey) == nil
                ? FakeItemLocator.location(of: ItemID(bundleID: fixtureID, key: .identifier("mantel.fixture.one")),
                                           slot: CGRect(x: 3000, y: 0, width: 40, height: 31))
                : nil
        }
        let running = Task { await harness.run(.spacing) }
        await clock.waitForSleepers(1)
        #expect(harness.preferences.held(spacingKey) == .integer(8), "the probe is waiting with Small written")
        // What it wrote is a temporary change: put back on quit.
        let records = await harness.journal.records()
        #expect(records.count == 2 && records.allSatisfy { $0.lifetime == .untilQuit })
        #expect(await harness.journal.keptRecords().isEmpty)

        await harness.runner.shutDown()
        let report = await running.value

        #expect(harness.preferences.held(spacingKey) == nil, "put back")
        #expect(report.restored)
        #expect(report.notes.contains { $0.contains("cut short") })
        #expect(await harness.journal.records().isEmpty)
        #expect(harness.relauncher.asked.count == 1, "and the test item isn't opened a second time while the probe is being stopped")
    }

    // MARK: What it measures

    @Test func widthsAreMeasuredBeforeAfterAndAfterTheRestore() async throws {
        let (harness, width) = try desk()
        opensWithTheSpacing(harness, width: width)

        let report = await harness.run(.spacing)

        #expect(widthOf(report, "widthsBefore", of: "one") == 40)
        #expect(widthOf(report, "widthsBefore", of: "two") == 40)
        #expect(widthOf(report, "widthsAfter", of: "one") == 30, "Small makes them 10 narrower in this world")
        #expect(widthOf(report, "widthsRestored", of: "one") == 40)
        let deltas = try #require(report.object("testItemWidthDeltas"))
        #expect(deltas[main] == .object(["one": .number(-10), "two": .number(-10)]))
        #expect(report.measurements["smallestShrink"] == .number(10))
        #expect(report.measurements["restoredWidthsMatch"] == .bool(true))
        #expect(report.measurements["systemChanged"] == .bool(false), "the clock is as wide as it was")
        // The clock is measured on the display that has one.
        guard case .object(let before)? = report.measurements["widthsBefore"], case .object(let onMain)? = before[main] else {
            Issue.record("widthsBefore has the main display")
            return
        }
        #expect(onMain["clock"] == .number(50))
    }

    @Test func anItemThatIsNotThereAfterwardsIsNotCompared() async throws {
        let (harness, width) = try desk()
        opensWithTheSpacing(harness, width: width)
        // Item two never comes back.
        let two = ItemID(bundleID: fixtureID, key: .identifier("mantel.fixture.two"))
        let preferences = harness.preferences
        harness.locator.answer(for: two) { _ in
            preferences.held(spacingKey) == nil ? FakeItemLocator.location(of: two, slot: CGRect(x: 3060, y: 0, width: 40, height: 31)) : nil
        }

        let report = await harness.run(.spacing)

        let deltas = try #require(report.object("testItemWidthDeltas"))
        #expect(deltas[main] == .object(["one": .number(-10)]))
        #expect(report.notes.contains { $0.contains("within 5 s") })
    }

    @Test func aWidthThatDoesNotComeBackIsNotAMatch() async throws {
        let (harness, width) = try desk()
        harness.relauncher.onRelaunch { _ in width.set(width.current == 40 ? 30 : 36) }

        let report = await harness.run(.spacing)

        #expect(report.measurements["restoredWidthsMatch"] == .bool(false), "36 is 4 points from 40")
    }

    @Test func theClockChangingWhileOnlyTheTestItemWasRelaunchedIsReported() async throws {
        let (harness, width) = try desk()
        let ax = harness.ax
        let clockSlot = harness.clockSlot
        harness.relauncher.onRelaunch { _ in
            width.set(30)
            ax.setAttribute(AXName.size, .size(CGSize(width: 56, height: 31)), on: clockSlot)
        }
        let report = await harness.run(.spacing)
        #expect(report.measurements["systemChanged"] == .bool(true))
    }

    @Test func nothingBelongingToAnyoneElseIsReadOrChanged() async throws {
        let (harness, width) = try desk()
        opensWithTheSpacing(harness, width: width)
        _ = await harness.run(.spacing)
        #expect(harness.preferences.writes.allSatisfy { $0.domain == .globalCurrentHost && [spacingKey, paddingKey].contains($0.key) })
        #expect(harness.locator.calls.allSatisfy { $0.item.bundleID == fixtureID }, "only the test item's items are looked for")
    }
}
