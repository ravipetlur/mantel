import CoreGraphics
import Foundation
import ImageIO
import MKCommands
import MKCore
import MKLayout
import MKTestSupport
import Synchronization
import Testing

@testable import MKMenuBar

private let fixtureID = ProbeHarness.fixtureID
private let ownID = ProbeHarness.ownBundleID
private let otherID = ProbeHarness.otherID

private func decodeSnapshot(_ url: URL) throws -> MenuBarSnapshot {
    try JSONCoding.decoder().decode(MenuBarSnapshot.self, from: Data(contentsOf: url))
}

// MARK: Inventory probe

@Suite("Inventory probe", .timeLimit(.minutes(1)))
struct InventoryProbeTests {
    @Test func theInventoryRecordsWhereTheFrontAppsMenusAre() async throws {
        // The front app (process 301 in the harness) has three menus. Their frames go in the snapshot file, so that a later replay can tell
        // which icons are under them; only frames, never a name.
        let harness = try ProbeHarness.make(configure: { $0.frontAppPID = { 301 } })
        let bar = harness.ax.addNode(attributes: [AXName.role: .string("AXMenuBar")])
        let menus = [CGRect(x: 0, y: 0, width: 30, height: 31), CGRect(x: 30, y: 0, width: 60, height: 31), CGRect(x: 90, y: 0, width: 50, height: 31)]
        for frame in menus { harness.ax.addNode(attributes: FakeAX.frameAttributes(frame), under: bar) }
        harness.ax.setAttribute(AXName.menuBar, .elements([harness.ax.ref(bar)]), on: harness.ax.root(ofApp: 301))

        let report = await harness.run(.inventory)
        #expect(report.errors.isEmpty)
        #expect(report.measurements["frontMenuFrames"] == .number(3))
        let file = try #require(harness.probeFiles().first { $0.hasSuffix("-snapshot.json") })
        let data = try Data(contentsOf: harness.probesFolder.appendingPathComponent(file))
        let snapshot = try JSONCoding.decoder().decode(MenuBarSnapshot.self, from: data)
        #expect(snapshot.frontMenuFrames == menus)
        // The menus rule can be replayed from it.
        #expect(BarRegion.drawnFrom(bar: MenuBarGeometry(displayUUID: "d", rect: CGRect(x: 0, y: 0, width: 3000, height: 31), notch: nil),
                                    menuFrames: snapshot.frontMenuFrames) == 140)
    }

    @Test func aSnapshotFromBeforeTheMenusWereKeptStillDecodes() throws {
        let snapshot = MenuBarSnapshot(capturedAt: Date(timeIntervalSince1970: 0), layout: .desk, agentWindows: [], apps: [], rawAgentTree: nil)
        #expect(snapshot.frontMenuFrames.isEmpty)
        let encoded = try JSONCoding.encoder().encode(snapshot)
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["frontMenuFrames"] = nil
        let old = try JSONCoding.decoder().decode(MenuBarSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.frontMenuFrames.isEmpty)
    }

    @Test func withNoFrontAppNothingIsRecorded() async throws {
        let harness = try ProbeHarness.make()
        let report = await harness.run(.inventory)
        #expect(report.measurements["frontMenuFrames"] == .number(0))
    }

    /// Mantel's slot is the first dot's, by what it is called for the accessibility tools.
    private func dotSlot(_ harness: ProbeHarness) throws -> Int {
        let slot = try #require(harness.slotOwners.first { $0.value == ownID }?.key)
        harness.ax.setAttribute(AXName.description, .string(DotsCopy.hiddenDotDescription), on: slot)
        return slot
    }

    @Test func ownFrameMatchesSlotPerDisplay() async throws {
        // The dot's button is 26 wide in a slot that is 30 wide (x 3000), on the main display: the middle of the frame is in the slot.
        let inside = CGRect(x: 3002, y: 2, width: 26, height: 27)
        let harness = try ProbeHarness.make { platform in
            platform.ownItemFrames = { [DotsCopy.hiddenDotName: inside] }
        }
        _ = try dotSlot(harness)

        let report = await harness.run(.inventory)

        #expect(report.errors.isEmpty)
        #expect(report.measurements["ownItemFrames"] == .object([DotsCopy.hiddenDotName: NotchCoordinatesProbe.rect(inside)]))
        let main = DisplayFixtures.deskMain.uuid
        #expect(report.object("ownFrameMatchesSlot")?[main] == .object([DotsCopy.hiddenDotName: .bool(true)]))
        // The portrait display has no bar in the harness: nothing is said of it.
        #expect(report.object("ownFrameMatchesSlot")?[DisplayFixtures.deskPortrait.uuid] == nil)

        // A frame somewhere else is not in the slot.
        let elsewhere = try ProbeHarness.make { platform in
            platform.ownItemFrames = { [DotsCopy.hiddenDotName: CGRect(x: 1500, y: 2, width: 26, height: 27)] }
        }
        _ = try dotSlot(elsewhere)
        let apart = await elsewhere.run(.inventory)
        #expect(apart.object("ownFrameMatchesSlot")?[main] == .object([DotsCopy.hiddenDotName: .bool(false)]))
    }

    @Test func anOwnItemWithNoSlotOnADisplayIsNull() async throws {
        // The second dot isn't in the bar: there is no slot of it to be in.
        let harness = try ProbeHarness.make { platform in
            platform.ownItemFrames = {
                [DotsCopy.hiddenDotName: CGRect(x: 3002, y: 2, width: 26, height: 27), DotsCopy.alwaysDotName: CGRect(x: 2000, y: 2, width: 26, height: 27)]
            }
        }
        _ = try dotSlot(harness)
        let report = await harness.run(.inventory)
        let main = DisplayFixtures.deskMain.uuid
        #expect(report.object("ownFrameMatchesSlot")?[main]
                == .object([DotsCopy.hiddenDotName: .bool(true), DotsCopy.alwaysDotName: .null]))
    }

    @Test func withNoOwnItemsNothingIsRecordedOfThem() async throws {
        let harness = try ProbeHarness.make()
        let report = await harness.run(.inventory)
        #expect(report.measurements["ownItemFrames"] == .object([:]))
        #expect(report.object("ownFrameMatchesSlot")?[DisplayFixtures.deskMain.uuid] == .object([:]))
    }
}

// MARK: Allowlist probes

@Suite("Allowlist probes", .timeLimit(.minutes(1)))
struct AllowlistProbeTests {
    @Test func allowlistInfoRecordsWhatTheShimFound() async throws {
        let harness = try ProbeHarness.make()
        let report = await harness.run(.allowlistInfo)
        #expect(report.errors.isEmpty)
        #expect(report.bool("frameworkLoaded") == true)
        #expect(report.object("classes") == ["MBAssessmentModeAssertion": .bool(true), "MBAssessmentModeConfiguration": .bool(true)])
        #expect(report.object("encodings")?["invalidate"] == .string("v16@0:8"))
        #expect(report.measurements["problem"] == .null)
        #expect(report.restored)
        #expect(harness.allowlist.calls.isEmpty, "inspecting never activates")
    }

    @Test func allowlistInfoSaysWhatIsWrong() async throws {
        let harness = try ProbeHarness.make()
        harness.allowlist.setInspection(AllowlistInspection(
            frameworkLoaded: true, configurationClassFound: true, assertionClassFound: true,
            encodings: ["invalidate": "v24@0:8@16"], problem: "invalidate has encoding \"v24@0:8@16\" where Mantel expects \"v16@0:8\""))
        let report = await harness.run(.allowlistInfo)
        #expect(report.measurements["problem"] == .string("invalidate has encoding \"v24@0:8@16\" where Mantel expects \"v16@0:8\""))
        #expect(report.notes.contains { $0.contains("v24@0:8@16") })
    }

    @Test func activateHidesTheTestItemAndPutsItBack() async throws {
        let harness = try ProbeHarness.make()
        let report = await harness.run(.allowlistActivate)

        #expect(report.errors.isEmpty)
        #expect(report.restored)
        // The allowlist is everything running except what is to be hidden, which is the test item and nothing else: Mantel's
        // own item is always on it. System items are 0 to 255.
        let call = try #require(harness.allowlist.calls.first)
        #expect(call.bundleIDs == ["com.apple.MenuBarAgent", ownID, otherID])
        #expect(report.strings("concealedApps") == [fixtureID])
        #expect(call.systemItems == Array(0...255))

        #expect(report.number("activateToCompletionMs") != nil)
        #expect(report.number("activateToVisibleChangeMs") != nil)
        #expect(report.number("activateToFrameChangeMs") != nil)
        #expect(report.number("invalidateToRestoreMs") != nil)
        #expect(report.bool("restored") == true)
        let concealed = try #require(report.strings("concealedSlots"))
        // By the IDs the matcher gives the items, not by where a slot happened to be listed.
        #expect(Set(concealed) == ["\(fixtureID)::one", "\(fixtureID)::two"])

        #expect(harness.allowlist.invalidations == 1)
        #expect(harness.allowlist.live == 0)
        #expect(harness.hidden.all.isEmpty)
    }

    @Test func theHoldIsTakenFromTheOptionAndKeptBetweenOneAndThirty() async throws {
        let long = try ProbeHarness.make()
        let report = await long.run(.allowlistActivate, ["hold": "100"])
        #expect(report.durationMs >= 30_000)
        #expect(report.durationMs < 40_000)

        let short = try ProbeHarness.make()
        let quick = await short.run(.allowlistActivate, ["hold": "0"])
        #expect(quick.durationMs >= 1000)
        #expect(quick.durationMs < 10_000)
    }

    @Test func theSystemItemsAndTheAppsComeFromTheOptions() async throws {
        // Hiding system items is for --allow-any; the apps are the test item's.
        let harness = try ProbeHarness.make()
        let report = await harness.run(.allowlistActivate, ["system-items": "2,5-6", "apps": "\(fixtureID)", "allow-any": "true"])
        #expect(report.errors.isEmpty)
        let call = try #require(harness.allowlist.calls.first)
        #expect(call.systemItems == [2, 5, 6])
        #expect(call.bundleIDs == ["com.apple.MenuBarAgent", ownID, otherID], "only the test item is hidden")
    }

    @Test func hidingSystemItemsNeedsAllowAny() async throws {
        let harness = try ProbeHarness.make()
        let refused = await harness.run(.allowlistActivate, ["system-items": "2,5"])
        #expect(refused.errors == ["This probe only hides MantelTestItem. Add --allow-any to hide system items."])
        #expect(refused.restored)
        let one = await harness.run(.allowlistActivate, ["system-items": "1-255"])
        #expect(one.errors == ["This probe only hides MantelTestItem. Add --allow-any to hide system items."], "one short of all of them")
        #expect(harness.allowlist.calls.isEmpty)

        // Every system item allowed hides none of them, so that needs nothing.
        let all = await harness.run(.allowlistActivate, ["system-items": "0-255"])
        #expect(all.errors.isEmpty)
        let more = await harness.run(.allowlistActivate, ["system-items": "0-300"])
        #expect(more.errors.isEmpty)
        #expect(harness.allowlist.calls.count == 2)
    }

    @Test func anAllowlistNamesEveryRunningAppIncludingTheOnesWithoutAMenuBarPresence() async throws {
        // A background-only app has no policy that shows an item, but its status items (if it makes any) would be concealed by
        // an allowlist that left it out.
        let harness = try ProbeHarness.make { platform in
            let known = platform.runningApps
            platform.runningApps = { known() + [.fake(500, "com.example.daemon", "Daemon", backgroundOnly: true)] }
        }
        let report = await harness.run(.allowlistActivate)
        #expect(report.errors.isEmpty)
        let call = try #require(harness.allowlist.calls.first)
        #expect(call.bundleIDs == ["com.apple.MenuBarAgent", ownID, otherID, "com.example.daemon"])
    }

    // MARK: Nothing to hide

    /// The platform with the test item not running.
    private func withoutTheTestItemRunning(_ platform: inout ProbePlatform) {
        let known = platform.runningApps
        platform.runningApps = { known().filter { $0.bundleID != fixtureID } }
    }

    @Test func nothingIsActivatedWhenTheTestItemIsNotRunning() async throws {
        // Every system item the allowlist conceals (the microphone and camera indicators, Now Playing, Focus) would be hidden for
        // the hold, and for nothing: the app that was to be hidden isn't there.
        let harness = try ProbeHarness.make(configure: withoutTheTestItemRunning)
        let report = await harness.run(.allowlistActivate)
        #expect(report.errors == ["Nothing to hide: \(fixtureID) isn't running. Open MantelTestItem first."])
        #expect(report.restored)
        #expect(report.measurements.isEmpty)
        #expect(harness.allowlist.calls.isEmpty, "nothing was activated")
        #expect(harness.allowlist.live == 0)
    }

    @Test func nothingIsActivatedWhenNoneOfTheAppsToHideIsRunning() async throws {
        let harness = try ProbeHarness.make()
        let report = await harness.run(.allowlistActivate, ["apps": "com.example.gone,com.example.also-gone", "allow-any": "true"])
        #expect(report.errors == ["Nothing to hide: com.example.gone, com.example.also-gone aren't running. Open them first."])
        #expect(harness.allowlist.calls.isEmpty)
    }

    @Test func oneAppToHideThatIsRunningIsEnough() async throws {
        let harness = try ProbeHarness.make()
        let report = await harness.run(.allowlistActivate, ["apps": "com.example.gone,\(otherID)", "allow-any": "true"])
        #expect(report.errors.isEmpty)
        #expect(harness.allowlist.calls.count == 1)
        #expect(report.strings("concealedApps") == ["com.example.gone", otherID])
    }

