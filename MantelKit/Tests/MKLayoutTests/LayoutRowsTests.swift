import CoreGraphics
import MKCore
import Testing

@testable import MKLayout

@Suite("Layout rows", .timeLimit(.minutes(1)))
struct LayoutRowsTests {
    private let frame = CGRect(x: 100, y: 0, width: 30, height: 30)

    /// An item of `bundleID` that the menu bar read named `appName`.
    private func item(_ bundleID: String, _ identifier: String = "main", appName: String? = nil, label: String? = nil,
                      overflowed: Bool = false) -> MenuBarItem {
        MenuBarItem(id: Fixtures.itemID(bundleID, identifier), ownerBundleID: bundleID, appName: appName, label: label,
                    frames: [Fixtures.display: frame], overflowedOn: overflowed ? [Fixtures.display] : [], isMantel: false)
    }

    private func systemItem(_ module: String, label: String? = nil) -> MenuBarItem {
        MenuBarItem(id: .system(module), ownerBundleID: ItemID.systemBundleID, appName: nil, label: label,
                    frames: [Fixtures.display: frame], overflowedOn: [], isMantel: false)
    }

    // MARK: Apps

    @Test func rowsGroupedBySectionSortedByName() {
        var sections = SectionModel()
        sections.move(app: "com.example.zeta", to: .hidden)
        sections.move(app: "com.example.alpha", to: .hidden)
        sections.move(app: "com.example.mid", to: .alwaysHidden)
        sections.move(app: "com.example.apple", to: .shown)
        let inventory = Fixtures.inventory([
            item("com.example.zeta"), item("com.example.alpha"), item("com.example.mid"), item("com.example.apple"),
            item("com.example.unplaced"),
        ])
        let names = ["com.example.zeta": "Zeta", "com.example.alpha": "alpha", "com.example.mid": "Middle",
                     "com.example.apple": "Apple", "com.example.unplaced": "Newcomer"]

        let rows = LayoutRows.apps(inventory: inventory, sections: sections, names: names)

        // Letters are ordered without regard to case, and an app nobody placed is in the new-items section (Shown).
        #expect(rows[.hidden]?.map(\.name) == ["alpha", "Zeta"])
        #expect(rows[.alwaysHidden]?.map(\.name) == ["Middle"])
        #expect(rows[.shown]?.map(\.name) == ["Apple", "Newcomer"])
        #expect(rows[.hidden]?.map(\.id) == ["com.example.alpha", "com.example.zeta"])
    }

    @Test func everySectionHasAListEvenWhenNothingIsInIt() {
        let rows = LayoutRows.apps(inventory: .empty, sections: SectionModel(), names: [:])
        for section in MenuBarSection.allCases {
            #expect(rows[section] == [])
        }
        #expect(rows.count == 3)
    }

    @Test func theNewItemsSectionIsWhereAnUnplacedAppIsListed() {
        var sections = SectionModel()
        sections.newItems = .alwaysHidden
        let rows = LayoutRows.apps(inventory: Fixtures.inventory([item("com.example.fresh")]), sections: sections,
                                   names: ["com.example.fresh": "Fresh"])
        #expect(rows[.alwaysHidden]?.map(\.id) == ["com.example.fresh"])
        #expect(rows[.shown] == [])
    }

    @Test func iconCountsPerApp() {
        let inventory = Fixtures.inventory([
            item("com.example.one"),
            item("com.example.three", "a"), item("com.example.three", "b"), item("com.example.three", "c"),
        ])
        let rows = LayoutRows.apps(inventory: inventory, sections: SectionModel(), names: [:])
        let byID = Dictionary(uniqueKeysWithValues: (rows[.shown] ?? []).map { ($0.id, $0) })
        #expect(byID["com.example.one"]?.iconCount == 1)
        #expect(byID["com.example.three"]?.iconCount == 3)
        #expect(byID["com.example.one"]?.iconCountText == "1 icon")
        #expect(byID["com.example.three"]?.iconCountText == "3 icons")
        #expect(AppRow(id: "x", name: "x", iconCount: 0, isAuto: false).iconCountText == "0 icons")
    }

    @Test func autoFlag() {
        var sections = SectionModel()
        sections.apps["com.example.auto"] = AppPlacement(section: .hidden, isAuto: true)
        sections.move(app: "com.example.chosen", to: .hidden)
        let inventory = Fixtures.inventory([item("com.example.auto"), item("com.example.chosen"), item("com.example.unplaced")])
        let rows = LayoutRows.apps(inventory: inventory, sections: sections, names: [:])

        let hidden = Dictionary(uniqueKeysWithValues: (rows[.hidden] ?? []).map { ($0.id, $0.isAuto) })
        #expect(hidden == ["com.example.auto": true, "com.example.chosen": false])
        #expect(rows[.shown]?.map(\.isAuto) == [false])
    }

