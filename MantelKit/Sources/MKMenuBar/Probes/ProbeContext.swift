import CoreGraphics
import Foundation
import MKCommands
import MKCore

/// What a probe writes down as it goes: its measurements, notes and errors, and whether what it changed is back.
struct ProbeRecorder {
    private(set) var measurements: [String: JSONValue] = [:]
    private(set) var notes: [String] = []
    private(set) var errors: [String] = []
    /// Changes made and not yet undone.
    private var outstanding = 0
    private var undoFailed = false

    mutating func measure(_ key: String, _ value: JSONValue) {
        measurements[key] = value
    }

    mutating func measure(_ key: String, _ number: Double) {
        measurements[key] = .number(number)
    }

    mutating func measure(_ key: String, _ number: Int) {
        measurements[key] = .number(Double(number))
    }

    mutating func measure(_ key: String, _ flag: Bool) {
        measurements[key] = .bool(flag)
    }

    mutating func measure(_ key: String, _ text: String) {
        measurements[key] = .string(text)
    }

    mutating func measure(_ key: String, strings: [String]) {
        measurements[key] = .array(strings.map(JSONValue.string))
    }

    /// What the polls that watched for a latency say about themselves, under `<latency>Poll` (`writeToVisibleChange` gives
    /// `writeToVisibleChangePoll`, beside `writeToVisibleChangeMs`): see `PollTrace`.
    mutating func measure(poll latency: String, _ trace: PollTrace) {
        measurements["\(latency)Poll"] = trace.json
    }

    mutating func note(_ text: String) {
        notes.append(text)
    }

    mutating func fail(_ text: String) {
        errors.append(text)
    }

    /// The probe is about to change something (it journals first, where the change is a file's).
    mutating func changeBegan() {
        outstanding += 1
    }

    /// What `changeBegan` announced has been undone.
    mutating func changeUndone() {
        outstanding = max(0, outstanding - 1)
    }

    /// What `changeBegan` announced couldn't be undone: it is in the errors, and the report says it isn't restored. For a
    /// change made to a file, the journal still holds it, and the next launch puts it back.
    mutating func undoFailed(_ text: String) {
        outstanding = max(0, outstanding - 1)
        undoFailed = true
        errors.append(text)
    }

    /// True when nothing was changed, or everything that was is back.
    var restored: Bool {
        outstanding == 0 && !undoFailed
    }
}

/// How a poll that found what it was waiting for came out: when the poll that saw it ended (as milliseconds from the trigger),
/// and the snapshot that showed it.
struct PollHit {
    let elapsedMs: Double
    let snapshot: MenuBarSnapshot
}

/// A poll's result: what it found, if it found anything, and what it can say about its own timing either way.
struct PollOutcome {
    let hit: PollHit?
    let trace: PollTrace
}

/// What a poll says about itself, all in milliseconds from the trigger (the moment the probe changed something): when the
/// poll that saw the change began and ended, when the poll before it ended, and what a read of the menu bar cost. A latency then
/// reads as "between A and B": the change was not there when the previous poll had looked, and was there when this one ended.
///
/// A poll that never saw what it was waiting for has no bounds, and still has the cost of its reads.
struct PollTrace: Sendable, Equatable {
    /// nil when the poll that saw it was the first, and when nothing was seen.
    let previousPollEndedMs: Double?
    let hitPollStartedMs: Double?
    let hitPollEndedMs: Double?
    /// How long a read of the menu bar took across the polls, the median (the mean of the middle two when there is an even
    /// number of them) and the longest.
    let pollSnapshotMsMedian: Double
    let pollSnapshotMsMax: Double
    let polls: Int

    var json: JSONValue {
        func number(_ value: Double?) -> JSONValue { value.map(JSONValue.number) ?? .null }
        return .object([
            "previousPollEndedMs": number(previousPollEndedMs), "hitPollStartedMs": number(hitPollStartedMs),
            "hitPollEndedMs": number(hitPollEndedMs), "pollSnapshotMsMedian": .number(pollSnapshotMsMedian),
            "pollSnapshotMsMax": .number(pollSnapshotMsMax), "polls": .number(Double(polls)),
        ])
    }
}

/// Keeps what each poll of a run took, and says what the poll that saw the change looked like.
struct PollTracker: Sendable {
    /// Where a poll that is the hit stood: its own start and end, and the end of the one before.
    struct Bounds: Sendable, Equatable {
        let previousEndedMs: Double?
        let startedMs: Double
        let endedMs: Double
    }

    private var durations: [Double] = []
    private var lastEndedMs: Double?