    @Test func theRefusalSaysWhatToOpen() {
        let nothing: [RunningApp] = []
        #expect(AllowlistSupport.nothingToHide([fixtureID], running: nothing, fixture: fixtureID)
                == "Nothing to hide: \(fixtureID) isn't running. Open MantelTestItem first.")
        #expect(AllowlistSupport.nothingToHide(["com.apple.Safari"], running: nothing, fixture: fixtureID)
                == "Nothing to hide: com.apple.Safari isn't running. Open it first.")
        #expect(AllowlistSupport.nothingToHide(["a.b", "c.d"], running: nothing, fixture: fixtureID)
                == "Nothing to hide: a.b, c.d aren't running. Open them first.")
        let running: [RunningApp] = [.fake(1, "c.d"), .fake(2, nil, "x")]
        #expect(AllowlistSupport.nothingToHide(["a.b", "c.d"], running: running, fixture: fixtureID) == nil)
    }

    @Test func theCheckComesAfterTheSafetyRulesAndBeforeAnythingIsRead() async throws {
        // Another app without --allow-any is refused for that, not for not running.
        let harness = try ProbeHarness.make()
        let report = await harness.run(.allowlistActivate, ["apps": "com.apple.Safari"])
        #expect(report.errors == ["This probe only touches MantelTestItem. Add --allow-any to touch com.apple.Safari."])
    }

    @Test func anotherAppIsRefusedWithoutAllowAnyAndNothingIsActivated() async throws {
        let harness = try ProbeHarness.make()
        let report = await harness.run(.allowlistActivate, ["apps": "com.apple.Safari"])
        #expect(report.errors == ["This probe only touches MantelTestItem. Add --allow-any to touch com.apple.Safari."])
        #expect(report.restored)
        #expect(harness.allowlist.calls.isEmpty)
    }

    @Test func mantelsOwnItemCanNotBeHiddenWhateverTheOptionsSay() async throws {
        let harness = try ProbeHarness.make()
        // Named with the test item: only the test item is hidden, and Mantel's own ID stays on the allowlist.
        let report = await harness.run(.allowlistActivate, ["apps": "\(ownID),\(fixtureID)", "allow-any": "true"])
        #expect(report.errors.isEmpty)
        #expect(report.notes.contains { $0.contains("Mantel's own item is never hidden") })
        #expect(report.strings("concealedApps") == [fixtureID])
        let call = try #require(harness.allowlist.calls.first)
        #expect(call.bundleIDs.contains(ownID))
        #expect(!(report.strings("concealedSlots") ?? []).contains("\(ownID)::\(ownID).dot"))
    }

    @Test func mantelsOwnIDAloneLeavesNothingToHideAndNothingIsActivated() async throws {
        for options in [["apps": ownID], ["apps": ownID, "allow-any": "true"]] {
            let harness = try ProbeHarness.make()
            let report = await harness.run(.allowlistActivate, options)
            #expect(report.errors == ["There is nothing to hide: Mantel's own item is never hidden by a probe."])
            #expect(report.restored)
            #expect(harness.allowlist.calls.isEmpty)
        }
    }

    @Test func anAppThatLaunchesDuringTheHoldIsNotAFailureToRestore() async throws {
        let harness = try ProbeHarness.make()
        let ax = harness.ax
        let window = harness.window
        harness.allowlist.onActivated {
            ax.addSlot(in: window, identifier: "com.example.newcomer.item", frame: CGRect(x: 2900, y: 0, width: 40, height: 31))
        }
        let report = await harness.run(.allowlistActivate)
        #expect(report.restored)
        #expect(report.bool("restored") == true)
        #expect(report.errors.isEmpty)
    }

    @Test func anAppThatQuitsDuringTheHoldIsNotAFailureToRestore() async throws {
        let harness = try ProbeHarness.make()
        let quit = harness.otherQuit
        harness.allowlist.onActivated { quit.set(true) }
        let report = await harness.run(.allowlistActivate)
        #expect(report.restored)
        #expect(report.bool("restored") == true)
        #expect(report.errors.isEmpty)
    }

    @Test func aSystemSlotThatDoesntComeBackIsStillAFailureToRestore() async throws {
        // The subset rule forgives apps that came and went, not what was there before and belongs to nobody who left: the
        // clock's slot is lost for good once the allowlist is live.
        let harness = try ProbeHarness.make()
        let clockSlot = harness.clockSlot
        let clockGone = Switch(false)
        harness.allowlist.onActivated { clockGone.set(true) }
        harness.ax.setOverride { id, name in
            guard id == clockSlot, name == AXName.position, clockGone.isOn else { return nil }
            return .failure(.noValue)
        }
        let report = await harness.run(.allowlistActivate)
        #expect(!report.restored)
        #expect(report.errors.contains { $0.contains("didn't come back") })
    }

    @Test func allowAnyLetsItHideAnotherApp() async throws {
        let harness = try ProbeHarness.make()
        let report = await harness.run(.allowlistActivate, ["apps": otherID, "allow-any": "true"])
        #expect(report.errors.isEmpty)
        let call = try #require(harness.allowlist.calls.first)
        #expect(!call.bundleIDs.contains(otherID))
        #expect(Set(try #require(report.strings("concealedSlots"))) == ["\(otherID)::\(otherID).item"])
    }

    @Test func aProblemWithTheAllowlistStopsBeforeAnythingIsCalled() async throws {
        let harness = try ProbeHarness.make()
        harness.allowlist.setInspection(AllowlistInspection(
            frameworkLoaded: true, configurationClassFound: true, assertionClassFound: false, encodings: [:], problem: "gone"))
        let report = await harness.run(.allowlistActivate)
        #expect(report.errors.contains { $0.contains("gone") })
        #expect(harness.allowlist.calls.isEmpty)
        #expect(report.restored)
    }

    @Test func anActivationThatFailsIsReportedAndLeavesNothingLive() async throws {
        let harness = try ProbeHarness.make()
        harness.allowlist.fail(with: .failed("macOS said no"))
        let report = await harness.run(.allowlistActivate)
        #expect(report.errors.contains { $0.contains("macOS said no") })
        #expect(report.restored)
        #expect(harness.allowlist.live == 0)
    }

    @Test func aMenuBarThatDoesntComeBackIsReportedAsNotRestored() async throws {
        let harness = try ProbeHarness.make()
        harness.allowlist.makeReleaseNotRestore()
        let report = await harness.run(.allowlistActivate)
        #expect(!report.restored)
        #expect(report.bool("restored") == false)
        #expect(report.errors.contains { $0.contains("didn't come back") })
        #expect(harness.allowlist.invalidations == 1, "the assertion was let go all the same")
    }

    @Test func aConcealedItemThatKeepsItsFrameIsStillSeenByTheItemsThatMoveUp() async throws {
        // macOS may leave a concealed item's old frame in the tree. Then no slot loses its frame, but the ones after it move:
        // here the other app's slot moves while anything is concealed, and nothing else changes.
        let harness = try ProbeHarness.make()
        let hidden = harness.hidden
        let otherSlot = try #require(harness.slotOwners.first { $0.value == otherID }?.key)
        harness.ax.setOverride { id, name in
            guard id == otherSlot, name == AXName.position, !hidden.all.isEmpty else { return nil }
            return .success(.point(CGPoint(x: 3120, y: 0)))
        }
        let report = await harness.run(.allowlistActivate)
        #expect(report.measurements["activateToVisibleChangeMs"] == .null, "no slot lost its frame")
        #expect(report.number("activateToFrameChangeMs") != nil, "but one moved")
        #expect(report.notes.contains { $0.contains("old frame") })
        #expect(report.restored)
    }

    @Test func aChangeNobodySawIsAMeasurementOfNothing() async throws {
        // Hiding an app that is running and has nothing in the menu bar changes nothing to see.
        let harness = try ProbeHarness.make { platform in
            let known = platform.runningApps
            platform.runningApps = { known() + [.fake(500, "com.example.daemon", "Daemon", backgroundOnly: true)] }
        }
        let report = await harness.run(.allowlistActivate, ["apps": "com.example.daemon", "allow-any": "true"])
        #expect(report.measurements["activateToVisibleChangeMs"] == .null)
        #expect(report.notes.contains { $0.contains("no visible change") })
        #expect(report.restored)
        // The polls that looked and saw nothing still say what they cost, and have no bounds to give.
        let poll = try #require(report.object("activateToVisibleChangePoll"))
        #expect(poll["hitPollStartedMs"] == .null)
        #expect(poll["hitPollEndedMs"] == .null)
        #expect(poll["previousPollEndedMs"] == .null)
        guard case .number(let polls)? = poll["polls"] else {
            Issue.record("the number of polls is a number")
            return
        }
        #expect(polls > 10, "every 25 ms for 2 s")
        #expect(poll["pollSnapshotMsMedian"] != nil)
    }

    // MARK: What a poll reads, and what it says about itself

    @Test func theChangesAreWatchedByReadingOnlyTheAgent() async throws {
        let harness = try ProbeHarness.make()
        let otherApp = harness.ax.root(ofApp: 301)
        let report = await harness.run(.allowlistActivate)
        #expect(report.errors.isEmpty)
        // The full snapshots (before, and after the hold) ask the app for its items once each; the polls ask nobody.
        #expect(harness.ax.attributeReads(on: otherApp) == 2)
    }

    @Test func eachLatencyComesWithTheBoundsOfThePollThatSawItAndWhatAPollCost() async throws {
        let clock = SteppingClock()
        // A read of the menu bar takes as long as its reads do: 1 ms each.
        let harness = try ProbeHarness.make(clock: clock, readCost: .milliseconds(1))
        // The test item's items leave the menu bar 60 ms after the allowlist is live, not at once.
        let activatedAt = Mutex<Date?>(nil)
        harness.allowlist.onActivated { activatedAt.withLock { $0 = clock.now() } }
        let hidden = harness.hidden
        let owners = harness.slotOwners
        harness.ax.setOverride { id, name in
            clock.advance(by: .milliseconds(1))
            guard name == AXName.position || name == AXName.size, owners[id] == fixtureID, hidden.contains(fixtureID),
                  let at = activatedAt.withLock({ $0 }), clock.now() >= at.addingTimeInterval(0.06) else { return nil }
            return .failure(.noValue)
        }

        let report = await harness.run(.allowlistActivate)

        #expect(report.errors.isEmpty)
        let latency = try #require(report.number("activateToVisibleChangeMs"))
        for name in ["activateToVisibleChange", "activateToFrameChange"] {
            let poll = try #require(report.object("\(name)Poll"), "\(name) has its poll")
            guard case .number(let previous)? = poll["previousPollEndedMs"], case .number(let started)? = poll["hitPollStartedMs"],
                  case .number(let ended)? = poll["hitPollEndedMs"], case .number(let median)? = poll["pollSnapshotMsMedian"],
                  case .number(let longest)? = poll["pollSnapshotMsMax"], case .number(let polls)? = poll["polls"] else {
                Issue.record("\(name)'s poll has all its numbers: \(poll)")
                continue
            }
            #expect(polls == 2, "the first poll was too early, the second saw it")
            #expect(previous > 0)
            #expect(started >= previous + 25, "a poll starts after the one before it ended and the 25 ms between")
            #expect(ended > started)
            #expect(ended == latency, "the latency is when the poll that saw it ended")
            #expect(median > 0 && longest >= median)
            // A latency reads as between two moments: the change came after the poll before had looked, and before this one ended.
            #expect(previous < latency)
        }
        let release = try #require(report.object("invalidateToRestorePoll"))
        guard case .number(let polls)? = release["polls"] else {
            Issue.record("the release poll has a count")
            return
        }
        #expect(polls >= 1)
    }
}

// MARK: Reading probes

@Suite("Reading probes", .timeLimit(.minutes(1)))
struct ReadingProbeTests {
    @Test func inventoryCountsWindowsSlotsAndApps() async throws {
        let harness = try ProbeHarness.make()
        let report = await harness.run(.inventory)
        #expect(report.errors.isEmpty)
        #expect(report.number("agentWindowCount") == 1)
        #expect(report.measurements["slotsPerWindow"] == .array([.number(6)]))
        #expect(report.number("appsWithExtras") == 3)
        #expect(report.measurements["timedOutApps"] == .array([]))
        #expect(report.restored)
    }

    @Test func inventorySavesTheWholeSnapshotWithTheRawTreeBesideTheReport() async throws {
        let harness = try ProbeHarness.make()
        let report = await harness.run(.inventory)
        let stamp = ProbeReport.timestamp(startedAt: report.startedAt)
        #expect(harness.probeFiles() == ["inventory-\(stamp)-snapshot.json", "inventory-\(stamp).json"])
        let snapshot = try decodeSnapshot(harness.probesFolder.appending(path: "inventory-\(stamp)-snapshot.json"))
        #expect(snapshot.allSlots.count == 6)
        #expect(snapshot.rawAgentTree != nil)
        #expect(snapshot.layout == .desk)
    }

    @Test func inventoryNamesTheAppsThatTimedOut() async throws {
        let harness = try ProbeHarness.make()
        harness.ax.failReads(on: harness.ax.root(ofApp: 301), with: .timeout)
        let report = await harness.run(.inventory)
        #expect(report.strings("timedOutApps") == [otherID])
        #expect(report.number("appsWithExtras") == 2)
    }

    @Test func inventoryWithoutAccessibilityCarriesTheProblem() async throws {
        let harness = try ProbeHarness.make()
        for app in ProbeHarness.runningApps { harness.ax.failReads(on: harness.ax.root(ofApp: app.pid), with: .notTrusted) }
        let report = await harness.run(.inventory)
        #expect(report.notes.contains("Device control and data access isn't granted to Mantel."))
        #expect(report.number("agentWindowCount") == 0)
    }

    @Test func overflowFindsTheChevronTheFramelessAndTheSqueezedItems() async throws {
        let harness = try ProbeHarness.make()
        harness.ax.addSlot(in: harness.window, subrole: "AXMenuExtra", description: "More", frame: CGRect(x: 2900, y: 0, width: 30, height: 31))
        harness.ax.addSlot(in: harness.window, identifier: "\(otherID).second")
        harness.ax.addApp(pid: 301, extras: [.init(title: "other", frame: CGRect(x: 3200, y: 0, width: 40, height: 31)),
                                             .init(title: "squeezed", frame: nil),
                                             .init(title: "under the chevron", frame: CGRect(x: 2905, y: 2, width: 20, height: 27))])
        let report = await harness.run(.overflow)

        #expect(report.bool("chevronPresent") == true)
        #expect(report.number("framelessSlots") == 1)
        let items = try #require({ () -> [JSONValue]? in
            if case .array(let values)? = report.measurements["overflowedItems"] { return values }
            return nil
        }())
        #expect(items == [.object(["bundleID": .string(otherID), "index": .number(1)]),
                          .object(["bundleID": .string(otherID), "index": .number(2)])])
    }

    @Test func overflowWithNothingSqueezedSaysSo() async throws {
        let harness = try ProbeHarness.make()
        let report = await harness.run(.overflow)
        #expect(report.bool("chevronPresent") == false)
        #expect(report.measurements["overflowedItems"] == .array([]))
        #expect(report.number("framelessSlots") == 0)
    }

    @Test func screenShareSavesTheIdentifiersAndDescriptionsBefore() async throws {
        let harness = try ProbeHarness.make()
        harness.ax.addSlot(in: harness.window, identifier: "com.example.described", description: "Some item")
        let report = await harness.run(.screenShare, ["phase": "before"])
        #expect(report.errors.isEmpty)
        #expect(report.measurements["phase"] == .string("before"))
        let identifiers = try #require(report.strings("identifiers"))
        #expect(identifiers.contains("com.apple.menuextra.clock"))
        #expect(identifiers == identifiers.sorted())
        #expect(report.strings("descriptions") == ["Some item"])
    }

    @Test func screenShareDuringDiffsAgainstTheLatestBefore() async throws {
        let clock = SteppingClock()
        let harness = try ProbeHarness.make(clock: clock)
        _ = await harness.run(.screenShare, ["phase": "before"])
        clock.advance(by: .seconds(30))
        harness.ax.addSlot(in: harness.window, identifier: "com.apple.controlcenter.screen-sharing", description: "Screen sharing")
        let during = await harness.run(.screenShare, ["phase": "during"])

        #expect(during.errors.isEmpty)
        #expect(during.strings("newIdentifiers") == ["com.apple.controlcenter.screen-sharing"])
        #expect(during.strings("newDescriptions") == ["Screen sharing"])
        #expect(during.measurements["comparedWith"] != nil)
    }

    @Test func screenShareDuringWithoutABeforeSaysSo() async throws {
        let harness = try ProbeHarness.make()
        let report = await harness.run(.screenShare, ["phase": "during"])
        #expect(report.notes.contains { $0.contains("before") })
        #expect(report.strings("newIdentifiers") == nil)
    }

    @Test func screenShareNeedsAPhase() async throws {
        let harness = try ProbeHarness.make()
        let report = await harness.run(.screenShare)
        #expect(report.errors == ["Say which phase: --phase before or --phase during."])
        let wrong = await harness.run(.screenShare, ["phase": "later"])
        #expect(wrong.errors == ["Say which phase: --phase before or --phase during."])
    }

    @Test func screenShareDuringTakesTheLatestBeforeNotAnEarlierOne() async throws {
        let clock = SteppingClock()
        let harness = try ProbeHarness.make(clock: clock)
        harness.ax.addSlot(in: harness.window, identifier: "com.example.late", description: "Late")
        _ = await harness.run(.screenShare, ["phase": "before"])
        clock.advance(by: .seconds(10))
        let during = await harness.run(.screenShare, ["phase": "during"])
        #expect(during.strings("newIdentifiers") == [], "the item was there in the latest before")
    }

    @Test func menuBarHeightReadsEveryDisplayAndWritesNothing() async throws {
        let harness = try ProbeHarness.make()
        let report = await harness.run(.menuBarHeight)
        #expect(report.errors.isEmpty)
        guard case .array(let displays)? = report.measurements["displays"] else {
            Issue.record("the displays are an array")
            return
        }
        #expect(displays.count == 2)
        guard case .object(let main) = displays[0], case .object(let portrait) = displays[1] else {
            Issue.record("each display is an object")
            return
        }
        #expect(main["name"] == .string("Desk Display"))
        #expect(main["frameMinusVisibleFrame"] == .number(31))
        #expect(main["agentWindowHeight"] == .number(31))
        #expect(portrait["frameMinusVisibleFrame"] == .number(0), "the side display reports no menu bar")
        #expect(portrait["agentWindowHeight"] == .null)
        #expect(report.number("statusBarThickness") == 31)
        #expect(!report.notes.isEmpty)
        #expect(report.restored)
    }
}

// MARK: Capture

@Suite("Capture probe", .timeLimit(.minutes(1)))
struct CaptureProbeTests {
    private func pngSize(_ url: URL) throws -> CGSize {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return CGSize(width: image.width, height: image.height)
    }

    @Test func captureSavesTheStripOfEachDisplayWithOneAndACropOfEachSlot() async throws {
        let harness = try ProbeHarness.make()
        let report = await harness.run(.capture)
        #expect(report.errors.isEmpty)
        #expect(report.number("capturedDisplays") == 1, "the side display reports no menu bar")
        #expect(report.number("crops") == 6)
        #expect(report.bool("screenRecordingGranted") == true)
        #expect(harness.capture.displays == [DisplayFixtures.deskMain.uuid])

        let stamp = ProbeReport.timestamp(startedAt: report.startedAt)
        let files = harness.probeFiles()
        #expect(files.contains("capture-\(stamp)-\(DisplayFixtures.deskMain.uuid).png"))
        #expect(files.filter { $0.hasPrefix("crop-\(stamp)-") }.sorted() == (0..<6).map { "crop-\(stamp)-\($0).png" }.sorted())

        // The strip is 3360 × 31 points at 2x; the clock's crop is 50 × 31 points.
        #expect(try pngSize(harness.probesFolder.appending(path: "capture-\(stamp)-\(DisplayFixtures.deskMain.uuid).png")) == CGSize(width: 6720, height: 62))
        #expect(try pngSize(harness.probesFolder.appending(path: "crop-\(stamp)-5.png")) == CGSize(width: 100, height: 62))
    }

    @Test func aSlotWithoutAFrameHasNoCrop() async throws {
        let harness = try ProbeHarness.make()
        harness.ax.addSlot(in: harness.window, identifier: "no-frame")
        let report = await harness.run(.capture)
        #expect(report.number("crops") == 6)
    }

    @Test func withoutScreenRecordingNothingIsCapturedAndTheReportSaysWhy() async throws {
        let harness = try ProbeHarness.make()
        harness.screenRecording.set(false)
        let report = await harness.run(.capture)
        #expect(report.bool("screenRecordingGranted") == false)
        #expect(report.number("capturedDisplays") == 0)
        #expect(report.number("crops") == 0)
        #expect(report.notes.contains { $0.contains("Screen Recording") })
        #expect(harness.capture.displays.isEmpty)
    }

    @Test func aCaptureThatFailsIsAnErrorAndTheOtherDisplaysStillRun() async throws {
        let harness = try ProbeHarness.make()
        harness.capture.fail(with: .failed("no frame"))
        let report = await harness.run(.capture)
        #expect(report.errors.contains { $0.contains("no frame") })
        #expect(report.number("capturedDisplays") == 0)
    }
}

// MARK: Grant probes

@Suite("Grant probes", .timeLimit(.minutes(1)))
struct GrantProbeTests {
    @Test func grantPersistenceReportsEachGrant() async throws {
        let harness = try ProbeHarness.make()
        try await harness.installFile(.controlCenterApprovals, ["trackedApplications": [fixtureID: true]])
        let report = await harness.run(.grantPersistence)

        #expect(report.errors.isEmpty)
        let grants = try #require(report.object("grants"))
        guard case .object(let approvals)? = grants["controlCenterApprovals"], case .object(let layout)? = grants["menuBarLayout"] else {
            Issue.record("a report for each grant")
            return
        }
        #expect(approvals["granted"] == .bool(true))
        #expect(approvals["resolves"] == .bool(true))
        #expect(approvals["isStale"] == .bool(false))
        #expect(approvals["readable"] == .bool(true))
        #expect(approvals["startAccessing"] != nil)
        #expect(layout["granted"] == .bool(false))
        #expect(layout["resolves"] == nil)
        #expect(report.restored)
    }

