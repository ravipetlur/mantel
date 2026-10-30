import CoreGraphics
import Foundation
import MKCore
import MKLayout
import MKTestSupport
import Synchronization

@testable import MKMenuBar

/// A writer that does nothing to any file: what it is told, and what it answers, are the test's.
final class FakeLayoutWriter: LayoutTableWriting {
    private struct State {
        var availability: LayoutWriterAvailability = .available
        var table = LayoutTableSnapshot(distances: [:])
        var writeError: LayoutWriteError?
        var readError: LayoutWriteError?
        /// What each write answers, in turn; the number of keys when it runs out.
        var writeAnswers: [Int] = []
        var writes: [(arrangement: LayoutArrangement, keys: [LayoutToken: String])] = []
        var restoreAnswer = 3
        var restoreError: LayoutWriteError?
        var restores = 0
        var hasKept = false
        var events: [String] = []
        /// What the writer says it is once a write or a read has thrown (a grant that went stale in the middle of it).
        var availabilityAfterAnError: LayoutWriterAvailability?
        /// Like the real writer: only the keys whose distance isn't the table's (within 0.25) are written, and the table takes them.
        var writesOnlyChanges = false
        /// The table as macOS has it after each write, in turn (it re-sorts and rewrites it).
        var tablesAfterWrites: [LayoutTableSnapshot] = []
        /// A write waits here before it answers.
        var writeGate: Gate?
        /// A read of the table waits here before it answers.
        var readGate: Gate?
        var readsHeld = 0
    }

    private let state = Mutex(State())

    var availabilityNow: LayoutWriterAvailability {
        get { state.withLock { $0.availability } }
        set { state.withLock { $0.availability = newValue } }
    }
    var table: LayoutTableSnapshot {
        get { state.withLock { $0.table } }
        set { state.withLock { $0.table = newValue } }
    }
    var writeError: LayoutWriteError? {
        get { state.withLock { $0.writeError } }
        set { state.withLock { $0.writeError = newValue } }
    }
    var readError: LayoutWriteError? {
        get { state.withLock { $0.readError } }
        set { state.withLock { $0.readError = newValue } }
    }
    var availabilityAfterAnError: LayoutWriterAvailability? {
        get { state.withLock { $0.availabilityAfterAnError } }
        set { state.withLock { $0.availabilityAfterAnError = newValue } }
    }
    var writesOnlyChanges: Bool {
        get { state.withLock { $0.writesOnlyChanges } }
        set { state.withLock { $0.writesOnlyChanges = newValue } }
    }
    func holdWrites(at gate: Gate?) { state.withLock { $0.writeGate = gate } }
    func holdReads(at gate: Gate?) { state.withLock { $0.readGate = gate } }
    /// How many reads of the table have reached the gate.
    var readsHeld: Int { state.withLock { $0.readsHeld } }
    func tablesAfterWrites(_ tables: [LayoutTableSnapshot]) { state.withLock { $0.tablesAfterWrites = tables } }
    var restoreAnswer: Int {
        get { state.withLock { $0.restoreAnswer } }
        set { state.withLock { $0.restoreAnswer = newValue } }
    }
    var restoreError: LayoutWriteError? {
        get { state.withLock { $0.restoreError } }
        set { state.withLock { $0.restoreError = newValue } }
    }
    var kept: Bool {
        get { state.withLock { $0.hasKept } }
        set { state.withLock { $0.hasKept = newValue } }
    }
    func answerWrites(_ answers: [Int]) { state.withLock { $0.writeAnswers = answers } }
    var writes: [(arrangement: LayoutArrangement, keys: [LayoutToken: String])] { state.withLock { $0.writes } }
    var writeCount: Int { state.withLock { $0.writes.count } }
    var restoreCount: Int { state.withLock { $0.restores } }
    /// What happened, in order: `write`, `restore`, and whatever the test notes.
    var events: [String] { state.withLock { $0.events.filter { $0 != "read" } } }
    /// The same, with each read of the bar (`read`) in its place among them.
    var eventsWithReads: [String] { state.withLock { $0.events } }
    func note(_ event: String) { state.withLock { $0.events.append(event) } }

    func availability() async -> LayoutWriterAvailability { state.withLock { $0.availability } }

    func readTable() async throws(LayoutWriteError) -> LayoutTableSnapshot {
        let held = state.withLock { state -> Gate? in
            if state.readGate != nil { state.readsHeld += 1 }
            return state.readGate
        }
        await held?.wait()
        let (table, error) = state.withLock { state -> (LayoutTableSnapshot, LayoutWriteError?) in
            if state.readError != nil, let after = state.availabilityAfterAnError { state.availability = after }
            return (state.table, state.readError)
        }
        if let error { throw error }
        return table
    }

