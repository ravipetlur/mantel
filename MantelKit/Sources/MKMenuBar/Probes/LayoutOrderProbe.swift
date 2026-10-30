import CoreGraphics
import Foundation
import MKCommands
import MKCore
import MKLayout

/// `layout-order`: what writing macOS's order table does to the menu bar: whether it re-sorts, how fast, whether the apps' own frames
/// follow, whether distances are places or only an order, and what else keeps or loses an item's place.
///
/// - **It refuses** while the layout file has places that are kept (`.kept` in the journal): the probe writes the table, and what is kept is
///   somebody's arrangement. Only `--dots-restore` runs then.
/// - **Without a switch** it swaps (and then spreads) two of the test item's items, `runs` times (1 to 5, 3 by default). `item` is `one`
///   (swapped with `two`) or `extra.<n>` (with `extra.<n+1>`).
///   1. **Swap.** Their two entries are written with each other's distances, as one write of the two places. The bar is read every 100 ms
///      for 5 s for the order of their slots to flip (`resortApplied`, `resortMs`), and the test item's own list of frames for them to
///      follow (`framesFollowed`, `framesFollowMs`: each item's own frame is in its new slot). The file's bytes catching up with what was
///      written is `fileFlushMs`. The places are put back, and the bar is read for the order to be as it was (`restoreMs`).
///   2. **Gap.** The item that is on the right is written 600 farther than the one on the left, which would put it 600 points left of it if
///      a distance were a place, and next to it if it is only an order. After it has re-sorted, the room between their slots that no slot
///      is in is `deadSpace`, and `packs` is whether it is under 10 points (and 4 for each slot between them). The place is put back.
/// - **`--visibility`:** with the test item started with extras, where all its items are, then `extra.1` hidden for a second and shown for a
///   second and a half (the test item is told to by a notification); `visibilityKeptPlace` is whether every item is back where it was.
/// - **`--relaunch-item`** (and `--extra-count N`, the extras it is opened with again; without it, the items it has now: a test item that is
///   one item alone is opened as one alone): where the test item's items are,
///   the test item relaunched (it and no other app), and where its items are when they are back (waited for 5 s): `relaunchKeptPlaces` is
///   whether the ones that are there again are in the same order. The count of `NSStatusItem Preferred Position` keys in the test item's
///   preferences is read before and after.
/// - **`--dots`:** Mantel's two dots are given places between the system's items and the apps': the dots' entries are written (`dotsMovedMs`:
///   when the dots moved, null when they didn't within 5 s), and put back. **`--dots-keep`** is the same write kept in the journal and left
///   in place, so that the place the dots come back at when Mantel is opened again can be seen; it needs `--dots-restore` after, which
///   puts back the kept places of the dots when those two are the places kept in the table and nothing else is (and says so, and does
///   nothing, when nothing is).
/// - **Every write** is a change to places in the table through the journal, `.untilQuit` and with the original check of the places that are
///   new only, and each is put back at the end of its step, whatever happened. Nothing is written to the table but the test item's entries
///   and, for the dots' steps, Mantel's own two. When a place can't be put back the probe stops there (`notPutBackMessage`): it writes
///   nothing more over a table that is not as it was.
enum LayoutOrderProbe {
    static let pollInterval: Duration = .milliseconds(100)
    /// How long the bar and the apps' frames are watched after a write, and how long the bar is given to come back.
    static let watchMs = 5000.0
    /// How much farther than the item next to it the gap step writes an item, in the table's distances.
    static let farDistance = 600.0
    /// The room between two slots, in points, below which the items are packed against each other, and what each slot between them adds.
    static let packsBelow: CGFloat = 10
    static let slotAllowance: CGFloat = 4
    /// How long the test item's first extra item is hidden, and how long it is given to come back.
    static let hideWait: Duration = .seconds(1)
    static let showWait: Duration = .milliseconds(1500)
    /// How long the file is watched for the places that were written: the preferences service writes it when it likes, and it is no use
    /// holding up the rest for that.
    static let fileWatchMs = 1000.0
    /// What the menu bar is given to settle after it has re-sorted.
    static let settle: Duration = .milliseconds(500)
    /// How far an item's own frame may be from the middle of a slot and be in it, in points.
    static let tieTolerance: CGFloat = 4

    static let keptMessage = "Kept changes are in the layout table. Run this probe with --dots-restore to put back the ones the dots' step kept, "
        + "or use Restore original layout."
    static let otherKeptMessage = "Other kept changes are in the layout table, so the probe won't restore them. Use Restore original layout instead."
    static let notPutBackMessage = "The table couldn't be put back, so the probe stopped. Mantel puts it back when it next starts."

    private struct Steps {
        let visibility: Bool
        let relaunch: Bool
        let dots: Bool
        let keep: Bool
        let restore: Bool