    @Test func grantPersistenceNoticesAFileThatHasGone() async throws {
        let harness = try ProbeHarness.make()
        let url = try await harness.installFile(.menuBarLayout, ["a": 1])
        try FileManager.default.removeItem(at: url)
        let report = await harness.run(.grantPersistence)
        let grants = try #require(report.object("grants"))
        guard case .object(let layout)? = grants["menuBarLayout"] else {
            Issue.record("a report for the grant")
            return
        }
        #expect(layout["granted"] == .bool(true))
        #expect(layout["readable"] == .bool(false))
    }

    @Test func approvalsReadReportsTheShapeAndNotTheValues() async throws {
        let harness = try ProbeHarness.make()
        try await harness.installFile(.controlCenterApprovals, [
            "trackedApplications": [fixtureID: true, otherID: ["allowed": false, "label": "SECRET-LABEL"]],
            "unrelated": "SECRET-TEXT",
        ])
        let report = await harness.run(.approvalsRead)

        #expect(report.errors.isEmpty)
        #expect(report.strings("topLevelKeys") == ["trackedApplications", "unrelated"])
        #expect(report.bool("fixtureBundleIDPresent") == true)
        let shape = try #require(report.object("trackedApplications"))
        #expect(shape["type"] == .string("dictionary"))
        #expect(shape["count"] == .number(2))
        let text = try String(decoding: JSONEncoder().encode(report.json), as: UTF8.self)
        #expect(!text.contains("SECRET-LABEL"))
        #expect(!text.contains("SECRET-TEXT"))
        #expect(report.restored)
    }

    @Test func approvalsReadWithoutTheFixtureSaysItIsNotThere() async throws {
        let harness = try ProbeHarness.make()
        try await harness.installFile(.controlCenterApprovals, ["trackedApplications": [otherID: true]])
        let report = await harness.run(.approvalsRead)
        #expect(report.bool("fixtureBundleIDPresent") == false)
    }

    @Test func approvalsReadWithoutAGrantSaysWhatToDo() async throws {
        let harness = try ProbeHarness.make()
        let report = await harness.run(.approvalsRead)
        #expect(report.errors.count == 1)
        #expect(report.errors.first?.contains("Allow in the Menu Bar") == true)
        #expect(report.errors.first?.contains("Permissions") == true)
    }

    @Test func layoutReadReportsTheKeyFormatsAndTheFixturesEntries() async throws {
        let harness = try ProbeHarness.make()
        try await harness.installFile(.menuBarLayout, [
            "other": 1,
            LayoutKeys.trailingPositions: ["status:\(fixtureID)::mantel.fixture.one": 120, "status:\(otherID)::x": 60, "module:Clock": 20],
        ])
        let report = await harness.run(.layoutRead)

        #expect(report.errors.isEmpty)
        #expect(report.strings("topLevelKeys") == ["TrailingItemPreferredPositions", "other"])
        #expect(report.number("trailingItemCount") == 3)
        #expect(report.object("keyPrefixes") == ["status:": .number(2), "module:": .number(1)])
        #expect(report.object("fixtureEntries") == ["status:\(fixtureID)::mantel.fixture.one": .number(120)])
        // Other apps' names are not in the report, only the formats.
        let text = try String(decoding: JSONEncoder().encode(report.json), as: UTF8.self)
        #expect(!text.contains(otherID))
    }

    @Test func layoutReadWithoutAGrantSaysWhatToDo() async throws {
        let harness = try ProbeHarness.make()
        let report = await harness.run(.layoutRead)
        #expect(report.errors.first?.contains("menu bar layout") == true)
    }
}

// MARK: Probes that change a file

@Suite("File-changing probes", .timeLimit(.minutes(1)))
struct FileChangingProbeTests {
    /// The test item's slots are on the menu bar while its flag in the approvals file is on.
    private func hideFixtureWhenNotApproved(_ harness: ProbeHarness) {
        let approvals = harness.approvalsURL
        let owners = harness.slotOwners
        harness.ax.setOverride { id, name in
            guard name == AXName.position || name == AXName.size, owners[id] == fixtureID else { return nil }
            guard let data = try? Data(contentsOf: approvals),
                  let top = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                  let tracked = top["trackedApplications"] as? [String: Any], tracked[fixtureID] as? Bool == false else { return nil }
            return .failure(.noValue)
        }
    }

    private let original: [String: Any] = [
        "trackedApplications": [fixtureID: true, otherID: true],
        "keep": "this",
    ]

    @Test(arguments: [nil, "cfPreferences"] as [String?])
    func approvalsToggleFlipsTheFlagSeesTheChangeAndPutsItBack(strategy: String?) async throws {
        let harness = try ProbeHarness.make()
        let url = try await harness.installFile(.controlCenterApprovals, original)
        hideFixtureWhenNotApproved(harness)
        let before = try ProbeHarness.read(url)

        let report = await harness.run(.approvalsToggle, strategy.map { ["strategy": $0] } ?? [:])

        #expect(report.errors.isEmpty)
        #expect(report.restored)
        #expect(report.number("writeToVisibleChangeMs") != nil)
        #expect(report.number("restoreToVisibleMs") != nil)
        #expect(report.bool("persistedToFile") == true)
        #expect(report.number("writtenToFileMs") != nil)
        #expect(report.measurements["strategy"] == .string(strategy ?? "cfPreferences"))
        #expect(report.measurements["flag"] == .string("trackedApplications[\(fixtureID)]"))
        #expect(try ProbeHarness.read(url) == before, "the file is as it was")
        #expect(await harness.journal.records().isEmpty, "and the journal has nothing left")
    }

    @Test func approvalsToggleWithTheFileReplacedDirectlyIsRefusedBecauseMacOSWouldRefuseIt() async throws {
        let harness = try ProbeHarness.make()
        let url = try await harness.installFile(.controlCenterApprovals, original)
        let before = try Data(contentsOf: url)

        let report = await harness.run(.approvalsToggle, ["strategy": "atomicFile"])

        #expect(report.errors.contains { $0.contains("macOS doesn't let apps replace group.com.apple.controlcenter.plist") }, "\(report.errors)")
        #expect(try Data(contentsOf: url) == before)
        #expect(await harness.journal.records().isEmpty, "refused before anything was journaled")
    }

    /// A preferences service that keeps what it is told in its cache and never writes the file.
    private func cacheOnly() -> PlistIO {
        let cache = Mutex<[String: PlistValue?]>([:])
        var io = PlistIO.filesOnly
        let fromFile = io.read
        io.write = { value, key, _, _ in cache.withLock { $0[key] = .some(value) } }
        io.read = { url, key, strategy in
            if let cached = cache.withLock({ $0[key] }) { return cached }
            return try fromFile(url, key, strategy)
        }
        return io
    }

    @Test func approvalsToggleRecordsTheBoundsOfTheChangeItSaw() async throws {
        let clock = SteppingClock()
        let harness = try ProbeHarness.make(clock: clock, readCost: .milliseconds(1))
        try await harness.installFile(.controlCenterApprovals, original)
        hideFixtureWhenNotApproved(harness)
        let report = await harness.run(.approvalsToggle)

        #expect(report.errors.isEmpty)
        for (latency, name) in [("writeToVisibleChangeMs", "writeToVisibleChangePoll"), ("restoreToVisibleMs", "restoreToVisiblePoll")] {
            let value = try #require(report.number(latency))
            let poll = try #require(report.object(name))
            #expect(poll["hitPollEndedMs"] == .number(value), "\(name) ends where \(latency) says")
            #expect(poll["hitPollStartedMs"] != nil && poll["hitPollStartedMs"] != .null)
            #expect(poll["pollSnapshotMsMedian"] != nil && poll["pollSnapshotMsMax"] != nil)
        }
    }

    @Test func approvalsToggleSaysWhenTheValueNeverReachedTheFile() async throws {
        let harness = try ProbeHarness.make(io: cacheOnly())
        let url = try await harness.installFile(.controlCenterApprovals, original)
        let before = try Data(contentsOf: url)
        let report = await harness.run(.approvalsToggle)
        #expect(report.bool("persistedToFile") == false)
        #expect(report.measurements["writtenToFileMs"] == .null)
        #expect(report.notes.contains { $0.contains("file on disk") })
        #expect(report.restored)
        #expect(try Data(contentsOf: url) == before, "the file was never touched")
    }

    @Test func approvalsToggleBacksTheFileUpBeforeItsFirstWrite() async throws {
        let harness = try ProbeHarness.make()
        let url = try await harness.installFile(.controlCenterApprovals, original)
        let before = try Data(contentsOf: url)

        let report = await harness.run(.approvalsToggle)

        #expect(report.errors.isEmpty)
        let backups = try FileManager.default.contentsOfDirectory(atPath: harness.paths.backups.path)
            .filter { $0.hasPrefix("group.com.apple.controlcenter-") }
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: harness.paths.backups.appending(path: try #require(backups.first))) == before,
                "the copy is of the file as the person had it, not as the probe left it")
    }

    @Test func approvalsToggleOfAnotherAppIsRefusedAndTheFileIsLeftAlone() async throws {
        let harness = try ProbeHarness.make()
        let url = try await harness.installFile(.controlCenterApprovals, original)
        let before = try Data(contentsOf: url)
        let report = await harness.run(.approvalsToggle, ["app": otherID])
        #expect(report.errors == ["This probe only touches MantelTestItem. Add --allow-any to touch \(otherID)."])
        #expect(try Data(contentsOf: url) == before)
        #expect(await harness.journal.records().isEmpty)
    }

    @Test func approvalsToggleWithAllowAnyTouchesTheOtherApp() async throws {
        let harness = try ProbeHarness.make()
        let url = try await harness.installFile(.controlCenterApprovals, original)
        let before = try ProbeHarness.read(url)
        let report = await harness.run(.approvalsToggle, ["app": otherID, "allow-any": "true"])
        #expect(report.errors.isEmpty)
        #expect(report.restored)
        #expect(try ProbeHarness.read(url) == before)
    }

    @Test func approvalsToggleOfAnAppThatIsNotInTheFileChangesNothing() async throws {
        let harness = try ProbeHarness.make()
        let url = try await harness.installFile(.controlCenterApprovals, ["trackedApplications": [otherID: true]])
        let before = try Data(contentsOf: url)
        let report = await harness.run(.approvalsToggle)
        #expect(report.errors.first?.contains(fixtureID) == true)
        #expect(report.errors.first?.contains("approvals-read") == true)
        #expect(report.restored)
        #expect(try Data(contentsOf: url) == before)
        #expect(await harness.journal.records().isEmpty)
    }

    @Test func approvalsToggleWithoutAGrantChangesNothing() async throws {
        let harness = try ProbeHarness.make()
        let report = await harness.run(.approvalsToggle)
        #expect(report.errors.first?.contains("Allow in the Menu Bar") == true)
        #expect(report.restored)
    }

    @Test func approvalsToggleThatCantPutItBackLeavesTheJournalToDoItAtTheNextLaunch() async throws {
        // The change is made, and then the file can't be written (the folder is locked the moment the flag
        // is seen to be off, which is after the write). The report says it isn't restored; the journal holds the original;
        // the next launch's replay puts it back.
        let harness = try ProbeHarness.make()
        let url = try await harness.installFile(.controlCenterApprovals, original)
        let before = try ProbeHarness.read(url)
        let folder = url.deletingLastPathComponent()
        let owners = harness.slotOwners
        harness.ax.setOverride { id, name in
            guard name == AXName.position || name == AXName.size, owners[id] == fixtureID,
                  let data = try? Data(contentsOf: url),
                  let top = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                  let tracked = top["trackedApplications"] as? [String: Any], tracked[fixtureID] as? Bool == false else { return nil }
            try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
            return .failure(.noValue)
        }
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }

        let report = await harness.run(.approvalsToggle)

        #expect(!report.restored)
        #expect(!report.errors.isEmpty)
        #expect(try ProbeHarness.read(url) != before, "the flag is still flipped")
        #expect(await harness.journal.records().count == 1, "and the journal still holds the original")

        // The next launch: the folder can be written again, and the replay puts the flag back.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        harness.ax.setOverride(nil)
        let restarted = Journal(file: harness.paths.journalFile)
        // On the files themselves, as the harness is: never the real preferences service, for a path that looks like a container.
        let access = PlistFileAccess(journal: restarted, paths: harness.paths, grants: harness.grants, io: .filesOnly)
        let failures = await restarted.replay(using: PlistJournalRestorer(access: access, grants: harness.grants))
        #expect(failures.isEmpty)
        #expect(try ProbeHarness.read(url) == before)
        #expect(await restarted.records().isEmpty)
    }

    // MARK: layout-move

    private let layout: [String: Any] = [
        LayoutKeys.trailingPositions: [
            "status:\(fixtureID)::mantel.fixture.one": 120, "status:\(fixtureID)::mantel.fixture.two": 100,
            "status:\(otherID)::x": 60,
        ],
        "keep": "this",
    ]

    /// The fixture's first item sits `3220 - distance` from the left, so 120 is where it starts (x = 3100).
    private func placeFixtureByTheLayoutFile(_ harness: ProbeHarness) {
        let layoutURL = harness.layoutURL
        let first = harness.fixtureOneSlot
        harness.ax.setOverride { id, name in
            guard id == first, name == AXName.position else { return nil }
            guard let data = try? Data(contentsOf: layoutURL),
                  let top = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                  let positions = top[LayoutKeys.trailingPositions] as? [String: Any],
                  let distance = (positions["status:\(fixtureID)::mantel.fixture.one"] as? NSNumber)?.doubleValue else { return nil }
            return .success(.point(CGPoint(x: 3220 - distance, y: 0)))
        }
    }

    @Test func layoutMoveWritesTheDistanceSeesTheSlotsMoveAndPutsItBack() async throws {
        let harness = try ProbeHarness.make()
        let url = try await harness.installFile(.menuBarLayout, layout)
        placeFixtureByTheLayoutFile(harness)
        let before = try ProbeHarness.read(url)

        let report = await harness.run(.layoutMove, ["distance": "0"])

        #expect(report.errors.isEmpty)
        #expect(report.restored)
        #expect(report.bool("resortApplied") == true)
        #expect(report.number("writeToResortMs") != nil)
        #expect(report.bool("persistedToFile") == true)
        #expect(report.measurements["key"] == .string("status:\(fixtureID)::mantel.fixture.one"), "the first of the fixture's keys")
        #expect(report.number("distance") == 0)
        #expect(try ProbeHarness.read(url) == before)
        #expect(await harness.journal.records().isEmpty)
    }

    @Test func layoutMoveRecordsTheBoundsOfTheChangeItSaw() async throws {
        let harness = try ProbeHarness.make(clock: SteppingClock(), readCost: .milliseconds(1))
        try await harness.installFile(.menuBarLayout, layout)
        placeFixtureByTheLayoutFile(harness)
        let report = await harness.run(.layoutMove, ["distance": "0"])

        let latency = try #require(report.number("writeToResortMs"))
        let poll = try #require(report.object("writeToResortPoll"))
        #expect(poll["hitPollEndedMs"] == .number(latency))
        #expect(poll["hitPollStartedMs"] != nil && poll["hitPollStartedMs"] != .null)
        #expect(poll["pollSnapshotMsMax"] != nil)
    }

    @Test func layoutMoveWithTheFileReplacedDirectlyIsRefusedBecauseMacOSWouldRefuseIt() async throws {
        let harness = try ProbeHarness.make()
        let url = try await harness.installFile(.menuBarLayout, layout)
        placeFixtureByTheLayoutFile(harness)
        let before = try Data(contentsOf: url)
        let report = await harness.run(.layoutMove, ["distance": "0", "strategy": "atomicFile"])
        #expect(report.errors.contains { $0.contains("macOS doesn't let apps replace com.apple.MenuBar.plist") }, "\(report.errors)")
        #expect(report.bool("resortApplied") == nil)
        #expect(try Data(contentsOf: url) == before)
        #expect(await harness.journal.records().isEmpty)
    }

    @Test func layoutMoveWritesOnlyTheTestItemsEntryAndPutsOnlyThatBack() async throws {
        let harness = try ProbeHarness.make()
        let url = try await harness.installFile(.menuBarLayout, layout)
        let layoutURL = harness.layoutURL
        let first = harness.fixtureOneSlot
        let otherKey = "status:\(otherID)::x"

        // While the probe waits for the menu bar to re-sort, macOS moves another item: its entry in the same table changes.
        let moved = Mutex(false)
        harness.ax.setOverride { id, name in
            guard id == first, name == AXName.position else { return nil }
            guard let data = try? Data(contentsOf: layoutURL),
                  let top = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                  var positions = top[LayoutKeys.trailingPositions] as? [String: Any],
                  let distance = (positions["status:\(fixtureID)::mantel.fixture.one"] as? NSNumber)?.doubleValue else { return nil }
            if distance == 0, !moved.withLock({ let was = $0; $0 = true; return was }) {
                positions[otherKey] = 77
                try? PlistIO.writeFile(PlistValue(propertyList: positions), key: LayoutKeys.trailingPositions, to: layoutURL)
            }
            return .success(.point(CGPoint(x: 3220 - distance, y: 0)))
        }

        let report = await harness.run(.layoutMove, ["distance": "0"])

        #expect(report.errors.isEmpty)
        #expect(report.restored)
        #expect(report.bool("resortApplied") == true)
        let table = try #require(ProbeHarness.read(url)[LayoutKeys.trailingPositions] as? [String: Any])
        #expect(table["status:\(fixtureID)::mantel.fixture.one"] as? Int == 120, "the test item's entry is back")
        #expect(table["status:\(fixtureID)::mantel.fixture.two"] as? Int == 100)
        #expect(table[otherKey] as? Int == 77, "the other item's entry is as macOS left it, not as the probe found it")
        #expect(try ProbeHarness.read(url)["keep"] as? String == "this")
        #expect(await harness.journal.records().isEmpty)
    }

    @Test func layoutMoveThatChangesNothingSaysSo() async throws {
        let harness = try ProbeHarness.make()
        let url = try await harness.installFile(.menuBarLayout, layout)
        placeFixtureByTheLayoutFile(harness)
        let before = try ProbeHarness.read(url)
        // 130 puts the item at x = 3090: still between the same neighbours.
        let report = await harness.run(.layoutMove, ["distance": "130"])
        #expect(report.bool("resortApplied") == false)
        #expect(report.measurements["writeToResortMs"] == .null)
        #expect(report.restored)
        #expect(try ProbeHarness.read(url) == before)
    }

    @Test func layoutMoveCanBeGivenAKeyOfTheFixture() async throws {
        let harness = try ProbeHarness.make()
        try await harness.installFile(.menuBarLayout, layout)
        let key = "status:\(fixtureID)::mantel.fixture.two"
        let report = await harness.run(.layoutMove, ["key": key, "distance": "5"])
        #expect(report.measurements["key"] == .string(key))
        #expect(report.restored)
    }

    @Test func layoutMoveOfAnAppsKeyIsRefusedWithoutAllowAny() async throws {
        let harness = try ProbeHarness.make()
        let url = try await harness.installFile(.menuBarLayout, layout)
        let before = try Data(contentsOf: url)
        let other = await harness.run(.layoutMove, ["key": "status:\(otherID)::x", "distance": "5"])
        #expect(other.errors == ["This probe only touches MantelTestItem. Add --allow-any to touch \(otherID)."])
        let module = await harness.run(.layoutMove, ["key": "module:Clock", "distance": "5"])
        #expect(module.errors == ["This probe only touches MantelTestItem. Add --allow-any to touch module:Clock."])
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func layoutMoveWhenTheFixtureHasNoEntryCreatesOneAndRemovesIt() async throws {
        let harness = try ProbeHarness.make()
        let url = try await harness.installFile(.menuBarLayout, [LayoutKeys.trailingPositions: ["status:\(otherID)::x": 60]])
        let before = try ProbeHarness.read(url)
        let report = await harness.run(.layoutMove, ["distance": "40"])
        #expect(report.errors.isEmpty)
        #expect(report.measurements["key"] == .string("status:\(fixtureID)::mantel.fixture.one"))
        #expect(report.restored)
        #expect(try ProbeHarness.read(url) == before, "the entry that wasn't there is gone again")
    }

    @Test func layoutMoveWithoutAGrantChangesNothing() async throws {
        let harness = try ProbeHarness.make()
        let report = await harness.run(.layoutMove, ["distance": "5"])
        #expect(report.errors.first?.contains("menu bar layout") == true)
        #expect(report.restored)
    }

    @Test func layoutMoveWhileTheJournalIsReplayingChangesNothing() async throws {
        let harness = try ProbeHarness.make()
        let url = try await harness.installFile(.menuBarLayout, layout)
        let before = try Data(contentsOf: url)

        try await harness.journal.record(.plistKey(filePath: "/tmp/x.plist", key: "k", original: nil, strategy: .atomicFile))
        let entered = Gate()
        let release = Gate()
        struct Blocker: JournalRestoring {
            let entered: Gate
            let release: Gate
            func restore(_ entry: JournalEntry) async throws {
                entered.open()
                await release.wait()
            }
        }
        let replay = Task { await harness.journal.replay(using: Blocker(entered: entered, release: release)) }
        await entered.wait()

        let report = await harness.run(.layoutMove, ["distance": "5"])
        #expect(report.errors.contains { $0.contains("restoring") })
        #expect(try Data(contentsOf: url) == before)

        release.open()
        _ = await replay.value
    }
}

