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
@Suite("Menu bar session: records", .serialized, .timeLimit(.minutes(1)))
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
        // The session sleeps on this clock itself (its polling, the trial), so what is waited for is one more than there are now: the
        // quit's own bound, and the clock moves only once it sleeps.
        let sleepersBefore = rig.clock.sleeperCount
        _ = Task {
            await session.finishSettingsMovesForQuit { order.withLock { $0.append("saved") } }
            done.withLock { $0 = true }
        }
        #expect(await rig.clock.waitForSleepers(sleepersBefore + 1, within: .seconds(5)))
        rig.clock.advance(by: MenuBarSession.quitSettingsMovesLimit - .milliseconds(1))
        for _ in 0..<20 { await Task.yield() }
        #expect(done.withLock { $0 } == false, "inside the limit, the moves are waited for")
        rig.clock.advance(by: .milliseconds(1))
        // Bounded: without the limit the quit would wait for the move for ever, and the test fails at the time limit, not hangs.
        #expect(await waitUntil(.seconds(5)) { done.withLock { $0 } }, "the quit goes on at the limit")
        #expect(MenuBarSession.quitSettingsMovesLimit < QuitTimer.base)
        #expect(order.withLock { $0 }.isEmpty, "and what was to follow the moves has not been done")
    }
}
