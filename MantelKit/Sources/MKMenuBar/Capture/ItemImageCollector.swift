import CoreGraphics
import Foundation
import MKCore
import Synchronization

/// What the check of a strip answers (`ItemImageCollector.capture`'s `isCurrent`).
public struct StillCurrentAnswer: Sendable, Equatable {
    /// The apps whose pictures may be kept.
    public var kept: Set<String>
    /// Whether the apps that weren't kept are so for want of time and not because the bar, or an app's own frames, differed.
    public var outOfTime: Bool
    /// What was found out of place, in words for the log (which slots moved and by how much, what appeared or went, which app's frames
    /// are elsewhere, what Mantel changed), and, when the check ran out of time, how far it got.
    public var changes: [String]

    public init(kept: Set<String>, outOfTime: Bool = false, changes: [String] = []) {
        self.kept = kept
        self.outOfTime = outOfTime
        self.changes = changes
    }
}

/// Takes the pictures of the icons the menu bar draws, and gives them to the store.
///
/// Only slots are cropped: an item's slot on a bar that is shown, where the item is not overflowed, is not Mantel's own and is not one of
/// the apps the plan in force conceals. An item's own reported frame is never used.
public actor ItemImageCollector {
    private let store: ItemImageStore
    private let capture: any StripCapturing
    private let layout: @Sendable () -> DisplayLayout
    private let windows: any WindowListReading
    private let screenRecordingGranted: @Sendable () -> Bool
    private let mayCapture: @Sendable () async -> String?
    private let clock: any Clock
    /// The rules the collector goes by: the session reads the launch budget and the quiet period from them.
    public let rules: CaptureRules

    private var lastBarCapture: [String: Date] = [:]
    private var lastAppearance: [String: BarAppearance] = [:]
    /// When pictures were last saved.
    public private(set) var lastCaptureAt: Date?
    /// When a strip of a bar was last taken, saved from or not: what the recording indicator can appear for.
    public private(set) var lastStripAt: Date?

    /// `mayCapture` is asked first at every moment: an answer is the reason to skip.
    public init(store: ItemImageStore, capture: any StripCapturing, layout: @escaping @Sendable () -> DisplayLayout,
                windows: any WindowListReading, screenRecordingGranted: @escaping @Sendable () -> Bool,
                mayCapture: @escaping @Sendable () async -> String? = { nil },
                clock: any Clock, rules: CaptureRules) {
        self.store = store
        self.capture = capture
        self.layout = layout
        self.windows = windows
        self.screenRecordingGranted = screenRecordingGranted
        self.mayCapture = mayCapture
        self.clock = clock
        self.rules = rules
    }

    /// Drops the pictures of index-keyed items whose app's item count is no longer the one they were taken at, and those of the records a check
    /// of an app's saved icons took out (`ItemImageStore.reconcile`).
    /// The session asks before it captures.
    public func reconcile(with inventory: Inventory, droppedRecords: Set<ItemID> = []) async {
        do { try await store.reconcile(with: inventory, droppedRecords: droppedRecords) } catch { Log.warning("capture", "the pictures couldn't be reconciled") }
    }

    /// `concealed`: the apps the plan in force conceals; they are never cropped.
    ///
    /// A picture is only kept when the strip was taken while the read was true of the bar, so that no picture is saved under an item
    /// that isn't the one in it; when that can't be told, nothing is saved:
    /// - `deadline`: the moment the caller goes on to change the bar. A strip that comes back after it is not cropped.
    /// - `isCurrent`: asked, with the bar's display and the apps whose icons would be cropped, when its strip is back and before anything
    ///   is cropped; it answers the apps whose pictures may be kept, none when the bar is not known to be as it was when the read was
    ///   taken, whether the apps that weren't kept are so because the check ran out of time (said so) and not because the bar differed,
    ///   and what differed (`StillCurrentAnswer`), which the log says.
    ///   The caller looks at the bar once more, compares its slots with the read's, and asks the apps for their frames again.
    ///
    /// Only one bar is captured when the read has more than one: the active display's, or the main display's when the read can't tell
    /// which is active (a display that isn't active draws its icons translucent, and two bars' pictures of an item would replace each
    /// other). A `clickDrawn` moment is of the bar the click was on, whichever that is, and of the one slot the click's location gives:
    /// only when the read has that same slot for the item (the location and the read are of moments of their own), else nothing is cropped.
    public func capture(_ moment: CaptureMoment, read: Inventory, concealed: Set<String>, deadline: Date? = nil,
                        isCurrent: (@Sendable (_ display: String, _ apps: Set<String>) async -> StillCurrentAnswer)? = nil) async -> CaptureSummary {
        if let reason = await mayCapture() { return Self.skipped(reason) }
        guard rules.moments.contains(moment.kind) else { return Self.skipped(SkipReason.momentOff.text) }
        guard screenRecordingGranted() else { return Self.skipped(SkipReason.screenRecordingOff.text) }

        let started = clock.now()
        let displays = layout().displays
        let shown = BarVisibility.shownBars(windows.onScreenWindows(), bars: read.bars)
        var captured = 0, changed = 0
        var reasons: Set<SkipReason> = []
        // What the check kept out, for the log.
        var notKept: [NotKept] = []

        let chosenBars = barsToCapture(for: moment, in: read, displays: displays)
        for bar in chosenBars {
            guard shown.contains(bar.displayUUID), let display = displays.first(where: { $0.uuid == bar.displayUUID }) else {
                reasons.insert(.barNotShown)
                continue
            }
            let slots = slots(on: bar.displayUUID, for: moment, read: read, concealed: concealed)
            guard !slots.isEmpty else { reasons.insert(.noIcon); continue }

            var pending: [(slot: Slot, record: ItemImageRecord?)] = []
            for slot in slots {
                let record = await store.record(for: slot.item.id)
                if isFresh(record, appearance: lastAppearance[bar.displayUUID], moment: moment) { continue }
                pending.append((slot, record))
            }
            guard !pending.isEmpty else { reasons.insert(.recent); continue }
            if let last = lastBarCapture[bar.displayUUID], clock.now().timeIntervalSince(last) < seconds(rules.perBarInterval) {
                reasons.insert(.throttled)
                continue
            }

            // Before the await: a capture that overlaps this one finds the bar taken.
            lastBarCapture[bar.displayUUID] = clock.now()
            lastStripAt = clock.now()
            let image: CGImage
            let taken = await strip(bar: bar, display: display, started: started, moment: moment, deadline: deadline)
            lastStripAt = clock.now()
            switch taken {
            case .picture(let picture): image = picture
            case .failed: reasons.insert(.failed); continue
            case .outOfTime: reasons.insert(moment == .launch ? .launchOutOfTime : .outOfTime); continue
            }
            // The slot frames are of the read, and the pixels are of the bar as it was when the strip was taken: where the bar has been
            // changed since, an icon may have slid into the slot, and the crop would be saved under another item.
            if let isCurrent {
                let apps = Set(pending.map(\.slot.item.ownerBundleID))
                let answer = await isCurrent(bar.displayUUID, apps)
                let kept = answer.kept.intersection(apps)
                if kept != apps {
                    reasons.insert(answer.outOfTime ? .outOfTime : .barChanged)
                    notKept.append(NotKept(apps: apps.subtracting(kept), changes: answer.changes))
                }
                guard !kept.isEmpty else {
                    lastBarCapture[bar.displayUUID] = nil
                    continue
                }
                pending.removeAll { !kept.contains($0.slot.item.ownerBundleID) }
            }

            for (slot, record) in pending {
                guard let crop = StripCapture.crop(image, bar: bar, item: slot.frame, scale: display.scale),
                      let matted = IconMatting.matte(crop) else { continue }
                lastAppearance[bar.displayUUID] = matted.barAppearance
                // The appearance is only known now: a picture of this look that is recent is kept as it is.
                if isFresh(record, appearance: matted.barAppearance, moment: moment) { continue }
                do {
                    let isChange = try await store.save(matted, scale: display.scale, for: slot.item.id,
                                                        appItemCount: read.items(ofApp: slot.item.ownerBundleID).count)
                    captured += 1
                    if isChange { changed += 1 }
                } catch {
                    reasons.insert(.notSaved)
                }
            }
        }

        guard captured > 0 else {
            let reason = reasons.min() ?? .noIcon
            Log.info("capture", "nothing captured at \(moment.kind.rawValue): \(reason.text)\(Self.changesText(notKept).map { " (\($0))" } ?? "")"
                + "; " + Self.whatWasLookedAt(read: read, chosen: chosenBars, shown: shown, displays: displays, concealed: concealed))
            return Self.skipped(reason.text)
        }
        lastCaptureAt = clock.now()
        Log.info("capture", "captured \(captured) icons, \(changed) changed\(Self.notKeptText(notKept))")
        return CaptureSummary(captured: captured, changed: changed, skipped: nil)
    }

    /// The apps a check kept out of a bar's capture, and what it found out of place.
    private struct NotKept {
        let apps: Set<String>
        let changes: [String]
    }

    /// What the checks found out of place, each said once, for the log; nil when they said nothing.
    private static func changesText(_ notKept: [NotKept]) -> String? {
        var lines: [String] = []
        for entry in notKept { for line in entry.changes where !lines.contains(line) { lines.append(line) } }
        guard !lines.isEmpty else { return nil }
        let shown = lines.prefix(4).joined(separator: "; ")
        return lines.count > 4 ? shown + "; and \(lines.count - 4) more" : shown
    }

    /// For the capture that kept some pictures: the apps whose pictures were left out, and why.
    private static func notKeptText(_ notKept: [NotKept]) -> String {
        guard !notKept.isEmpty else { return "" }
        let apps = Set(notKept.flatMap(\.apps)).sorted()
        let named = apps.prefix(5).joined(separator: ", ") + (apps.count > 5 ? " and \(apps.count - 5) more" : "")
        return "; not kept: \(named)" + (changesText(notKept).map { " (\($0))" } ?? "")
    }

    /// Why nothing was captured, most telling first: when several apply, the first of these is said.
    enum SkipReason: Int, Comparable {
        case screenRecordingOff, momentOff, launchOutOfTime, outOfTime, barChanged, barNotShown, noIcon, recent, throttled, failed, notSaved

        static func < (one: SkipReason, other: SkipReason) -> Bool { one.rawValue < other.rawValue }

        var text: String {
            switch self {
            case .screenRecordingOff: "Screen Recording is off"
            case .momentOff: "This moment doesn't capture icons"
            case .launchOutOfTime: "The launch capture ran out of time"
            case .outOfTime: "The capture ran out of time"
            case .barChanged: "The bar changed while it was captured"
            case .barNotShown: "The bar isn't shown"
            case .noIcon: "No icon to capture"
            case .recent: "The pictures are recent"
            case .throttled: "The bar was captured a moment ago"
            case .failed: "The bar couldn't be captured"
            case .notSaved: "A picture couldn't be saved"
            }
        }
    }

    // MARK: Which slots

    private struct Slot {
        let item: MenuBarItem
        let frame: CGRect
    }

    private func slots(on display: String, for moment: CaptureMoment, read: Inventory, concealed: Set<String>) -> [Slot] {
        func croppable(_ item: MenuBarItem) -> Bool {
            !item.isMantel && item.ownKind == nil && !concealed.contains(item.ownerBundleID) && !item.overflowedOn.contains(display)
                // An app that answered in part names some of its icons by their places in the read, and the pictures would be saved under
                // IDs that aren't its records'.
                && !read.incompleteApps.contains(item.ownerBundleID)
        }
        if case .clickDrawn(let location) = moment {
            // The location was found at a moment of its own: it is cropped only where the read has the item's slot too.
            guard location.displayUUID == display,
                  let item = read.items.first(where: { $0.id == location.item }), croppable(item),
                  let readFrame = item.frames[display], Self.sameSlot(readFrame, location.slotFrame) else { return [] }
            return [Slot(item: item, frame: location.slotFrame)]
        }
        return read.items.compactMap { item in
            guard croppable(item), let frame = item.frames[display] else { return nil }
            if case .revealSeen(let apps) = moment, !apps.contains(item.ownerBundleID) { return nil }
            return Slot(item: item, frame: frame)
        }
    }

    private static func sameSlot(_ one: CGRect, _ other: CGRect) -> Bool {
        let tolerance = BarSlotCheck.tolerance
        return abs(one.minX - other.minX) <= tolerance && abs(one.minY - other.minY) <= tolerance
            && abs(one.width - other.width) <= tolerance && abs(one.height - other.height) <= tolerance
    }

    /// For the log, when nothing was captured: the read's active display and the main one, the bars chosen, and for each bar of the read
    /// whether it is shown, how many of its items have a frame on it, and why the others with one aren't cropped.
    private static func whatWasLookedAt(read: Inventory, chosen: [MenuBarGeometry], shown: Set<String>, displays: [DisplayInfo],
                                        concealed: Set<String>) -> String {
        func short(_ uuid: String?) -> String { uuid.map { String($0.prefix(8)) } ?? "none" }
        let main = DisplayLayout(displays: displays).main?.uuid
        let bars = read.bars.map { bar in
            let display = bar.displayUUID
            let framed = read.items.filter { $0.frames[display] != nil }
            let own = framed.filter { $0.isMantel || $0.ownKind != nil }.count
            let hidden = framed.filter { concealed.contains($0.ownerBundleID) }.count
            let overflowed = framed.filter { $0.overflowedOn.contains(display) }.count
            return "\(short(display)) shown \(shown.contains(display)), \(framed.count) with a frame (own \(own), concealed \(hidden), "
                + "overflowed \(overflowed))"
        }
        return "active \(short(read.activeDisplay)), main \(short(main)), displays \(displays.map { short($0.uuid) }), "
            + "chosen \(chosen.map { short($0.displayUUID) }), \(read.items.count) items; bars: \(bars.joined(separator: "; "))"
    }

    /// The bars to take, in the order the read has them: the one bar of a read that has several (see `capture`).
    private func barsToCapture(for moment: CaptureMoment, in read: Inventory, displays: [DisplayInfo]) -> [MenuBarGeometry] {
        if case .clickDrawn(let location) = moment { return read.bars.filter { $0.displayUUID == location.displayUUID } }
        guard read.bars.count > 1 else { return read.bars }
        let chosen = read.activeDisplay.flatMap { active in read.bars.first { $0.displayUUID == active } }
            ?? DisplayLayout(displays: displays).main.flatMap { main in read.bars.first { $0.displayUUID == main.uuid } }
        return chosen.map { [$0] } ?? []
    }

    /// A steady picture of this appearance, younger than `freshFor`. Never at a recapture: it is what the person asks for when a picture
    /// looks wrong, and a picture that is recent is the one that may be wrong.
    private func isFresh(_ record: ItemImageRecord?, appearance: BarAppearance?, moment: CaptureMoment) -> Bool {
        if moment == .recapture { return false }
        guard let record, !record.isDynamic, let appearance, let variant = record.variants[appearance] else { return false }
        return clock.now().timeIntervalSince(variant.capturedAt) < seconds(rules.freshFor)
    }

    // MARK: Taking the strip

    private enum Strip {
        case picture(CGImage)
        case failed
        case outOfTime
    }

    /// The strip of the bar. The launch's is cut off at the cap `launchBudget` allows, or at `deadline` when that is sooner, and a strip
    /// of any moment that is back after `deadline` is thrown away: it shows the bar after the caller changed it.
    private func strip(bar: MenuBarGeometry, display: DisplayInfo, started: Date, moment: CaptureMoment, deadline: Date?) async -> Strip {
        let layout = self.layout()
        let capture = self.capture
        let work: @Sendable () async -> CGImage? = { try? await capture.capture(bar: bar, display: display, layout: layout) }
        var latest = deadline
        if moment == .launch {
            let cap = started.addingTimeInterval(seconds(rules.launchBudget))
            latest = min(latest ?? cap, cap)
        }
        guard let latest else { return await work().map(Strip.picture) ?? .failed }
        let left = latest.timeIntervalSince(clock.now())
        guard left > 0 else { return .outOfTime }
        let result = await Self.race(work, within: .seconds(left), clock: clock)
        switch result {
        case .none: return .outOfTime
        case .some(.some(let image)): return clock.now() <= latest ? .picture(image) : .outOfTime
        case .some(.none): return .failed
        }
    }

    /// The result of `work`, or nil if `limit` passes on `clock` first (the work is then cancelled and let go).
    private static func race<T: Sendable>(_ work: @escaping @Sendable () async -> T, within limit: Duration, clock: any Clock) async -> T? {
        let finished = Mutex(false)
        let tasks = Mutex<[Task<Void, Never>]>([])
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            @Sendable func finish(_ value: T?) {
                let first = finished.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                guard first else { return }
                continuation.resume(returning: value)
                for task in tasks.withLock({ $0 }) { task.cancel() }
            }
            let worker = Task { finish(await work()) }
            let timer = Task {
                guard (try? await clock.sleep(for: limit)) != nil else { return }
                finish(nil)
            }
            tasks.withLock { $0 = [worker, timer] }
            if finished.withLock({ $0 }) { worker.cancel(); timer.cancel() }
        }
    }

    private func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private static func skipped(_ reason: String) -> CaptureSummary {
        CaptureSummary(captured: 0, changed: 0, skipped: reason)
    }
}
