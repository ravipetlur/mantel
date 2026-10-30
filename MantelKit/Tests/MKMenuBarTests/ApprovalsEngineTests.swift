import Foundation
import MKCore
import MKLayout
import MKTestSupport
import Synchronization
import Testing

@testable import MKMenuBar

/// The "Allow in the Menu Bar" file in a fake home folder, granted, with the list in it built in the shape macOS keeps it in and with
/// synthetic apps, and an engine over it. The preferences service is the file itself (`ScriptedService`): nothing here reaches the real
/// one, and every file is in the test's own folder.
private struct ApprovalsDesk: Sendable {
    static let own = EngineFixtures.own
    static let key = ApprovalsCodec.key

    let folder: TemporaryFolder
    let home: URL
    let file: URL
    let journal: Journal
    let grants: FileGrantStore
    let settings: SettingsStore
    let access: PlistFileAccess
    let service: ScriptedService
    let engine: ApprovalsEngine
    let clock: SteppingClock

    /// The apps of the list: ones with a switch that is on, one the person turned off, one named only by the path of a program, and an
    /// entry that names two apps.
    static let entries: [BlobFixtures.Approval] = [
        .init("com.example.one", allowed: true),
        .init("com.example.two", allowed: true),
        .init("com.example.three", allowed: true),
        .init("com.example.off", allowed: false),
        .init(allowed: true, locations: [.program("Example Tools/exampled")]),
        .init(allowed: true, locations: [.bundle("com.example.pair"), .bundle("com.example.pair.helper")]),
    ]

    static func make(entries: [BlobFixtures.Approval] = ApprovalsDesk.entries, service: ScriptedService = ScriptedService(.followsTheFile),
                     grantTheFile: Bool = true, content: Data? = nil, engineClock: (any Clock)? = nil) async throws -> ApprovalsDesk {
        let folder = TemporaryFolder(prefix: "mantel-approvals")
        let clock = SteppingClock()
        let paths = MantelPaths(root: folder.url.appending(path: "Mantel", directoryHint: .isDirectory),
                                logs: folder.url.appending(path: "Logs", directoryHint: .isDirectory))
        try paths.createDirectories()
        let home = folder.url.appending(path: "home", directoryHint: .isDirectory)
        let file = home.appending(path: "Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let blob = content ?? BlobFixtures.approvalsList(entries)
        try PropertyListSerialization.data(fromPropertyList: [key: blob, "other": "kept"], format: .binary, options: 0).write(to: file)

        let settings = SettingsStore(paths: paths, clock: SystemClock(), debounce: .seconds(3600))
        let grants = FileGrantStore(store: settings, bookmarkOptions: [], clock: clock)
        if grantTheFile {
            _ = try await grants.grant(.controlCenterApprovals, chosen: file, home: home)
            await settings.flush()
        }
        let journal = Journal(file: paths.journalFile, clock: clock)
        let access = PlistFileAccess(journal: journal, paths: paths, grants: grants, codecs: PlistBlobCodecs.standard, io: service.io, clock: clock)
        let engine = ApprovalsEngine(access: access, grants: grants, journal: journal, clock: engineClock ?? clock)
        return ApprovalsDesk(folder: folder, home: home, file: file, journal: journal, grants: grants, settings: settings, access: access,
                             service: service, engine: engine, clock: clock)
    }

    var identity: String { CanonicalPath.of(file) }

    /// The list as the file holds it now.
    func blob() throws -> Data {
        let data = try Data(contentsOf: file)
        let top = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        return try #require(top[Self.key] as? Data)
    }

    func entriesOnDisk() throws -> [NSDictionary] {
        try #require(PropertyListSerialization.propertyList(from: blob(), format: nil) as? [NSDictionary])
    }

    /// An app's switch in the file: nil when the list has no entry for it (or more than one).
    func flag(_ id: String) throws -> Bool? {
        guard case .bool(let flag)? = try ApprovalsCodec().value(at: ApprovalsCodec.flagPath(for: id), in: blob()) else { return nil }
        return flag
    }

    /// Replaces the list the way System Settings does: the whole list written again, here in `list`'s order.
    func rewrite(_ list: [NSDictionary]) throws {
        let blob = try PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0)
        try PropertyListSerialization.data(fromPropertyList: [Self.key: blob, "other": "kept"], format: .binary, options: 0).write(to: file)
    }

    /// The person changes a switch in System Settings: the list is written again, in the opposite order, with that one flag changed.
    func personSets(_ id: String, allowed: Bool) throws {
        let current = try entriesOnDisk()
        let changed = current.map { entry -> NSDictionary in
            let ids = ((entry["menuItemLocations"] as? [[String: Any]]) ?? []).compactMap { ($0["bundle"] as? [String: Any])?["_0"] as? String }
            guard ids.contains(id) else { return entry }
            let copy = NSMutableDictionary(dictionary: entry)
            copy["isAllowed"] = allowed
            return copy
        }
        try rewrite(changed.reversed())
    }

    /// The journal's records for this engine, oldest first.
    func records() async -> [JournalRecord] { await journal.records() }

    func plan(visible: Set<String> = [], concealed: Set<String> = []) -> VisibilityPlan {
        EngineFixtures.plan(visible: visible, concealed: concealed)
    }
}

/// A clock that moves by itself and notes what was slept, and can run something at each sleep.
private final class SleepLog: Clock {
    private let base = SteppingClock()
    private let slept = Mutex<[Duration]>([])
    private let hook = Mutex<(@Sendable () -> Void)?>(nil)

    var durations: [Duration] { slept.withLock { $0 } }
    func onSleep(_ body: (@Sendable () -> Void)?) { hook.withLock { $0 = body } }
    func now() -> Date { base.now() }