// MARK: click-replay

@Suite("Click-replay probe", .timeLimit(.minutes(1)))
struct ClickReplayProbeTests {
    private let click = CGPoint(x: 3320, y: 10)

    private func letTheClickWorkOnceTheAllowlistIsLifted(_ harness: ProbeHarness) {
        let hidden = harness.hidden
        harness.windows.setOpens { hidden.all.isEmpty }
    }

    /// What the report says of each click, as objects.
    private func records(_ report: ProbeReport) -> [[String: JSONValue]] {
        guard case .array(let values)? = report.measurements["clicks"] else {
            Issue.record("the clicks are an array")
            return []
        }
        return values.map { value in
            guard case .object(let record) = value else {
                Issue.record("a click is an object")
                return [:]
            }
            return record
        }
    }

    private func number(_ record: [String: JSONValue], _ key: String) -> Double? {
        if case .number(let value)? = record[key] { return value }
        return nil
    }

    @Test func eachClickLiftsTheAllowlistReplaysAndRecordsWhetherItOpened() async throws {
        let harness = try ProbeHarness.make(clicks: [click, click])
        letTheClickWorkOnceTheAllowlistIsLifted(harness)

        let report = await harness.run(.clickReplay)

        #expect(report.errors.isEmpty)
        #expect(report.restored)
        let clicks = records(report)
        #expect(clicks.count == 2)
        for record in clicks {
            #expect(record["delayMs"] == .number(100))
            #expect(record["opened"] == .bool(true))
        }

        // The tap sat on the clock's frame, with the default delay, for 30 seconds at most.
        #expect(harness.taps.made == [FakeTapFactory.Made(rects: [CGRect(x: 3300, y: 0, width: 50, height: 31)],
                                                          delay: .milliseconds(100), lifetime: .seconds(30))])
        #expect(harness.taps.started == 1)
        #expect(harness.taps.stopped >= 1)
        // The fixture is hidden to begin with; each click lifts the allowlist and puts it back.
        #expect(harness.allowlist.calls.count == 3)
        #expect(harness.allowlist.calls.allSatisfy { !$0.bundleIDs.contains(fixtureID) && $0.bundleIDs.contains(ownID) })
        #expect(harness.allowlist.invalidations == 3)
        #expect(harness.allowlist.live == 0)
        #expect(harness.hidden.all.isEmpty)
    }

    // MARK: The lift

    @Test(arguments: [20, 100, 400])
    func theAllowlistIsLiftedInsideTheClickCallbackBeforeTheReplayAtEveryDelay(delay: Int) async throws {
        let harness = try ProbeHarness.make(clicks: [click, click])
        letTheClickWorkOnceTheAllowlistIsLifted(harness)

        let report = await harness.run(.clickReplay, ["delay": "\(delay)"])

        #expect(report.errors.isEmpty)
        // Seen from the tap: when the click callback had returned, the allowlist was already lifted, once more than before. The
        // probe didn't wait to notice the click in a mailbox first.
        let deliveries = harness.taps.deliveries
        #expect(deliveries.count == 2)
        for delivery in deliveries {
            #expect(delivery.delay == .milliseconds(delay))
            #expect(delivery.liftsAfterTheClickCallback == delivery.liftsBefore + 1)
        }

        // And the times say the same: the click, the lift, the replay, in that order, `delay` between the lift and the replay.
        for record in records(report) {
            let clickAt = try #require(number(record, "clickAt"))
            let liftedAt = try #require(number(record, "liftedAt"))
            let replayedAt = try #require(number(record, "replayedAt"))
            let liftToReplay = try #require(number(record, "liftToReplayMs"))
            #expect(clickAt <= liftedAt)
            #expect(liftedAt <= replayedAt)
            #expect(abs(liftToReplay - Double(delay)) < 0.01, "the lift came the whole delay before the replay")
            #expect(abs(liftToReplay - (replayedAt - liftedAt)) < 0.01)
            #expect(record["delayMs"] == .number(Double(delay)), "the configured delay is recorded beside the measured one")
        }
    }

    @Test func aClickThatComesWhileTheAllowlistIsAlreadyLiftedIsRecordedWithoutALift() async throws {
        // A second click during the first one's watch: nothing was live to lift, and nothing is put back for it.
        let harness = try ProbeHarness.make(clicks: [click, click])
        let delivering = try #require(harness.clock as? ClickDeliveryClock)
        let taps = harness.taps
        let once = Switch(false)
        harness.windows.setOpens {
            // The first read of the watch (the one before the tap is on is for the baseline).
            if taps.started > 0, !once.isOn {
                once.set(true)
                taps.deliverNext(advance: delivering.advance)
            }
            return false
        }

        let report = await harness.run(.clickReplay)

        let clicks = records(report)
        #expect(clicks.count == 2)
        #expect(number(clicks[0], "liftedAt") != nil)
        #expect(clicks[1]["liftedAt"] == .null)
        #expect(clicks[1]["liftToReplayMs"] == .null)
        #expect(clicks[1]["opened"] == .null)
        #expect(number(clicks[1], "clickAt") != nil && number(clicks[1], "replayedAt") != nil)
        #expect(harness.allowlist.live == 0)
        #expect(report.restored)
    }

    @Test func theTimesAreMillisecondsAfterTheProbeStartedAndTheReportSaysSo() async throws {
        let harness = try ProbeHarness.make(clicks: [click])
        let report = await harness.run(.clickReplay)
        #expect(report.notes.contains { $0.contains("clickAt, liftedAt and replayedAt are milliseconds after the probe started") })
        let record = try #require(records(report).first)
        #expect(try #require(number(record, "clickAt")) >= 0)
    }

    @Test func aClickThatNeverOpensNotificationCenterIsRecordedAsNotOpened() async throws {
        let harness = try ProbeHarness.make(clicks: [click])
        let report = await harness.run(.clickReplay)
        let clicks = records(report)
        #expect(clicks.count == 1)
        #expect(clicks.first?["opened"] == .bool(false))
        #expect(clicks.first?["delayMs"] == .number(100))
        // It watched for a second before giving up, on the clock the probe has.
        #expect(report.durationMs >= 1000)
    }

    @Test func itEndsAfterFiveClicks() async throws {
        let harness = try ProbeHarness.make(clicks: Array(repeating: click, count: 8))
        letTheClickWorkOnceTheAllowlistIsLifted(harness)
        let report = await harness.run(.clickReplay)
        guard case .array(let clicks)? = report.measurements["clicks"] else {
            Issue.record("clicks are an array")
            return
        }
        #expect(clicks.count == 5)
        #expect(harness.allowlist.live == 0)
        #expect(harness.taps.stopped >= 1)
    }

    @Test func withNoClickItEndsAfterThirtySecondsAndReleasesEverything() async throws {
        let harness = try ProbeHarness.make()
        let report = await harness.run(.clickReplay)
        #expect(report.measurements["clicks"] == .array([]))
        #expect(report.durationMs >= 30_000)
        #expect(report.durationMs < 40_000)
        #expect(harness.allowlist.live == 0)
        #expect(report.restored)
    }

    @Test func theDelayIsKeptBetween20And400() async throws {
        let low = try ProbeHarness.make(clicks: [click])
        let lowReport = await low.run(.clickReplay, ["delay": "1"])
        #expect(low.taps.made.first?.delay == .milliseconds(20))
        #expect(records(lowReport).first?["delayMs"] == .number(20))

        let high = try ProbeHarness.make(clicks: [click])
        _ = await high.run(.clickReplay, ["delay": "9999"])
        #expect(high.taps.made.first?.delay == .milliseconds(400))
    }

    @Test func clickReplayTargetsEveryDisplaysClock() async throws {
        let harness = try ProbeHarness.make(clicks: [click])
        // The portrait display has an agent window of its own, and a clock in it.
        let second = harness.ax.addAgentWindow(agent: ProbeHarness.agentPID, frame: CGRect(x: -1800, y: -491, width: 1800, height: 31))
        harness.ax.addSlot(in: second, identifier: "com.apple.menuextra.clock", frame: CGRect(x: -60, y: -491, width: 50, height: 31))
        // A window that shows the same clock again (another Space's) is not a second target.
        let spare = harness.ax.addAgentWindow(agent: ProbeHarness.agentPID, frame: CGRect(x: -1800, y: -491, width: 1800, height: 31))
        harness.ax.addSlot(in: spare, identifier: "com.apple.menuextra.clock", frame: CGRect(x: -60, y: -491, width: 50, height: 31))

        let report = await harness.run(.clickReplay)

        #expect(report.errors.isEmpty)
        #expect(harness.taps.made.map(\.rects) == [[CGRect(x: 3300, y: 0, width: 50, height: 31), CGRect(x: -60, y: -491, width: 50, height: 31)]],
                "a click on the clock of either display is held")
        #expect(report.measurements["clockSlots"] == .number(2))
    }

    @Test func aWindowOfAnotherAppOrASmallOneOrOneBelowThePanelsLevelIsNotTheClockOpening() async throws {
        let harness = try ProbeHarness.make(clicks: [click])
        let main = ProbeHarness.screens[0].frame
        harness.windows.setExtra([
            // Another app's window over the whole display; Notification Center's banner, and its widget over the whole display but below.
            WindowInfo(number: 50, ownerPID: 301, ownerBundleID: otherID, layer: FakeWindows.panelLayer, bounds: main, alpha: 1),
            WindowInfo(number: 51, ownerPID: 70, ownerBundleID: "com.apple.notificationcenterui", layer: FakeWindows.panelLayer,
                       bounds: CGRect(x: 2900, y: 40, width: 420, height: 90), alpha: 1),
            WindowInfo(number: 52, ownerPID: 70, ownerBundleID: "com.apple.notificationcenterui", layer: 0, bounds: main, alpha: 1),
        ])
        let report = await harness.run(.clickReplay)
        #expect(report.errors.isEmpty)
        #expect(records(report).first?["opened"] == .bool(false))
    }

    @Test func clickReplayOpenedUsesDisplayFrames() async throws {
        // The layout is the desk: the main display, and a portrait one to its left. Its frames are in AppKit's points (y up from the main
        // display's bottom), and the window list's bounds are CoreGraphics' (y down from its top), which differ for the portrait one.
        let layout = DisplayLayout.desk
        let portrait = try #require(layout.displays.first { !$0.isMain })
        let cgFrame = layout.cgRect(fromAppKit: portrait.frame)
        #expect(cgFrame == CGRect(x: -1800, y: -491, width: 1800, height: 3200))
        #expect(cgFrame != portrait.frame)

        // The panel is where `bounds` says once the click has been replayed, and not before.
        func opened(by bounds: CGRect) async throws -> JSONValue? {
            let harness = try ProbeHarness.make(clicks: [click])
            harness.windows.setPanel(bounds)
            letTheClickWorkOnceTheAllowlistIsLifted(harness)
            let report = await harness.run(.clickReplay)
            #expect(report.errors.isEmpty, "\(bounds)")
            return records(report).first?["opened"]
        }
        // A panel over the portrait display, as the window list says it, is the click opening it.
        #expect(try await opened(by: cgFrame) == .bool(true))
        // The same window at the numbers AppKit has for that display is not: it is mostly somewhere else.
        #expect(try await opened(by: portrait.frame) == .bool(false))
        // Half of the display is not enough, and neither is a display the layout doesn't have.
        #expect(try await opened(by: CGRect(x: -1800, y: -491, width: 900, height: 3200)) == .bool(false))
        #expect(try await opened(by: CGRect(x: 4000, y: 0, width: 3360, height: 1890)) == .bool(false))
        // The main display's own, which the desk's two spaces agree about.
        #expect(try await opened(by: layout.cgRect(fromAppKit: try #require(layout.main).frame)) == .bool(true))
    }

    @Test func theClockOpeningIsSeenOnlyAfterTheReplay() async throws {
        // The pop-up is reported open from the moment the first click is held; it only counts once the replay has been made.
        let harness = try ProbeHarness.make(clicks: [click])
        let taps = harness.taps
        let seenBeforeReplay = Mutex(false)
        harness.windows.setOpens {
            // A read that comes while the click is held and not replayed yet (the fake tap reports the replay in the same step).
            if taps.deliveries.isEmpty && taps.started > 0 { seenBeforeReplay.withLock { $0 = true } }
            return !taps.deliveries.isEmpty
        }
        let report = await harness.run(.clickReplay)
        #expect(records(report).first?["opened"] == .bool(true))
        #expect(!seenBeforeReplay.withLock { $0 }, "the window list was not read for the click before it was replayed")
    }

    @Test func aPopUpThatIsOpenWhenTheTapIsAboutToStartIsRefusedAndEverythingIsReleased() async throws {
        let harness = try ProbeHarness.make(clicks: [click])
        harness.windows.setOpens { true }
        let report = await harness.run(.clickReplay)
        #expect(report.errors == ["Notification Center is open. Close it, and run the probe again."])
        #expect(harness.taps.started == 0, "no tap was started")
        #expect(harness.allowlist.live == 0)
        #expect(report.restored)
    }

    @Test func nothingIsActivatedWhenTheTestItemIsNotRunning() async throws {
        let harness = try ProbeHarness.make(clicks: [click]) { platform in
            let known = platform.runningApps
            platform.runningApps = { known().filter { $0.bundleID != fixtureID } }
        }
        let report = await harness.run(.clickReplay)
        #expect(report.errors == ["Nothing to hide: \(fixtureID) isn't running. Open MantelTestItem first."])
        #expect(report.restored)
        #expect(harness.allowlist.calls.isEmpty, "the system items weren't hidden for nothing")
        #expect(harness.taps.made.isEmpty, "and no tap was made")
    }

    @Test func aTapThatCantStartIsAnErrorAndTheAllowlistIsReleased() async throws {
        let harness = try ProbeHarness.make(clicks: [click])
        harness.taps.failToStart()
        let report = await harness.run(.clickReplay)
        #expect(report.errors.contains { $0.contains("Device control and data access") })
        #expect(harness.allowlist.live == 0)
        #expect(report.restored)
    }

    @Test func withoutAClockSlotWithAFrameNothingIsActivated() async throws {
        let harness = try ProbeHarness.make(clicks: [click])
        let clockSlot = harness.clockSlot
        harness.ax.setOverride { id, name in id == clockSlot && name == AXName.position ? .failure(.noValue) : nil }
        let report = await harness.run(.clickReplay)
        #expect(report.errors.contains { $0.contains("clock") })
        #expect(harness.allowlist.calls.isEmpty)
        #expect(harness.taps.made.isEmpty)
    }

    @Test func hidingSystemItemsNeedsAllowAny() async throws {
        let harness = try ProbeHarness.make(clicks: [click])
        let report = await harness.run(.clickReplay, ["system-items": "2,5"])
        #expect(report.errors == ["This probe only hides MantelTestItem. Add --allow-any to hide system items."])
        #expect(harness.allowlist.calls.isEmpty)
        #expect(harness.taps.made.isEmpty)
    }

    @Test func mantelsOwnItemCanNotBeTheAppToHide() async throws {
        for options in [["app": ownID], ["app": ownID, "allow-any": "true"]] {
            let harness = try ProbeHarness.make(clicks: [click])
            let report = await harness.run(.clickReplay, options)
            #expect(report.errors == ["Mantel's own item is never hidden by a probe."])
            #expect(harness.allowlist.calls.isEmpty)
        }
    }

    @Test func anAppThatQuitsDuringTheProbeIsNotAFailureToRestore() async throws {
        let harness = try ProbeHarness.make(clicks: [click])
        let quit = harness.otherQuit
        harness.allowlist.onActivated { quit.set(true) }
        let report = await harness.run(.clickReplay)
        #expect(report.restored)
        #expect(report.errors.isEmpty)
    }

    @Test func anotherAppThanTheFixtureIsRefusedWithoutAllowAny() async throws {
        let harness = try ProbeHarness.make(clicks: [click])
        let report = await harness.run(.clickReplay, ["app": otherID])
        #expect(report.errors == ["This probe only touches MantelTestItem. Add --allow-any to touch \(otherID)."])
        #expect(harness.allowlist.calls.isEmpty)
        #expect(harness.taps.made.isEmpty)
    }

    @Test func anActivationThatFailsIsAnErrorAndNoTapIsMade() async throws {
        let harness = try ProbeHarness.make(clicks: [click])
        harness.allowlist.fail(with: .failed("no"))
        let report = await harness.run(.clickReplay)
        #expect(report.errors.contains { $0.contains("no") })
        #expect(harness.taps.made.isEmpty)
    }
}