    func write(_ arrangement: LayoutArrangement, keys: [LayoutToken: String]) async throws(LayoutWriteError) -> [String] {
        let gate = state.withLock { state -> Gate? in
            state.writes.append((arrangement, keys))
            return state.writeGate
        }
        await gate?.wait()
        let (error, answer) = state.withLock { state -> (LayoutWriteError?, [String]) in
            state.events.append("write")
            if state.writeError != nil, let after = state.availabilityAfterAnError { state.availability = after }
            var all = arrangement.tokens.compactMap { token in keys[token].map { (key: $0, distance: arrangement.distances[token]) } }
            if state.writesOnlyChanges {
                all = all.filter { entry in
                    guard let distance = entry.distance, let current = state.table.distances[entry.key] else { return true }
                    return abs(current - distance) > 0.25
                }
            }
            let count = state.writeAnswers.isEmpty ? all.count : state.writeAnswers.removeFirst()
            if !state.tablesAfterWrites.isEmpty { state.table = state.tablesAfterWrites.removeFirst() }
            return (state.writeError, Array(all.prefix(count).map(\.key)))
        }
        if let error { throw error }
        return answer
    }

    func restoreOriginalLayout() async throws(LayoutWriteError) -> Int {
        let (error, answer) = state.withLock { state -> (LayoutWriteError?, Int) in
            state.restores += 1
            state.events.append("restore")
            return (state.restoreError, state.restoreAnswer)
        }
        if let error { throw error }
        state.withLock { $0.hasKept = false }
        return answer
    }

    var hasKeptChanges: Bool { get async { state.withLock { $0.hasKept } } }
}

/// What the applier told the session about its phase, in order.
final class PhaseLog: Sendable {
    private let log = Mutex<[String]>([])
    private let phases = Mutex<[(pending: Bool, settling: Bool)]>([])
    private let revisions = Mutex<[Int]>([])

    func add(_ pending: Bool, _ settling: Bool, _ revision: Int = 0) {
        phases.withLock { $0.append((pending, settling)) }
        revisions.withLock { $0.append(revision) }
        log.withLock { $0.append("phase(\(pending),\(settling))") }
    }

    var all: [String] { log.withLock { $0 } }
    var last: (pending: Bool, settling: Bool)? { phases.withLock { $0.last } }
    var count: Int { phases.withLock { $0.count } }
    /// The revision each phase call carried, in order.
    var allRevisions: [Int] { revisions.withLock { $0 } }
}

/// What `read` answers: a script of inventories, the last one repeated; nil answers nothing. Each read carries the concealed set scripted
/// for it (the last one repeated; none by default).
final class ReadScript: Sendable {
    private let state = Mutex<(answers: [Inventory?], concealed: [Set<String>], reads: Int)>(([], [], 0))

    var reads: Int { state.withLock { $0.reads } }
    func answer(_ answers: [Inventory?], concealed: [Set<String>] = []) {
        state.withLock {
            $0.answers = answers
            $0.concealed = concealed
        }
    }

    func next() -> CheckRead? {
        state.withLock { state in
            let index = min(state.reads, max(state.answers.count - 1, 0))
            state.reads += 1
            guard !state.answers.isEmpty, let inventory = state.answers[index] else { return nil }
            let set = state.concealed.isEmpty ? [] : state.concealed[min(index, state.concealed.count - 1)]
            return CheckRead(inventory, concealedApps: set)
        }
    }
}

/// Why writes are held, when they are (`LayoutApplier`'s `held`).
final class HeldBox: Sendable {
    private let reason = Mutex<String?>(nil)
    func set(_ text: String?) { reason.withLock { $0 = text } }
    var current: String? { reason.withLock { $0 } }
}

/// Inventories and sections for the tests of the layout writer: the app items are the test's own (`com.example.*`).
enum LayoutFixtures {
    static let own = "com.example.mantel"
    static let display = "display-1"
    static let bar = MenuBarGeometry(displayUUID: display, rect: CGRect(x: 0, y: 0, width: 1000, height: 24), notch: nil)

    static func named(_ app: String, _ name: String = "main") -> ItemID {
        ItemID(bundleID: "com.example.\(app)", key: .identifier(name))
    }

    static func nameless(_ app: String, _ index: Int = 0) -> ItemID {
        ItemID(bundleID: "com.example.\(app)", key: .index(index))
    }

    static func key(_ id: ItemID) -> String {
        guard case .identifier(let name) = id.key else { return "" }
        return LayoutKey.status(bundleID: id.bundleID, autosaveName: name)
    }

    static func ownKey(_ name: String) -> String {
        LayoutKey.status(bundleID: own, autosaveName: name)
    }

