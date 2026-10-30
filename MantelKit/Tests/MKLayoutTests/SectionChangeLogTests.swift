import MKCore
import Testing

@testable import MKLayout

/// The line the log has when the sections are saved: what changed and who changed it, in bundle IDs, section names and counts.
@Suite("Section change log", .timeLimit(.minutes(2)))
struct SectionChangeLogTests {
    private let a = "com.example.a"
    private let b = "com.example.b"

    private func model(shown: [String] = [], hidden: [String] = []) -> SectionModel {
        var model = SectionModel()
        for app in shown { model.move(app: app, to: .shown) }
        for app in hidden { model.move(app: app, to: .hidden) }
        return model
    }

    private func index(_ app: String, _ n: Int) -> ItemID { ItemID(bundleID: app, key: .index(n)) }

    @Test func aSaveThatChangedNothingHasNoLine() {
        let start = model(shown: [a], hidden: [b])
        var log = SectionChangeLog(from: start)
        #expect(log.line == nil)
        log.took(start, by: .person)
        #expect(log.line == nil, "a step that left the sections as they were says nothing")
    }

    @Test func aMoveSaysWhichAppToWhichSectionAndWho() {
        let start = model(shown: [a, b])
        var moved = start
        moved.move(app: b, to: .alwaysHidden)
        moved.move(app: a, to: .hidden)
        var log = SectionChangeLog(from: start)
        log.took(moved, by: .person)
        #expect(log.line == "sections saved: com.example.a to Hidden, com.example.b to Always Hidden (the person)")
    }

    @Test func aSaveOfManyAppsNamesSixAndCountsTheRest() {
        let apps = (1...10).map { "com.example.app\($0 < 10 ? "0" : "")\($0)" }
        var log = SectionChangeLog(from: SectionModel())
        log.took(model(shown: apps), by: .newApps)
        let named = apps.prefix(6).map { "\($0) placed in Shown" }.joined(separator: ", ")
        #expect(log.line == "sections saved: \(named), and 4 more apps (apps seen for the first time)")
    }

    @Test(arguments: [
        (SectionChangeLog.Cause.commandDrag, "a ⌘-drag"), (.barOrder, "the order on the bar"), (.overflowTracker, "the overflow tracker"),
        (.check, "a check of saved icons"), (.newIcons, "icons seen in a read"), (.newApps, "apps seen for the first time"),
    ])
    func theLineNamesWhoDidIt(cause: SectionChangeLog.Cause, words: String) {
        let start = model(shown: [a])
        var moved = start
        moved.move(app: a, to: .hidden)
        var log = SectionChangeLog(from: start)
        log.took(moved, by: cause)
        #expect(log.line == "sections saved: com.example.a to Hidden (\(words))")
    }

    @Test func aReadThatDidSeveralThingsHasOnePartForEachInOrder() {
        let start = model(shown: [a, b])
        var log = SectionChangeLog(from: start)
        var now = start
        now.move(app: a, to: .hidden)
        log.took(now, by: .commandDrag)
        now.noteIcons([index(b, 1)])
        log.took(now, by: .newIcons)
        now.assignNew(apps: ["com.example.c"])
        log.took(now, by: .newApps)
        #expect(log.line == "sections saved: com.example.a to Hidden (a ⌘-drag); 1 icon record added: com.example.b#1 (icons seen in a read); "
                + "com.example.c placed in Shown (apps seen for the first time)")
    }

    @Test func aRecordThatComesBackToAnAppIsNamedHoweverManyFirstIconsCameWithIt() {
        // The app the record comes back to sorts after the others, so it would be the one counted and not named.
        let late = "com.example.z"
        var start = model(shown: [late])
        start.noteIcons([index(late, 0)])
        var log = SectionChangeLog(from: start)
        var now = start
        now.noteIcons([index(late, 1), index("com.example.c", 0), index("com.example.d", 0), index("com.example.e", 0), index("com.example.f", 0)])
        log.took(now, by: .newIcons)
        #expect(log.line == "sections saved: 5 icon records added: com.example.z#1, com.example.c#0, com.example.d#0, com.example.e#0 and 1 more "
                + "(icons seen in a read)", "the record that came back first, then the first icons a few at a time")
    }

    @Test func aChangeSomeoneElseSavedIsNotSaidAgain() {
        let start = model(shown: [a, b])
        var log = SectionChangeLog(from: start)
        var now = start
        now.move(app: a, to: .hidden)
        log.skip(to: now)
        now.move(app: b, to: .hidden)
        log.took(now, by: .overflowTracker)
        #expect(log.line == "sections saved: com.example.b to Hidden (the overflow tracker)")
        var onlyTheirs = SectionChangeLog(from: start)
        onlyTheirs.skip(to: now)
        #expect(onlyTheirs.line == nil)
    }

    @Test func recordsAreNamedAFewAtATimeAndCounted() {
        var start = model(shown: [a])
        start.noteIcons([index(a, 0), index(a, 1), index(a, 2), index(a, 3), index(a, 4)])
        var dropped = start
        _ = dropped.reconcile(app: a, current: [index(a, 0)])
        var log = SectionChangeLog(from: start)
        log.took(dropped, by: .check)
        #expect(log.line == "sections saved: 4 icon records dropped: com.example.a#1, com.example.a#2, com.example.a#3 and 1 more (a check of saved icons)")
    }

    @Test func anAppForgottenAndAnAppPlacedAreSaidAsSuch() {
        let start = model(shown: [a])
        var now = start
        now.forget(app: a)
        now.assignNew(apps: [b])
        var log = SectionChangeLog(from: start)
        log.took(now, by: .person)
        #expect(log.line == "sections saved: com.example.a forgotten, com.example.b placed in Shown (the person)")
    }

    @Test func aSystemItemAndTheWhereNewAppsGoAreSaid() {
        var start = model()
        start.noteIcons([.system("wifi")])
        var now = start
        now.move(item: .system("wifi"), to: .hidden)
        now.newItems = .hidden
        var log = SectionChangeLog(from: start)
        log.took(now, by: .person)
        #expect(log.line == "sections saved: system item wifi to Hidden, new apps go to Hidden (the person)")
    }

    @Test func spacersAndGroupsAreCounted() {
        let start = model()
        var now = start
        now.addSpacer(LayoutSpacer(width: 12), in: .shown, at: 0)
        var log = SectionChangeLog(from: start)
        log.took(now, by: .person)
        #expect(log.line == "sections saved: 1 spacer added (the person)", "an own item is no icon record")
    }

    @Test func iconsThatOnlyChangedPlaceInTheirListAreSaidToHaveBeenReordered() {
        var start = model(shown: [a, b])
        start.noteIcons([index(a, 0), index(b, 0)])
        var now = start
        now.insert(index(b, 0), in: .shown, at: 0)
        #expect(now != start)
        var log = SectionChangeLog(from: start)
        log.took(now, by: .person)
        #expect(log.line == "sections saved: the order of icons changed (the person)")
    }
}