    @Test func anAppWithNoNameInTheMapIsCalledWhatTheReadSaysThenItsBundleID() {
        let inventory = Fixtures.inventory([item("com.example.read", appName: "Read Name"), item("com.example.bare"),
                                            item("com.example.blank", appName: "  ")])
        let rows = LayoutRows.apps(inventory: inventory, sections: SectionModel(), names: [:])
        let names = Dictionary(uniqueKeysWithValues: (rows[.shown] ?? []).map { ($0.id, $0.name) })
        #expect(names == ["com.example.read": "Read Name", "com.example.bare": "com.example.bare", "com.example.blank": "com.example.blank"])

        // A name that was resolved wins over the one the read has.
        let resolved = LayoutRows.apps(inventory: inventory, sections: SectionModel(), names: ["com.example.read": "Resolved"])
        #expect(resolved[.shown]?.first { $0.id == "com.example.read" }?.name == "Resolved")
    }

    @Test func mantelsOwnIconsAndTheSystemsAreNotApps() {
        let own = MenuBarItem(id: Fixtures.itemID("com.example.mantel"), ownerBundleID: "com.example.mantel", appName: "Mantel", label: nil,
                              frames: [Fixtures.display: frame], overflowedOn: [], isMantel: true)
        let inventory = Fixtures.inventory([own, systemItem("wifi"), item("com.example.app")])
        let rows = LayoutRows.apps(inventory: inventory, sections: SectionModel(), names: [:])
        #expect(rows[.shown]?.map(\.id) == ["com.example.app"])
    }