    static func appItem(_ id: ItemID, x: CGFloat?, width: CGFloat = 30) -> MenuBarItem {
        MenuBarItem(id: id, ownerBundleID: id.bundleID, appName: nil, label: nil,
                    frames: x.map { [display: CGRect(x: $0, y: 0, width: width, height: 24)] } ?? [:], overflowedOn: [], isMantel: false)
    }

    static func ownItem(_ kind: OwnItemKind, x: CGFloat?) -> MenuBarItem {
        let name: String = switch kind {
        case .hiddenDot: OwnItems.hiddenDotName
        case .alwaysDot: OwnItems.alwaysDotName
        case .divider: OwnItems.dividerName
        case .spacer: "mantel.spacer.0000abcd"
        case .group: "mantel.group.0000abcd"
        }
        return MenuBarItem(id: ItemID(bundleID: own, key: .identifier(name)), ownerBundleID: own, appName: nil, label: nil,
                           frames: x.map { [display: CGRect(x: $0, y: 0, width: 12, height: 24)] } ?? [:], overflowedOn: [], isMantel: true,
                           ownKind: kind)
    }

    static func systemItem(_ module: String, x: CGFloat) -> MenuBarItem {
        MenuBarItem(id: .system(module), ownerBundleID: ItemID.systemBundleID, appName: nil, label: nil,
                    frames: [display: CGRect(x: x, y: 0, width: 30, height: 24)], overflowedOn: [], isMantel: false)
    }

    /// A read of the bar with these items, which a write can be planned from: it has a bar and draws a system module (Wi‑Fi at the right
    /// end, unless the items have one), and the apps that have an item are the running ones.
    static func inventory(_ items: [MenuBarItem], running: Set<String>? = nil) -> Inventory {
        let drawn = withFloor(items)
        return Inventory(capturedAt: Date(timeIntervalSince1970: 1_700_000_000), bars: [bar], items: drawn, chevrons: [:], reach: [],
                         problems: [], runningApps: running ?? Set(drawn.map(\.ownerBundleID)))
    }

    /// An inventory whose slots are the frames the items have, left to right (what the matcher's tie leaves).
    static func slotted(_ items: [MenuBarItem]) -> Inventory {
        let drawn = withFloor(items)
        let slots = drawn.compactMap { $0.frames[display] }.sorted { $0.minX < $1.minX }.map { BarSlot(frame: $0, name: nil) }
        return Inventory(capturedAt: Date(timeIntervalSince1970: 1_700_000_000), bars: [bar], items: drawn, chevrons: [:], reach: [],
                         problems: [], barSlots: [display: slots], runningApps: Set(drawn.map(\.ownerBundleID)))
    }

    /// The items, with a system module at the right end when none is among them: what a write is planned from. It is Wi‑Fi, which the
    /// tables here have no key for, so it gives no floor: the tests that want one draw the clock or another module the table has.
    private static func withFloor(_ items: [MenuBarItem]) -> [MenuBarItem] {
        items.contains { $0.id.isSystem } ? items : items + [systemItem("wifi", x: 960)]
    }

    /// The three own tokens drawn left to right as the arrangement has them (••, •, the divider), or in another order.
    static func ownDrawn(_ order: [OwnItemKind] = [.alwaysDot, .hiddenDot, .divider]) -> Inventory {
        inventory(order.enumerated().map { ownItem($1, x: CGFloat(100 + 100 * $0)) })
    }

    /// Sections with these items in the lists, their apps placed there.
    static func sections(always: [ItemID] = [], hidden: [ItemID] = [], shown: [ItemID] = []) -> SectionModel {
        var model = SectionModel()
        for (section, items) in [(MenuBarSection.alwaysHidden, always), (.hidden, hidden), (.shown, shown)] where !items.isEmpty {
            model.order[section] = items
            for item in items where !item.isSystem && !OwnItems.isOwn(item) {
                model.apps[item.bundleID] = AppPlacement(section: section, isAuto: false)
            }
        }
        return model
    }

    static func inputs(_ sections: SectionModel = SectionModel(), divider: Bool = true, widths: [ItemID: CGFloat] = [:]) -> LayoutInputs {
        LayoutInputs(sections: sections, placement: .betweenSections, alwaysDotShown: true, dotsShown: true, dividerShown: divider,
                     widths: widths)
    }

    /// The measured rules, with a verification wait of one second: a test drives the clock through it in a few steps.
    static func rules(_ keyMatch: KeyMatchRule = .identifiersOnly, wait: Duration = .seconds(1)) -> LayoutRules {
        var rules = LayoutRules.measured
        rules.keyMatch = keyMatch
        rules.verificationWait = wait
        return rules
    }
}