// MARK: reveal-latency

@Suite("Reveal-latency probe", .timeLimit(.minutes(1)))
struct RevealLatencyProbeTests {
    private func list(_ report: ProbeReport, _ key: String) throws -> [JSONValue] {
        let stats = try #require(report.object(key), "\(key) is an object")
        guard case .array(let values)? = stats["values"] else {
            Issue.record("\(key) holds its values")
            return []
        }
        return values
    }

    private func number(_ report: ProbeReport, _ key: String, _ name: String) -> Double? {
        if case .number(let value)? = report.object(key)?[name] { return value }
        return nil
    }

    @Test func revealLatencyPollsOnlyTheAppsExtras() async throws {
        // A read of MenuBarAgent costs about half a second on a real Mac, which would be what was measured: while a time is taken
        // nothing of the agent's is read, and nothing of any other app's either.
        let harness = try ProbeHarness.make(readCost: .milliseconds(1), extrasLag: .milliseconds(30))
        let agentRoot = harness.ax.root(ofApp: ProbeHarness.agentPID)
        let otherApp = harness.ax.root(ofApp: 301)
        let mantel = harness.ax.root(ofApp: 100)

        let report = await harness.run(.revealLatency, ["runs": "4"])

        #expect(report.errors.isEmpty)
        #expect(harness.ax.attributeReads(on: agentRoot) == 0, "MenuBarAgent is never read")
        #expect(harness.ax.attributeReads(on: harness.window) == 0)
        #expect(harness.ax.attributeReads(on: harness.clockSlot) == 0)
        #expect(harness.slotOwners.keys.allSatisfy { harness.ax.attributeReads(on: $0) == 0 }, "nor any slot of it")
        #expect(harness.ax.attributeReads(on: otherApp) == 0, "no other app is asked for its items")
        #expect(harness.ax.attributeReads(on: mantel) == 0)
        let appRoot = harness.ax.root(ofApp: 300)
        #expect(harness.ax.attributeReads(on: appRoot) > 0, "the test item's own list is what is read")
        #expect(harness.ax.attributeReads(on: harness.fixtureExtras[0]) > 0)
        #expect(harness.windows.readCount == 0, "and the window list isn't")
    }

    @Test func eachRunTimesTheHideAndTheRevealAndTheTwoWaysAlternate() async throws {
        let harness = try ProbeHarness.make(extrasLag: .milliseconds(40))
        let report = await harness.run(.revealLatency, ["runs": "5"])

        #expect(report.errors.isEmpty)
        #expect(report.restored)
        #expect(report.measurements["runs"] == .number(5))
        #expect(report.measurements["app"] == .string(fixtureID))
        #expect(report.measurements["baselineItemCount"] == .number(2))
        #expect(report.measurements["baselineFrames"] == .array([NotchCoordinatesProbe.rect(CGRect(x: 3100, y: 0, width: 40, height: 31)),
                                                                 NotchCoordinatesProbe.rect(CGRect(x: 3150, y: 0, width: 40, height: 31))]))
        // Five runs: swap, release, swap, release, swap.
        #expect(try list(report, "hideMs").count == 5)
        #expect(try list(report, "revealSwapMs").count == 3)
        #expect(try list(report, "revealReleaseMs").count == 2)
        // The items follow the allowlist 40 ms after it, and the polls are every 10 ms: the time is the lag (a date's own rounding aside).
        for key in ["hideMs", "revealSwapMs", "revealReleaseMs"] {
            for value in try list(report, key) {
                guard case .number(let ms) = value else {
                    Issue.record("\(key) holds numbers")
                    continue
                }
                #expect(abs(ms - 40) < 0.01, "\(key) is the lag of the items: \(ms)")
            }
            for name in ["p50", "p95", "max"] {
                #expect(abs((number(report, key, name) ?? 0) - 40) < 0.01, "\(key) \(name)")
            }
        }
        #expect(number(report, "hideMs", "count") == 5)
        #expect(report.object("pollReadMs") != nil)
        #expect(report.object("pollReadMs")?["values"] == nil, "what a read cost is said by its numbers, not listed")
        #expect(report.restored)
    }

    @Test func aSwapIsActivatedBeforeTheOldAllowlistIsLetGo() async throws {
        let harness = try ProbeHarness.make(extrasLag: .milliseconds(20))
        let calls = harness.allowlist
        let report = await harness.run(.revealLatency, ["runs": "1"])
        #expect(report.errors.isEmpty)
        // The first run swaps: an allowlist that hides the test item, then one that allows every running app.
        let all = calls.calls
        #expect(all.count == 2)
        #expect(!all[0].bundleIDs.contains(fixtureID) && all[0].bundleIDs.contains(ownID))
        #expect(all[1].bundleIDs.contains(fixtureID), "the second names every running app")
        #expect(Set(all[1].bundleIDs) == Set(ProbeHarness.runningApps.compactMap(\.bundleID)))
        #expect(calls.live == 0)
        #expect(calls.invalidations == 2)
    }

    @Test func aSecondRunWhoseOddRunIsReleasedMakesOneActivationAndOneRelease() async throws {
        let harness = try ProbeHarness.make(extrasLag: .milliseconds(20))
        let report = await harness.run(.revealLatency, ["runs": "2"])
        #expect(report.errors.isEmpty)
        // Run 1 swaps (two activations), run 2 releases (one).
        #expect(harness.allowlist.calls.count == 3)
        #expect(harness.allowlist.invalidations == 3)
        #expect(harness.allowlist.live == 0)
    }

    @Test func theRunsAreKeptBetweenOneAndTwenty() async throws {
        let low = try ProbeHarness.make()
        #expect(await low.run(.revealLatency, ["runs": "0"]).measurements["runs"] == .number(1))
        let high = try ProbeHarness.make()
        #expect(await high.run(.revealLatency, ["runs": "99"]).measurements["runs"] == .number(20))
        let normal = try ProbeHarness.make()
        #expect(await normal.run(.revealLatency).measurements["runs"] == .number(10))
    }

    @Test func aChangeThatNeverComesIsNullAndSaidInTheNotes() async throws {
        // The items lag for 5 s: each phase is given 2 s.
        let harness = try ProbeHarness.make(extrasLag: .seconds(5))
        let report = await harness.run(.revealLatency, ["runs": "1"])
        #expect(try list(report, "hideMs") == [.null])
        #expect(number(report, "hideMs", "p50") == nil)
        #expect(report.notes.contains { $0.contains("didn't see the items concealed") })
        #expect(harness.allowlist.live == 0, "and everything is let go all the same")
    }

    @Test func revealLatencyAlwaysReleases() async throws {
        // Cut short while the allowlist is live (the items are slow to follow, so the probe is waiting on its clock).
        let clock = FakeClock()
        let harness = try ProbeHarness.make(clock: clock, extrasLag: .seconds(1))
        let running = Task { await harness.run(.revealLatency, ["runs": "3"]) }
        await clock.waitForSleepers(1)
        #expect(harness.allowlist.live == 1, "the probe is holding an allowlist")

        await harness.runner.shutDown()
        let cut = await running.value
        #expect(harness.allowlist.live == 0)
        #expect(cut.restored)
        #expect(cut.notes.contains { $0.contains("cut short") })

        // An activation that fails part way (the swap's): what was live is let go.
        let failing = try ProbeHarness.make(extrasLag: .milliseconds(20))
        let allowlist = failing.allowlist
        failing.allowlist.onActivated { allowlist.fail(with: .failed("refused")) }
        let report = await failing.run(.revealLatency, ["runs": "2"])
        #expect(report.errors.contains { $0.contains("refused") })
        #expect(failing.allowlist.live == 0)
        #expect(failing.allowlist.invalidations == 1)
        #expect(report.restored)
    }

    @Test func theTestItemMustBeRunningAndHaveItemsToWatch() async throws {
        let notRunning = try ProbeHarness.make { platform in
            let known = platform.runningApps
            platform.runningApps = { known().filter { $0.bundleID != fixtureID } }
        }
        let report = await notRunning.run(.revealLatency)
        #expect(report.errors == ["Nothing to hide: \(fixtureID) isn't running. Open MantelTestItem first."])
        #expect(notRunning.allowlist.calls.isEmpty)

        let noItems = try ProbeHarness.make()
        noItems.ax.setAttribute(AXName.extrasMenuBar, .elements([]), on: noItems.ax.root(ofApp: 300))
        let empty = await noItems.run(.revealLatency)
        #expect(empty.errors.count == 1 && empty.errors[0].contains("no items in the menu bar to watch"))
        #expect(noItems.allowlist.calls.isEmpty)
    }

    @Test func anotherAppNeedsAllowAnyAndMantelsOwnItemIsNeverHidden() async throws {
        let refused = try ProbeHarness.make()
        let report = await refused.run(.revealLatency, ["app": otherID])
        #expect(report.errors == ["This probe only touches MantelTestItem. Add --allow-any to touch \(otherID)."])
        #expect(refused.allowlist.calls.isEmpty)

        let own = try ProbeHarness.make()
        #expect(await own.run(.revealLatency, ["app": ownID, "allow-any": "true"]).errors == ["Mantel's own item is never hidden by a probe."])

        let system = try ProbeHarness.make()
        #expect(await system.run(.revealLatency, ["system-items": "2,5"]).errors
                == ["This probe only hides MantelTestItem. Add --allow-any to hide system items."])
        #expect(system.allowlist.calls.isEmpty)
    }

    @Test func allowAnyLetsItWatchAnotherApp() async throws {
        let harness = try ProbeHarness.make()
        let report = await harness.run(.revealLatency, ["app": otherID, "allow-any": "true", "runs": "1"])
        #expect(report.errors.isEmpty)
        #expect(report.measurements["app"] == .string(otherID))
        #expect(harness.allowlist.calls.first.map { !$0.bundleIDs.contains(otherID) } == true)
    }
}

// MARK: Latency statistics

@Suite("Latency statistics")
struct LatencyStatsTests {
    @Test func theMiddleOneTheNinetyFifthAndTheLongest() {
        let stats = LatencyStats(values: [50, 10, 30, 20, 40])
        #expect(stats.p50 == 30)
        #expect(stats.p95 == 50, "with fewer than twenty times the 95th is the longest")
        #expect(stats.max == 50)
        let many = LatencyStats(values: (1...20).map { Double($0) })
        #expect(many.p50 == 10)
        #expect(many.p95 == 19)
        #expect(many.max == 20)
    }

    @Test func aTimeThatWasntMeasuredIsNullInTheListAndLeftOutOfTheNumbers() {
        let stats = LatencyStats(values: [10, nil, 30])
        #expect(stats.p50 == 10)
        #expect(stats.max == 30)
        guard case .object(let json) = stats.json() else {
            Issue.record("an object")
            return
        }
        #expect(json["values"] == .array([.number(10), .null, .number(30)]))
        #expect(json["count"] == .number(2))
        #expect(LatencyStats(values: []).json(includingValues: false) == .object(["count": .number(0), "p50": .null, "p95": .null, "max": .null]))
    }
}

// MARK: approvals-decode and approvals-flip

/// The approvals list in a blob, in a file the harness grants, with the test item's own list of its items concealed while its flag is
/// false in the blob (as the real menu bar is while its switch is off).
/// How many times the file was written through the preferences layer.
private final class WriteCounter: Sendable {
    private let count = Mutex(0)

    func bump() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}

private struct ApprovalsDesk {
    let harness: ProbeHarness
    let codec: any PlistBlobCodec
    let flagPath: PlistKeyPath
    let writes: WriteCounter

    static let marker = fixtureID

    /// - Parameter service: what the system does to a value that is written to it before it keeps it, which a test gives when the
    ///   system writes the list again in its own way (`reorderedByTheSystem`, and the others below).
    /// - Parameter duringTheWatch: runs once, with the file's URL, the first time the menu bar is looked at while the flag is off in the
    ///   list: something else (System Settings) rewrites the file while the probe waits to see the items go.
    static func make(blob: Data, codec: any PlistBlobCodec, flagPath: PlistKeyPath, lag: Duration = .zero,
                     platformTestEnabled: Bool = true, duringTheWatch: (@Sendable (URL) -> Void)? = nil,
                     service: @escaping @Sendable (PlistValue?) -> PlistValue? = { $0 }) async throws -> ApprovalsDesk {
        let writes = WriteCounter()
        let io = PlistIO(read: PlistIO.filesOnly.read, write: { value, key, url, strategy in
            writes.bump()
            try PlistIO.filesOnly.write(service(value), key, url, strategy)
        })
        let harness = try ProbeHarness.make(io: io, platformTestEnabled: platformTestEnabled)
        let url = try await harness.installFile(.controlCenterApprovals, ["trackedApplications": blob])
        let items = Set(harness.fixtureExtras)
        let interfered = Mutex(false)
        harness.ax.setOverride { id, name in
            guard name == AXName.position, items.contains(id),
                  case .data(let held)? = try? PlistIO.readFile(url, key: "trackedApplications"),
                  (try? codec.value(at: flagPath, in: held)) == .bool(false) else { return nil }
            let isFirst = interfered.withLock { done -> Bool in
                defer { done = true }
                return !done
            }
            if isFirst, let duringTheWatch { duringTheWatch(url) }
            return .success(.point(CGPoint(x: -1, y: 0)))
        }
        return ApprovalsDesk(harness: harness, codec: codec, flagPath: flagPath, writes: writes)
    }

    /// The blob under `trackedApplications` as the file holds it now.
    func blob() throws -> Data {
        guard case .data(let held)? = try PlistIO.readFile(harness.approvalsURL, key: "trackedApplications") else {
            throw ApprovalsDeskError.notABlob
        }
        return held
    }

    enum ApprovalsDeskError: Error { case notABlob }
}

/// An approvals list changed the way the system does when it keeps a write: through `change` on the array of entries.
private func rewrittenByTheSystem(_ value: PlistValue?, _ change: ([Any]) -> [Any]) -> PlistValue? {
    guard case .data(let blob)? = value,
          let entries = try? PropertyListSerialization.propertyList(from: blob, format: nil) as? [Any],
          let data = try? PropertyListSerialization.data(fromPropertyList: change(entries), format: .binary, options: 0) else { return value }
    return .data(data)
}

/// The system writes the whole list again, and its entries come out in the opposite order.
@Sendable private func reorderedByTheSystem(_ value: PlistValue?) -> PlistValue? {
    rewrittenByTheSystem(value) { Array($0.reversed()) }
}

/// The system adds an entry of its own to the list each time it is written.
@Sendable private func addingAnEntry(_ value: PlistValue?) -> PlistValue? {
    rewrittenByTheSystem(value) { $0 + [BlobFixtures.Approval("com.example.extra", allowed: true).object] }
}

/// The system writes the entry of the test item twice.
@Sendable private func doublingTheTestItem(_ value: PlistValue?) -> PlistValue? {
    rewrittenByTheSystem(value) { entries in
        entries + entries.filter { entry in
            let places = (entry as? [String: Any])?["menuItemLocations"] as? [[String: Any]]
            return places?.contains { ($0["bundle"] as? [String: Any])?["_0"] as? String == fixtureID } ?? false
        }
    }
}

/// An entry of the test item's, found by the way macOS's list names it, with its flag from there.
private func approvalsFlag(_ id: String) -> PlistKeyPath {
    [.matchingPath(path: [.key("menuItemLocations"), .anyElement, .key("bundle"), .key("_0")], value: id), .key("isAllowed")]
}

private func plainEntryPath(_ id: String) -> PlistKeyPath { [.key("apps"), .matching(key: "bundleID", value: id), .key("allowed")] }
private func archiveEntryPath(_ id: String) -> PlistKeyPath { [.key("$objects"), .matching(key: "bundleID", value: id), .key("allowed")] }

@Suite("Approvals-flip probe", .timeLimit(.minutes(1)))
struct ApprovalsFlipProbeTests {
    private let plain = BlobFixtures.plainEntries([(fixtureID, true, 1), (otherID, true, 2)])

    private func list(_ report: ProbeReport, _ key: String) -> [JSONValue] {
        if case .array(let values)? = report.object(key)?["values"] { return values }
        Issue.record("\(key) holds its values")
        return []
    }