    func sleep(for duration: Duration) async throws {
        slept.withLock { $0.append(duration) }
        hook.withLock { $0 }?()
        try await base.sleep(for: duration)
    }
}

@Suite("Approvals engine", .timeLimit(.minutes(1)))
struct ApprovalsEngineTests {
    private let one = "com.example.one", two = "com.example.two", three = "com.example.three", off = "com.example.off"

    // MARK: Availability

    @Test func availabilityNeedsTheFileThenTheShape() async throws {
        let healthy = try await ApprovalsDesk.make()
        #expect(await healthy.engine.availability() == .available)
        #expect(healthy.engine.kind == .approvals)

        let noGrant = try await ApprovalsDesk.make(grantTheFile: false)
        #expect(await noGrant.engine.availability() == .needsPermission("Choose the “Allow in the Menu Bar” file in Settings › Permissions"))

        let changed = EngineAvailability.broken("macOS changed the “Allow in the Menu Bar” list, so Mantel can't edit it")
        // Not a property list; a property list that isn't a list; a list that isn't of entries; entries with no places in them.
        let garbage = Data("not a property list".utf8)
        let notAList = try PropertyListSerialization.data(fromPropertyList: ["isAllowed": true], format: .binary, options: 0)
        let numbers = try PropertyListSerialization.data(fromPropertyList: [1, 2, 3], format: .binary, options: 0)
        let noPlaces = try PropertyListSerialization.data(fromPropertyList: [["isAllowed": true, "name": "x"]], format: .binary, options: 0)
        for content in [garbage, notAList, numbers, noPlaces] {
            let desk = try await ApprovalsDesk.make(content: content)
            #expect(await desk.engine.availability() == changed)
        }
        // A list with nothing in it says nothing against its shape.
        let empty = try await ApprovalsDesk.make(entries: [])
        #expect(await empty.engine.availability() == .available)
    }

    @Test func aKeyThatIsNotThereIsAChangedList() async throws {
        let desk = try await ApprovalsDesk.make()
        try PropertyListSerialization.data(fromPropertyList: ["other": "x"], format: .binary, options: 0).write(to: desk.file)
        #expect(await desk.engine.availability() == .broken("macOS changed the “Allow in the Menu Bar” list, so Mantel can't edit it"))
    }

    @Test func aFileThatIsGoneNeedsTheGrantAgain() async throws {
        let desk = try await ApprovalsDesk.make()
        try FileManager.default.removeItem(at: desk.file)
        // The grant is for a file that isn't there any more: the person has to choose the file again.
        #expect(await desk.engine.availability() == .needsPermission("Choose the “Allow in the Menu Bar” file in Settings › Permissions"))
    }

    @Test func applyWithoutAUsableListThrowsUnavailable() async throws {
        let noGrant = try await ApprovalsDesk.make(grantTheFile: false)
        let error = await #expect(throws: HidingError.self) { try await noGrant.engine.apply(noGrant.plan(concealed: ["com.example.one"])) }
        #expect(error == .unavailable(.approvals, "Choose the “Allow in the Menu Bar” file in Settings › Permissions"))
        #expect(error?.errorDescription == "System Settings switches can't be used: Choose the “Allow in the Menu Bar” file in Settings › Permissions.")

        let changed = try await ApprovalsDesk.make(content: Data("not a property list".utf8))
        let other = await #expect(throws: HidingError.self) { try await changed.engine.apply(changed.plan(concealed: ["com.example.one"])) }
        #expect(other == .unavailable(.approvals, "macOS changed the “Allow in the Menu Bar” list, so Mantel can't edit it"))
        #expect(await changed.records().isEmpty)
    }

    // MARK: Applying