    /// Notes a poll that began and ended at these times, and gives its bounds (which are the hit's, if it is the hit).
    mutating func record(startedMs: Double, endedMs: Double) -> Bounds {
        let bounds = Bounds(previousEndedMs: lastEndedMs, startedMs: startedMs, endedMs: endedMs)
        durations.append(endedMs - startedMs)
        lastEndedMs = endedMs
        return bounds
    }

    /// The trace as of now, with the bounds of the hit, or without when nothing was seen. A tracker is a value, so a trace
    /// taken at the hit stays as it was when polling goes on.
    func trace(hit: Bounds?) -> PollTrace {
        let sorted = durations.sorted()
        let middle = sorted.count / 2
        let median = sorted.isEmpty ? 0 : (sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle])
        return PollTrace(previousPollEndedMs: hit?.previousEndedMs, hitPollStartedMs: hit?.startedMs, hitPollEndedMs: hit?.endedMs,
                         pollSnapshotMsMedian: median, pollSnapshotMsMax: sorted.last ?? 0, polls: durations.count)
    }
}

/// What a running probe has to work with.
struct ProbeContext: Sendable {
    let paths: MantelPaths
    let reader: MenuBarReader
    let plist: PlistFileAccess
    let grants: FileGrantStore
    let layoutProvider: @Sendable () async -> DisplayLayout
    let clock: any Clock
    let platform: ProbePlatform
    let options: ProbeOptions
    let store: ProbeReportStore
    let startedAt: Date

    /// The test item's bundle ID: Mantel's own with `.testitem` after it.
    var fixtureBundleID: String {
        platform.ownBundleID + ProbeSafety.fixtureBundleIDSuffix
    }

    /// The autosave names of the test item's two status items.
    static let fixtureItemNames = ["mantel.fixture.one", "mantel.fixture.two"]

    /// The test item's layout keys, as the layout table names them: `status:<bundle ID>::<autosave name>`.
    var fixtureLayoutKeys: [String] {
        Self.fixtureItemNames.map { "status:\(fixtureBundleID)::\($0)" }
    }

    /// The whole menu bar, every app's items too: for the records a probe keeps of how it was before and after.
    func snapshot(includeRawTree: Bool = false) async -> MenuBarSnapshot {
        await reader.snapshot(layout: await layoutProvider(), includeRawTree: includeRawTree)
    }

    /// MenuBarAgent's windows and slots alone, which is all that change detection looks at, and much cheaper to read.
    func agentSnapshot() async -> MenuBarSnapshot {
        await reader.agentSnapshot(layout: await layoutProvider())
    }

    func milliseconds(since start: Date) -> Double {
        clock.now().timeIntervalSince(start) * 1000
    }

    /// Reads the agent's slots every `intervalMs` until `condition` holds of one, or `timeoutMs` have passed since `start`. The
    /// outcome has the hit, nil when it never held, and the trace of the polls, which says when the poll that saw it began and
    /// ended. Throws when the probe is cancelled.
    func poll(every intervalMs: Int, upTo timeoutMs: Int, from start: Date,
              until condition: @Sendable (MenuBarSnapshot) -> Bool) async throws -> PollOutcome {
        let deadline = start.addingTimeInterval(Double(timeoutMs) / 1000)
        var tracker = PollTracker()
        while true {
            try Task.checkCancellation()
            let startedMs = milliseconds(since: start)
            let snapshot = await agentSnapshot()
            let endedMs = milliseconds(since: start)
            let bounds = tracker.record(startedMs: startedMs, endedMs: endedMs)
            if condition(snapshot) {
                return PollOutcome(hit: PollHit(elapsedMs: endedMs, snapshot: snapshot), trace: tracker.trace(hit: bounds))
            }
            if clock.now() >= deadline { return PollOutcome(hit: nil, trace: tracker.trace(hit: nil)) }
            try await clock.sleep(for: .milliseconds(intervalMs))
        }
    }

    /// A slot macOS is drawing (one with a frame) on a display's chosen window, and what tells it from the others between reads.
    private struct KeyedSlot {
        /// `<display UUID>|<name>`. The name is the ID of a system item (`system:clock`), else the slot's identifier, else (for a slot
        /// that has none) its width and its rank among the slots of that width that have none, counted from the right
        /// (`@w<width>#<rank>`). None of them depends on the order Accessibility lists the slots or the windows in, or on which of a
        /// display's windows is read; and none moves when the clock's text gets a point wider, as a place measured from the left or
        /// the right would.
        let key: String
        let ownerPID: pid_t?
        let frame: CGRect
        /// The display's place among the chosen windows.
        let display: Int
    }