        var swap: Bool { !(visibility || relaunch || dots || keep || restore) }
    }

    // MARK: Running

    static func run(_ context: ProbeContext, _ recorder: inout ProbeRecorder) async {
        let options = context.options
        let steps = Steps(visibility: options.flag("visibility"), relaunch: options.flag("relaunch-item"), dots: options.flag("dots"),
                          keep: options.flag("dots-keep"), restore: options.flag("dots-restore"))
        if steps.restore, steps.visibility || steps.relaunch || steps.dots || steps.keep {
            recorder.fail("--dots-restore runs alone.")
            return
        }
        if steps.dots, steps.keep {
            recorder.fail("Choose --dots or --dots-keep, not both.")
            return
        }
        guard let url = await GrantedFile.url(of: .menuBarLayout, in: context) else {
            recorder.fail(GrantedFile.missing(.menuBarLayout))
            return
        }
        if steps.restore {
            await restoreDots(context, url: url, recorder: &recorder)
            return
        }
        if !(await keptPlaces(context, url: url)).isEmpty {
            recorder.fail(keptMessage)
            return
        }

        do {
            if steps.swap { try await swapRuns(context, url: url, recorder: &recorder) }
            if steps.visibility { try await visibility(context, recorder: &recorder) }
            if steps.relaunch { try await relaunchItem(context, recorder: &recorder) }
            if steps.dots || steps.keep { try await dots(context, url: url, keep: steps.keep, recorder: &recorder) }
        } catch is CancellationError {
            recorder.note("The probe was cut short; what it changed was put back.")
        } catch let refusal as ProbeRefusal {
            recorder.fail(refusal.message)
        } catch {
            recorder.fail("The probe stopped: \(error.localizedDescription)")
        }
    }

    // MARK: The table

    /// What the journal keeps (`.kept`) in the layout file, as the places it is kept at; a whole key is `nil`.
    private struct KeptPlace: Hashable {
        let key: String
        let path: PlistKeyPath?
    }

    private static func keptPlaces(_ context: ProbeContext, url: URL) async -> [KeptPlace] {
        let identity = CanonicalPath.of(url)
        return await context.journal.keptRecords().compactMap { record -> KeptPlace? in
            switch record.entry {
            case .plistPath(let file, let key, let path, _, _, _) where file == identity: KeptPlace(key: key, path: path)
            case .plistKey(let file, let key, _, _) where file == identity: KeptPlace(key: key, path: nil)
            default: nil
            }
        }
    }

    /// The order table through the preferences service, as the system has it now.
    private static func positions(_ context: ProbeContext, url: URL) async throws -> [String: PlistValue] {
        guard case .dictionary(let table)? = try await context.plist.value(at: [], key: LayoutKeys.trailingPositions, in: url) else {
            throw ProbeRefusal(message: "The layout file has no \(LayoutKeys.trailingPositions) table, so there is nothing to write. Run layout-map.")
        }
        return table
    }

    private static func number(_ value: PlistValue?) -> Double? {
        switch value {
        case .integer(let number)?: Double(number)
        case .real(let number)?: number
        default: nil
        }
    }

    /// A distance as the table would hold it: a whole number when it is one.
    private static func distance(_ value: Double) -> PlistValue {
        value == value.rounded() && abs(value) < 1e15 ? .integer(Int(value)) : .real(value)
    }

    private static func fixtureKey(_ name: String, _ context: ProbeContext) -> String {
        LayoutKey.status(bundleID: context.fixtureBundleID, autosaveName: TestItemNames.autosaveName(name))
    }

    private static func dotKeys(_ context: ProbeContext) -> (hidden: String, always: String) {
        (LayoutKey.status(bundleID: context.platform.ownBundleID, autosaveName: DotsCopy.hiddenDotName),
         LayoutKey.status(bundleID: context.platform.ownBundleID, autosaveName: DotsCopy.alwaysDotName))
    }

    // MARK: Swap and gap

    /// Two items of the test item, and how to tell their slots apart and follow them.
    private struct Pair {
        let keyA: String
        let keyB: String
        /// The first item's slot is left of the second's.
        let aIsLeft: Bool
        /// The bar can tell the two slots apart: one has a name, or their widths differ. When it can't, an order that flips can't be seen.
        let identifiable: Bool
        /// Where the two slots were before the write.
        let slotA: CGRect
        let slotB: CGRect
        let pid: pid_t?
        /// Each item's place in the test item's own list of frames, when that was found.
        let indexA: Int?
        let indexB: Int?
        let baselineFrames: [CGRect?]?

        func isALeft(in snapshot: MenuBarSnapshot) -> Bool? {
            let frames = ProbeContext.slotFrames(snapshot)
            guard let a = frames[keyA], let b = frames[keyB] else { return nil }
            return a.minX < b.minX
        }