    @Test func rowsWithTheSameNameKeepTheOrderOfTheirBundleIDs() {
        let inventory = Fixtures.inventory([item("com.example.b"), item("com.example.a")])
        let names = ["com.example.a": "Same", "com.example.b": "Same"]
        #expect(LayoutRows.apps(inventory: inventory, sections: SectionModel(), names: names)[.shown]?.map(\.id)
                == ["com.example.a", "com.example.b"])
    }

    // MARK: System icons

    @Test func systemRowsLockedWithoutPermission() {
        let inventory = Fixtures.inventory([
            systemItem("wifi"), systemItem("clock"), systemItem("controlcenter"), systemItem("battery"),
        ])
        let locked = LayoutRows.system(inventory: inventory, sections: SectionModel(), allowClockAndControlCenter: false)
        #expect(locked.map(\.title) == ["Battery", "Clock", "Control Center", "Wi-Fi"])
        #expect(locked.map(\.canChange) == [true, false, false, true])

        let allowed = LayoutRows.system(inventory: inventory, sections: SectionModel(), allowClockAndControlCenter: true)
        #expect(allowed.allSatisfy { $0.canChange })
    }

    @Test func systemRowsCarryTheirSectionAndModule() {
        var sections = SectionModel()
        sections.move(item: .system("wifi"), to: .hidden)
        let rows = LayoutRows.system(inventory: Fixtures.inventory([systemItem("wifi"), systemItem("sound")]), sections: sections,
                                     allowClockAndControlCenter: false)
        #expect(rows.map(\.id) == ["sound", "wifi"])
        #expect(rows.map(\.section) == [.shown, .hidden])
    }

    @Test func onlyKnownModulesThatArePresentAreListed() {
        // AirDrop has no number, so it can't be put in a section; a module that isn't in the menu bar has no row.
        let inventory = Fixtures.inventory([systemItem("airdrop"), systemItem("wifi"), systemItem("wifi"),
                                            item("com.example.app", "wifi")])
        let rows = LayoutRows.system(inventory: inventory, sections: SectionModel(), allowClockAndControlCenter: false)
        #expect(rows.map(\.id) == ["wifi"])
    }

    @Test func aHiddenSystemIconStaysListedWhenTheReadDoesNotHaveIt() {
        var sections = SectionModel()
        sections.move(item: .system("bluetooth"), to: .alwaysHidden)
        sections.systemItems["airdrop"] = .hidden
        let rows = LayoutRows.system(inventory: .empty, sections: sections, allowClockAndControlCenter: false)
        #expect(rows.map(\.id) == ["bluetooth"])
        #expect(rows.first?.section == .alwaysHidden)
    }

    // MARK: Lists that can't be changed

    private func lists(cantMove: [ItemID] = [], turnedOff: TurnedOffList = .apps([]), missing: [String] = [], overflow: [ItemID] = [],
                       cantHideYet: [ItemID] = []) -> ReadOnlyLists {
        ReadOnlyLists(cantMove: cantMove, turnedOff: turnedOff, missing: missing, overflow: overflow, cantHideYet: cantHideYet)
    }

    @Test func cantMoveListsTheClockAndControlCenterUntilHidingThemIsAllowed() {
        let source = lists(cantMove: [.system("controlcenter"), .system("clock")])
        let inventory = Fixtures.inventory([systemItem("clock"), systemItem("controlcenter")])
        let locked = LayoutRows.readOnly(lists: source, inventory: inventory, names: [:], allowClockAndControlCenter: false)
        #expect(locked.cantMove.map(\.name) == ["Clock", "Control Center"])
        #expect(LayoutRows.readOnly(lists: source, inventory: inventory, names: [:], allowClockAndControlCenter: true).cantMove.isEmpty)
    }

    @Test func turnedOffAppsAreNamedAndAnUnavailableListSaysWhy() {
        let names = ["com.example.b": "Bravo", "com.example.a": "Alpha"]
        let apps = LayoutRows.readOnly(lists: lists(turnedOff: .apps(["com.example.b", "com.example.a", "com.example.unknown"])),
                                       inventory: .empty, names: names, allowClockAndControlCenter: false)
        #expect(apps.turnedOff == .apps([NamedRow(id: "com.example.a", name: "Alpha"), NamedRow(id: "com.example.b", name: "Bravo"),
                                         NamedRow(id: "com.example.unknown", name: "com.example.unknown")]))

        let unavailable = LayoutRows.readOnly(lists: lists(turnedOff: .unavailable("The list can't be read.")), inventory: .empty,
                                              names: names, allowClockAndControlCenter: false)
        #expect(unavailable.turnedOff == .unavailable("The list can't be read."))
        #expect(LayoutRows.readOnly(lists: ReadOnlyLists(cantMove: [], turnedOff: .apps([]), missing: [], overflow: [], cantHideYet: []), inventory: .empty, names: [:], allowClockAndControlCenter: false).turnedOff == .apps([]))
    }

    @Test func missingAppsAreNamedAndSortedByName() {
        let rows = LayoutRows.readOnly(lists: lists(missing: ["com.example.a", "com.example.b"]), inventory: .empty,
                                       names: ["com.example.a": "Zulu", "com.example.b": "Yankee"], allowClockAndControlCenter: false)
        #expect(rows.missing.map(\.name) == ["Yankee", "Zulu"])
        #expect(rows.missing.map(\.id) == ["com.example.b", "com.example.a"])
    }

    @Test func overflowListsEachAppOnceAndSystemIconsByTitle() {
        let inventory = Fixtures.inventory([
            item("com.example.app", "a", appName: "Read App", overflowed: true), item("com.example.app", "b", overflowed: true),
            item("com.example.other", overflowed: true),
        ])
        let source = lists(overflow: [Fixtures.itemID("com.example.app", "a"), Fixtures.itemID("com.example.app", "b"),
                                      Fixtures.itemID("com.example.other"), .system("battery")])
        let rows = LayoutRows.readOnly(lists: source, inventory: inventory, names: ["com.example.other": "Other"],
                                       allowClockAndControlCenter: false)
        #expect(rows.overflow.map(\.name) == ["Battery", "Other", "Read App"])
        #expect(rows.overflow.count == 3)
    }

    @Test func iconsThatCantBeHiddenYetUseTheirLabel() {
        let inventory = Fixtures.inventory([systemItem("airdrop", label: "AirDrop"), systemItem("newthing"),
                                            systemItem("blank", label: "  ")])
        let rows = LayoutRows.readOnly(lists: lists(cantHideYet: [.system("airdrop"), .system("newthing"), .system("blank")]),
                                       inventory: inventory, names: [:], allowClockAndControlCenter: false)
        // No label (or a blank one) falls back to the module.
        #expect(rows.cantHideYet.map(\.name) == ["AirDrop", "blank", "newthing"])
        #expect(rows.cantHideYet.map(\.id) == ["system:airdrop", "system:blank", "system:newthing"])
    }

    // MARK: Names to find

    @Test func appIDsAreEveryAppThePaneLists() {
        let inventory = Fixtures.inventory([item("com.example.running"), systemItem("wifi"), item("com.example.overflowed", overflowed: true)])
        let source = lists(turnedOff: .apps(["com.example.off"]), missing: ["com.example.gone"],
                           overflow: [Fixtures.itemID("com.example.overflowed"), .system("battery")])
        #expect(LayoutRows.appIDs(inventory: inventory, sections: SectionModel(), lists: source)
            == ["com.example.running", "com.example.overflowed", "com.example.off", "com.example.gone"])
        #expect(LayoutRows.appIDs(inventory: .empty, sections: SectionModel(), lists: lists(turnedOff: .unavailable("x"))).isEmpty)
    }

    @Test func appIDsIncludeTheUnansweredAppsThatHaveAPlace() {
        var sections = SectionModel()
        sections.move(app: "com.example.slow", to: .hidden)
        let inventory = Fixtures.inventory([item("com.example.running")], unansweredApps: ["com.example.slow", "com.example.stranger"])
        #expect(LayoutRows.appIDs(inventory: inventory, sections: sections, lists: lists()) == ["com.example.running", "com.example.slow"])
    }

    // MARK: An app that didn't answer

    @Test func anAppThatDidNotAnswerKeepsItsRow() {
        var sections = SectionModel()
        sections.move(app: "com.example.slow", to: .hidden)
        sections.apps["com.example.auto"] = AppPlacement(section: .hidden, isAuto: true)
        sections.move(app: "com.example.quiet", to: .alwaysHidden)
        // The slow app and the auto one timed out; the quiet one answered with its one icon; a stranger was never placed.
        let inventory = Fixtures.inventory([item("com.example.quiet")],
                                           unansweredApps: ["com.example.slow", "com.example.auto", "com.example.stranger"])
        let names = ["com.example.slow": "Slow", "com.example.auto": "Auto One", "com.example.quiet": "Quiet"]

        let rows = LayoutRows.apps(inventory: inventory, sections: sections, names: names)

        // Each stays in the section it was placed in, with the flag, and no count of icons.
        #expect(rows[.hidden]?.map(\.id) == ["com.example.auto", "com.example.slow"])
        #expect(rows[.hidden]?.map(\.isNotAnswering) == [true, true])
        #expect(rows[.hidden]?.map(\.statusText) == ["Not answering", "Not answering"])
        #expect(rows[.hidden]?.map(\.isAuto) == [true, false], "its place, and who put it there, are as they were")
        // The one that answered is a row as always, and one that has no place isn't listed: it was never seen with icons.
        #expect(rows[.alwaysHidden]?.map(\.statusText) == ["1 icon"])
        #expect(rows[.alwaysHidden]?.first?.isNotAnswering == false)
        #expect(rows.values.joined().contains { $0.id == "com.example.stranger" } == false)
        #expect(rows[.shown] == [])
    }

    @Test func anAppThatAnsweredWithItsIconsIsNotAlsoListedAsNotAnswering() {
        // An app with two processes: one answered, one didn't.
        var sections = SectionModel()
        sections.move(app: "com.example.two", to: .hidden)
        let inventory = Fixtures.inventory([item("com.example.two")], unansweredApps: ["com.example.two"])
        let rows = LayoutRows.apps(inventory: inventory, sections: sections, names: [:])
        #expect(rows[.hidden]?.count == 1)
        #expect(rows[.hidden]?.first?.isNotAnswering == false)
    }

    // MARK: An app macOS has turned off

    @Test func anAppTurnedOffInSystemSettingsIsMarked() {
        var sections = SectionModel()
        sections.move(app: "com.example.off", to: .hidden)
        sections.move(app: "com.example.on", to: .hidden)
        sections.move(app: "com.example.shownoff", to: .shown)
        let inventory = Fixtures.inventory([item("com.example.off"), item("com.example.off", "second"), item("com.example.on"),
                                            item("com.example.shownoff")])
        let names = ["com.example.off": "Off One", "com.example.on": "On One", "com.example.shownoff": "Shown Off"]

        let rows = LayoutRows.apps(inventory: inventory, sections: sections, names: names,
                                   turnedOff: .apps(["com.example.off", "com.example.shownoff", "com.example.notrunning"]))

        // The apps whose switch is off are marked, in whichever section they are, and say so in place of their count.
        let off = rows[.hidden]?.first { $0.id == "com.example.off" }
        #expect(off?.isTurnedOff == true)
        #expect(off?.statusText == "Off in System Settings")
        #expect(off?.needsAttention == true)
        #expect(off?.isNotAnswering == false)
        #expect(off?.iconCount == 2, "the icons are still counted")
        #expect(rows[.shown]?.first?.isTurnedOff == true)
        // An app that is on is as it was, and one that isn't running isn't listed because of the list.
        let on = rows[.hidden]?.first { $0.id == "com.example.on" }
        #expect(on?.isTurnedOff == false)
        #expect(on?.statusText == "1 icon")
        #expect(on?.needsAttention == false)
        #expect(on?.helpText == "")
        #expect(rows.values.joined().contains { $0.id == "com.example.notrunning" } == false)

        // What the row explains.
        #expect(off?.helpText == "macOS hides this app's icon because its switch is off in System Settings › Menu Bar. Turn it on there to let Mantel show and hide it.")
        #expect(LayoutCopy.offInSystemSettings == "Off in System Settings")
    }

    @Test func nothingIsMarkedWhenTheListCantBeRead() {
        var sections = SectionModel()
        sections.move(app: "com.example.off", to: .hidden)
        let inventory = Fixtures.inventory([item("com.example.off")])
        for turnedOff in [TurnedOffList.unavailable("Choose the file first."), .apps([])] {
            let row = LayoutRows.apps(inventory: inventory, sections: sections, names: [:], turnedOff: turnedOff)[.hidden]?.first
            #expect(row?.isTurnedOff == false)
            #expect(row?.statusText == "1 icon")
        }
        // Not asking is the same as not knowing.
        #expect(LayoutRows.apps(inventory: inventory, sections: sections, names: [:])[.hidden]?.first?.isTurnedOff == false)
    }

    @Test func anAppThatIsNotAnsweringIsNotAlsoMarkedAsTurnedOff() {
        var sections = SectionModel()
        sections.move(app: "com.example.slow", to: .hidden)
        // The app didn't answer, and is on the list as well: "Not answering" is what the row says, and it says nothing else.
        let slow = LayoutRows.apps(inventory: Fixtures.inventory([], unansweredApps: ["com.example.slow"]), sections: sections, names: [:],
                                   turnedOff: .apps(["com.example.slow"]))[.hidden]?.first
        #expect(slow?.isNotAnswering == true)
        #expect(slow?.isTurnedOff == false)
        #expect(slow?.statusText == "Not answering")
        #expect(slow?.helpText == LayoutCopy.notAnsweringHelp)

        // A row that is both, built by hand, still says "Not answering".
        let both = AppRow(id: "x", name: "x", iconCount: 0, isAuto: false, isNotAnswering: true, isTurnedOff: true)
        #expect(both.statusText == "Not answering")
        #expect(both.helpText == LayoutCopy.notAnsweringHelp)
    }

    // MARK: Locked system icons

    @Test func lockedModulesShowAsShownWhateverWasStored() {
        var sections = SectionModel()
        sections.move(item: .system("clock"), to: .alwaysHidden)
        sections.move(item: .system("controlcenter"), to: .hidden)
        sections.move(item: .system("wifi"), to: .hidden)
        let inventory = Fixtures.inventory([systemItem("clock"), systemItem("controlcenter"), systemItem("wifi")])

        // While hiding them isn't allowed the plan keeps them on the bar, and the rows say so.
        let locked = Dictionary(uniqueKeysWithValues: LayoutRows.system(inventory: inventory, sections: sections, allowClockAndControlCenter: false)
            .map { ($0.id, $0.section) })
        #expect(locked == ["clock": .shown, "controlcenter": .shown, "wifi": .hidden])

        // Allowed, they are where they were put.
        let allowed = Dictionary(uniqueKeysWithValues: LayoutRows.system(inventory: inventory, sections: sections, allowClockAndControlCenter: true)
            .map { ($0.id, $0.section) })
        #expect(allowed == ["clock": .alwaysHidden, "controlcenter": .hidden, "wifi": .hidden])
    }

    // MARK: An icon macOS doesn't tie to its app

    private let unattachedNote = "macOS can't tell which app this icon belongs to, so it's hidden whenever anything is hidden."

    @Test func unattachedRowCarriesTheNoteWhileTheAllowlistIsInUse() {
        var sections = SectionModel()
        sections.move(app: "com.example.hid", to: .hidden)
        let inventory = Fixtures.inventory([item("com.example.one"), item("com.example.hid"), item("com.example.fine")])
        let rows = LayoutRows.apps(inventory: inventory, sections: sections, names: [:], unattached: ["com.example.one", "com.example.hid"],
                                   allowlistInUse: true)
        let byID = Dictionary(uniqueKeysWithValues: rows.values.joined().map { ($0.id, $0) })

        // In any section: the note, the tooltip and the colour; the status stays the count of icons.
        for id in ["com.example.one", "com.example.hid"] {
            let row = byID[id]
            #expect(row?.isUnattached == true, "\(id)")
            #expect(row?.note == unattachedNote)
            #expect(row?.helpText == unattachedNote)
            #expect(row?.needsAttention == true)
            #expect(row?.statusText == "1 icon")
        }
        #expect(LayoutCopy.unattachedIcon == unattachedNote)
        let fine = byID["com.example.fine"]
        #expect(fine?.note == nil)
        #expect(fine?.helpText == "")
        #expect(fine?.needsAttention == false)
    }

    @Test func noNoteUnderTheSwitches() {
        let inventory = Fixtures.inventory([item("com.example.one")])
        let rows = LayoutRows.apps(inventory: inventory, sections: SectionModel(), names: [:], unattached: ["com.example.one"],
                                   allowlistInUse: false)
        let row = rows.values.joined().first
        #expect(row?.isUnattached == false)
        #expect(row?.note == nil)
        #expect(row?.needsAttention == false)
        // Nor by default.
        #expect(LayoutRows.apps(inventory: inventory, sections: SectionModel(), names: [:], unattached: ["com.example.one"])
            .values.joined().first?.note == nil)
    }

    @Test func turnedOffOrNotAnsweringRowsCarryNoNote() {
        var sections = SectionModel()
        sections.move(app: "com.example.silent", to: .shown)
        let inventory = Fixtures.inventory([item("com.example.off")], unansweredApps: ["com.example.silent"])
        let rows = LayoutRows.apps(inventory: inventory, sections: sections, names: [:], turnedOff: .apps(["com.example.off"]),
                                   unattached: ["com.example.off", "com.example.silent"], allowlistInUse: true)
        let byID = Dictionary(uniqueKeysWithValues: rows.values.joined().map { ($0.id, $0) })
        #expect(byID["com.example.off"]?.isTurnedOff == true)
        #expect(byID["com.example.off"]?.note == nil)
        #expect(byID["com.example.off"]?.helpText == LayoutCopy.offInSystemSettingsHelp)
        #expect(byID["com.example.silent"]?.isNotAnswering == true)
        #expect(byID["com.example.silent"]?.note == nil)
        #expect(byID["com.example.silent"]?.helpText == LayoutCopy.notAnsweringHelp)
    }

    // MARK: What the strips say of an app

    @Test func unattachedAppsTooltipCarriesTheNoteWhileTheAllowlistIsInUse() {
        let inventory = Fixtures.inventory([item("com.example.one"), item("com.example.fine")])
        let sections = SectionModel()
        let rows = Dictionary(uniqueKeysWithValues: LayoutRows.apps(inventory: inventory, sections: sections, names: [:],
                                                                    unattached: ["com.example.one"], allowlistInUse: true)
            .values.joined().map { ($0.id, $0) })
        let one = StripToken.app(bundleID: "com.example.one", items: [Fixtures.itemID("com.example.one")])
        let fine = StripToken.app(bundleID: "com.example.fine", items: [Fixtures.itemID("com.example.fine")])
        let names = ["com.example.one": "One", "com.example.fine": "Fine"]

        #expect(LayoutEditorModel.tooltip(of: one, names: names, sections: sections, cantReorder: [], rows: rows)
            == "One\n\(unattachedNote)")
        #expect(LayoutEditorModel.accessibilityLabel(of: one, names: names, sections: sections, cantReorder: [], rows: rows)
            == "One, \(unattachedNote)")
        #expect(LayoutEditorModel.tooltip(of: fine, names: names, sections: sections, cantReorder: [], rows: rows) == "Fine")
        #expect(LayoutEditorModel.accessibilityLabel(of: fine, names: names, sections: sections, cantReorder: [], rows: rows) == "Fine")
    }

    @Test func noNoteInTheTooltipUnderTheSwitches() {
        let inventory = Fixtures.inventory([item("com.example.one")])
        let rows = Dictionary(uniqueKeysWithValues: LayoutRows.apps(inventory: inventory, sections: SectionModel(), names: [:],
                                                                    unattached: ["com.example.one"], allowlistInUse: false)
            .values.joined().map { ($0.id, $0) })
        let one = StripToken.app(bundleID: "com.example.one", items: [Fixtures.itemID("com.example.one")])

        #expect(LayoutEditorModel.tooltip(of: one, names: [:], sections: SectionModel(), cantReorder: [], rows: rows) == "com.example.one")
        #expect(LayoutEditorModel.accessibilityLabel(of: one, names: [:], sections: SectionModel(), cantReorder: [], rows: rows)
            == "com.example.one")
    }

    @Test func theTooltipSaysEachThingInItsOrder() {
        var sections = SectionModel()
        sections.move(app: "com.example.off", to: .hidden)
        sections.place(app: "com.example.off", in: .hidden, isAuto: true)
        let inventory = Fixtures.inventory([item("com.example.off")], unansweredApps: ["com.example.silent"])
        sections.move(app: "com.example.silent", to: .hidden)
        let rows = Dictionary(uniqueKeysWithValues: LayoutRows.apps(inventory: inventory, sections: sections, names: [:],
                                                                    turnedOff: .apps(["com.example.off"])).values.joined().map { ($0.id, $0) })
        let off = StripToken.app(bundleID: "com.example.off", items: [Fixtures.itemID("com.example.off")])
        let silent = StripToken.app(bundleID: "com.example.silent", items: [Fixtures.itemID("com.example.silent")])
        let names = ["com.example.off": "Off", "com.example.silent": "Silent"]

        // The title, the row's help, that Mantel moved it, that it can't be reordered.
        #expect(LayoutEditorModel.tooltip(of: off, names: names, sections: sections, cantReorder: ["com.example.off"], rows: rows)
            == "Off\n\(LayoutCopy.offInSystemSettingsHelp)\n\(LayoutCopy.autoHelp)\n\(LayoutCopy.cantReorderHelp)")
        #expect(LayoutEditorModel.accessibilityLabel(of: off, names: names, sections: sections, cantReorder: ["com.example.off"], rows: rows)
            == "Off, Off in System Settings, Auto, can't reorder")
        #expect(LayoutEditorModel.tooltip(of: silent, names: names, sections: sections, cantReorder: [], rows: rows)
            == "Silent\n\(LayoutCopy.notAnsweringHelp)")
        #expect(LayoutEditorModel.accessibilityLabel(of: silent, names: names, sections: sections, cantReorder: [], rows: rows)
            == "Silent, Not answering")
    }
}