    /// The framed slots of the window chosen for each display (`AgentWindowChooser`), and not the «, which isn't an item.
    ///
    /// A window of a display sometimes lacks the identifiers the others have, and they all have their slots in the same places, so a
    /// slot without one takes the identifier another window has for the same place.
    private static func keyedSlots(_ snapshot: MenuBarSnapshot) -> [KeyedSlot] {
        var keyed: [KeyedSlot] = []
        for (display, window) in snapshot.chosenWindows().enumerated() {
            var namesByPlace: [String: String] = [:]
            for other in snapshot.agentWindows where other.frame == window.frame {
                for slot in other.slots {
                    if let name = slot.identifier, !name.isEmpty, let frame = slot.frame { namesByPlace[place(frame)] = name }
                }
            }
            var unnamed: [(slot: AgentSlot, frame: CGRect)] = []
            for slot in snapshot.agentWindows[window.index].slots where !OverflowDetector.isChevron(slot) {
                guard let frame = slot.frame, !frame.isEmpty else { continue }
                let name: String
                if let identifier = slot.identifier, let module = ItemID.systemModule(ofIdentifier: identifier) {
                    name = ItemID.system(module).string
                } else if let identifier = slot.identifier ?? namesByPlace[place(frame)], !identifier.isEmpty {
                    name = ItemID.systemModule(ofIdentifier: identifier).map { ItemID.system($0).string } ?? identifier
                } else {
                    unnamed.append((slot, frame))
                    continue
                }
                keyed.append(KeyedSlot(key: "\(window.displayUUID)|\(name)", ownerPID: slot.ownerPID, frame: frame, display: display))
            }
            // The ones with no name: by width, and by how many of the same width are to their right.
            var rightOf: [Int: Int] = [:]
            for (slot, frame) in unnamed.sorted(by: { ($0.frame.maxX, $0.frame.minX) > ($1.frame.maxX, $1.frame.minX) }) {
                let width = Int((frame.width * 2).rounded())
                let rank = rightOf[width, default: 0]
                rightOf[width] = rank + 1
                keyed.append(KeyedSlot(key: "\(window.displayUUID)|@w\(width)#\(rank)", ownerPID: slot.ownerPID, frame: frame, display: display))
            }
        }
        return keyed
    }

    /// A slot's place, to half a point: its x and its width.
    private static func place(_ frame: CGRect) -> String {
        "\(Int((frame.minX * 2).rounded())),\(Int((frame.width * 2).rounded()))"
    }

    /// The slots macOS is drawing, each named by its display and what it is (see `KeyedSlot`): what "a visible change" is measured
    /// on.
    static func framedKeys(_ snapshot: MenuBarSnapshot) -> Set<String> {
        Set(keyedSlots(snapshot).map(\.key))
    }

    /// The items the menu bar shows, by the text of their `ItemID`: the matcher's answer, for a snapshot that has the apps' own
    /// lists of items too. A snapshot of the agent alone can't say which app a slot is.
    static func shownItems(_ snapshot: MenuBarSnapshot, ownBundleID: String) -> Set<String> {
        var memory = IndexMemory()
        let inventory = InventoryMatcher.match(snapshot.matchInput(ownBundleID: ownBundleID), memory: &memory)
        return Set(inventory.items.filter { !$0.isConcealed }.map(\.id.string))
    }

    /// Whether the menu bar is as it was after a probe's hold: every slot that was framed before is framed again. A slot that is there
    /// now and wasn't is an app that launched during the hold, and one whose owner (as it was told before) is no longer running quit
    /// during it: neither is a failure to restore.
    static func isRestored(before: MenuBarSnapshot, now: MenuBarSnapshot, running: [RunningApp]) -> Bool {
        let stillRunning = Set(running.map(\.pid))
        let framedNow = framedKeys(now)
        for slot in keyedSlots(before) {
            if let owner = slot.ownerPID, !stillRunning.contains(owner) { continue }
            if !framedNow.contains(slot.key) { return false }
        }
        return true
    }

    /// Where each framed slot is, by the same names: position and size to a tenth of a point. A slot macOS keeps drawing at
    /// a stale frame after hiding its item doesn't leave `framedKeys`, but the items that move up to fill its place change
    /// theirs.
    static func framedFrames(_ snapshot: MenuBarSnapshot) -> [String: String] {
        var frames: [String: String] = [:]
        for slot in keyedSlots(snapshot) {
            frames[slot.key] = String(format: "%.1f,%.1f,%.1f,%.1f", slot.frame.minX, slot.frame.minY, slot.frame.width, slot.frame.height)
        }
        return frames
    }

    /// The framed slots, left to right on each display, by the same names: the order the menu bar is in.
    static func framedOrder(_ snapshot: MenuBarSnapshot) -> [String] {
        keyedSlots(snapshot).sorted { ($0.display, $0.frame.minX, $0.key) < ($1.display, $1.frame.minX, $1.key) }.map(\.key)
    }
}