        /// Whether both items' own frames are in their slots now, and at least one has moved from where it was. Where the bar can't tell the
        /// slots apart, a slot is no item's by its name, so the items' frames are in each other's slots as they were.
        func framesFollowed(_ frames: [CGRect?]?, in snapshot: MenuBarSnapshot) -> Bool? {
            guard let indexA, let indexB, let baselineFrames, let frames, frames.indices.contains(indexA), frames.indices.contains(indexB) else {
                return nil
            }
            guard let a = frames[indexA], let b = frames[indexB] else { return false }
            let nowA: CGRect, nowB: CGRect
            if identifiable {
                let slots = ProbeContext.slotFrames(snapshot)
                guard let found = slots[keyA], let other = slots[keyB] else { return false }
                (nowA, nowB) = (found, other)
            } else {
                (nowA, nowB) = (slotB, slotA)
            }
            guard abs(a.midX - nowA.midX) <= tieTolerance, abs(b.midX - nowB.midX) <= tieTolerance else { return false }
            let movedA = baselineFrames[indexA].map { !ItemLocator.sameFrame($0, a) } ?? true
            let movedB = baselineFrames[indexB].map { !ItemLocator.sameFrame($0, b) } ?? true
            return movedA || movedB
        }
    }

    /// What one watch of a swap saw.
    private struct Watched {
        var resortMs: Double?
        var framesMs: Double?
        var fileMs: Double?
    }

    private static func swapRuns(_ context: ProbeContext, url: URL, recorder: inout ProbeRecorder) async throws {
        let options = context.options
        let itemName = options.string("item") ?? "one"
        let neighbourName: String
        if itemName == "one" {
            neighbourName = "two"
        } else if let number = TestItemNames.extraNumber(of: itemName), number < TestItemNames.maximumExtras {
            neighbourName = "extra.\(number + 1)"
        } else {
            throw ProbeRefusal(message: "The item is one (swapped with two) or extra.<n> (swapped with extra.<n+1>).")
        }
        let runs = options.int("runs", default: 3, range: 1...5)
        recorder.measure("item", itemName)
        recorder.measure("neighbour", neighbourName)
        recorder.measure("runCount", runs)

        var records: [JSONValue] = []
        var resorted: [Bool?] = [], followed: [Bool?] = [], packed: [Bool?] = []
        var resortTimes: [Double?] = [], followTimes: [Double?] = [], restoreTimes: [Double?] = []
        var pending: (any Error)?
        for index in 0..<runs {
            do {
                let run = try await oneSwap(index, itemName, neighbourName, context, url: url, recorder: &recorder)
                records.append(run.json)
                resorted.append(run.resortApplied)
                followed.append(run.framesFollowed)
                packed.append(run.packs)
                resortTimes.append(run.resortMs)
                followTimes.append(run.framesFollowMs)
                restoreTimes.append(run.restoreMs)
                try await context.clock.sleep(for: settle)
            } catch {
                pending = error
                break
            }
        }
        recorder.measure("runs", .array(records))
        recorder.measure("resortMs", LatencyStats(values: resortTimes).json())
        recorder.measure("framesFollowMs", LatencyStats(values: followTimes).json())
        recorder.measure("restoreMs", LatencyStats(values: restoreTimes).json())
        recorder.measure("resortAppliedEveryRun", .bool(!resorted.isEmpty && resorted.allSatisfy { $0 == true }))
        recorder.measure("resortAppliedNoRun", .bool(!resorted.isEmpty && resorted.allSatisfy { $0 == false }))
        recorder.measure("framesFollowedEveryRun", .bool(!followed.isEmpty && followed.allSatisfy { $0 == true }))
        recorder.measure("packsEveryRun", .bool(!packed.isEmpty && packed.allSatisfy { $0 == true }))
        recorder.measure("packsNoRun", .bool(!packed.isEmpty && packed.allSatisfy { $0 == false }))
        if resorted.contains(nil) {
            recorder.note("The two slots have no names and one width, so the order of the bar can't tell them apart: resortApplied is null where that was so, and framesFollowed says whether the items moved.")
        }
        recorder.note("Times are milliseconds from just before the write. A distance is how far an item is from the bar's trailing edge.")
        if let pending { throw pending }
    }

    private struct SwapRun {
        var resortApplied: Bool?
        var resortMs: Double?
        var framesFollowed: Bool?
        var framesFollowMs: Double?
        var restoreMs: Double?
        var packs: Bool?
        var json: JSONValue = .null
    }

