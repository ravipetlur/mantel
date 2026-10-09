import CoreGraphics
import Foundation
import ImageIO
import MKCommands
import MKCore
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
        #expect(Set(concealed) == ["0:\(fixtureID)::one", "0:\(fixtureID)::two"])

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
            platform.runningApps = { known() + [(pid: 500, bundleID: "com.example.daemon", name: "Daemon")] }
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
        let nothing: [ProbePlatform.RunningApp] = []
        #expect(AllowlistSupport.nothingToHide([fixtureID], running: nothing, fixture: fixtureID)
                == "Nothing to hide: \(fixtureID) isn't running. Open MantelTestItem first.")
        #expect(AllowlistSupport.nothingToHide(["com.apple.Safari"], running: nothing, fixture: fixtureID)
                == "Nothing to hide: com.apple.Safari isn't running. Open it first.")
        #expect(AllowlistSupport.nothingToHide(["a.b", "c.d"], running: nothing, fixture: fixtureID)
                == "Nothing to hide: a.b, c.d aren't running. Open them first.")
        let running: [ProbePlatform.RunningApp] = [(pid: 1, bundleID: "c.d", name: nil), (pid: 2, bundleID: nil, name: "x")]
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
        #expect(!(report.strings("concealedSlots") ?? []).contains("0:\(ownID).dot"))
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
        #expect(Set(try #require(report.strings("concealedSlots"))) == ["0:\(otherID).item"])
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
            platform.runningApps = { known() + [(pid: 500, bundleID: "com.example.daemon", name: "Daemon")] }
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
        for (pid, _, _) in ProbeHarness.runningApps { harness.ax.failReads(on: harness.ax.root(ofApp: pid), with: .notTrusted) }
        let report = await harness.run(.inventory)
        #expect(report.notes.contains("Accessibility isn't granted to Mantel."))
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
        #expect(main["name"] == .string("U32J59x"))
        #expect(main["frameMinusVisibleFrame"] == .number(31))
        #expect(main["agentWindowHeight"] == .number(31))
        #expect(portrait["frameMinusVisibleFrame"] == .number(0), "the LG reports no menu bar")
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
        #expect(report.number("capturedDisplays") == 1, "the LG reports no menu bar")
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

    @Test(arguments: [nil, "cfPreferences", "atomicFile"] as [String?])
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
        let report = await harness.run(.approvalsToggle, ["strategy": "atomicFile"])

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

        let report = await harness.run(.approvalsToggle, ["strategy": "atomicFile"])

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

        let report = await harness.run(.approvalsToggle, ["strategy": "atomicFile"])

        #expect(!report.restored)
        #expect(!report.errors.isEmpty)
        #expect(try ProbeHarness.read(url) != before, "the flag is still flipped")
        #expect(await harness.journal.records().count == 1, "and the journal still holds the original")

        // The next launch: the folder can be written again, and the replay puts the flag back.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        harness.ax.setOverride(nil)
        let restarted = Journal(file: harness.paths.journalFile)
        let failures = await restarted.replay(using: PlistJournalRestorer(access: PlistFileAccess(journal: restarted, paths: harness.paths), grants: harness.grants))
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

    @Test func layoutMoveWithTheFileWrittenDirectlyAlsoMoves() async throws {
        let harness = try ProbeHarness.make()
        let url = try await harness.installFile(.menuBarLayout, layout)
        placeFixtureByTheLayoutFile(harness)
        let before = try ProbeHarness.read(url)
        let report = await harness.run(.layoutMove, ["distance": "0", "strategy": "atomicFile"])
        #expect(report.bool("resortApplied") == true)
        #expect(report.measurements["strategy"] == .string("atomicFile"))
        #expect(try ProbeHarness.read(url) == before)
    }

    @Test func layoutMoveThatChangesNothingSaysSo() async throws {
        let harness = try ProbeHarness.make()
        let url = try await harness.installFile(.menuBarLayout, layout)
        placeFixtureByTheLayoutFile(harness)
        let before = try ProbeHarness.read(url)
        // 130 puts the item at x = 3090: still between the same neighbours.
        let report = await harness.run(.layoutMove, ["distance": "130", "strategy": "atomicFile"])
        #expect(report.bool("resortApplied") == false)
        #expect(report.measurements["writeToResortMs"] == .null)
        #expect(report.restored)
        #expect(try ProbeHarness.read(url) == before)
    }

    @Test func layoutMoveCanBeGivenAKeyOfTheFixture() async throws {
        let harness = try ProbeHarness.make()
        try await harness.installFile(.menuBarLayout, layout)
        let key = "status:\(fixtureID)::mantel.fixture.two"
        let report = await harness.run(.layoutMove, ["key": key, "distance": "5", "strategy": "atomicFile"])
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
        let report = await harness.run(.layoutMove, ["distance": "40", "strategy": "atomicFile"])
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
        #expect(report.errors.contains { $0.contains("Accessibility") })
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
