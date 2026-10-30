import CoreGraphics
import Foundation
import MKCore
import MKLayout
import MKTestSupport
import Synchronization
import Testing

@testable import MKMenuBar

private let weather = SessionWorld.weather
private let notes = SessionWorld.notes
private let vpn = SessionWorld.vpn
private let sync = SessionWorld.sync

/// What an app's read is for the records: whole, or with a name that didn't come in time, or from two processes.
@Suite("Menu bar session: records", .timeLimit(.minutes(1)))
struct MenuBarSessionRecordsTests {
    private func index(_ bundleID: String, _ n: Int) -> ItemID { ItemID(bundleID: bundleID, key: .index(n)) }
    private func name(_ bundleID: String, _ name: String) -> ItemID { ItemID(bundleID: bundleID, key: .identifier(name)) }

    private func records(_ sections: SectionModel, _ bundleID: String) -> [ItemID] {
        MenuBarSection.allCases.flatMap { sections.order[$0] ?? [] }.filter { $0.bundleID == bundleID }
    }

    @Test func aPartialReadAddsNoRecord() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(shown: [weather, notes, vpn, sync]))
        // The notes app's item has a name that didn't come in time, in a new process: nothing is known of it.
        rig.extras.rewriteAnswers { outcome, app in
            guard app.bundleID == notes, case .items(let extras) = outcome else { return outcome }
            return .items(AppExtras(pid: extras.pid, bundleID: extras.bundleID, name: extras.name, items: extras.items, timedOut: false,
                                    itemTimeouts: 1, namesIncomplete: true))
        }
        await rig.session.start()
        let partial = await rig.session.sections
        #expect(records(partial, notes).isEmpty, "no `#0` from a read that couldn't tell the name")
        #expect(records(partial, weather) == [name(weather, "weather.temp"), name(weather, "weather.alerts")].sorted { $0.string < $1.string }
                || Set(records(partial, weather)) == [name(weather, "weather.temp"), name(weather, "weather.alerts")], "the others are noted")
        #expect(await rig.session.currentIDs[notes] == nil)

        // The next read says the name is none: whole, and the icon is noted by what it is.
        rig.extras.rewriteAnswers(nil)
        await rig.session.refresh()
        #expect(records(await rig.session.sections, notes) == [index(notes, 0)])
        #expect(await rig.session.currentIDs[notes] == [index(notes, 0)])
    }

    private func uncheckedRig() -> SessionRig {
        var initial = sections(shown: [weather, notes, vpn, sync])
        initial.noteIcons([index(sync, 0), name(sync, "x.main-menu"), index(sync, 1), index(notes, 0), name(notes, "x.main-menu")])
        initial.unchecked = [sync, notes]
        return SessionRig.withAllowlist(sections: initial)
    }

    @Test func aReadOfMenuBarAgentThatWasCutChecksNoAppWhoseIconsItPlacesInMoreThanOneGroupAndStillChecksOneWithOne() async throws {
        // The records come from the apps' own lists, and a slot that lacks its frame leaves no icon out; it leaves an app's icons in the
        // order the read happens to give them, an icon without a frame after those that have one. So an app with one icon is checked from
        // such a read, and one with two, of which one lost its frame, waits for a read that wasn't cut.
        let rig = uncheckedRig()
        rig.world.hangSlotFrame(ofItemTitled: "Sync A", ofApp: sync)
        await rig.session.start()
        await rig.session.settingsMovesFinished()

        let cut = try #require(await rig.state)
        #expect(cut.inventory.agentReadCut, "the read of MenuBarAgent was cut")
        let during = await rig.session.sections
        #expect(records(during, notes) == [index(notes, 0)], "one icon: its one record, whatever order the bar was read in")
        #expect(!during.unchecked.contains(notes))
        #expect(during.unchecked.contains(sync), "two icons, one of them without its frame: not checked from this read")
        #expect(records(during, sync) == [index(sync, 0), name(sync, "x.main-menu"), index(sync, 1)])
        #expect(cut.currentIDs[sync] == nil)

        rig.world.releaseSlotFrame()
        await rig.session.refresh()
        await rig.session.settingsMovesFinished()
        let after = await rig.session.sections
        #expect(!after.unchecked.contains(sync))
        #expect(records(after, sync) == [index(sync, 0), index(sync, 1)])
        #expect(await rig.session.currentIDs[sync] == [index(sync, 0), index(sync, 1)])
    }

    @Test func aReadOfMenuBarAgentThatWasCutOnlyInWhatTheSlotsSayOfThemselvesChecksAnAppWhoseIconsAllKeptTheirFrames() async throws {
        // The slots' descriptions timed out: the read is cut, and every icon of the sync app has its frame, so they are in order all the same.
        let rig = uncheckedRig()
        rig.world.setSlotsHung(true)
        await rig.session.start()
        await rig.session.settingsMovesFinished()

        let cut = try #require(await rig.state)
        #expect(cut.inventory.agentReadCut, "the read of MenuBarAgent was cut")
        let during = await rig.session.sections
        #expect(!during.unchecked.contains(notes))
        #expect(!during.unchecked.contains(sync), "two icons, both with their frames: whole")
        #expect(records(during, sync) == [index(sync, 0), index(sync, 1)])
        #expect(cut.currentIDs[sync] == [index(sync, 0), index(sync, 1)])
    }

    @Test func aReadOfMenuBarAgentThatWasCutChecksAConcealedAppWithSeveralIcons() async throws {
        // A concealed app's icons have no frame in any read and are ordered by ID, cut or not. The sync app is refused while it is on the bar
        // and one of its slots lacks a frame, and is checked when it is concealed, in a read that is cut all the same.
        var initial = sections(shown: [weather, notes, vpn], hidden: [sync])
        initial.noteIcons([index(sync, 0), name(sync, "x.main-menu"), index(sync, 1)])
        initial.unchecked = [sync]
        let rig = SessionRig.withAllowlist(sections: initial)
        rig.world.setSlotsHung(true)
        rig.world.hangSlotFrame(ofItemTitled: "Sync A", ofApp: sync)
        await rig.session.start()
        await rig.session.refresh()
        await rig.session.settingsMovesFinished()

        let cut = try #require(await rig.state)
        #expect(rig.world.concealed.contains(sync), "the plan hides it")
        #expect(cut.inventory.agentReadCut, "and the read of MenuBarAgent is still cut")
        #expect(cut.inventory.items(ofApp: sync).allSatisfy { $0.frames.isEmpty })
        let during = await rig.session.sections
        #expect(!during.unchecked.contains(sync), "a concealed app is whole whatever was cut")
        #expect(records(during, sync) == [index(sync, 0), index(sync, 1)])
    }

    /// The sync app's answer with one more icon than it has: a menu that was rebuilt, or an icon that came and went.
    private func syncListsAThirdIcon(_ rig: SessionRig, _ lists: Bool) {
        guard lists else { return rig.extras.rewriteAnswers(nil) }
        rig.extras.rewriteAnswers { outcome, app in
            guard app.bundleID == sync, case .items(let extras) = outcome else { return outcome }
            let more = extras.items + [ExtraItem(index: extras.items.count, frame: nil, identifier: nil, title: nil, description: nil)]
            return .items(AppExtras(pid: extras.pid, bundleID: extras.bundleID, name: extras.name, items: more, timedOut: false))
        }
    }

    @Test func anAppsFirstIconsAreRecordedAtOnce() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(shown: [weather, notes, vpn, sync]))
        // The sync app's reads are in part while the session starts (a name that didn't come in time), so that it has no whole read yet.
        rig.extras.rewriteAnswers { outcome, app in
            guard app.bundleID == sync, case .items(let extras) = outcome else { return outcome }
            return .items(AppExtras(pid: extras.pid, bundleID: extras.bundleID, name: extras.name, items: extras.items, timedOut: false,
                                    itemTimeouts: 1, namesIncomplete: true))
        }
        await rig.session.start()
        #expect(records(await rig.session.sections, sync).isEmpty)
        #expect(await rig.session.currentIDs[sync] == nil, "no whole read of it, and so none for a read to be held to")

        // Its first whole read records its icons: they are not held to a read before it, which an app with no record has not had.
        rig.extras.rewriteAnswers(nil)
        await rig.session.refresh()
        #expect(records(await rig.session.sections, sync) == [index(sync, 0), index(sync, 1)], "at once, in the one whole read")
    }

    @Test func aNewIconOfAnAppThatHasRecordsIsRecordedOnlyWhenTheReadBeforeListedItToo() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(shown: [weather, notes, vpn, sync]))
        await rig.session.start()
        #expect(records(await rig.session.sections, sync) == [index(sync, 0), index(sync, 1)])

        // The app has one more icon in one read, and not in the next: nothing is recorded.
        syncListsAThirdIcon(rig, true)
        await rig.session.refresh()
        #expect(records(await rig.session.sections, sync) == [index(sync, 0), index(sync, 1)], "no `#2` from one read")
        syncListsAThirdIcon(rig, false)
        await rig.session.refresh()
        #expect(records(await rig.session.sections, sync) == [index(sync, 0), index(sync, 1)])
        // And again, the icon coming back after a read without it: still one read of it before the record.
        syncListsAThirdIcon(rig, true)
        await rig.session.refresh()
        #expect(records(await rig.session.sections, sync) == [index(sync, 0), index(sync, 1)])

        // An icon that two reads in a row list is a real one: recorded in the second.
        await rig.session.refresh()
        #expect(records(await rig.session.sections, sync) == [index(sync, 0), index(sync, 1), index(sync, 2)])
    }

    @Test func aRelaunchOverlapAddsNoIndexRecord() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(shown: [weather, notes, vpn, sync]))
        await rig.session.start()
        #expect(records(await rig.session.sections, sync) == [index(sync, 0), index(sync, 1)])

        // The sync app is started again while the first still lists: two processes list its two items each, and four unnamed items are read.
        let second: pid_t = 9001
        rig.world.addHelper(of: sync, pid: second)
        rig.extras.rewriteAnswers { outcome, app in
            guard app.pid == second else { return outcome }
            let items = (0..<2).map { ExtraItem(index: $0, frame: nil, identifier: nil, title: nil, description: nil) }
            return .items(AppExtras(pid: second, bundleID: sync, name: nil, items: items, timedOut: false))
        }
        await rig.session.refresh()
        #expect(records(await rig.session.sections, sync) == [index(sync, 0), index(sync, 1)], "no `#2`, no `#3`")
        #expect(await rig.session.currentIDs[sync] == [index(sync, 0), index(sync, 1)], "and what the app has is what the last whole read said")
    }

    @Test func theFirstWholeReadAfterTheMigrationReconcilesTheApp() async throws {
        var initial = sections(shown: [weather, notes, vpn, sync])
        initial.noteIcons([name(weather, "x.phantom"), name(weather, "weather.temp"), name(weather, "weather.alerts"),
                           index(notes, 0), name(notes, "x.main-menu"), index(notes, 1)])
        initial.unchecked = [weather, notes]
        let checked = Mutex<[String: Set<ItemID>]>([:])
        let rig = SessionRig.withAllowlist(sections: initial, recordsChecked: { app, done in
            checked.withLock { $0[app] = Set(done.dropped) }
            return SettingsMoved()
        })
        await rig.session.start()
        await rig.session.settingsMovesFinished()

        let model = await rig.session.sections
        #expect(records(model, weather) == [name(weather, "weather.temp"), name(weather, "weather.alerts")], "where they were, the phantom gone")
        #expect(records(model, notes) == [index(notes, 0)])
        #expect(model.unchecked.isEmpty)
        #expect(rig.saved.latest?.unchecked.isEmpty == true, "and saved")
        #expect(checked.withLock { $0 } == [notes: [name(notes, "x.main-menu"), index(notes, 1)], weather: [name(weather, "x.phantom")]])
        let state = try #require(await rig.state)
        #expect(state.currentIDs[weather] == [name(weather, "weather.temp"), name(weather, "weather.alerts")])
        #expect(state.staleRecords.contains(name(weather, "x.phantom")))
        #expect(!state.staleRecords.contains(index(notes, 0)))
    }

    @Test func anAppThatHasNotBeenReadWholeIsHeldToItsFirstRecord() async throws {
        // The app is unchecked and its read is never whole: its records stay as they are, and the places that list icons show one.
        var initial = sections(shown: [weather, notes, vpn, sync])
        initial.noteIcons([index(notes, 0), name(notes, "x.main-menu")])
        initial.unchecked = [notes]
        let rig = SessionRig.withAllowlist(sections: initial)
        rig.extras.rewriteAnswers { outcome, app in
            guard app.bundleID == notes, case .items(let extras) = outcome else { return outcome }
            return .items(AppExtras(pid: extras.pid, bundleID: extras.bundleID, name: extras.name, items: extras.items, timedOut: false,
                                    itemTimeouts: 1, namesIncomplete: true))
        }
        await rig.session.start()

        #expect(records(await rig.session.sections, notes) == [index(notes, 0), name(notes, "x.main-menu")])
        let state = try #require(await rig.state)
        #expect(state.currentIDs[notes] == nil)
        #expect(state.staleRecords.contains(name(notes, "x.main-menu")) && !state.staleRecords.contains(index(notes, 0)))
        #expect(await rig.session.hasNoSuchIcon(name(notes, "x.main-menu")) == false, "not read whole: nothing is known to be missing")
    }

    @Test func theSettingsOfTheTakenOutRecordsAreMovedOnATaskTheSessionDoesNotWaitOn() async throws {
        // The app that moves the settings is slow (it is the main actor's, and the launch is busy): the read goes on, the records are
        // checked and saved, and the moves are made after, one app at a time, in the order of the apps' bundle IDs.
        var initial = sections(shown: [weather, notes, vpn, sync])
        initial.noteIcons([name(weather, "x.phantom"), name(weather, "weather.temp"), name(weather, "weather.alerts"),
                           index(notes, 0), name(notes, "x.main-menu")])
        initial.unchecked = [weather, notes]
        let gate = Gate()
        let moved = Mutex<[String]>([])
        let rig = SessionRig.withAllowlist(sections: initial, recordsChecked: { app, _ in
            await gate.wait()
            moved.withLock { $0.append(app) }
            return SettingsMoved()
        })

        await rig.session.start()

        #expect(records(await rig.session.sections, notes) == [index(notes, 0)], "checked and saved while the moves wait")
        #expect(rig.saved.latest?.unchecked.isEmpty == true)
        #expect(moved.withLock { $0 }.isEmpty)
        gate.open()
        await rig.session.settingsMovesFinished()
        #expect(moved.withLock { $0 } == [notes, weather], "in the order of the bundle IDs")
    }

    private func checked(_ app: String) -> [(app: String, done: SectionModel.Reconciled)] {
        [(app: app, done: SectionModel.Reconciled())]
    }

    @Test func theQuitWaitsForTheMovesOfTheSettingsAndThenForTheSavesAndOnlyThen() async throws {
        // The quit writes the settings after it has waited for the moves and for what waits to be saved: a move that was still to be made
        // would be lost, as the app that was checked isn't checked again. It goes on when the slow app's move is done and what comes after
        // it has been done, and not before.
        let gate = Gate()
        let order = Mutex<[String]>([])
        let rig = SessionRig.withAllowlist(recordsChecked: { _, _ in
            await gate.wait()
            order.withLock { $0.append("moved") }
            return SettingsMoved()
        })
        await rig.session.start()
        await rig.session.reportChecked(checked(weather), in: .empty)
        #expect(order.withLock { $0 }.isEmpty, "the check is over, and the move waits")

        let session = rig.session
        let quit = Task {
            await session.finishSettingsMovesForQuit { order.withLock { $0.append("saved") } }
            order.withLock { $0.append("the quit goes on") }
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(order.withLock { $0 }.isEmpty)
        gate.open()
        await quit.value

        #expect(order.withLock { $0 } == ["moved", "saved", "the quit goes on"])
    }

    @Test func aCheckMadeWhileTheQuitWaitsHasItsMovesWaitedForToo() async throws {
        // A read that is in `ingest` when the quit begins makes a check of its own: its task is chained behind the one the quit was
        // waiting for, and the quit isn't done until that one is.
        let gates = ["a": Gate(), "b": Gate()]
        let order = Mutex<[String]>([])
        let rig = SessionRig.withAllowlist(recordsChecked: { app, _ in
            await gates[app == weather ? "a" : "b"]?.wait()
            order.withLock { $0.append("moved \(app)") }
            return SettingsMoved()
        })
        await rig.session.start()
        await rig.session.reportChecked(checked(weather), in: .empty)

        let session = rig.session
        let quit = Task {
            await session.finishSettingsMovesForQuit { order.withLock { $0.append("saved") } }
        }
        for _ in 0..<20 { await Task.yield() }
        await rig.session.reportChecked(checked(notes), in: .empty)
        gates["a"]?.open()
        for _ in 0..<50 { await Task.yield() }
        #expect(order.withLock { $0 } == ["moved \(weather)"], "the quit still waits: the second check's move hasn't been made")
        gates["b"]?.open()
        await quit.value

        #expect(order.withLock { $0 } == ["moved \(weather)", "moved \(notes)", "saved"])
    }

    @Test func theQuitDoesNotWaitForTheMovesPastItsLimit() async throws {
        let gate = Gate()
        let order = Mutex<[String]>([])
        let rig = SessionRig.withAllowlist(recordsChecked: { _, _ in
            await gate.wait()
            return SettingsMoved()
        })
        defer { gate.open() }
        await rig.session.start()
        await rig.session.reportChecked(checked(weather), in: .empty)

        let session = rig.session
        let done = Mutex(false)
        _ = Task {
            await session.finishSettingsMovesForQuit { order.withLock { $0.append("saved") } }
            done.withLock { $0 = true }
        }
        #expect(await rig.clock.waitForSleepers(1, within: .seconds(5)))
        rig.clock.advance(by: MenuBarSession.quitSettingsMovesLimit - .milliseconds(1))
        for _ in 0..<20 { await Task.yield() }
        #expect(done.withLock { $0 } == false, "inside the limit, the moves are waited for")
        rig.clock.advance(by: .milliseconds(1))
        // Bounded: without the limit the quit would wait for the move for ever, and the test fails at the time limit, not hangs.
        #expect(await waitUntil(.seconds(5)) { done.withLock { $0 } }, "the quit goes on at the limit")
        #expect(MenuBarSession.quitSettingsMovesLimit < QuitTimer.base)
        #expect(order.withLock { $0 }.isEmpty, "and what was to follow the moves has not been done")
    }

    @Test func anUncheckedAppWhoseFirstRecordIsAPhantomShowsItsListedIconUntilItIsReadWhole() async throws {
        // The first record of the app is a name it never had, and its read isn't whole (a name didn't come): the places that list icons show
        // the icon the latest read lists, `#0`, and not the phantom.
        var initial = sections(shown: [weather, notes, vpn, sync])
        initial.noteIcons([name(notes, "x.main-menu"), index(notes, 0)])
        initial.unchecked = [notes]
        let rig = SessionRig.withAllowlist(sections: initial)
        rig.extras.rewriteAnswers { outcome, app in
            guard app.bundleID == notes, case .items(let extras) = outcome else { return outcome }
            return .items(AppExtras(pid: extras.pid, bundleID: extras.bundleID, name: extras.name, items: extras.items, timedOut: false,
                                    itemTimeouts: 1, namesIncomplete: true))
        }
        await rig.session.start()

        let state = try #require(await rig.state)
        #expect(state.currentIDs[notes] == nil, "not read whole")
        #expect(state.staleRecords.contains(name(notes, "x.main-menu")) && !state.staleRecords.contains(index(notes, 0)))
    }
}