    private static func oneSwap(_ index: Int, _ itemName: String, _ neighbourName: String, _ context: ProbeContext, url: URL,
                                recorder: inout ProbeRecorder) async throws -> SwapRun {
        var run = SwapRun()
        var record: [String: JSONValue] = ["run": .number(Double(index + 1))]

        // Where things are now.
        let table = try await positions(context, url: url)
        let keyA = fixtureKey(itemName, context), keyB = fixtureKey(neighbourName, context)
        guard let valueA = table[keyA], let valueB = table[keyB], let distanceA = number(valueA), let distanceB = number(valueB) else {
            throw ProbeRefusal(message: "The layout table has no entry for \(itemName) and \(neighbourName). Run layout-map to see what it holds.")
        }
        guard distanceA != distanceB else {
            throw ProbeRefusal(message: "\(itemName) and \(neighbourName) are at one distance, so swapping them changes nothing.")
        }
        let located = await context.locateFixtureItems([itemName, neighbourName])
        guard let locationA = located[itemName], let locationB = located[neighbourName] else {
            throw ProbeRefusal(message: "\(itemName) and \(neighbourName) aren't both found in the menu bar. Put MantelTestItem in Shown, open it with --extra N for extra items, and run the inventory probe to see what its items are called.")
        }
        let baseline = await context.agentSnapshot()
        guard let slotA = ProbeContext.slotKey(at: locationA.slotFrame, in: baseline),
              let slotB = ProbeContext.slotKey(at: locationB.slotFrame, in: baseline) else {
            throw ProbeRefusal(message: "Couldn't tell which of the bar's slots are \(itemName)'s and \(neighbourName)'s.")
        }
        let pair = makePair(slotA, slotB, locationA, locationB, context)
        record["identifiable"] = .bool(pair.identifiable)

        // 1. Swap. The change is announced first: a write that fails half way has still changed something to put back.
        let started = context.clock.now()
        recorder.changeBegan()
        var failure: (any Error)?
        var watched = Watched()
        do {
            try await context.plist.write([PathEdit(path: [.key(keyA)], value: valueB), PathEdit(path: [.key(keyB)], value: valueA)],
                                          key: LayoutKeys.trailingPositions, in: url, strategy: .cfPreferences, lifetime: .untilQuit,
                                          originalCheck: .newPathsOnly)
            record["writeMs"] = .number(context.milliseconds(since: started))
            watched = try await watchSwap(pair, expectedAIsLeft: !pair.aIsLeft, written: [(keyA, valueB), (keyB, valueA)], since: started,
                                          context: context)
        } catch {
            failure = error
        }
        run.resortMs = watched.resortMs
        run.resortApplied = pair.identifiable ? watched.resortMs != nil : nil
        run.framesFollowMs = watched.framesMs
        run.framesFollowed = pair.indexA != nil && pair.indexB != nil ? watched.framesMs != nil : nil
        record["resortApplied"] = ProbeJSON.flag(run.resortApplied)
        record["resortMs"] = ProbeJSON.number(run.resortMs)
        record["framesFollowed"] = ProbeJSON.flag(run.framesFollowed)
        record["framesFollowMs"] = ProbeJSON.number(run.framesFollowMs)
        record["fileFlushMs"] = ProbeJSON.number(watched.fileMs)

        // Put back, whatever happened above. A table that won't go back stops the probe here: no gap is written over it, and no run follows.
        let undoStarted = context.clock.now()
        guard await putBack([keyA, keyB], context, url: url, recorder: &recorder) else {
            throw putBackFailed(after: failure, recorder: &recorder)
        }
        if failure == nil, pair.identifiable {
            run.restoreMs = try await restoredMs(pair, expectedAIsLeft: pair.aIsLeft, since: undoStarted, context: context)
        }
        record["restoreMs"] = ProbeJSON.number(run.restoreMs)
        if failure == nil {
            // The next run takes the apps' own frames as its baseline: they are waited for to be where they were.
            record["framesBackMs"] = ProbeJSON.number(try await framesBackMs(pair, since: undoStarted, context: context))
        }
        if let failure { throw failure }

        // 2. Gap.
        if pair.identifiable {
            let spread = try await spreadApart(pair, valueA: distanceA, valueB: distanceB, keyA: keyA, keyB: keyB, context: context, url: url,
                                               recorder: &recorder)
            run.packs = spread.packs
            record["gapPt"] = ProbeJSON.number(spread.gap)
            record["slotsBetween"] = spread.between.map { .number(Double($0)) } ?? .null
            record["deadSpace"] = ProbeJSON.number(spread.deadSpace)
            record["packs"] = ProbeJSON.flag(spread.packs)
            record["gapResortMs"] = ProbeJSON.number(spread.resortMs)
        }
        run.json = .object(record)
        return run
    }