    @Test func approvalsFlipUndoesEachRun() async throws {
        let desk = try await ApprovalsDesk.make(blob: plain, codec: NestedPlistCodec(), flagPath: plainEntryPath(fixtureID))
        let harness = desk.harness

        let report = await harness.run(.approvalsFlip, ["flag-path": "k:allowed", "codec": "nested", "runs": "3"])

        #expect(report.errors == [])
        #expect(report.restored)
        #expect(report.measurements["restored"] == .bool(true))
        #expect(desk.writes.value == 6, "a write to flip and a write to put back, for each of the three runs")
        #expect(await harness.journal.records().isEmpty, "each run's record was taken out by its undo")
        // The flag is what it was, and so is the other app's.
        let held = try desk.blob()
        #expect(try NestedPlistCodec().value(at: plainEntryPath(fixtureID), in: held) == .bool(true))
        #expect(try NestedPlistCodec().value(at: plainEntryPath(otherID), in: held) == .bool(true), "another app's entry is never touched")
        // Each run saw the items concealed and shown again.
        #expect(list(report, "writeToHiddenMs").count == 3)
        #expect(list(report, "restoreToShownMs").count == 3)
        #expect(!list(report, "writeToHiddenMs").contains(.null))
        #expect(!list(report, "restoreToShownMs").contains(.null))
        #expect(report.measurements["codec"] == .string("nested"))
        #expect(report.measurements["idKey"] == .string("bundleID"), "the only key of the entry that holds the test item's ID")
        #expect(report.measurements["entryPath"] == .string("/k:apps/m:bundleID=\(fixtureID)/k:allowed"))
        #expect(report.measurements["wasFlag"] == .bool(true))
        #expect(report.measurements["runs"] == .number(3))
        #expect(report.measurements["reencodedIdentical"] != nil)
        // A backup of the file was made before its first change.
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: harness.paths.backups.path)) ?? []).count == 1)
    }

    @Test func theFlipCodecPutsAKeyedArchiveBackByteForByte() async throws {
        // One entry that is true, one that is false: the true is the test item's alone.
        let archive = BlobFixtures.archive([(fixtureID, true, 1), (otherID, false, 2)])
        let desk = try await ApprovalsDesk.make(blob: archive, codec: BinaryPlistFlip(), flagPath: archiveEntryPath(fixtureID))

        let report = await desk.harness.run(.approvalsFlip, ["flag-path": "k:allowed", "codec": "flip", "runs": "2"])

        #expect(report.errors == [])
        #expect(report.restored)
        #expect(try desk.blob() == archive, "the list is the bytes it was")
        #expect(report.measurements["reencodedIdentical"] == .bool(false), "a keyed archive can't be decoded as a property list and written again")
        #expect(report.measurements["blobByteCount"] == .number(Double(archive.count)))
        #expect(report.measurements["entryPath"] == .string("/k:$objects/m:bundleID=\(fixtureID)/k:allowed"))
        #expect(list(report, "writeToHiddenMs").count == 2 && !list(report, "writeToHiddenMs").contains(.null))
        #expect(await desk.harness.journal.records().isEmpty)
    }

    @Test func reencodedIdenticalIsWhatEncodingItAgainGivesWhicheverCodecIsChosen() async throws {
        // A list written in one order only: decoded and encoded again it is the same bytes, whether the probe then changes it as a
        // property list or in place. (The flip codec's own no-change write is always the same bytes, and says nothing.)
        let single = try PropertyListSerialization.data(fromPropertyList: [fixtureID: ["allowed": true]] as [String: Any], format: .binary, options: 0)
        #expect(try NestedPlistCodec.reencoded(single) == single)
        for (codecName, codec) in [("nested", NestedPlistCodec() as any PlistBlobCodec), ("flip", BinaryPlistFlip())] {
            let desk = try await ApprovalsDesk.make(blob: single, codec: codec, flagPath: [.key(fixtureID), .key("allowed")])
            let report = await desk.harness.run(.approvalsFlip, ["flag-path": "k:allowed", "codec": codecName, "runs": "1"])
            #expect(report.errors == [], "\(codecName)")
            #expect(report.measurements["reencodedIdentical"] == .bool(true), "\(codecName)")
            #expect(try desk.blob() == single)
        }

        // Entries of several keys: whatever re-encoding gives, both codecs say the same of it, and it is what `nested` writes.
        let several = BlobFixtures.plainEntries([(fixtureID, true, 1), (otherID, false, 2)])
        let expected = (try? NestedPlistCodec.reencoded(several)) == several
        for codecName in ["nested", "flip"] {
            let desk = try await ApprovalsDesk.make(blob: several, codec: codecName == "nested" ? NestedPlistCodec() : BinaryPlistFlip(),
                                                    flagPath: plainEntryPath(fixtureID))
            let report = await desk.harness.run(.approvalsFlip, ["flag-path": "k:allowed", "codec": codecName, "runs": "1"])
            #expect(report.errors == [], "\(codecName)")
            #expect(report.measurements["reencodedIdentical"] == .bool(expected), "\(codecName) says what encoding it again gives")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aListTooLargeToRecodeIsSaidSoAndIsStillFlippedInPlace() async throws {
        // The list holds, beside the test item's entry, a list that refers to its own parts so many times that decoding it as a
        // property list would be sixteen million values.
        let blob = BlobFixtures.approvalsWithDeeplySharedList(levels: 24)
        let desk = try await ApprovalsDesk.make(blob: blob, codec: BinaryPlistFlip(), flagPath: plainEntryPath(fixtureID))

        let report = await desk.harness.run(.approvalsFlip, ["flag-path": "k:allowed", "codec": "flip", "runs": "1"])

        #expect(report.errors == [])
        #expect(report.measurements["reencodedIdentical"] == .bool(false))
        #expect(report.notes.contains { $0.contains("too large to compare with its own re-encoding") })
        #expect(report.restored)
        #expect(try desk.blob() == blob, "and the flag was flipped in place and put back")

        // As a property list it can't be changed, and the probe says why.
        let nestedDesk = try await ApprovalsDesk.make(blob: blob, codec: NestedPlistCodec(), flagPath: plainEntryPath(fixtureID))
        let refused = await nestedDesk.harness.run(.approvalsFlip, ["flag-path": "k:allowed", "codec": "nested", "runs": "1"])
        #expect(refused.errors.count == 1 && refused.errors[0].contains("too large to read whole"))
        #expect(nestedDesk.writes.value == 0)
    }

    @Test func aFlagTheListSharesWithAnotherEntryIsFlippedForTheTestItemAlone() async throws {
        // Both are true, as is the other one: the list has one true object. The probe flips only the test item's, by pointing it at
        // the false the list has.
        let archive = BlobFixtures.archive([(fixtureID, true, 1), (otherID, true, 2), ("com.example.third", false, 3)])
        let desk = try await ApprovalsDesk.make(blob: archive, codec: BinaryPlistFlip(), flagPath: archiveEntryPath(fixtureID))

        let report = await desk.harness.run(.approvalsFlip, ["flag-path": "k:allowed", "codec": "flip", "runs": "1"])

        #expect(report.errors == [])
        #expect(list(report, "writeToHiddenMs").first.map { $0 != .null } == true, "the test item's items were concealed")
        let held = try desk.blob()
        #expect(try BinaryPlistFlip().value(at: archiveEntryPath(otherID), in: held) == .bool(true), "the other app's flag was never false")
        #expect(held == archive)
    }

    @Test func aFlagThatWouldChangeOtherEntriesIsRefusedAndNothingIsChanged() async throws {
        // Every entry is true: there is no false to point the test item's at, and flipping the one would flip every entry.
        let archive = BlobFixtures.archive([(fixtureID, true, 1), (otherID, true, 2)])
        let desk = try await ApprovalsDesk.make(blob: archive, codec: BinaryPlistFlip(), flagPath: archiveEntryPath(fixtureID))
        let before = try Data(contentsOf: desk.harness.approvalsURL)

        let report = await desk.harness.run(.approvalsFlip, ["flag-path": "k:allowed", "codec": "flip"])

        #expect(report.errors.contains { $0.contains("shared") })
        #expect(report.restored)
        #expect(try Data(contentsOf: desk.harness.approvalsURL) == before, "the file is as it was")
        #expect(await desk.harness.journal.records().isEmpty, "nothing was journaled for a change that couldn't be made")
        #expect(desk.writes.value == 0)
    }

    @Test func theNestedCodecRefusesAKeyedArchiveAndSaysWhatToUse() async throws {
        let archive = BlobFixtures.archive([(fixtureID, true, 1), (otherID, false, 2)])
        let desk = try await ApprovalsDesk.make(blob: archive, codec: BinaryPlistFlip(), flagPath: archiveEntryPath(fixtureID))
        let report = await desk.harness.run(.approvalsFlip, ["flag-path": "k:allowed", "codec": "nested"])
        #expect(report.errors.contains { $0.contains("This list is an archive; use the flip codec") })
        #expect(desk.writes.value == 0)
        #expect(report.restored)
    }

    @Test func theIDKeyIsFoundWhenOnlyOneKeyHoldsTheIDAndSaidWhenSeveralDo() async throws {
        let entries: [[String: Any]] = [["bundleID": fixtureID, "alias": fixtureID, "allowed": true], ["bundleID": otherID, "alias": otherID, "allowed": true]]
        let blob = try PropertyListSerialization.data(fromPropertyList: ["apps": entries], format: .binary, options: 0)
        let desk = try await ApprovalsDesk.make(blob: blob, codec: NestedPlistCodec(), flagPath: plainEntryPath(fixtureID))

        let ambiguous = await desk.harness.run(.approvalsFlip, ["flag-path": "k:allowed", "codec": "nested"])
        #expect(ambiguous.errors == ["More than one key of the entry holds the test item's ID: alias, bundleID. Say which with --id-key."])
        #expect(desk.writes.value == 0)

        let said = await desk.harness.run(.approvalsFlip, ["flag-path": "k:allowed", "codec": "nested", "id-key": "alias", "runs": "1"])
        #expect(said.errors == [])
        #expect(said.measurements["idKey"] == .string("alias"))
        #expect(said.measurements["entryPath"] == .string("/k:apps/m:alias=\(fixtureID)/k:allowed"))

        let wrong = await desk.harness.run(.approvalsFlip, ["flag-path": "k:allowed", "codec": "nested", "id-key": "nothing"])
        #expect(wrong.errors.count == 1 && wrong.errors[0].contains("no key called nothing"))
    }

    @Test func aDictionaryKeyedByTheTestItemIsFoundToo() async throws {
        let keyed: [String: Any] = [fixtureID: ["allowed": true], otherID: ["allowed": true]]
        let blob = try PropertyListSerialization.data(fromPropertyList: keyed, format: .binary, options: 0)
        let desk = try await ApprovalsDesk.make(blob: blob, codec: NestedPlistCodec(), flagPath: [.key(fixtureID), .key("allowed")])
        let report = await desk.harness.run(.approvalsFlip, ["flag-path": "k:allowed", "codec": "nested", "runs": "1"])
        #expect(report.errors == [])
        #expect(report.measurements["entryPath"] == .string("/k:‹test item›/k:allowed"), "the test item's ID as a key is not said")
        #expect(report.measurements["idKey"] == nil)
    }

    // MARK: Finding the entry by a way to its ID

    private let way = "k:menuItemLocations/*/k:bundle/k:_0"

    private func approvalsDesk(service: @escaping @Sendable (PlistValue?) -> PlistValue? = { $0 },
                               entries: [BlobFixtures.Approval] = BlobFixtures.approvals()) async throws -> ApprovalsDesk {
        try await ApprovalsDesk.make(blob: BlobFixtures.approvalsList(entries), codec: NestedPlistCodec(), flagPath: approvalsFlag(fixtureID),
                                     service: service)
    }

    private func entries(_ blob: Data) throws -> [NSDictionary] {
        try #require(PropertyListSerialization.propertyList(from: blob, format: nil) as? [NSDictionary])
    }

    @Test func approvalsFlipWithMatchPathUndoesEachRun() async throws {
        // The system writes the list again in the opposite order every time it keeps a write, so the entry is never where it was.
        let original = BlobFixtures.approvalsList(BlobFixtures.approvals())
        let desk = try await approvalsDesk(service: reorderedByTheSystem)
        let harness = desk.harness

        let report = await harness.run(.approvalsFlip, ["match-path": way, "flag-path": "k:isAllowed", "codec": "nested", "runs": "3"])

        #expect(report.errors == [])
        #expect(report.restored)
        #expect(report.measurements["restored"] == .bool(true))
        #expect(desk.writes.value == 6, "a write to flip and a write to put back, for each of the three runs")
        #expect(await harness.journal.records().isEmpty, "each run's record was taken out by its undo")
        // The flag is what it was, every other entry is as it was, and none was added or taken out.
        let held = try desk.blob()
        #expect(try NestedPlistCodec().value(at: approvalsFlag(fixtureID), in: held) == .bool(true))
        #expect(try Set(entries(held)) == Set(entries(original)))
        #expect(try entries(held).count == 5)
        for other in ["com.example.one", "com.example.three"] {
            #expect(try NestedPlistCodec().value(at: approvalsFlag(other), in: held) == NestedPlistCodec().value(at: approvalsFlag(other), in: original))
        }
        // Each run saw the items concealed and shown again.
        #expect(list(report, "writeToHiddenMs").count == 3 && !list(report, "writeToHiddenMs").contains(.null))
        #expect(list(report, "restoreToShownMs").count == 3 && !list(report, "restoreToShownMs").contains(.null))
        #expect(report.measurements["codec"] == .string("nested"))
        #expect(report.measurements["entryPath"] == .string("/mp:k:menuItemLocations,*,k:bundle,k:_0=\(fixtureID)/k:isAllowed"))
        #expect(report.measurements["idKey"] == nil, "no key holds the ID")
        #expect(report.measurements["wasFlag"] == .bool(true))
        #expect(report.measurements["runs"] == .number(3))
        #expect(report.measurements["reencodedIdentical"] != nil)
        #expect(!(try said(report)).contains("com.example.one"), "another app's ID is never said")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: harness.paths.backups.path)) ?? []).count == 1)
    }

    private func said(_ report: ProbeReport) throws -> String {
        String(decoding: try JSONCoding.encoder().encode(report), as: UTF8.self)
    }

    @Test func approvalsFlipRecordsEntryCounts() async throws {
        let desk = try await approvalsDesk(service: reorderedByTheSystem)
        let report = await desk.harness.run(.approvalsFlip, ["match-path": way, "flag-path": "k:isAllowed", "codec": "nested", "runs": "2"])

        #expect(report.errors == [])
        #expect(report.measurements["entryCountBefore"] == .number(5))
        #expect(report.measurements["entryCountsAfterWrite"] == .array([.number(5), .number(5)]))
        #expect(report.measurements["entryCountAfter"] == .number(5))
        #expect(report.measurements["matchedOnceAfterEachWrite"] == .bool(true))
        #expect(!report.notes.contains { $0.contains("changed it while the probe ran") })

        // The system adds an entry of its own each time it keeps a write: the counts say so, and the entry still matches once.
        let growing = try await approvalsDesk(service: addingAnEntry)
        let grown = await growing.harness.run(.approvalsFlip, ["match-path": way, "flag-path": "k:isAllowed", "codec": "nested", "runs": "2"])
        #expect(grown.errors == [])
        #expect(grown.restored)
        #expect(grown.measurements["entryCountBefore"] == .number(5))
        #expect(grown.measurements["entryCountsAfterWrite"] == .array([.number(6), .number(8)]))
        #expect(grown.measurements["entryCountAfter"] == .number(9))
        #expect(grown.measurements["matchedOnceAfterEachWrite"] == .bool(true))
        #expect(grown.notes.contains { $0.contains("5 entries before the probe and has 9 now") })
        #expect(try NestedPlistCodec().value(at: approvalsFlag(fixtureID), in: growing.blob()) == .bool(true))
    }

    @Test func anEntryThatTheSystemDoublesWhileTheProbeWatchesIsSaidAndTheRecordStays() async throws {
        // The write is kept and checked. Then System Settings writes the list again with two entries for the test item: which one was
        // changed isn't known, so the probe does not put one back over the other. It says so, and the journal still has the change.
        let desk = try await ApprovalsDesk.make(blob: BlobFixtures.approvalsList(BlobFixtures.approvals()), codec: NestedPlistCodec(),
                                                flagPath: approvalsFlag(fixtureID), duringTheWatch: { url in
            let doubled = (try? PlistIO.readFile(url, key: "trackedApplications")).map { doublingTheTestItem($0) }
            if let doubled { try? PlistIO.writeFile(doubled, key: "trackedApplications", to: url) }
        })
        let report = await desk.harness.run(.approvalsFlip, ["match-path": way, "flag-path": "k:isAllowed", "codec": "nested", "runs": "3"])

        #expect(report.measurements["entryCountBefore"] == .number(5))
        #expect(report.measurements["entryCountsAfterWrite"] == .array([.number(6)]))
        #expect(report.measurements["matchedOnceAfterEachWrite"] == .bool(false))
        #expect(report.notes.contains { $0.contains("didn't match exactly once") })
        #expect(report.notes.contains { $0.contains("5 entries before the probe and has 6 now") })
        #expect(!report.restored)
        #expect(report.errors.contains { $0.contains("couldn't be put back") })
        #expect(await desk.harness.journal.records().count == 1, "the change is still in the journal")
        #expect(desk.writes.value == 1, "and nothing more was written")
    }

    @Test func aWriteTheSystemKeepsWithTwoEntriesForTheTestItemIsNotAWriteThatTook() async throws {
        let desk = try await approvalsDesk(service: doublingTheTestItem)
        let report = await desk.harness.run(.approvalsFlip, ["match-path": way, "flag-path": "k:isAllowed", "codec": "nested", "runs": "3"])

        #expect(report.errors.contains { $0.contains("The flag couldn't be changed in run 1") })
        #expect(!report.restored)
        #expect(await desk.harness.journal.records().count == 1, "the change is in the journal, for the next start")
        #expect(desk.writes.value == 1, "and the probe went no further")
        #expect(report.measurements["writeToHiddenMs"] != nil)
    }

    @Test func flagPathRefusesMatchingPath() async throws {
        let desk = try await approvalsDesk()
        let harness = desk.harness
        let refusal = ["The flag-path is a place from the entry, so it can't hold a step that finds an entry (mp:). --match-path finds the entry."]

        // A step that finds an entry in the flag-path, by itself or after a key: the flag is one place of the entry that was found.
        for text in ["mp:k:menuItemLocations,*,k:bundle,k:_0=com.example.other/k:isAllowed", "k:menuItemLocations/mp:*,k:_0=x/k:isAllowed"] {
            let report = await harness.run(.approvalsFlip, ["match-path": way, "flag-path": text, "codec": "nested"])
            #expect(report.errors == refusal, "\(text)")
        }
        // One inside another is no path at all.
        let nested = await harness.run(.approvalsFlip, ["match-path": way, "flag-path": "mp:mp:k:a=b=c/k:isAllowed", "codec": "nested"])
        #expect(nested.errors == ["The flag-path isn't in the form k:name or k:name/i:2."])
        // Nothing is read or changed for it, and a flag-path of keys, positions and the m: step is as it was.
        #expect(desk.writes.value == 0)
        #expect(await harness.journal.records().isEmpty)
        let fine = await harness.run(.approvalsFlip, ["match-path": way, "flag-path": "k:isAllowed", "codec": "nested", "runs": "1"])
        #expect(fine.errors.isEmpty)
    }

    @Test func theMatchPathRequestIsCheckedBeforeAnythingIsChanged() async throws {
        let desk = try await approvalsDesk()
        let harness = desk.harness
        func errors(_ options: [String: String]) async -> [String] {
            await harness.run(.approvalsFlip, options.merging(["flag-path": "k:isAllowed", "codec": "nested"]) { given, _ in given }).errors
        }

        #expect(await errors(["match-path": way, "id-key": "bundleID"]) == ["Give --id-key or --match-path, not both."])
        for text in ["x:1", "mp:k:a=b", "k:a//k:b", "k:a%2"] {
            #expect(await errors(["match-path": text]).first?.contains("isn't in the form") == true, "\(text)")
        }
        #expect(await errors(["match-path": "k:menuItemLocations/*/k:bundle/k:nothing"])
                == ["The test item is in the list, but --match-path doesn't lead to its ID. Run approvals-decode to see the entry's keys."])
        #expect(await errors(["match-path": way, "flag-path": "k:*"]).first?.contains("Nothing is at") == true, "a key called * is a key")
        #expect(await errors(["match-path": way, "flag-path": "*/k:isAllowed"]) == ["The flag-path is one place, so it can't say * (any element)."])
        #expect(await errors(["match-path": way, "flag-path": "k:note"]).first?.contains("Nothing is at") == true)
        #expect(await errors(["match-path": way, "flag-path": "k:menuItemLocations"]).first?.contains("isn't a flag") == true)
        #expect(desk.writes.value == 0, "no write was made by any of them")
        #expect(await harness.journal.records().isEmpty)

        // Two entries claim the test item: nothing is changed.
        let twice = try await approvalsDesk(entries: BlobFixtures.approvals() + [BlobFixtures.Approval(fixtureID, allowed: false)])
        let ambiguous = await twice.harness.run(.approvalsFlip, ["match-path": way, "flag-path": "k:isAllowed", "codec": "nested"])
        #expect(ambiguous.errors == ["More than one entry of the list holds the test item's ID where --match-path says, so which one to change isn't known. Nothing was changed."])
        #expect(twice.writes.value == 0)

        // The test item isn't in the list at all.
        let absent = try await approvalsDesk(entries: [BlobFixtures.Approval("com.example.one", allowed: true)])
        let missing = await absent.harness.run(.approvalsFlip, ["match-path": way, "flag-path": "k:isAllowed", "codec": "nested"])
        #expect(missing.errors.count == 1 && missing.errors[0].contains("isn't in the list"))

        // A keyed archive has no way to its entries.
        let archive = BlobFixtures.archive([(fixtureID, true, 1), (otherID, false, 2)])
        let archived = try await ApprovalsDesk.make(blob: archive, codec: BinaryPlistFlip(), flagPath: archiveEntryPath(fixtureID))
        let refused = await archived.harness.run(.approvalsFlip, ["match-path": "k:bundleID", "flag-path": "k:allowed", "codec": "flip"])
        #expect(refused.errors == ["--match-path follows a list that is a property list, and this one is a keyed archive. Use --id-key."])
        #expect(archived.writes.value == 0)
    }

    @Test func withoutAMatchPathAListThatNamesItsAppsDeeperSaysToUseOne() async throws {
        let desk = try await approvalsDesk()
        let report = await desk.harness.run(.approvalsFlip, ["flag-path": "k:isAllowed", "codec": "nested"])
        #expect(report.errors.count == 1 && report.errors[0].contains("no key of an entry holds its ID") && report.errors[0].contains("--match-path"))
        #expect(desk.writes.value == 0)
    }

    @Test func theFlipCodecFindsTheEntryByAWayToItsIDToo() async throws {
        let blob = BlobFixtures.approvalsList(BlobFixtures.approvals())
        let desk = try await ApprovalsDesk.make(blob: blob, codec: BinaryPlistFlip(), flagPath: approvalsFlag(fixtureID))
        let report = await desk.harness.run(.approvalsFlip, ["match-path": way, "flag-path": "k:isAllowed", "codec": "flip", "runs": "2"])

        #expect(report.errors == [])
        #expect(report.restored)
        #expect(try desk.blob() == blob, "the list is the bytes it was")
        #expect(list(report, "writeToHiddenMs").count == 2 && !list(report, "writeToHiddenMs").contains(.null))
        #expect(report.measurements["entryCountBefore"] == .number(5) && report.measurements["entryCountAfter"] == .number(5))
        #expect(await desk.harness.journal.records().isEmpty)
    }

    @Test func theRequestIsCheckedBeforeAnythingIsChanged() async throws {
        let desk = try await ApprovalsDesk.make(blob: plain, codec: NestedPlistCodec(), flagPath: plainEntryPath(fixtureID))
        let harness = desk.harness
        func errors(_ options: [String: String]) async -> [String] { await harness.run(.approvalsFlip, options).errors }

        #expect(await errors([:]) == ["Say where the flag is: --flag-path k:name (a place from the test item's entry, as k:…, i:… separated by /)."])
        #expect(await errors(["flag-path": "x:1"]) == ["The flag-path isn't in the form k:name or k:name/i:2."])
        #expect(await errors(["flag-path": ""]) == ["Say where the flag is: --flag-path k:name (a place from the test item's entry, as k:…, i:… separated by /)."])
        #expect(await errors(["flag-path": "k:allowed", "codec": "gzip"]) == ["The codec is nested or flip."])
        #expect(await errors(["flag-path": "k:allowed"]) == ["trackedApplications is kept as a blob. Choose how to change it: --codec nested or --codec flip."])
        #expect(await errors(["flag-path": "k:note", "codec": "nested"]).first?.contains("isn't a flag") == true)
        #expect(await errors(["flag-path": "k:nothing", "codec": "nested"]).first?.contains("Nothing is at") == true)
        #expect(desk.writes.value == 0, "no write was made by any of them")
        #expect(await harness.journal.records().isEmpty)
    }

    @Test func aListThatIsNotABlobTakesNoCodecAndIsChangedAsItIs() async throws {
        let harness = try ProbeHarness.make()
        let entries: [[String: Any]] = [["bundleID": fixtureID, "allowed": true], ["bundleID": otherID, "allowed": true]]
        try await harness.installFile(.controlCenterApprovals, ["trackedApplications": entries])
        let items = Set(harness.fixtureExtras)
        let url = harness.approvalsURL
        harness.ax.setOverride { id, name in
            guard name == AXName.position, items.contains(id), let top = try? PlistIO.readFile(url, key: "trackedApplications"),
                  top.value(at: [.matching(key: "bundleID", value: fixtureID), .key("allowed")]) == .bool(false) else { return nil }
            return .success(.point(CGPoint(x: -1, y: 0)))
        }

        let withCodec = await harness.run(.approvalsFlip, ["flag-path": "k:allowed", "codec": "nested"])
        #expect(withCodec.errors == ["trackedApplications is kept as a plain list, which needs no codec. Leave out --codec."])

        let report = await harness.run(.approvalsFlip, ["flag-path": "k:allowed", "runs": "2"])
        #expect(report.errors == [])
        #expect(report.restored)
        #expect(report.measurements["codec"] == .string("none"))
        #expect(report.measurements["reencodedIdentical"] == nil)
        #expect(list(report, "writeToHiddenMs").count == 2 && !list(report, "writeToHiddenMs").contains(.null))
        let after = try PlistIO.readFile(url, key: "trackedApplications")
        #expect(after?.value(at: [.matching(key: "bundleID", value: fixtureID), .key("allowed")]) == .bool(true))
    }

    @Test func aFlagThatNeverConcealsAnythingIsNullAndSaid() async throws {
        // The flag is flipped and put back, and the menu bar never follows (the list isn't what macOS reads).
        let desk = try await ApprovalsDesk.make(blob: plain, codec: NestedPlistCodec(), flagPath: plainEntryPath("com.example.nobody"))
        let report = await desk.harness.run(.approvalsFlip, ["flag-path": "k:allowed", "codec": "nested", "runs": "1"])
        #expect(report.errors == [])
        #expect(list(report, "writeToHiddenMs") == [.null])
        #expect(report.notes.contains { $0.contains("saw no change in the menu bar within 3 s") })
        #expect(report.restored)
    }

    @Test func aProbeCutShortPutsTheFlagBack() async throws {
        let clock = FakeClock()
        let writes = WriteCounter()
        let io = PlistIO(read: PlistIO.filesOnly.read, write: { value, key, url, strategy in
            writes.bump()
            try PlistIO.filesOnly.write(value, key, url, strategy)
        })
        let harness = try ProbeHarness.make(clock: clock, io: io)
        let url = try await harness.installFile(.controlCenterApprovals, ["trackedApplications": plain])
        // Nothing ever follows the flag, so the probe waits on its clock with the flag flipped.
        let running = Task { await harness.run(.approvalsFlip, ["flag-path": "k:allowed", "codec": "nested", "runs": "3"]) }
        await clock.waitForSleepers(1)
        #expect(writes.value == 1, "the flag is flipped")

        await harness.runner.shutDown()
        let report = await running.value

        #expect(report.restored)
        #expect(report.notes.contains { $0.contains("cut short") })
        guard case .data(let held)? = try PlistIO.readFile(url, key: "trackedApplications") else {
            Issue.record("the list is a blob")
            return
        }
        #expect(try NestedPlistCodec().value(at: plainEntryPath(fixtureID), in: held) == .bool(true), "the flag was put back on the way out")
        #expect(await harness.journal.records().isEmpty)
    }

    @Test func withoutAGrantNothingIsChanged() async throws {
        let harness = try ProbeHarness.make()
        let report = await harness.run(.approvalsFlip, ["flag-path": "k:allowed", "codec": "nested"])
        #expect(report.errors == [GrantedFile.missing(.controlCenterApprovals)])
    }

    @Test func theTestItemMustBeRunning() async throws {
        let harness = try ProbeHarness.make { platform in
            let known = platform.runningApps
            platform.runningApps = { known().filter { $0.bundleID != fixtureID } }
        }
        try await harness.installFile(.controlCenterApprovals, ["trackedApplications": plain])
        let report = await harness.run(.approvalsFlip, ["flag-path": "k:allowed", "codec": "nested"])
        #expect(report.errors == ["Nothing to watch: \(fixtureID) isn't running. Open MantelTestItem first."])
    }
}