    @Test func applyWritesOnlyChangedApps() async throws {
        let desk = try await ApprovalsDesk.make()
        // `one` and `three` are to go; `two` is to stay and is on; `off` stays, and the person turned it off.
        let plan = desk.plan(visible: [two, off], concealed: [one, three])

        try await desk.engine.apply(plan)

        #expect(try desk.flag(one) == false)
        #expect(try desk.flag(three) == false)
        #expect(try desk.flag(two) == true)
        #expect(try desk.flag(off) == false, "the person's own switch isn't turned on")
        #expect(desk.service.writeCount == 1, "every change in one write")
        #expect(try desk.entriesOnDisk().count == 6, "no entry was added or taken out")
        // Nothing else in the file was touched.
        let top = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: desk.file), format: nil) as? [String: Any])
        #expect(top["other"] as? String == "kept")

        // The same plan again changes nothing, and writes nothing.
        try await desk.engine.apply(plan)
        #expect(desk.service.writeCount == 1)

        // `three` is shown again: that is one change.
        try await desk.engine.apply(desk.plan(visible: [two, off, three], concealed: [one]))
        #expect(desk.service.writeCount == 2)
        #expect(try desk.flag(three) == true)
        #expect(try desk.flag(one) == false)
        #expect(try desk.flag(off) == false)
    }

    @Test func aSwitchThePersonTurnedOffIsNotTurnedOn() async throws {
        let desk = try await ApprovalsDesk.make()
        // `off` is visible in the plan, and its switch is off, and nobody but the person did that.
        try await desk.engine.apply(desk.plan(visible: [off, two]))
        #expect(desk.service.writeCount == 0)
        #expect(try desk.flag(off) == false)
        // And one the person turns off while Mantel shows it stays off.
        try await desk.engine.apply(desk.plan(visible: [off, two], concealed: [one]))
        try desk.personSets(two, allowed: false)
        try await desk.engine.apply(desk.plan(visible: [off, two], concealed: [one]))
        #expect(try desk.flag(two) == false)
        #expect(try desk.flag(one) == false)
        #expect(await desk.records().count == 1, "only Mantel's own change is in the journal")
    }

    @Test func eachPathJournaledFirstOriginalWins() async throws {
        let desk = try await ApprovalsDesk.make()
        // What the journal's file holds at the moment of the write: the records come before the change.
        let journalFile = desk.folder.url.appending(path: "Mantel/journal.json")  // MantelPaths.journalFile
        let atTheWrite = Mutex<[JournalEntry]>([])
        desk.service.onWrite {
            struct OnDisk: Decodable { var records: [JournalRecord] }
            let records = (try? Data(contentsOf: journalFile)).flatMap { try? JSONCoding.decoder().decode(OnDisk.self, from: $0) }
            atTheWrite.withLock { $0 = records?.records.map(\.entry) ?? [] }
        }
        let plan = desk.plan(visible: [two], concealed: [one, three])

        try await desk.engine.apply(plan)

        func entry(_ id: String) -> JournalEntry {
            .plistPath(filePath: desk.identity, key: ApprovalsCodec.key, path: ApprovalsCodec.flagPath(for: id), original: .bool(true),
                       strategy: .cfPreferences, codec: ApprovalsCodec.id)
        }
        #expect(atTheWrite.withLock { $0 } == [entry(one), entry(three)], "each path, with its original, was journaled before the list was written")
        #expect(await desk.records().map(\.entry) == [entry(one), entry(three)])
        #expect(await desk.records().map(\.lastWritten) == [.value(.bool(false)), .value(.bool(false))] as [WrittenValue?])
        #expect(await desk.engine.holdsJournalEntries)

        // The person turns `one` on in System Settings, and Mantel hides it again: the original is still the first one, and there is
        // still only one record for it.
        try desk.personSets(one, allowed: true)
        try await desk.engine.apply(desk.plan(visible: [two], concealed: [one, three, "com.example.nothing"]))
        #expect(try desk.flag(one) == false)
        let records = await desk.records()
        #expect(records.map(\.entry) == [entry(one), entry(three)])
    }

    @Test func tearDownUndoesEachPathOnFreshRead() async throws {
        let desk = try await ApprovalsDesk.make()
        try await desk.engine.apply(desk.plan(visible: [two], concealed: [one, three]))
        #expect(await desk.engine.holdsJournalEntries)

        // Meanwhile System Settings writes the whole list again, in another order, and the person turns `two` off.
        try desk.personSets(two, allowed: false)
        let reversedOrder = try desk.entriesOnDisk()
        // What the file holds at each of the writes that undo: which place has been put back by then.
        let states = Mutex<[[Bool?]]>([])
        let probe = desk
        desk.service.onWrite { states.withLock { $0.append([try? probe.flag(one), try? probe.flag(three)]) } }

        await desk.engine.tearDown()

        #expect(try desk.flag(one) == true)
        #expect(try desk.flag(three) == true)
        #expect(try desk.flag(two) == false, "the person's change, which Mantel never made, is left alone")
        #expect(try desk.flag(off) == false)
        let after = try desk.entriesOnDisk()
        #expect(after.count == reversedOrder.count)
        // Every entry is where macOS left it, and the only ones that differ are the two that were put back.
        let changed = zip(reversedOrder, after).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
        #expect(changed.count == 2)
        // Newest first: the last place to be changed is the first to be put back.
        #expect(states.withLock { $0 } == [[false, false], [false, true]], "three, which was recorded last, goes first")
        #expect(await desk.records().isEmpty)
        #expect(await !desk.engine.holdsJournalEntries)
        #expect(await desk.engine.statusNote() == nil)
    }

    @Test func pathAnchoredByBundleIDSurvivesReorder() async throws {
        let desk = try await ApprovalsDesk.make()
        try await desk.engine.apply(desk.plan(visible: [two], concealed: [one]))

        // The list is written again in the opposite order (an index would now point at another app's entry).
        try desk.rewrite(try desk.entriesOnDisk().reversed())
        #expect(try desk.flag(one) == false, "found wherever it is")

        // `three` goes, and `one` is shown again, on the reordered list: each is found by its ID.
        try await desk.engine.apply(desk.plan(visible: [two, one], concealed: [three]))
        #expect(try desk.flag(one) == true)
        #expect(try desk.flag(three) == false)
        #expect(try desk.flag(two) == true)
        let ids = try desk.entriesOnDisk().map { entry in
            ((entry["menuItemLocations"] as? [[String: Any]])?.first?["bundle"] as? [String: Any])?["_0"] as? String ?? "program"
        }
        #expect(ids == ["com.example.pair", "program", "com.example.off", "com.example.three", "com.example.two", "com.example.one"],
                "the order macOS left is the order it is in")
        #expect(await desk.records().count == 1, "the record of `one` went when it was shown again")
    }

    @Test func showingAnAppAgainPutsItsFlagBackAndTakesItsRecordOut() async throws {
        let desk = try await ApprovalsDesk.make()
        try await desk.engine.apply(desk.plan(visible: [two], concealed: [one, three]))
        #expect(await desk.records().count == 2)

        try await desk.engine.apply(desk.plan(visible: [one, two, three]))

        #expect(try desk.flag(one) == true)
        #expect(try desk.flag(three) == true)
        #expect(await desk.records().isEmpty, "nothing is held for an app that shows")
        #expect(await !desk.engine.holdsJournalEntries)
        #expect(desk.service.writeCount == 2, "hiding both was one write, and showing both was one")
    }

    @Test func aSwitchThePersonTurnedOnLetsGoOfTheRecord() async throws {
        let desk = try await ApprovalsDesk.make()
        try await desk.engine.apply(desk.plan(visible: [two], concealed: [one]))
        #expect(await desk.records().count == 1)

        // The person turns `one` on in System Settings while Mantel holds it hidden, and then the plan shows it.
        try desk.personSets(one, allowed: true)
        let writes = desk.service.writeCount
        try await desk.engine.apply(desk.plan(visible: [one, two]))

        #expect(desk.service.writeCount == writes, "there is nothing to write: the switch is on")
        #expect(try desk.flag(one) == true)
        #expect(await desk.records().isEmpty, "and Mantel lets go of the record")
        #expect(await !desk.engine.holdsJournalEntries, "so Replay now isn't refused for good")

        // Later the person turns it off. That is theirs: it is listed, and no plan writes over it.
        try desk.personSets(one, allowed: false)
        #expect(await desk.engine.turnedOff() == .apps([off, one]))
        try await desk.engine.apply(desk.plan(visible: [one, two]))
        #expect(try desk.flag(one) == false)
        #expect(desk.service.writeCount == writes)
    }

    @Test func aRecordIsLetGoOfWhenItsSwitchWasTurnedOnEvenWithOtherChanges() async throws {
        let desk = try await ApprovalsDesk.make()
        try await desk.engine.apply(desk.plan(visible: [two], concealed: [one, three]))
        try desk.personSets(one, allowed: true)

        // One app shows with its switch already on, another is shown again from off, in the one write.
        try await desk.engine.apply(desk.plan(visible: [one, three, two]))

        #expect(try desk.flag(one) == true)
        #expect(try desk.flag(three) == true)
        #expect(await desk.records().isEmpty)
        #expect(desk.service.writeCount == 2)
    }

    @Test func changesForAShowingAppWhoseSwitchIsOnHoldsNoEdit() {
        let entries = [ApprovalsEntry(bundleIDs: ["a"], isAllowed: true), ApprovalsEntry(bundleIDs: ["b"], isAllowed: false)]
        let held = JournalRecord(key: "k", entry: .plistPath(filePath: "/x/group.com.apple.controlcenter.plist", key: ApprovalsCodec.key,
                                                             path: ApprovalsCodec.flagPath(for: "a"), original: .bool(true),
                                                             strategy: .cfPreferences, codec: ApprovalsCodec.id), recordedAt: Date(timeIntervalSince1970: 0))
        let plan = EngineFixtures.plan(visible: ["a", "b"])
        let changes = ApprovalsEngine.changes(for: plan, entries: entries, records: [ApprovalsCodec.flagPath(for: "a"): held])
        #expect(changes.edits.isEmpty, "a is on, and b is off and the person's")
        #expect(changes.shownAgain == [ApprovalsCodec.flagPath(for: "a")])
    }

    @Test func leftoverProbeRecordMakesTheSwitchesUnavailable() async throws {
        let desk = try await ApprovalsDesk.make()
        let text = "A platform test's change to this list hasn't been put back yet. Use Replay now in Settings › Diagnostics."
        #expect(await desk.engine.availability() == .available)

        // A place of this list journaled with another codec (the platform test's).
        try await desk.access.write([PathEdit(path: ApprovalsCodec.flagPath(for: two), value: .bool(false))], key: ApprovalsCodec.key,
                                    in: desk.file, codec: PlistBlobCodecs.nested)
        #expect(await desk.engine.availability() == .broken(text))
        let writes = desk.service.writeCount
        let error = await #expect(throws: HidingError.self) { try await desk.engine.apply(desk.plan(visible: [two], concealed: [one])) }
        #expect(error == .unavailable(.approvals, text))
        #expect(desk.service.writeCount == writes, "nothing was changed with the record in the way")
        // And a controller that has been asked for the switches uses the allowlist instead of them.
        #expect(EngineChoice.decide(EngineChoiceInputs(method: .systemSettingsSwitches, availability: [.allowlist: .available, .approvals: .broken(text), .spacer: .available])).kind == .allowlist)

        // Put back (Replay now), the switches are usable again.
        let restorer = PlistJournalRestorer(access: desk.access, grants: desk.grants)
        #expect(await desk.journal.replay(using: restorer).isEmpty)
        #expect(await desk.engine.availability() == .available)
        try await desk.engine.apply(desk.plan(visible: [two], concealed: [one]))
        #expect(try desk.flag(one) == false)

        // The whole key recorded, which is how a change to all of it is journaled, makes them unavailable too.
        await desk.engine.tearDown()
        try await desk.access.write(.data(try desk.blob()), key: ApprovalsCodec.key, in: desk.file, strategy: .cfPreferences)
        #expect(await desk.records().count == 1)
        #expect(await desk.engine.availability() == .broken(text))
        #expect(await desk.journal.replay(using: restorer).isEmpty)
        #expect(await desk.engine.availability() == .available)
    }

    @Test func appsMissingFromListAreCounted() async throws {
        var entries = ApprovalsDesk.entries
        entries.append(.init("com.example.twice", allowed: true))
        entries.append(.init("com.example.twice", allowed: false))
        let desk = try await ApprovalsDesk.make(entries: entries)
        #expect(await desk.engine.statusNote() == nil)

        // `ghost` has no entry; `twice` has two; `program` is named only by the path of a program, which has no bundle ID to find it by;
        // `pair` shares its entry with `pair.helper`, which is to stay. None of the four can be hidden. `one` can.
        let plan = desk.plan(visible: ["com.example.pair.helper"], concealed: [one, "com.example.ghost", "com.example.twice", "com.example.program", "com.example.pair"])
        try await desk.engine.apply(plan)

        #expect(try desk.flag(one) == false, "the one that can be hidden was")
        #expect(try desk.flag("com.example.pair") == true, "and the one that shares an entry with an app that stays is not")
        #expect(await desk.records().count == 1)
        #expect(await desk.engine.statusNote() == "4 apps with icons can't be hidden with their switches, so they stay visible.")

        // One app, and the singular: no "1 apps".
        try await desk.engine.apply(desk.plan(visible: [two], concealed: [one, "com.example.ghost"]))
        #expect(await desk.engine.statusNote() == "1 app with an icon can't be hidden with its switch, so it stays visible.")
        try await desk.engine.apply(desk.plan(visible: [two], concealed: [one]))
        #expect(await desk.engine.statusNote() == nil)

        // The status the controller shows says so after the reason.
        let controller = HidingController(engines: [.approvals: desk.engine], clock: desk.clock, confirm: { _ in .seen })
        await controller.choose(method: .systemSettingsSwitches)
        await controller.apply(desk.plan(visible: [two], concealed: [one, "com.example.ghost", "com.example.ghost2"]))
        #expect(await controller.status().reason
            == "Chosen in Settings › Advanced. 2 apps with icons can't be hidden with their switches, so they stay visible.")
    }

    /// What the person is told when the preferences service and the file keep disagreeing: nothing of the key it was about.
    private static let notSettledText = "System Settings switches couldn't hide icons: macOS hadn't finished saving its menu bar settings, so nothing was changed. Mantel tries again with the next change."

    /// What the person is told when macOS took a write and didn't keep it: the list by its name in System Settings, and no key.
    private static let notKeptText = "System Settings switches couldn't hide icons: macOS didn't keep the change to its “Allow in the Menu Bar” list. Mantel tries again with the next change."

    @Test func aDisagreementThatStaysIsRetriedOnceAndThenIsNotSettledNotAFailure() async throws {
        // The preferences service says the first app's switch is on while the file says it is off: which is right isn't known. It is
        // tried a second time after a second, and then it is the preferences that haven't caught up, not an engine that failed.
        let sleeps = SleepLog()
        let disagreeing = try await ApprovalsDesk.make(service: ScriptedService(.says(.data(BlobFixtures.approvalsList(ApprovalsDesk.entries)))),
                                                       content: BlobFixtures.approvalsList(Self.entriesWithOneOff), engineClock: sleeps)

        let error = await #expect(throws: HidingError.self) { try await disagreeing.engine.apply(disagreeing.plan(visible: [two], concealed: [one])) }

        let text = "macOS hadn't finished saving its menu bar settings, so nothing was changed. Mantel tries again with the next change."
        #expect(error == .notSettled(.approvals, text))
        #expect(error?.errorDescription == Self.notSettledText)
        #expect(error?.errorDescription?.contains("trackedApplications") == false, "the key's name is for the log, not the person")
        #expect(sleeps.durations == [.seconds(1)], "one second, once")
        #expect(await disagreeing.records().isEmpty)
        #expect(disagreeing.service.writeCount == 0)
    }

    @Test func aWriteMacOSDoesNotKeepIsAFailureAndIsNotRetried() async throws {
        // The service takes the write and the next read of the key is the old value: macOS didn't keep the change. That is the engine's
        // failure, as any other: nothing waits for it to settle, and the controller counts it.
        let sleeps = SleepLog()
        let desk = try await ApprovalsDesk.make(service: ScriptedService(.dropsWrites), engineClock: sleeps)

        let error = await #expect(throws: HidingError.self) { try await desk.engine.apply(desk.plan(visible: [two], concealed: [one])) }

        let isFailure = if case .failed(.approvals, _)? = error { true } else { false }
        #expect(isFailure, "a failure, not `notSettled`: \(String(describing: error))")
        #expect(error?.errorDescription == Self.notKeptText)
        #expect(error?.errorDescription?.contains("trackedApplications") == false, "the key's name is for the log, not the person")
        #expect(error?.errorDescription?.contains("\"") == false, "and the quotes are curly")
        #expect(error?.errorDescription?.hasSuffix("next change.") == true && error?.errorDescription?.hasSuffix("..") == false, "one full stop")
        #expect(sleeps.durations.isEmpty, "no second try: the write was made and read back")
        #expect(desk.service.writeCount == 1)
        #expect(try desk.flag(one) == true, "and the list is as it was")
    }

    @Test func aServiceThatReportsNothingForTheListIsAFailureThatNamesNoKey() {
        // The key is for the log: what the person reads says which list it was by its name in System Settings.
        let text = "System Settings switches couldn't hide icons: macOS reported nothing for its “Allow in the Menu Bar” list. Mantel tries again with the next change."
        let error = ApprovalsEngine.failure(for: .serviceSeesNothing(key: "trackedApplications"))
        #expect(error == .failed(.approvals, ApprovalsEngine.noValueText))
        #expect(error.errorDescription == text)
        #expect(error.errorDescription?.contains("trackedApplications") == false)
        #expect(error.errorDescription?.contains("\"") == false, "the quotes are curly")
        #expect(error.errorDescription?.hasSuffix("next change.") == true && error.errorDescription?.hasSuffix("..") == false, "one full stop")
    }

    @Test func everyOtherWriteErrorKeepsItsOwnWordsAndNamesNoKey() {
        #expect(ApprovalsEngine.failure(for: .notPersisted(key: "trackedApplications")).errorDescription == Self.notKeptText)
        let other = ApprovalsEngine.failure(for: .unreadable("no access"))
        #expect(other == .failed(.approvals, PlistAccessError.unreadable("no access").localizedDescription))
        for error in [PlistAccessError.notRepresentable(key: "trackedApplications"), .disagree(key: "trackedApplications")] {
            #expect(ApprovalsEngine.failure(for: error).errorDescription?.contains("trackedApplications") == false)
        }
    }

    @Test func threeWritesMacOSDoesNotKeepFailTheEngineOut() async throws {
        let log = CallLog()
        let desk = try await ApprovalsDesk.make(service: ScriptedService(.dropsWrites))
        let spacer = FakeEngine(.spacer, log: log)
        let controller = HidingController(engines: [.approvals: desk.engine, .spacer: spacer], clock: desk.clock, confirm: { _ in .seen })
        await controller.choose(method: .systemSettingsSwitches)
        #expect(await controller.status().kind == .approvals)

        // Two plans that macOS doesn't keep: the engine shows everything each time, and is tried again with the next.
        for number in 0..<2 {
            await controller.apply(desk.plan(visible: [two, "com.example.x\(number)"], concealed: [one]))
            #expect(await controller.status().kind == .approvals, "\(number + 1) in a row isn't enough")
            #expect(await controller.status().lastError == Self.notKeptText)
        }
        #expect(spacer.applied.isEmpty)

        // The third: the engine fails out, and the next engine takes over. (Unlike a preferences service that is only behind.)
        await controller.apply(desk.plan(visible: [two, "com.example.x2"], concealed: [one]))
        let status = await controller.status()
        #expect(status.kind == .spacer)
        #expect(status.reason == "System Settings switches can't be used (it failed 3 times in a row; Refresh Menu Bar tries it again), so Mantel uses Wide spacer.")
        #expect(spacer.applied.count == 1, "and it is given the plan")
        #expect(desk.service.writeCount == 3, "each of the three plans was written once")
    }

    private static var entriesWithOneOff: [BlobFixtures.Approval] {
        var entries = ApprovalsDesk.entries
        entries[0] = .init("com.example.one", allowed: false)
        return entries
    }

    @Test func aDisagreementThatClearsIsRetriedOnceAfterASecond() async throws {
        let service = ScriptedService(.says(.data(BlobFixtures.approvalsList(ApprovalsDesk.entries))))
        let sleeps = SleepLog()
        // The second passes, and the preferences service has caught up with the file (where the app's switch is off already).
        sleeps.onSleep { service.follow() }
        let desk = try await ApprovalsDesk.make(service: service, content: BlobFixtures.approvalsList(Self.entriesWithOneOff), engineClock: sleeps)

        try await desk.engine.apply(desk.plan(visible: [two], concealed: [one]))

        #expect(sleeps.durations == [.seconds(1)])
        #expect(try desk.flag(one) == false)
        #expect(await desk.records().isEmpty, "nothing was left to change on the second look")
        // A pass that went well waits for nothing.
        try await desk.engine.apply(desk.plan(visible: [two], concealed: [one]))
        #expect(sleeps.durations.count == 1)
    }

    @Test func preferencesDisagreementDoesNotFailTheEngineOut() async throws {
        let sleeps = SleepLog()
        let desk = try await ApprovalsDesk.make(service: ScriptedService(.says(.data(BlobFixtures.approvalsList(ApprovalsDesk.entries)))),
                                                content: BlobFixtures.approvalsList(Self.entriesWithOneOff), engineClock: sleeps)
        let controller = HidingController(engines: [.approvals: desk.engine], clock: desk.clock, confirm: { _ in .seen })
        await controller.choose(method: .systemSettingsSwitches)

        // Five plans in a row that the preferences service won't take: every one shows everything and retries once, and none is a failure.
        for number in 0..<5 {
            await controller.apply(desk.plan(visible: [two, "com.example.x\(number)"], concealed: [one]))
        }

        #expect(sleeps.durations == Array(repeating: .seconds(1), count: 5))
        let status = await controller.status()
        #expect(status.kind == .approvals, "failing out would have made the choice again without it")
        #expect(status.reason == "Chosen in Settings › Advanced.")
        #expect(status.lastError == Self.notSettledText)
        // Choosing again still gives it: it isn't failed out.
        await controller.choose(method: .systemSettingsSwitches)
        #expect(await controller.status().kind == .approvals)
    }

    // MARK: Writes close together

    @Test func backToBackAppliesPassTheCheckWhileTheFlushIsPending() async throws {
        // The preferences service is ahead of the file: what Mantel writes is what it says, and the file follows later.
        let service = ScriptedService(.aheadOfTheFile)
        let desk = try await ApprovalsDesk.make(service: service)
        let hiding = desk.plan(visible: [two], concealed: [one])
        let showing = desk.plan(visible: [one, two])

        // Run 1: hide it, and the flush of that write reaches the file.
        try await desk.engine.apply(hiding)
        try service.flush(to: desk.file)
        // Run 2: show it again. The put-back is in the service and not yet in the file, and the record of the change is gone.
        try await desk.engine.apply(showing)
        #expect(await desk.records().isEmpty)
        // Run 3, within seconds: hide it once more. The service and the file disagree about it (the file still says hidden), and what
        // the service holds is Mantel's own last write.
        try await desk.engine.apply(hiding)

        let held = try await desk.access.value(at: ApprovalsCodec.flagPath(for: one), key: ApprovalsCodec.key, in: desk.file,
                                               codec: ApprovalsCodec.id)
        #expect(held == .bool(false), "hidden again")
        #expect(await desk.records().count == 1)
        #expect(await desk.engine.holdsJournalEntries)

        // And the person turning it on in System Settings in the meantime is not mistaken for Mantel's own write: the service says
        // on, the file says off (the flush of Mantel's hide), and what Mantel last wrote is off. The write is refused, not forced.
        try service.flush(to: desk.file)
        let cached = try ApprovalsDesk.cachedBlob(of: desk)
        let turnedOn = try ApprovalsCodec().setting(.bool(true), at: ApprovalsCodec.flagPath(for: one), in: cached)
        service.someoneElseWrites(.data(turnedOn), key: ApprovalsCodec.key)
        let error = await #expect(throws: HidingError.self) { try await desk.engine.apply(hiding) }
        #expect(error?.errorDescription == Self.notSettledText, "refused as not settled, never forced")
    }

    // MARK: Apps the person turned off

    @Test func turnedOffExcludesMantelsOwnChanges() async throws {
        let desk = try await ApprovalsDesk.make()
        #expect(await desk.engine.turnedOff() == .apps([off]))

        // Mantel turns `two` and the shared entry off: they are not the person's.
        try await desk.engine.apply(desk.plan(visible: [one], concealed: [two, "com.example.pair"]))
        #expect(try desk.flag(two) == false)
        #expect(try desk.flag("com.example.pair") == false)
        #expect(await desk.engine.turnedOff() == .apps([off]), "an entry Mantel turned off, whichever of its apps it did it by, isn't listed")

        // The person turns one off too: now it is listed, sorted.
        try desk.personSets(one, allowed: false)
        #expect(await desk.engine.turnedOff() == .apps([off, one]))

        // And once Mantel lets go, the person's remain.
        await desk.engine.tearDown()
        #expect(await desk.engine.turnedOff() == .apps([off, one]))
    }

    @Test func turnedOffNamesEveryAppOfAnEntry() async throws {
        let entries: [BlobFixtures.Approval] = [
            .init(allowed: false, locations: [.bundle("com.example.z"), .bundle("com.example.a")]),
            .init(allowed: false, locations: [.program("Example Tools/exampled")]),
            .init("com.example.on", allowed: true),
        ]
        let desk = try await ApprovalsDesk.make(entries: entries)
        #expect(await desk.engine.turnedOff() == .apps(["com.example.a", "com.example.z"]), "sorted; the program has no ID to list")
    }

    @Test func turnedOffSaysWhyItCantBeSaid() async throws {
        let noGrant = try await ApprovalsDesk.make(grantTheFile: false)
        #expect(await noGrant.engine.turnedOff() == .unavailable("Choose the “Allow in the Menu Bar” file in Permissions to see this list."))
        let changed = try await ApprovalsDesk.make(content: Data("not a property list".utf8))
        #expect(await changed.engine.turnedOff() == .unavailable("Mantel can't read this list: macOS changed how it keeps it."))
    }

    // MARK: The journal and the probes

    @Test func holdsJournalEntriesIgnoresTheProbesRecords() async throws {
        let desk = try await ApprovalsDesk.make()
        // The platform test journals its own changes to the same list, with another codec.
        try await desk.access.write([PathEdit(path: ApprovalsCodec.flagPath(for: one), value: .bool(false))], key: ApprovalsCodec.key,
                                    in: desk.file, codec: PlistBlobCodecs.nested)
        #expect(await desk.records().count == 1)
        #expect(await !desk.engine.holdsJournalEntries, "the engine holds nothing")
        await desk.engine.tearDown()
        #expect(await desk.records().count == 1, "and doesn't put back what isn't its own")
        #expect(try desk.flag(one) == false)
    }

    @Test func holdsJournalEntriesFeedsReplayNow() async throws {
        let desk = try await ApprovalsDesk.make()
        func decision() async -> ReplayNowDecision {
            let empty = await desk.journal.records().isEmpty
            return ReplayNowPolicy.decide(journalEmpty: empty, probeChangingMenuBar: false, engineHoldsJournal: await desk.engine.holdsJournalEntries)
        }
        #expect(await decision() == .refused("Nothing is waiting to be put back."))

        // While the engine keeps an app hidden, the journal is its own, and putting it back would unhide the app from under it.
        try await desk.engine.apply(desk.plan(visible: [two], concealed: [one]))
        #expect(await decision() == .refused("The hiding method is using these changes. Use Reset menu bar to undo them."))

        // A change of someone else's in the journal (an old probe's) is Replay now's to put back, while the engine holds nothing.
        await desk.engine.tearDown()
        try await desk.access.write([PathEdit(path: ApprovalsCodec.flagPath(for: two), value: .bool(false))], key: ApprovalsCodec.key,
                                    in: desk.file, codec: PlistBlobCodecs.nested)
        #expect(await decision() == .allowed)
    }

    @Test func aRecordThatCantBePutBackStaysInTheJournal() async throws {
        let desk = try await ApprovalsDesk.make()
        try await desk.engine.apply(desk.plan(visible: [two], concealed: [one]))
        // The file is gone: nothing can be put back, and the record stays for the next launch.
        try FileManager.default.removeItem(at: desk.file)
        await desk.engine.tearDown()
        #expect(await desk.engine.holdsJournalEntries)
    }

    // MARK: The codec

    @Test func codecRoundTripIsByteIdentical() throws {
        let codec = ApprovalsCodec()
        let blob = BlobFixtures.approvalsList(ApprovalsDesk.entries)
        let flag = ApprovalsCodec.flagPath(for: "com.example.one")
        #expect(ApprovalsCodec.id.rawValue == "approvals")
        #expect(flag == [.matchingPath(path: [.key("menuItemLocations"), .anyElement, .key("bundle"), .key("_0")], value: "com.example.one"), .key("isAllowed")])
        #expect(try codec.value(at: flag, in: blob) == .bool(true))

        // Writing a list again isn't promised to give the bytes it had (the real list doesn't, and neither does this one), so what is
        // pinned is this: a change that changes nothing hands back the very bytes that came in, and a change and its undo give the same
        // list.
        #expect(try codec.setting(.bool(true), at: flag, in: blob) == blob)
        // Turned off and on again, it is the same list: every entry, in the order it was in, with nothing added or taken out.
        let off = try codec.setting(.bool(false), at: flag, in: blob)
        #expect(off != blob)
        #expect(try codec.value(at: flag, in: off) == .bool(false))
        let back = try codec.setting(.bool(true), at: flag, in: off)
        func decoded(_ data: Data) throws -> [NSDictionary] {
            try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [NSDictionary])
        }
        #expect(try decoded(back) == decoded(blob))
        #expect(back.starts(with: Data("bplist00".utf8)), "and it is a binary list still")
        // A second turning back changes nothing at all: the bytes of `back` come back as they are.
        #expect(try codec.setting(.bool(true), at: flag, in: back) == back)
        // The registered codec is this one.
        #expect(PlistBlobCodecs.standard[ApprovalsCodec.id] is ApprovalsCodec)
    }

    @Test func aListAnotherWriterMadeIsTheSameListInOtherBytes() throws {
        // Written again, a list from another writer isn't the same bytes; it is the same list, and only the flag differs.
        let xml = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><array><dict><key>menuItemLocations</key><array><dict><key>bundle</key><dict><key>_0</key><string>com.example.one</string></dict></dict></array><key>isAllowed</key><true/></dict><dict><key>isAllowed</key><true/><key>menuItemLocations</key><array><dict><key>bundle</key><dict><key>_0</key><string>com.example.two</string></dict></dict></array></dict></array></plist>
        """.utf8)
        let codec = ApprovalsCodec()
        #expect(try NestedPlistCodec.reencoded(xml) != xml)
        let off = try codec.setting(.bool(false), at: ApprovalsCodec.flagPath(for: "com.example.one"), in: xml)
        func decoded(_ data: Data) throws -> [NSDictionary] {
            try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [NSDictionary])
        }
        let before = try decoded(xml), after = try decoded(off)
        #expect(after.count == before.count)
        #expect(after[1] == before[1], "the other entry is the same")
        #expect(after[0]["isAllowed"] as? Bool == false)
        #expect((after[0]["menuItemLocations"] as? NSArray) == (before[0]["menuItemLocations"] as? NSArray), "and so are the places of this one")
        // Putting it back gives the list that came in, semantically.
        #expect(try decoded(codec.setting(.bool(true), at: ApprovalsCodec.flagPath(for: "com.example.one"), in: off)) == before)
    }

    @Test func entriesAreReadWhateverOrderTheyAreIn() {
        let list: PlistValue = .array([
            .dictionary(["isAllowed": .bool(false), "menuItemLocations": .array([.dictionary(["bundle": .dictionary(["_0": .string("a")])])])]),
            .dictionary(["isAllowed": .bool(true), "menuItemLocations": .array([
                .dictionary(["adhocBinary": .dictionary(["_0": .dictionary(["relative": .string("x")])])]),
                .dictionary(["bundle": .dictionary(["_0": .string("b")])]), .dictionary(["bundle": .dictionary(["_0": .string("c")])]),
            ])]),
            .dictionary(["menuItemLocations": .array([])]),
        ])
        #expect(ApprovalsList.entries(in: list) == [
            ApprovalsEntry(bundleIDs: ["a"], isAllowed: false), ApprovalsEntry(bundleIDs: ["b", "c"], isAllowed: true),
            ApprovalsEntry(bundleIDs: [], isAllowed: nil),
        ])
        #expect(ApprovalsList.entries(in: nil) == nil)
        #expect(ApprovalsList.entries(in: .dictionary([:])) == nil)
        #expect(ApprovalsList.entries(in: .array([.integer(1)])) == nil)
        #expect(ApprovalsList.entries(in: .array([])) == [])
    }
}

/// The person chooses the "Allow in the Menu Bar" file in Permissions while the session runs: the real engine and the real grants (in a
/// folder of the test's own) tell the session, through its two questions, that the file can be used now.
@Suite("Session: choosing the Allow in the Menu Bar file", .timeLimit(.minutes(1)))
struct SessionFileGrantTests {
    @Test func grantingTheFileClearsTheReasonAndTheTurnedOffListAfterPermissionsChanged() async throws {
        let desk = try await ApprovalsDesk.make(grantTheFile: false)
        let log = CallLog()
        let rig = SessionRig.withEngines(
            [.allowlist: FakeEngine(.allowlist, log: log), .approvals: desk.engine, .spacer: FakeEngine(.spacer, log: log)], events: log)
        rig.turnedOff.follow { [engine = desk.engine] in await engine.turnedOff() }
        await rig.session.start()

        let before = try #require(await rig.state)
        #expect(before.engine.unavailableReasons[.approvals] == "Choose the “Allow in the Menu Bar” file in Settings › Permissions")
        #expect(before.lists.turnedOff == .unavailable(ApprovalsEngine.turnedOffNeedsFile))

        // The file is chosen in Permissions: nothing is said to the session until it is told.
        _ = try await desk.grants.grant(.controlCenterApprovals, chosen: desk.file, home: desk.home)
        #expect(try #require(await rig.state).engine.unavailableReasons[.approvals] != nil, "not yet")

        await rig.session.permissionsChanged()

        let after = try #require(await rig.state)
        #expect(after.engine.unavailableReasons[.approvals] == nil)
        #expect(after.engine.availability[.approvals] == "available")
        #expect(after.lists.turnedOff == .apps(["com.example.off"]))
    }
}

extension ApprovalsDesk {
    /// The list the preferences service holds now (not the file's).
    fileprivate static func cachedBlob(of desk: ApprovalsDesk) throws -> Data {
        guard case .data(let blob)? = try desk.service.io.read(desk.file, ApprovalsCodec.key, .cfPreferences) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return blob
    }
}