    private static func makePair(_ slotA: String, _ slotB: String, _ locationA: ItemLocation, _ locationB: ItemLocation,
                                 _ context: ProbeContext) -> Pair {
        let pid = context.platform.runningApps().first(where: { $0.bundleID == context.fixtureBundleID })?.pid
        let frames = pid.flatMap { context.reader.extrasFrames(ofPID: $0) }
        func index(of location: ItemLocation) -> Int? {
            frames?.firstIndex { $0.map { abs($0.midX - location.slotFrame.midX) <= tieTolerance } ?? false }
        }
        // A slot with no name of its own is told by its width, and two such slots of one width can't be told apart by where they are.
        func isUnnamed(_ key: String) -> Bool { key.split(separator: "|", maxSplits: 1).last?.hasPrefix("@w") ?? false }
        func width(_ key: String) -> String { String(key.split(separator: "#").first ?? "") }
        let identifiable = !(isUnnamed(slotA) && isUnnamed(slotB) && width(slotA) == width(slotB))
        return Pair(keyA: slotA, keyB: slotB, aIsLeft: locationA.slotFrame.minX < locationB.slotFrame.minX, identifiable: identifiable,
                    slotA: locationA.slotFrame, slotB: locationB.slotFrame, pid: pid, indexA: index(of: locationA),
                    indexB: index(of: locationB), baselineFrames: frames)
    }

    /// Reads the bar and the test item's own frames every 100 ms from `started` until the order has flipped and the frames have followed,
    /// or 5 s have passed; and watches the file for the places that were written.
    private static func watchSwap(_ pair: Pair, expectedAIsLeft: Bool, written: [(key: String, value: PlistValue)], since started: Date,
                                  context: ProbeContext) async throws -> Watched {
        var watched = Watched()
        let tracksFrames = pair.indexA != nil && pair.indexB != nil
        while true {
            try Task.checkCancellation()
            let snapshot = await context.agentSnapshot()
            let frames = pair.pid.flatMap { context.reader.extrasFrames(ofPID: $0) }
            let elapsed = context.milliseconds(since: started)
            if watched.resortMs == nil, pair.isALeft(in: snapshot) == expectedAIsLeft { watched.resortMs = elapsed }
            if watched.framesMs == nil, pair.framesFollowed(frames, in: snapshot) == true { watched.framesMs = elapsed }
            if watched.fileMs == nil, elapsed < fileWatchMs, let top = try? await GrantedFile.readTopLevel(.menuBarLayout, in: context),
               written.allSatisfy({ top[LayoutKeys.trailingPositions]?.value(at: [.key($0.key)]) == $0.value }) {
                watched.fileMs = elapsed
            }
            let barDone = !pair.identifiable || watched.resortMs != nil
            let framesDone = !tracksFrames || watched.framesMs != nil
            let fileDone = watched.fileMs != nil || elapsed >= fileWatchMs
            if (barDone && framesDone && fileDone) || elapsed >= watchMs { return watched }
            try await context.clock.sleep(for: pollInterval)
        }
    }

    /// When the bar is in the order it had, polled every 100 ms for 5 s from `started`; nil when it never is.
    private static func restoredMs(_ pair: Pair, expectedAIsLeft: Bool, since started: Date, context: ProbeContext) async throws -> Double? {
        let outcome = try await context.poll(every: 100, upTo: Int(watchMs), from: started, until: { pair.isALeft(in: $0) == expectedAIsLeft })
        return outcome.hit?.elapsedMs
    }

    /// When the test item's own frames are where they were, polled every 100 ms for 5 s from `started`; nil when they never are (or when there
    /// is nothing to compare them with).
    private static func framesBackMs(_ pair: Pair, since started: Date, context: ProbeContext) async throws -> Double? {
        guard let pid = pair.pid, let baseline = pair.baselineFrames else { return nil }
        while true {
            try Task.checkCancellation()
            let frames = context.reader.extrasFrames(ofPID: pid)
            let elapsed = context.milliseconds(since: started)
            if let frames, frames.count == baseline.count,
               zip(frames, baseline).allSatisfy({ now, was in
                   switch (now, was) {
                   case (nil, nil): true
                   case (let now?, let was?): ItemLocator.sameFrame(now, was)
                   default: false
                   }
               }) { return elapsed }
            if elapsed >= watchMs { return nil }
            try await context.clock.sleep(for: pollInterval)
        }
    }