@Suite("Approvals-decode probe", .timeLimit(.minutes(1)))
struct ApprovalsDecodeProbeTests {
    private let plain = BlobFixtures.plainEntries([(fixtureID, true, 1), (BlobFixtures.secretID, false, 2)])

    private func said(_ report: ProbeReport) throws -> String {
        String(decoding: try JSONCoding.encoder().encode(report), as: UTF8.self)
    }

    @Test func itReportsTheShapeOfTheBlobAndNeverAnotherAppsIDOrAString() async throws {
        let harness = try ProbeHarness.make(platformTestEnabled: false)
        try await harness.installFile(.controlCenterApprovals, ["trackedApplications": plain])

        let report = await harness.run(.approvalsDecode)

        #expect(report.errors == [])
        #expect(report.restored)
        #expect(report.measurements["kind"] == .string("blob"))
        #expect(report.number("byteCount") == Double(plain.count))
        #expect(report.measurements["magic"] == .string("62706c6973743030"))
        #expect(report.bool("parsesAsPropertyList") == true)
        #expect(report.bool("markerFound") == true)
        #expect(report.bool("isKeyedArchive") == false)
        #expect(report.measurements["plistFormat"] == .string("binary"))
        #expect(report.object("structure") != nil)
        #expect(report.object("markerEntryShape") != nil)
        #expect(report.number("entryCount") == 1)
        let text = try said(report)
        #expect(!text.contains(BlobFixtures.secretID), "another app's ID is never said")
        #expect(!text.contains(BlobFixtures.secretText), "no string value is")
        // It reads, and changes nothing.
        #expect(await harness.journal.records().isEmpty)
        #expect(harness.allowlist.calls.isEmpty)
    }