@Suite("Layout copy")
struct LayoutCopyTests {
    @Test func theSectionsHaveTheirFooters() {
        #expect(LayoutCopy.footer(for: .shown) == "Always in the menu bar.")
        #expect(LayoutCopy.footer(for: .hidden) == "Shown when you click •, or by the ways you chose in General.")
        #expect(LayoutCopy.footer(for: .alwaysHidden) == "Shown only when you click ••.")
        for section in MenuBarSection.allCases {
            #expect(!LayoutCopy.footer(for: section).isEmpty)
        }
    }

    @Test func theSectionsHaveTheirNames() {
        #expect(MenuBarSection.allCases.map(\.title) == ["Shown", "Hidden", "Always Hidden"])
    }

    @Test func theWordsOfTheRowsAndTheLists() {
        #expect(LayoutCopy.autoHelp == "Moved here to make room. It moves back when there's room.")
        #expect(LayoutCopy.overflowFooter
            == "When the menu bar is full or the notch is in the way, apps move to Hidden instead of disappearing into «, so the dots stay in sight. They move back when there's room.")
        #expect(LayoutCopy.systemIconsFooter == "To hide the clock or Control Center, allow it in Advanced.")
        #expect(LayoutCopy.cantMoveCaption == "macOS keeps these in place.")
        #expect(LayoutCopy.missingCaption == "Apps you've placed that aren't running.")
        #expect(LayoutCopy.overflowCaption == "macOS moved these out of sight because the menu bar is full.")
        #expect(LayoutCopy.cantHideYetCaption == "Mantel doesn't know how to hide these system icons yet.")
        #expect(LayoutCopy.none == "None.")
        #expect(LayoutCopy.notAnswering == "Not answering")
        #expect(LayoutCopy.notAnsweringHelp == "This app didn't answer when Mantel last read the menu bar. It keeps its place.")
        #expect([LayoutCopy.cantMoveTitle, LayoutCopy.turnedOffTitle, LayoutCopy.missingTitle, LayoutCopy.overflowTitle,
                 LayoutCopy.cantHideYetTitle] == ["Can't move", "Turned off in System Settings", "Missing", "In the « overflow", "Can't be hidden yet"])
    }

    // MARK: What can't be reordered

    @Test func cantReorderRows() {
        let inventory = Fixtures.inventory([Fixtures.item(Fixtures.itemID("com.example.quiet")),
                                            Fixtures.item(Fixtures.itemID("com.example.mute"))])
        let sourceLists = ReadOnlyLists(
            cantMove: [], turnedOff: .apps([]), missing: [], overflow: [], cantHideYet: [],
            cantReorder: [Fixtures.itemID("com.example.quiet", "one"), Fixtures.itemID("com.example.quiet", "two"),
                          Fixtures.itemID("com.example.mute"), .system("wifi"), OwnItems.itemID(SpacerID(rawValue: "0000000a"))])
        let names = ["com.example.quiet": "Quiet", "com.example.mute": "Mute"]

        let rows = LayoutRows.readOnly(lists: sourceLists, inventory: inventory, names: names, allowClockAndControlCenter: false)

        // Once for each app, by name; a system icon or one of Mantel's own is no app's.
        #expect(rows.cantReorder == [NamedRow(id: "com.example.mute", name: "Mute"), NamedRow(id: "com.example.quiet", name: "Quiet")])
        #expect(LayoutRows.cantReorderApps(lists: sourceLists) == ["com.example.quiet", "com.example.mute"])
        // The app is given a name like any other listed one.
        let ids = LayoutRows.appIDs(inventory: .empty, sections: SectionModel(), lists: sourceLists)
        #expect(ids == ["com.example.quiet", "com.example.mute"])
        #expect(LayoutRows.readOnly(lists: ReadOnlyLists(cantMove: [], turnedOff: .apps([]), missing: [], overflow: [], cantHideYet: []), inventory: inventory, names: names, allowClockAndControlCenter: false)
            .cantReorder.isEmpty)
    }

    @Test func newCopyStrings() {
        #expect(LayoutCopy.cantReorderTitle == "Can't reorder")
        #expect(LayoutCopy.cantReorderCaption == "macOS gives Mantel no way to place these. ⌘-drag them in the menu bar.")
        #expect(LayoutCopy.cantReorderHelp == "Can't reorder: ⌘-drag it in the menu bar.")
        #expect(LayoutCopy.cantReorderLabel == "can't reorder")
        #expect(LayoutEditorCopy.cantPlaceThisIcon == "macOS gives Mantel no way to place this icon. ⌘-drag it in the menu bar.")
        #expect(LayoutEditorCopy.systemIconsKeepOrder == "System icons keep macOS's order.")
        #expect(LayoutCopy.needsGrantBanner == "Grant access to reorder, or ⌘-drag in the menu bar")
        #expect(LayoutCopy.grantAccessButton == "Grant Access…")
        #expect(LayoutCopy.notAcceptedBanner == "macOS didn't accept the last order. Try the change again, or ⌘-drag in the menu bar.")
        #expect(LayoutCopy.notPlacedBanner
            == "Some of Mantel's icons couldn't be placed among icons it can't reorder. ⌘-drag them in the menu bar.")
        #expect(LayoutCopy.addedAtTheEnd(of: .hidden) == "Added at the end of Hidden. ⌘-drag it into place in the menu bar.")
        #expect(LayoutCopy.groupedHeader == "Grouped")
        #expect(LayoutCopy.groupedFooter == "Grouped icons open from their group's icon. •• shows them too.")
        #expect(LayoutCopy.emptyStrip == "Drag icons here")
        #expect(LayoutCopy.paletteHeader == "Add to the menu bar")
        #expect(LayoutCopy.paletteFooter == "Drag one into a row.")
        #expect(PaletteItem.allCases.map(LayoutCopy.paletteTitle) == ["Spacer", "Group", "New icons go here"])
        #expect(PaletteItem.allCases.map(LayoutCopy.paletteSymbol) == ["arrow.left.and.right", "square.grid.2x2", "plus.square.dashed"])
        #expect(LayoutCopy.add == "Add")
        #expect(LayoutCopy.noGroups == "No groups yet. Add one below.")
        #expect(LayoutCopy.searchNamesPrompt == "Other names, separated by commas")
        #expect(LayoutCopy.selectedIconHeader == "Selected icon")
        #expect(LayoutCopy.iconCount(1) == "1 icon" && LayoutCopy.iconCount(3) == "3 icons")
        #expect(LayoutCopy.movesWithOthers(count: 2, app: "Quiet") == "Moves with 2 other icons from Quiet")
        #expect(LayoutCopy.movesWithOthers(count: 1, app: "Quiet") == "Moves with 1 other icon from Quiet")
        #expect(LayoutCopy.keepDotsBesideClock == "Keep the dots beside the clock")
        #expect(LayoutCopy.keepDotsFooter
            == "They stay in place when icons show, and macOS's « never takes them. Hidden icons then appear left of your shown icons.")
        #expect(LayoutCopy.showAllWhileDragging == "Show all sections while ⌘-dragging")
        #expect(LayoutCopy.recaptureIcons == "Recapture icons")
        #expect(LayoutCopy.restoreOriginal == "Restore original layout…")
        #expect(LayoutCopy.restoreTitle == "Restore the original layout?")
        #expect(LayoutCopy.restoreText
            == "Mantel puts the menu bar icons back in the order they had before Mantel first changed it. Your sections stay as they are.")
        #expect(LayoutCopy.markerNote == "New icons appear here.")
        #expect(LayoutCopy.opensOnHover == "Open when the pointer rests on it")
        #expect(LayoutEditorModel.tokenGap == 4)
    }
}