    /// Puts the places back, each on its own, and says in the recorder whether they all are. Returns whether they are.
    private static func putBack(_ keys: [String], _ context: ProbeContext, url: URL, recorder: inout ProbeRecorder) async -> Bool {
        var failures: [String] = []
        for key in keys {
            do {
                try await context.plist.undo(path: [.key(key)], key: LayoutKeys.trailingPositions, in: url)
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        if failures.isEmpty {
            recorder.changeUndone()
            return true
        }
        recorder.undoFailed("The table couldn't be put back: \(failures.joined(separator: "; ")) Mantel puts it back when it next starts.")
        return false
    }

    /// What stops the probe when a place couldn't be put back: `putBack` has said why in the errors already. A failure of the step before
    /// it, if there was one, is said too, as it would have been if it had been thrown.
    private static func putBackFailed(after failure: (any Error)?, recorder: inout ProbeRecorder) -> ProbeRefusal {
        if let failure, !(failure is CancellationError) {
            recorder.fail((failure as? ProbeRefusal)?.message ?? "The probe stopped: \(failure.localizedDescription)")
        }
        return ProbeRefusal(message: notPutBackMessage)
    }

    private struct GapResult {
        var gap: Double?
        var between: Int?
        var deadSpace: Double?
        var packs: Bool?
        var resortMs: Double?
    }

    /// Writes the item on the right 600 farther than the one on the left, and looks at the room between the two when the bar has re-sorted.
    private static func spreadApart(_ pair: Pair, valueA: Double, valueB: Double, keyA: String, keyB: String, context: ProbeContext,
                                    url: URL, recorder: inout ProbeRecorder) async throws -> GapResult {
        let staysIsA = pair.aIsLeft
        let staysSlot = staysIsA ? pair.keyA : pair.keyB
        let moverSlot = staysIsA ? pair.keyB : pair.keyA
        let moverKey = staysIsA ? keyB : keyA
        let target = distance((staysIsA ? valueA : valueB) + farDistance)

        var result = GapResult()
        let started = context.clock.now()
        recorder.changeBegan()
        var failure: (any Error)?
        do {
            try await context.plist.write([PathEdit(path: [.key(moverKey)], value: target)], key: LayoutKeys.trailingPositions, in: url,
                                          strategy: .cfPreferences, lifetime: .untilQuit, originalCheck: .newPathsOnly)
            // The mover was on the right; it is on the left of the other when it has re-sorted.
            let outcome = try await context.poll(every: 100, upTo: Int(watchMs), from: started, until: { snapshot in
                let frames = ProbeContext.slotFrames(snapshot)
                guard let mover = frames[moverSlot], let stays = frames[staysSlot] else { return false }
                return mover.minX < stays.minX
            })
            result.resortMs = outcome.hit?.elapsedMs
            if outcome.hit != nil {
                try await context.clock.sleep(for: settle)
                let frames = ProbeContext.slotFrames(await context.agentSnapshot())
                if let mover = frames[moverSlot], let stays = frames[staysSlot], mover.minX < stays.minX {
                    let display = staysSlot.split(separator: "|", maxSplits: 1).first.map(String.init) ?? ""
                    let between = frames.filter { key, frame in
                        key != moverSlot && key != staysSlot && key.hasPrefix(display + "|")
                            && frame.minX >= mover.maxX - 0.5 && frame.maxX <= stays.minX + 0.5
                    }.map(\.value)
                    let room = Double(stays.minX - mover.maxX)
                    let dead = room - between.reduce(0) { $0 + Double($1.width) }
                    result.gap = room
                    result.between = between.count
                    result.deadSpace = dead
                    result.packs = dead < Double(packsBelow + slotAllowance * CGFloat(between.count))
                }
            }
        } catch {
            failure = error
        }
        let undoStarted = context.clock.now()
        guard await putBack([moverKey], context, url: url, recorder: &recorder) else {
            throw putBackFailed(after: failure, recorder: &recorder)
        }
        if failure == nil {
            _ = try await restoredMs(pair, expectedAIsLeft: pair.aIsLeft, since: undoStarted, context: context)
            _ = try await framesBackMs(pair, since: undoStarted, context: context)
        }
        if let failure { throw failure }
        return result
    }

    // MARK: Visibility

    private static func visibility(_ context: ProbeContext, recorder: inout ProbeRecorder) async throws {
        let platform = context.platform
        guard let count = context.fixtureItemCount(), count >= 3 else {
            throw ProbeRefusal(message: "Open the test item with extras first: open /Applications/MantelTestItem.app --args --extra 2")
        }
        let names = TestItemNames.names(itemCount: count)
        let before = await context.locateFixtureItems(names)
        guard before["extra.1"] != nil else {
            throw ProbeRefusal(message: "extra.1 isn't found in the menu bar. Put MantelTestItem in Shown, and run the inventory probe to see what its items are called.")
        }
        recorder.measure("itemsBefore", slots(before))

        var hidden = false
        var failure: (any Error)?
        var whileHidden: [String: ItemLocation] = [:]
        do {
            recorder.changeBegan()
            platform.notifyTestItem(TestItemCommands.toggleExtraOne)
            hidden = true
            try await context.clock.sleep(for: hideWait)
            whileHidden = await context.locateFixtureItems(names)
            platform.notifyTestItem(TestItemCommands.toggleExtraOne)
            hidden = false
            try await context.clock.sleep(for: showWait)
        } catch {
            failure = error
        }
        // Shown again, whatever happened above.
        if hidden { platform.notifyTestItem(TestItemCommands.toggleExtraOne) }
        recorder.changeUndone()
        if let failure { throw failure }

        let after = await context.locateFixtureItems(names)
        recorder.measure("extraOneGoneWhileHidden", .bool(whileHidden["extra.1"] == nil))
        recorder.measure("itemsAfter", slots(after))
        // Nothing else moved, so an item that is back in its place has its slot where it was; one that came back elsewhere moves the others.
        let kept = names.allSatisfy { name in
            guard let was = before[name], let now = after[name] else { return false }
            return ItemLocator.sameFrame(was.slotFrame, now.slotFrame)
        }
        recorder.measure("visibilityKeptPlace", .bool(kept))
    }

    private static func slots(_ locations: [String: ItemLocation]) -> JSONValue {
        .object(locations.mapValues { ProbeJSON.rect($0.slotFrame) })
    }

    // MARK: Relaunching

    private static func relaunchItem(_ context: ProbeContext, recorder: inout ProbeRecorder) async throws {
        let platform = context.platform
        guard let count = context.fixtureItemCount() else {
            throw ProbeRefusal(message: "MantelTestItem isn't running, or has no items in the menu bar. Open it first.")
        }
        // With a count it is opened with that many extra items; without one, with the items it has (one alone stays one alone).
        let arguments: [String]
        let itemsAfter: Int
        if context.options.string("extra-count").flatMap({ Int($0) }) != nil {
            let extras = context.options.int("extra-count", default: 0, range: 0...TestItemNames.maximumExtras)
            arguments = TestItemNames.launchArguments(extras: extras)
            itemsAfter = 2 + extras
        } else {
            arguments = TestItemNames.launchArguments(itemCount: count)
            itemsAfter = count
        }
        guard let candidate = context.fixtureRelaunchCandidate(arguments: arguments) else {
            throw ProbeRefusal(message: "MantelTestItem has no app to open again. Open it from /Applications first.")
        }
        let namesBefore = TestItemNames.names(itemCount: count)
        let before = await context.locateFixtureItems(namesBefore)
        let orderBefore = leftToRight(before)
        let keysBefore = platform.testItemPreferredPositionKeyCount()

        recorder.measure("extraCount", max(itemsAfter - 2, 0))
        recorder.measure("orderBefore", strings: orderBefore)
        let outcome = await platform.relauncher.relaunch(candidate)
        recorder.measure("relaunch", outcome == .relaunched ? "relaunched" : (outcome == .didNotQuit ? "didNotQuit" : "couldNotOpen"))
        guard outcome == .relaunched else {
            recorder.note("The test item didn't relaunch, so what it kept can't be compared.")
            return
        }
        let namesAfter = TestItemNames.names(itemCount: itemsAfter)
        let waited = try await context.waitForFixtureItems(namesAfter, upTo: 5000)
        let orderAfter = leftToRight(waited.found)
        recorder.measure("itemsBackMs", ProbeJSON.number(waited.allFoundMs))
        recorder.measure("orderAfter", strings: orderAfter)
        recorder.measure("testItemPreferredPositionKeyCountBefore", .number(Double(keysBefore)))
        recorder.measure("testItemPreferredPositionKeyCountAfter", .number(Double(platform.testItemPreferredPositionKeyCount())))
        let common = orderBefore.filter { orderAfter.contains($0) }
        recorder.measure("relaunchKeptPlaces", .bool(waited.allFoundMs != nil && !common.isEmpty && orderAfter.filter { common.contains($0) } == common))
        if waited.allFoundMs == nil { recorder.note("Not every item of the test item was back in the menu bar within 5 s.") }
    }

    /// The items' names in the order of their slots, left to right.
    private static func leftToRight(_ locations: [String: ItemLocation]) -> [String] {
        locations.sorted { ($0.value.slotFrame.minX, $0.key) < ($1.value.slotFrame.minX, $1.key) }.map(\.key)
    }

    // MARK: The dots

    /// Places for the dots between the system's items and the apps': the largest distance a system item has (or 0) and the smallest an
    /// app's item has, the dots' own entries aside. • is nearer the system items than ••.
    static func dotDistances(table: [String: PlistValue], dotKeys: [String]) -> (hidden: Double, always: Double)? {
        var modules: [Double] = [], apps: [Double] = []
        for (key, value) in table {
            guard let distance = number(value), !dotKeys.contains(key) else { continue }
            switch LayoutKey.parse(key) {
            case .module?: modules.append(distance)
            case .status?: apps.append(distance)
            case nil: continue
            }
        }
        let lower = modules.max() ?? 0
        guard let upper = apps.min(), upper > lower else { return nil }
        let step = (upper - lower) / 3
        return (lower + step, lower + 2 * step)
    }

    private static func dots(_ context: ProbeContext, url: URL, keep: Bool, recorder: inout ProbeRecorder) async throws {
        let keys = dotKeys(context)
        let table = try await positions(context, url: url)
        guard let places = dotDistances(table: table, dotKeys: [keys.hidden, keys.always]) else {
            throw ProbeRefusal(message: "There is no room in the table between the system's items and the apps' to place the dots in. Run layout-map to see what it holds.")
        }
        recorder.measure("hiddenDotDistance", .number(places.hidden))
        recorder.measure("alwaysDotDistance", .number(places.always))
        recorder.measure("kept", .bool(keep))

        let baseline = dotPositions(await context.agentSnapshot())
        recorder.measure("dotSlotsBefore", .number(Double(baseline.count)))
        let started = context.clock.now()
        recorder.changeBegan()
        var failure: (any Error)?
        do {
            try await context.plist.write([PathEdit(path: [.key(keys.hidden)], value: distance(places.hidden)),
                                           PathEdit(path: [.key(keys.always)], value: distance(places.always))],
                                          key: LayoutKeys.trailingPositions, in: url, strategy: .cfPreferences,
                                          lifetime: keep ? .kept : .untilQuit, originalCheck: .newPathsOnly)
            let outcome = try await context.poll(every: 100, upTo: Int(watchMs), from: started, until: { dotPositions($0) != baseline })
            recorder.measure("dotsMovedMs", ProbeJSON.number(outcome.hit?.elapsedMs))
            if outcome.hit == nil { recorder.note("The dots didn't move within 5 s of the write.") }
        } catch {
            failure = error
        }
        if keep {
            guard let failure else {
                // Left in place, kept: the next step is Mantel opened again, and then --dots-restore.
                recorder.note("The dots' places are kept in the table. Run layout-order --dots-restore to put them back.")
                return
            }
            // The write didn't come to what was asked, and a kept place is put back by a restore and by nothing else.
            do {
                _ = try await context.plist.restoreKept(key: LayoutKeys.trailingPositions, in: url)
                recorder.changeUndone()
            } catch {
                recorder.undoFailed("The dots' places couldn't be put back: \(error.localizedDescription) Run layout-order --dots-restore, or use Restore original layout.")
            }
            throw failure
        }
        let undoStarted = context.clock.now()
        guard await putBack([keys.hidden, keys.always], context, url: url, recorder: &recorder) else {
            throw putBackFailed(after: failure, recorder: &recorder)
        }
        if failure == nil {
            let outcome = try await context.poll(every: 100, upTo: Int(watchMs), from: undoStarted, until: { dotPositions($0) == baseline })
            recorder.measure("dotsRestoredMs", ProbeJSON.number(outcome.hit?.elapsedMs))
        }
        if let failure { throw failure }
    }

    /// Where the dots' slots are, by x, to a tenth of a point.
    private static func dotPositions(_ snapshot: MenuBarSnapshot) -> [Double] {
        snapshot.allSlots.filter { DotsCopy.isDot(name: $0.identifier, description: $0.description) }
            .compactMap { $0.frame.map { Double(($0.minX * 10).rounded() / 10) } }.sorted()
    }

    private static func restoreDots(_ context: ProbeContext, url: URL, recorder: inout ProbeRecorder) async {
        let keys = dotKeys(context)
        let dotPlaces: Set<KeptPlace> = [KeptPlace(key: LayoutKeys.trailingPositions, path: [.key(keys.hidden)]),
                                         KeptPlace(key: LayoutKeys.trailingPositions, path: [.key(keys.always)])]
        let kept = await keptPlaces(context, url: url).filter { $0.key == LayoutKeys.trailingPositions }
        recorder.measure("keptPlaces", .number(Double(kept.count)))
        if kept.isEmpty {
            // Nothing is in the way, and nothing is out of place: there is nothing to put back, which is no refusal.
            recorder.measure("restoredPlaces", .number(0))
            recorder.measure("restored", .bool(true))
            recorder.note("Nothing was kept.")
            return
        }
        // Exactly the dots' two places: one of them alone, or either with another place, is not what the dots' step kept.
        guard Set(kept) == dotPlaces else {
            recorder.fail(otherKeptMessage)
            return
        }
        do {
            let count = try await context.plist.restoreKept(key: LayoutKeys.trailingPositions, in: url)
            recorder.measure("restoredPlaces", .number(Double(count)))
            recorder.measure("restored", .bool(true))
        } catch {
            recorder.measure("restored", .bool(false))
            recorder.fail("The dots' places couldn't be put back: \(error.localizedDescription) Use Restore original layout instead.")
        }
    }
}