    @Test func aListWhoseEntriesHoldTheirIDSomeLevelsDownIsDescribedByTheWholeEntryAndCompareSeesOneLeaf() async throws {
        let harness = try ProbeHarness.make()
        let entries = BlobFixtures.approvals(testItem: true)
        let url = try await harness.installFile(.controlCenterApprovals, ["trackedApplications": BlobFixtures.approvalsList(entries)])

        let decoded = await harness.run(.approvalsDecode, ["save-baseline": "true"])
        #expect(decoded.errors == [])
        #expect(decoded.bool("markerFound") == true)
        let shape = try #require(decoded.object("markerEntryShape"))
        #expect(shape["keyCount"] == .number(2))
        guard case .object(let keys)? = shape["entries"] else {
            Issue.record("the entry has keys")
            return
        }
        #expect(Set(keys.keys) == ["isAllowed", "menuItemLocations"])

        // The person flips the switch in System Settings, which writes the whole list again, in another order.
        var changed = BlobFixtures.approvals(testItem: false)
        changed.reverse()
        try PlistIO.writeFile(.data(BlobFixtures.approvalsList(changed)), key: "trackedApplications", to: url)
        let report = await harness.run(.approvalsDecode, ["compare": "true"])

        #expect(report.errors == [])
        #expect(report.measurements["changedLeaves"] == .array([
            .object(["path": .string("/mp:k:menuItemLocations,*,k:bundle,k:_0=\(fixtureID)/k:isAllowed"), "wasType": .string("bool"),
                     "nowType": .string("bool"), "was": .bool(true), "now": .bool(false)]),
        ]))
        #expect(report.measurements["changedLeafCount"] == .number(1))
        for text in [try said(decoded), try said(report), try String(contentsOf: harness.probesFolder.appending(path: "approvals-baseline.json"), encoding: .utf8)] {
            #expect(!text.contains("com.example.one") && !text.contains("com.example.two") && !text.contains("com.example.three"))
            #expect(!text.contains("exampled") && !text.contains("helperd"), "no program's path either")
        }
    }

    @Test func aKeyedArchiveIsSaidToBeOneWithItsClasses() async throws {
        let harness = try ProbeHarness.make()
        try await harness.installFile(.controlCenterApprovals,
                                      ["trackedApplications": BlobFixtures.archive([(fixtureID, true, 1), (BlobFixtures.secretID, false, 2)])])
        let report = await harness.run(.approvalsDecode)
        #expect(report.bool("isKeyedArchive") == true)
        #expect(report.measurements["archiveClasses"] != nil)
        #expect(!(try said(report)).contains(BlobFixtures.secretID))
    }

    @Test func aListThatIsNotABlobIsDescribedAsItIs() async throws {
        let harness = try ProbeHarness.make()
        let entries: [[String: Any]] = [["bundleID": fixtureID, "allowed": true], ["bundleID": BlobFixtures.secretID, "allowed": false]]
        try await harness.installFile(.controlCenterApprovals, ["trackedApplications": entries])
        let report = await harness.run(.approvalsDecode)
        #expect(report.measurements["kind"] == .string("plainValue"))
        #expect(report.bool("markerFound") == true)
        #expect(report.notes.contains { $0.contains("isn't kept as a blob") })
        #expect(!(try said(report)).contains(BlobFixtures.secretID))
    }

    @Test func withoutAGrantOrAKeyItSaysSo() async throws {
        let harness = try ProbeHarness.make()
        #expect(await harness.run(.approvalsDecode).errors == [GrantedFile.missing(.controlCenterApprovals)])
        try await harness.installFile(.controlCenterApprovals, ["somethingElse": 1])
        let report = await harness.run(.approvalsDecode)
        #expect(report.errors == [])
        #expect(report.measurements["markerFound"] == .bool(false))
        #expect(report.notes.contains { $0.contains("no trackedApplications key") })
    }

    @Test func saveBaselineKeepsLeavesWithoutStringsAndCompareListsWhatChanged() async throws {
        let harness = try ProbeHarness.make()
        let url = try await harness.installFile(.controlCenterApprovals, ["trackedApplications": plain])

        let saved = await harness.run(.approvalsDecode, ["save-baseline": "true"])
        #expect(saved.errors.isEmpty)
        #expect(saved.measurements["baselineSaved"] == .bool(true))
        #expect(saved.measurements["baselineFile"] == .string("approvals-baseline.json"))
        let file = harness.probesFolder.appending(path: "approvals-baseline.json")
        let baseline = try String(contentsOf: file, encoding: .utf8)
        #expect(!baseline.contains(BlobFixtures.secretID), "no other app's ID")
        #expect(!baseline.contains(BlobFixtures.secretText), "no string value")
        #expect(baseline.contains("/k:apps/m:bundleID=\(fixtureID)/k:allowed"), "the test item's entry by its ID")

        // Nothing changed: nothing is listed.
        let same = await harness.run(.approvalsDecode, ["compare": "true"])
        #expect(same.measurements["changedLeaves"] == .array([]))
        #expect(same.measurements["changedLeafCount"] == .number(0))

        // The person flips the switch in System Settings: the list is written again with the flag changed.
        let changed = BlobFixtures.plainEntries([(fixtureID, false, 1), (BlobFixtures.secretID, false, 2)])
        try PlistIO.writeFile(.data(changed), key: "trackedApplications", to: url)
        let report = await harness.run(.approvalsDecode, ["compare": "true"])
        #expect(report.errors == [])
        #expect(report.measurements["changedLeaves"] == .array([
            .object(["path": .string("/k:apps/m:bundleID=\(fixtureID)/k:allowed"), "wasType": .string("bool"), "nowType": .string("bool"),
                     "was": .bool(true), "now": .bool(false)]),
        ]))
        #expect(report.measurements["comparedWith"] == .string("approvals-baseline.json"))
        #expect(!(try said(report)).contains(BlobFixtures.secretID))
    }

    @Test func aListKeyedByAppsSaysNothingOfTheAppsInTheReportTheBaselineOrTheComparison() async throws {
        func keyed(testItem: Bool) throws -> Data {
            try PropertyListSerialization.data(
                fromPropertyList: [fixtureID: ["allowed": testItem], BlobFixtures.secretID: ["allowed": true], "com.example.third": ["allowed": false]] as [String: Any],
                format: .binary, options: 0)
        }
        let harness = try ProbeHarness.make()
        let url = try await harness.installFile(.controlCenterApprovals, ["trackedApplications": try keyed(testItem: true)])

        let decoded = await harness.run(.approvalsDecode, ["save-baseline": "true"])
        let baseline = try String(contentsOf: harness.probesFolder.appending(path: "approvals-baseline.json"), encoding: .utf8)
        try PlistIO.writeFile(.data(try keyed(testItem: false)), key: "trackedApplications", to: url)
        let compared = await harness.run(.approvalsDecode, ["compare": "true"])

        for text in [try said(decoded), baseline, try said(compared)] {
            #expect(!text.contains(BlobFixtures.secretID))
            #expect(!text.contains("com.example.third"))
            #expect(!text.contains(fixtureID), "the test item's ID is not said as a key")
        }
        #expect(baseline.contains("/k:‹test item›/k:allowed"))
        // Another app's flag has its type and how many there are, and no value.
        let file = try JSONCoding.decoder().decode(JSONValue.self, from: Data(baseline.utf8))
        guard case .object(let top) = file, case .object(let leaves)? = top["leaves"] else {
            Issue.record("the baseline has its leaves")
            return
        }
        #expect(leaves["/k:‹key›/k:allowed"] == .object(["type": .string("bool"), "count": .number(2)]))
        #expect(leaves["/k:‹test item›/k:allowed"] == .object(["type": .string("bool"), "value": .bool(true)]))
        #expect(compared.measurements["changedLeaves"] == .array([
            .object(["path": .string("/k:‹test item›/k:allowed"), "wasType": .string("bool"), "nowType": .string("bool"),
                     "was": .bool(true), "now": .bool(false)]),
        ]))
    }

    @Test func aBaselineEditedByHandWithACountThatIsNoCountIsLeftOutAndNothingTraps() async throws {
        let harness = try ProbeHarness.make()
        try await harness.installFile(.controlCenterApprovals, ["trackedApplications": plain])
        _ = await harness.run(.approvalsDecode, ["save-baseline": "true"])
        let file = harness.probesFolder.appending(path: "approvals-baseline.json")
        let kept = try String(contentsOf: file, encoding: .utf8)

        // Counts that don't fit an integer, are fractional or are not positive: each is left out, and the comparison goes on.
        for count in ["1e300", "2.5", "-3", "0", "\"many\""] {
            let edited = """
            {"savedAt": "2024-01-01T00:00:00Z", "leaves": {
              "/k:apps/m:bundleID=\(fixtureID)/k:allowed": {"type": "bool", "value": true, "count": \(count)},
              "/k:apps/m:bundleID=\(fixtureID)/k:order": {"type": "integer", "value": 1}
            }}
            """
            try Data(edited.utf8).write(to: file)
            let report = await harness.run(.approvalsDecode, ["compare": "true"])
            #expect(report.errors == [], "count \(count)")
            #expect(report.notes.contains { $0.contains("couldn't be read and were left out") }, "count \(count)")
            #expect(report.measurements["changedLeaves"] != nil, "count \(count)")
        }
        try Data(kept.utf8).write(to: file)
        let whole = await harness.run(.approvalsDecode, ["compare": "true"])
        #expect(whole.measurements["changedLeaves"] == .array([]))
        #expect(!whole.notes.contains { $0.contains("left out") })
    }

    @Test(.timeLimit(.minutes(1)))
    func aListThatIsTooLargeToReadWholeSaysSoAndKeepsWhatItGathered() async throws {
        // The test item's entry, and beside it a list that refers to its own parts so many times that it is sixteen million values.
        let harness = try ProbeHarness.make()
        try await harness.installFile(.controlCenterApprovals, ["trackedApplications": BlobFixtures.approvalsWithDeeplySharedList(levels: 24)])

        let report = await harness.run(.approvalsDecode, ["save-baseline": "true"])

        #expect(report.errors == [])
        #expect(report.bool("truncated") == true)
        #expect(report.bool("markerFound") == true, "what was gathered before the limit is kept")
        #expect(report.notes.contains { $0.contains("too large to read whole") })
        let baseline = try String(contentsOf: harness.probesFolder.appending(path: "approvals-baseline.json"), encoding: .utf8)
        #expect(baseline.contains("\"truncated\" : true"))
        #expect(baseline.contains("/k:apps/m:bundleID=\(fixtureID)/k:allowed"))
        let compared = await harness.run(.approvalsDecode, ["compare": "true"])
        #expect(compared.errors == [])
        #expect(compared.notes.contains { $0.contains("cut at the work limit") })
        #expect(compared.measurements["changedLeaves"] == .array([]))
    }

    @Test func compareWithoutABaselineSaysWhatToDo() async throws {
        let harness = try ProbeHarness.make()
        try await harness.installFile(.controlCenterApprovals, ["trackedApplications": plain])
        let report = await harness.run(.approvalsDecode, ["compare": "true"])
        #expect(report.measurements["changedLeaves"] == .null)
        #expect(report.notes.contains { $0.contains("Run it with --save-baseline first") })
        #expect(report.errors == [])
    }

    @Test func theBaselineIsNotAReportOfAnyProbe() async throws {
        // It sits in the Probes folder beside the reports, and the runner doesn't take it for one.
        let harness = try ProbeHarness.make()
        try await harness.installFile(.controlCenterApprovals, ["trackedApplications": plain])
        _ = await harness.run(.approvalsDecode, ["save-baseline": "true"])
        #expect(harness.probeFiles().contains("approvals-baseline.json"))
        let latest = await harness.runner.latestReports()
        #expect(latest.keys.sorted { $0.rawValue < $1.rawValue } == [.approvalsDecode])
    }
}

// MARK: notch-coordinates

@Suite("Notch-coordinates probe", .timeLimit(.minutes(1)))
struct NotchCoordinatesProbeTests {
    private func screens(_ report: ProbeReport) throws -> [[String: JSONValue]] {
        guard case .array(let values)? = report.measurements["screens"] else {
            Issue.record("the screens are an array")
            return []
        }
        return values.compactMap { if case .object(let object) = $0 { object } else { nil } }
    }

    /// The built-in screen to the right of the desk (lid open, an external display as the main one), as `DisplayLayout.deskWithLaptopOpen`
    /// has it, with areas beside its notch in the coordinates given.
    private func laptopOpen(globalAreas: Bool) -> [ScreenFacts] {
        let laptop = DisplayFixtures.laptopRightOfDesk
        let left = globalAreas ? CGRect(x: 3360, y: 950, width: 663, height: 32) : CGRect(x: 0, y: 950, width: 663, height: 32)
        let right = globalAreas ? CGRect(x: 4209, y: 950, width: 663, height: 32) : CGRect(x: 849, y: 950, width: 663, height: 32)
        return [
            ScreenFacts(uuid: DisplayFixtures.deskMain.uuid, frame: DisplayFixtures.deskMain.frame, safeAreaTop: 0, auxiliaryTopLeft: nil,
                        auxiliaryTopRight: nil, isBuiltIn: false),
            ScreenFacts(uuid: laptop.uuid, frame: laptop.frame, safeAreaTop: 32, auxiliaryTopLeft: left, auxiliaryTopRight: right, isBuiltIn: true),
        ]
    }

    @Test func eachScreenIsSaidWithItsVerdictAndTheBarOnIt() async throws {
        let harness = try ProbeHarness.make { platform in platform.screens = { laptopOpen(globalAreas: true) } }
        let report = await harness.run(.notchCoordinates)

        #expect(report.errors.isEmpty)
        #expect(report.restored)
        let reported = try screens(report)
        #expect(reported.count == 2)
        #expect(reported[0]["verdict"] == .string("undecided"), "the main display is at the origin")
        #expect(reported[0]["isBuiltIn"] == .bool(false))
        #expect(reported[1]["verdict"] == .string("global"))
        #expect(reported[1]["isBuiltIn"] == .bool(true))
        #expect(reported[1]["safeAreaTop"] == .number(32))
        #expect(reported[1]["frame"] == NotchCoordinatesProbe.rect(DisplayFixtures.laptopRightOfDesk.frame))
        #expect(reported[1]["auxiliaryTopLeft"] == NotchCoordinatesProbe.rect(CGRect(x: 3360, y: 950, width: 663, height: 32)))
        #expect(reported[0]["auxiliaryTopLeft"] == .null)
        #expect(report.strings("verdicts") == ["undecided", "global"])
        // The bar of the main display is the agent's window that starts on it, in CoreGraphics points.
        #expect(reported[0]["barFrame"] == NotchCoordinatesProbe.rect(CGRect(x: 0, y: 0, width: 3360, height: 31)))
        #expect(reported[1]["barFrame"] == .null, "no agent window starts on a screen the layout doesn't have")
        #expect(report.notes.contains { $0.contains("barFrame is CoreGraphics points") })
    }

    @Test func aWindowThatLiesOnAScreenIsItsBarInCoreGraphicsPoints() async throws {
        // The desk's two screens, each with an agent window of its own.
        let harness = try ProbeHarness.make()
        let portraitBar = CGRect(x: -1800, y: -491, width: 1800, height: 31)
        let second = harness.ax.addAgentWindow(agent: ProbeHarness.agentPID, frame: portraitBar)
        harness.ax.addSlot(in: second, identifier: "com.apple.menuextra.clock", frame: CGRect(x: -60, y: -491, width: 50, height: 31))

        let report = await harness.run(.notchCoordinates)

        let reported = try screens(report)
        #expect(reported.count == 2)
        #expect(reported[0]["barFrame"] == NotchCoordinatesProbe.rect(CGRect(x: 0, y: 0, width: 3360, height: 31)))
        #expect(reported[1]["barFrame"] == NotchCoordinatesProbe.rect(portraitBar), "the AppKit frame (-1800, -819) is (-1800, -491) in CoreGraphics")
    }

    @Test func areasThatAreZeroBasedOnAScreenAwayFromTheOriginAreScreenLocal() async throws {
        let harness = try ProbeHarness.make { platform in platform.screens = { laptopOpen(globalAreas: false) } }
        let report = await harness.run(.notchCoordinates)
        #expect(try screens(report).map { $0["verdict"] } == [.string("undecided"), .string("screenLocal")])
        #expect(report.notes.contains { $0.contains("nothing could be decided") } == false)
    }

    @Test func withNothingToDecideItSaysHowToRunItAgain() async throws {
        let harness = try ProbeHarness.make()
        let report = await harness.run(.notchCoordinates)
        #expect(report.errors.isEmpty)
        #expect(try screens(report).count == 2)
        #expect(report.notes.contains { $0.contains("Open the lid with an external display as the main one") })
    }

    @Test func itOnlyReads() async throws {
        let harness = try ProbeHarness.make(platformTestEnabled: false)
        let report = await harness.run(.notchCoordinates)
        #expect(report.errors.isEmpty)
        #expect(harness.allowlist.calls.isEmpty)
        #expect(await harness.journal.records().isEmpty)
        #expect(!ProbeRunner.changesState(.notchCoordinates))
    }
}

// MARK: inventory: what tells the windows apart

@Suite("Inventory of the windows", .timeLimit(.minutes(1)))
struct InventoryWindowsTests {
    private func list(_ report: ProbeReport, _ key: String) -> [[String: JSONValue]] {
        guard case .array(let values)? = report.measurements[key] else {
            Issue.record("\(key) is a list")
            return []
        }
        return values.compactMap { if case .object(let object) = $0 { object } else { nil } }
    }

    @Test func spaceWindowsHasEachAgentWindowsFrameAttributesAndSlotCount() async throws {
        let harness = try ProbeHarness.make()
        let window = harness.window
        harness.ax.setAttribute(AXName.role, .string("AXWindow"), on: window)
        harness.ax.setAttribute(AXName.subrole, .string("AXSystemDialog"), on: window)
        harness.ax.setAttribute(AXName.main, .bool(true), on: window)
        harness.ax.setAttribute(AXName.focused, .bool(false), on: window)
        harness.ax.setAttribute(AXName.identifier, .string("menubar"), on: window)
        // Any other attribute that holds a true or false is kept as well; one that holds anything else is not.
        harness.ax.setAttribute("AXFullScreen", .bool(false), on: window)
        harness.ax.setAttribute("AXMinimized", .bool(true), on: window)
        harness.ax.setAttribute(AXName.title, .string("Window title that is never recorded"), on: window)
        // A second window, of another Space, with its own.
        let other = harness.ax.addAgentWindow(agent: ProbeHarness.agentPID, frame: CGRect(x: 0, y: 0, width: 3360, height: 31))
        harness.ax.setAttribute(AXName.main, .bool(false), on: other)

        let report = await harness.run(.inventory)

        let windows = list(report, "spaceWindows")
        #expect(windows.count == 2)
        let first = windows[0]
        #expect(first["frame"] == NotchCoordinatesProbe.rect(CGRect(x: 0, y: 0, width: 3360, height: 31)))
        #expect(first["slotCount"] == .number(6))
        guard case .object(let attributes)? = first["attributes"] else {
            Issue.record("the attributes are an object")
            return
        }
        #expect(attributes["AXRole"] == .string("AXWindow"))
        #expect(attributes["AXSubrole"] == .string("AXSystemDialog"))
        #expect(attributes["AXMain"] == .bool(true))
        #expect(attributes["AXFocused"] == .bool(false))
        #expect(attributes["AXIdentifier"] == .string("menubar"))
        #expect(attributes["AXFullScreen"] == .bool(false))
        #expect(attributes["AXMinimized"] == .bool(true))
        #expect(attributes["AXTitle"] == nil, "a text that isn't one of the five is not kept")
        #expect(windows[1]["slotCount"] == .number(0))
        guard case .object(let others)? = windows[1]["attributes"] else {
            Issue.record("the attributes are an object")
            return
        }
        #expect(others["AXMain"] == .bool(false))
        #expect(!String(decoding: try JSONCoding.encoder().encode(report), as: UTF8.self).contains("never recorded"))
    }

    @Test func agentOnScreenListsOnlyTheAgentsWindowsWithNumberLayerBoundsAndAlpha() async throws {
        let harness = try ProbeHarness.make()
        let report = await harness.run(.inventory)
        let windows = list(report, "agentOnScreen")
        #expect(windows.map { $0["number"] } == [.number(20), .number(21)])
        #expect(windows.map { $0["layer"] } == [.number(24), .number(25)])
        #expect(windows[0]["bounds"] == NotchCoordinatesProbe.rect(CGRect(x: 0, y: 0, width: 3360, height: 31)))
        #expect(windows[0]["alpha"] == .number(1))
    }

    @Test func menuBarWindowsAreTheOnesAtLayer24And25WithOwnersAndBounds() async throws {
        let harness = try ProbeHarness.make()
        harness.windows.setExtra([
            WindowInfo(number: 40, ownerPID: 301, ownerBundleID: otherID, layer: 25, bounds: CGRect(x: 3200, y: 0, width: 40, height: 31), alpha: 1),
            WindowInfo(number: 41, ownerPID: 301, ownerBundleID: otherID, layer: 3, bounds: CGRect(x: 10, y: 10, width: 400, height: 300), alpha: 1),
        ])
        let report = await harness.run(.inventory)
        let windows = list(report, "menuBarWindows")
        // The agent's two, the test item's item, the other app's item; not the widgets (layer 0) or the app's ordinary window (3).
        #expect(windows.count == 4)
        let owners = windows.compactMap { window -> String? in if case .string(let owner)? = window["owner"] { owner } else { nil } }
        #expect(Set(owners) == ["com.apple.MenuBarAgent", fixtureID, otherID])
        #expect(windows.allSatisfy { $0["layer"] == .number(24) || $0["layer"] == .number(25) })
        #expect(windows.contains { $0["bounds"] == NotchCoordinatesProbe.rect(CGRect(x: 3200, y: 0, width: 40, height: 31)) })
        // Never a title: a window is told by its owner, its level and where it is.
        #expect(windows.allSatisfy { Set($0.keys) == ["owner", "layer", "bounds"] })
    }

    @Test func systemModulesAreTheMenuExtraIdentifiersInTheMenuBar() async throws {
        let harness = try ProbeHarness.make()
        let report = await harness.run(.inventory)
        #expect(report.strings("systemModules") == ["com.apple.menuextra.clock", "com.apple.menuextra.controlcenter"])
    }
}
