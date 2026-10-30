import Foundation
import MKCore
import MKLayout
import MKTestSupport
import Testing

@testable import MKMenuBar

private let weather = SessionWorld.weather
private let notes = SessionWorld.notes
private let vpn = SessionWorld.vpn
private let sync = SessionWorld.sync

/// A save of the sections leaves one line in the log, with what changed and who changed it (`SectionChangeLog`).
///
/// The log is the whole process's (`LogCapture`): each test looks for its own line.
@Suite("Menu bar session: the line a save leaves", .timeLimit(.minutes(1)))
struct MenuBarSessionSaveLogTests {
    private func said(_ lines: [String], _ text: String) -> Bool {
        lines.contains { $0.hasSuffix("[layout] " + text) }
    }

    @Test func aPersonsMoveSaysWhatMovedAndThatItWasTheirs() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(shown: [weather, notes, vpn, sync]))
        await rig.session.start()
        let session = rig.session
        let lines = await LogCapture.lines {
            await session.move(app: notes, to: .alwaysHidden)
        }
        #expect(said(lines, "sections saved: \(notes) to Always Hidden (the person)"), "\(lines)")
    }

    @Test func aPersonsForgetAndTheNewAppsSectionAreSaidToo() async throws {
        let rig = SessionRig.withAllowlist(sections: sections(shown: [weather, notes, vpn, sync]))
        await rig.session.start()
        let session = rig.session
        let lines = await LogCapture.lines {
            await session.setNewItemsSection(.alwaysHidden)
            await session.forget(app: sync)
        }
        #expect(said(lines, "sections saved: new apps go to Always Hidden (the person)"), "\(lines)")
        #expect(lines.contains { $0.contains("[layout] sections saved: \(sync) forgotten") && $0.hasSuffix("(the person)") }, "\(lines)")
    }

    @Test func appsNewToTheSessionAreSaidWithTheirIconsAtTheLaunch() async throws {
        // Only the VPN app was ever placed: the others are seen for the first time, and their icons are listed by the same read.
        let rig = SessionRig.withAllowlist(sections: sections(shown: [vpn]))
        let lines = await LogCapture.lines {
            await rig.session.start()
        }
        // The log is the whole process's, and other tests place the same apps: the line is looked for by all it has to say.
        #expect(lines.contains { $0.contains("[layout] sections saved:") && $0.contains("\(sync) placed in Shown") && $0.contains("(icons seen in a read); ")
                    && $0.hasSuffix("(apps seen for the first time)") },
                "the apps placed, with the records of the icons the read lists: \(lines)")
    }

    @Test func anAppMovedForTheDotsSaysThatTheTrackerDidIt() async throws {
        var settings = HidingSettings()
        settings.automaticOverflow = true
        let rig = SessionRig.withAllowlist(shape: .laptop, capacity: 4, ownFirst: true,
                                           sections: sections(shown: [vpn, sync], hidden: [weather, notes]), settings: settings)
        let lines = await LogCapture.lines {
            await rig.session.start()
            _ = await rig.waitForReads(SessionRig.readsAtStart + 1)
        }
        #expect(said(lines, "sections saved: \(vpn) to Hidden (the overflow tracker)"), "\(lines)")
    }

    @Test func theCheckOfAnAppsSavedIconsSaysWhatItDropped() async throws {
        var initial = sections(shown: [weather, notes, vpn, sync])
        // An identifier no other test uses: the log is the whole process's, and other tests' checks drop records of the same apps.
        let extra = ItemID(bundleID: notes, key: .identifier("x.save-log-check"))
        initial.noteIcons([ItemID(bundleID: notes, key: .index(0)), extra])
        initial.unchecked = [notes]
        let rig = SessionRig.withAllowlist(sections: initial)
        let lines = await LogCapture.lines {
            await rig.session.start()
            await rig.session.settingsMovesFinished()
        }
        #expect(lines.contains { $0.contains("[layout] sections saved:") && $0.contains("icon record dropped: \(extra)")
                    && $0.contains("(a check of saved icons)") }, "\(lines)")
    }

    @Test func aTrialOfAnAppThatWasMovedForRoomSaysSoWhenItBeginsAndWhenItPasses() async throws {
        var settings = HidingSettings()
        settings.automaticOverflow = true
        let rig = SessionRig.withAllowlist(shape: .laptop, capacity: 4, ownFirst: true,
                                           sections: sections(shown: [vpn, sync], hidden: [weather, notes]), settings: settings)
        await rig.session.start()
        #expect(await rig.waitForReads(SessionRig.readsAtStart + 2))
        #expect(await rig.session.sections.apps[vpn] == AppPlacement(section: .hidden, isAuto: true))
        let allowlist = try #require(rig.allowlist)

        // The bar has room again: a minute on, the app is tried on the bar again, and it fits.
        rig.world.setCapacity(nil)
        let clock = rig.clock
        let lines = await LogCapture.lines {
            _ = await clock.waitForSleepers(2, within: .seconds(5))
            clock.advance(by: .seconds(60))
            _ = await waitUntil { allowlist.calls.last?.bundleIDs.contains(vpn) == true }
            _ = await rig.pumpUntilReads(SessionRig.readsAtStart + 3)
        }
        #expect(said(lines, "sections saved: \(vpn) to Shown (the overflow tracker)"), "\(lines)")
        #expect(said(lines, "sections saved: \(vpn) no longer marked as moved by Mantel (the overflow tracker)"), "\(lines)")
    }
}
