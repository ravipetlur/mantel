import CoreGraphics
import Foundation
import MKCommands
import MKCore

/// What `trackedApplications` is, as bytes: the value itself when it is a blob, and otherwise the value written as a binary property
/// list, so that the same reading serves both.
enum TrackedList {
    static let key = "trackedApplications"

    enum Kind: String {
        case blob, plainValue
    }

    /// The bytes to look at, and whether the value was a blob already; nil when the value can't be written as a property list.
    static func bytes(of value: PlistValue) -> (data: Data, kind: Kind)? {
        if case .data(let blob) = value { return (blob, .blob) }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: value.propertyList, format: .binary, options: 0) else { return nil }
        return (data, .plainValue)
    }
}

/// `approvals-decode`: what the "Allow in the Menu Bar" list is, in its bytes: whether it is a property list or a keyed archive, the
/// shape of what is inside, and where the test item is (`BlobShape.describe`). Only reads (through the grant of the file, by `cfprefsd`).
///
/// It never says a string value, and never another app's ID: key names that are part of the format, types, counts and whether
/// the test item's own ID is there, and the keys and types of its entry (`BlobShape`).
///
/// - `--save-baseline` keeps every leaf of the list in `Probes/approvals-baseline.json`: its type, and for a flag or a number its
///   value, by path. No string is in it.
/// - `--compare` lists `changedLeaves`: the leaves that differ from that file, by their paths in the journal's segment form
///   (`/k:…`, `/i:…`, `/m:<id key>=<test item>` for the test item's entry when it holds its ID itself, and
///   `/mp:<way to the ID>=<test item>` when the ID is further down in it), with flag and number values only. Flip a switch in
///   System Settings between the two runs to see which leaf it is: the test item's entry has the same path wherever macOS puts it,
///   and when the list is a list of entries that hold their IDs further down, the other entries are counted under one path, so
///   that the order macOS writes the list in changes nothing that is compared.
/// - The report's `markerEntryShape` is the shape of the whole entry that holds the test item's ID, wherever in it the ID is.
enum ApprovalsDecodeProbe {
    static let baselineName = "approvals-baseline.json"

    static func run(_ context: ProbeContext, _ recorder: inout ProbeRecorder) async {
        let options = context.options
        guard let url = await GrantedFile.url(of: .controlCenterApprovals, in: context) else {
            recorder.fail(GrantedFile.missing(.controlCenterApprovals))
            return
        }
        let value: PlistValue?
        do {
            value = try await context.plist.value(at: [], key: TrackedList.key, in: url)
        } catch {
            recorder.fail("The list couldn't be read: \(error.localizedDescription)")
            return
        }
        guard let value else {
            recorder.measure("markerFound", false)
            recorder.note("The file has no \(TrackedList.key) key.")
            return
        }
        guard let (bytes, kind) = TrackedList.bytes(of: value) else {
            recorder.fail("The list isn't a property list that can be read.")
            return
        }
        let marker = context.fixtureBundleID
        recorder.measure("kind", kind.rawValue)
        // What `BlobShape.describe` says, each as a measurement of its own: byteCount, magic, parsesAsPropertyList, plistFormat,
        // isKeyedArchive, archiveClasses, structure, entryCount, markerFound and markerEntryShape.
        if case .object(let shape) = BlobShape.describe(bytes, marker: marker) {
            for (name, value) in shape { recorder.measure(name, value) }
        }
        if kind == .plainValue {
            recorder.note("\(TrackedList.key) isn't kept as a blob: the shape is of the list itself, written as a binary property list.")
        }

        guard options.flag("save-baseline") || options.flag("compare") else { return }
        guard let (leaves, truncated) = BlobShape.leavesWalk(of: bytes, marker: marker) else {
            recorder.fail("The list isn't a property list, so it has no leaves to keep or compare.")
            return
        }
        if truncated {
            // What was gathered is kept: the leaves before the limit, and a leaf of type ‹truncated› where the walk stopped.
            recorder.measure("truncated", true)
            recorder.note("The list is too large to read whole: the leaves are those gathered before the work limit, and a leaf of type \(BlobShape.truncatedMarker) is where it stopped.")
        }
        let file = context.paths.probes.appending(path: baselineName)
        if options.flag("save-baseline") {
            do {
                try save(leaves, truncated: truncated, to: file, at: context.clock.now(), probes: context.paths.probes)
                recorder.measure("baselineSaved", true)
                recorder.measure("baselineLeafCount", leaves.count)
                recorder.measure("baselineFile", baselineName)
            } catch {
                recorder.fail("The baseline couldn't be saved: \(error.localizedDescription)")
            }
        }
        if options.flag("compare") {
            guard let baseline = loadBaseline(file) else {
                recorder.measure("changedLeaves", .null)
                recorder.note("There is no baseline to compare with. Run it with --save-baseline first.")
                return
            }
            if baseline.truncated {
                recorder.note("The baseline was cut at the work limit, so what follows the place it stopped at is not compared.")
            }
            if baseline.skipped > 0 {
                recorder.note("\(baseline.skipped) entries of the baseline couldn't be read and were left out of the comparison.")
            }
            let changed = BlobShape.changes(from: baseline.leaves, to: leaves)
            recorder.measure("changedLeaves", .array(changed))
            recorder.measure("changedLeafCount", changed.count)
            recorder.measure("comparedWith", baselineName)
            recorder.measure("baselineSavedAt", .string(baseline.savedAt))
        }
    }

    // MARK: The baseline file

    private static func save(_ leaves: [String: BlobShape.Leaf], truncated: Bool, to file: URL, at date: Date, probes: URL) throws {
        var entries: [String: JSONValue] = [:]
        for (path, leaf) in leaves {
            var entry: [String: JSONValue] = ["type": .string(leaf.type)]
            if let value = leaf.value { entry["value"] = value }
            if leaf.count != 1 { entry["count"] = .number(Double(leaf.count)) }
            entries[path] = .object(entry)
        }
        var members: [String: JSONValue] = ["savedAt": .string(ISO8601Dates.string(from: date)), "leaves": .object(entries)]
        if truncated { members["truncated"] = .bool(true) }
        let document = JSONValue.object(members)
        try AtomicFile.ensureFolder(probes)
        try AtomicFile.write(try JSONCoding.encoder().encode(document), to: file)
    }

    /// The baseline file: when it was saved, its leaves, and how many of its entries were left out because what they hold isn't a count
    /// (a file edited by hand).
    private static func loadBaseline(_ file: URL) -> (savedAt: String, leaves: [String: BlobShape.Leaf], skipped: Int, truncated: Bool)? {
        guard let data = try? Data(contentsOf: file), let document = try? JSONCoding.decoder().decode(JSONValue.self, from: data),
              case .object(let top) = document, case .object(let entries)? = top["leaves"] else { return nil }
        var leaves: [String: BlobShape.Leaf] = [:]
        var skipped = 0
        for (path, entry) in entries {
            guard case .object(let fields) = entry, case .string(let type)? = fields["type"] else {
                skipped += 1
                continue
            }
            var count = 1
            if let held = fields["count"] {
                // A count that isn't a whole number that fits (a huge or a fractional one, or a text) is no count, and `Int(held)` would trap.
                guard case .number(let number) = held, let whole = Int(exactly: number), whole >= 1 else {
                    skipped += 1
                    continue
                }
                count = whole
            }
            leaves[path] = BlobShape.Leaf(type: type, value: fields["value"], count: count)
        }
        let savedAt: String
        if case .string(let text)? = top["savedAt"] { savedAt = text } else { savedAt = "" }
        var truncated = false
        if case .bool(let cut)? = top["truncated"] { truncated = cut }
        return (savedAt, leaves, skipped, truncated)
    }
}

/// Where the test item's entry is inside the list, so that a place relative to it can be written as a path from the top.
enum ApprovalsLocator {
    struct Found {
        /// The steps to the list that holds the entry (or to the dictionary keyed by the test item's ID).
        let prefix: PlistKeyPath
        /// The step that is the entry: `.matching(idKey, test item)` in a list, `.key(test item)` in a dictionary.
        let entry: KeyPathStep
        /// The key of the entry that holds the ID, when the entry is in a list.
        let idKey: String?
        /// The same two as a report says them: keys that are data are not said (`ShownKey`, which depends on how many keys the
        /// dictionary the key is in has).
        let shownPrefix: PlistKeyPath
        let shownEntry: KeyPathStep
        let shownIdKey: String?

        var path: PlistKeyPath { prefix + [entry] }
        var shownPath: PlistKeyPath { shownPrefix + [shownEntry] }
    }

    /// A path a person gave (a place from the entry) as a report says it.
    static func shown(_ path: PlistKeyPath, marker: String) -> PlistKeyPath {
        path.map { step in
            switch step {
            case .key(let key): .key(ShownKey.text(key, marker: marker))
            case .index, .anyElement: step
            case .matching(let key, let value): .matching(key: ShownKey.text(key, marker: marker), value: value == marker ? marker : "‹value›")
            case .matchingPath(let subPath, let value):
                .matchingPath(path: shown(subPath, marker: marker), value: value == marker ? marker : "‹value›")
            }
        }
    }

    /// Finds the entry in a value, or says in words why it can't: the test item isn't in it, its ID is held by more than one key of
    /// the entry (and `idKey` doesn't say which), or the entry is in a list that is itself in a list.
    static func find(in root: PlistNode, marker: String, idKey: String?) -> Result<Found, ProbeRefusal> {
        if let objects = root.archiveObjects {
            return findInArchive(ArchiveView(objects: objects), marker: marker, idKey: idKey)
        }
        return findPlain(root, marker: marker, idKey: idKey, prefix: [], shownPrefix: [], depth: 0) ?? .failure(notFound(marker))
    }

    /// Finds the entry by a way to its ID (`--match-path`) instead of by the key that holds it: the list is the first array, going
    /// by the sorted keys, in which exactly one element reaches the test item's ID along `subPath`. Says in words why it can't: the
    /// list is a keyed archive (which has no such way to its entries), the test item is in the list but not where `subPath` says,
    /// or more than one entry reaches it there (the codec would refuse the write for that too, and nothing is changed).
    static func find(in root: PlistNode, marker: String, matchPath subPath: PlistKeyPath) -> Result<Found, ProbeRefusal> {
        if root.archiveObjects != nil {
            return .failure(ProbeRefusal(message: "--match-path follows a list that is a property list, and this one is a keyed archive. Use --id-key."))
        }
        return findByPath(root, marker: marker, subPath: subPath, prefix: [], shownPrefix: [], depth: 0) ?? .failure(notFound(marker))
    }

    private static func findByPath(_ node: PlistNode, marker: String, subPath: PlistKeyPath, prefix: PlistKeyPath, shownPrefix: PlistKeyPath,
                                   depth: Int) -> Result<Found, ProbeRefusal>? {
        guard depth <= PlistNode.maximumDepth else { return nil }
        switch node {
        case .dictionary(let entries):
            for key in entries.keys.sorted() {
                let shown = ShownKey.text(key, marker: marker, among: entries.count)
                if let found = findByPath(entries[key]!, marker: marker, subPath: subPath, prefix: prefix + [.key(key)],
                                          shownPrefix: shownPrefix + [.key(shown)], depth: depth + 1) {
                    return found
                }
            }
        case .array(let elements):
            let matching = elements.filter { $0.reaches(marker, along: subPath[...]) }.count
            if matching > 1 {
                return .failure(ProbeRefusal(message: "More than one entry of the list holds the test item's ID where --match-path says, so which one to change isn't known. Nothing was changed."))
            }
            if matching == 1 {
                return .success(Found(prefix: prefix, entry: .matchingPath(path: subPath, value: marker), idKey: nil, shownPrefix: shownPrefix,
                                      shownEntry: .matchingPath(path: ApprovalsLocator.shown(subPath, marker: marker), value: marker), shownIdKey: nil))
            }
            // The entry is further in than this list's elements are (a list in a list, which a path can't follow safely by position),
            // or the test item is in the list and the way given doesn't lead to it.
            if elements.contains(where: { $0.contains(string: marker) }) {
                return .failure(ProbeRefusal(message: "The test item is in the list, but --match-path doesn't lead to its ID. Run approvals-decode to see the entry's keys."))
            }
        default:
            break
        }
        return nil
    }

    private static func notFound(_ marker: String) -> ProbeRefusal {
        ProbeRefusal(message: "The test item (\(marker)) isn't in the list. Open MantelTestItem, and run approvals-decode to see what the list holds.")
    }

    /// The keys of an entry (read as what was archived, in an archive) that hold the test item's ID, with how many keys it has.
    private static func keyNames(in entry: PlistNode, marker: String, view: ArchiveView?) -> (names: [String], keyCount: Int) {
        guard case .dictionary(let entries) = view?.logical(entry) ?? entry else { return ([], 0) }
        let names = entries.keys.filter { key in
            if let view { return view.text(of: entries[key]!) == marker }
            if case .string(let text) = entries[key]! { return text == marker }
            return false
        }
        return (names.sorted(), entries.count)
    }

    private static func choose(_ candidates: [String], idKey: String?, marker: String) -> Result<String, ProbeRefusal> {
        // A key that is data is not said, here as anywhere.
        let said = candidates.map { ShownKey.text($0, marker: marker) }.joined(separator: ", ")
        if let idKey {
            guard candidates.contains(idKey) else {
                return .failure(ProbeRefusal(message: "The entry of the test item has no key called \(idKey) that holds its ID."
                                             + (candidates.isEmpty ? "" : " The keys that do: \(said)."))) }
            return .success(idKey)
        }
        if candidates.count == 1 { return .success(candidates[0]) }
        if candidates.isEmpty { return .failure(notFound(marker)) }
        return .failure(ProbeRefusal(message: "More than one key of the entry holds the test item's ID: \(said). Say which with --id-key."))
    }

    private static func findInArchive(_ view: ArchiveView, marker: String, idKey: String?) -> Result<Found, ProbeRefusal> {
        var candidates: Set<String> = []
        var keyCount = 1
        for object in view.objects {
            let found = keyNames(in: object, marker: marker, view: view)
            candidates.formUnion(found.names)
            if !found.names.isEmpty { keyCount = found.keyCount }
        }
        if view.budget.isExhausted {
            return .failure(ProbeRefusal(message: "The list is too large to search for the test item's entry. Run approvals-decode to see what it holds."))
        }
        return choose(candidates.sorted(), idKey: idKey, marker: marker).map { key in
            let shown = ShownKey.text(key, marker: marker, among: keyCount)
            return Found(prefix: [.key("$objects")], entry: .matching(key: key, value: marker), idKey: key,
                         shownPrefix: [.key("$objects")], shownEntry: .matching(key: shown, value: marker), shownIdKey: shown)
        }
    }

    private static func findPlain(_ node: PlistNode, marker: String, idKey: String?, prefix: PlistKeyPath, shownPrefix: PlistKeyPath,
                                  depth: Int) -> Result<Found, ProbeRefusal>? {
        guard depth <= PlistNode.maximumDepth else { return nil }
        switch node {
        case .dictionary(let entries):
            if entries[marker] != nil {
                return .success(Found(prefix: prefix, entry: .key(marker), idKey: nil, shownPrefix: shownPrefix,
                                      shownEntry: .key(ShownKey.testItem), shownIdKey: nil))
            }
            for key in entries.keys.sorted() {
                let shown = ShownKey.text(key, marker: marker, among: entries.count)
                if let found = findPlain(entries[key]!, marker: marker, idKey: idKey, prefix: prefix + [.key(key)],
                                         shownPrefix: shownPrefix + [.key(shown)], depth: depth + 1) {
                    return found
                }
            }
        case .array(let elements):
            let found = elements.map { keyNames(in: $0, marker: marker, view: nil) }
            let candidates = Set(found.flatMap(\.names))
            if !candidates.isEmpty {
                let keyCount = found.first { !$0.names.isEmpty }?.keyCount ?? 1
                return choose(candidates.sorted(), idKey: idKey, marker: marker).map { key in
                    let shown = ShownKey.text(key, marker: marker, among: keyCount)
                    return Found(prefix: prefix, entry: .matching(key: key, value: marker), idKey: key, shownPrefix: shownPrefix,
                                 shownEntry: .matching(key: shown, value: marker), shownIdKey: shown)
                }
            }
            // No key of an element holds the ID: it is further down in the entry (`--match-path` says the way to it), or the entry is in a
            // list that is in a list, and the way to it is by position, which macOS can change under a probe.
            if elements.contains(where: { $0.contains(string: marker) }) {
                return .failure(ProbeRefusal(message: "The test item is in the list, but no key of an entry holds its ID. If the ID is further down in the entry, say the way to it with --match-path. An entry in a list inside a list can't be followed safely by position."))
            }
        default:
            break
        }
        return nil
    }
}

/// `approvals-flip`: flips one flag of the test item's entry in the "Allow in the Menu Bar" list, sees whether the menu bar follows,
/// and puts it back, `runs` times (1 to 10, 5 by default).
///
/// - **`flag-path`** (required) is where the flag is, from the test item's entry, in the journal's segment form (`k:allowed`, or
///   `k:settings/k:visible`). **`id-key`** names the key of the entry that holds its bundle ID; it is found when exactly one key of the
///   entry holds the test item's ID. **`match-path`** is the other way to find the entry, for a list whose entries hold their ID further
///   down: the way from an entry to the string that is its ID, in the same form with `*` for any element
///   (`k:menuItemLocations/*/k:bundle/k:_0`); the entry is then found by that wherever macOS puts it in the list, and `flag-path` is
///   from it (`k:isAllowed`; a step that finds an entry, `mp:`, is refused there: the entry is found already). Give one of the two,
///   not both. **`codec`** is how the list is kept: `nested` for a blob that is a
///   property list, `flip` for one that is a binary property list or a keyed archive (a place is changed in the bytes, and nothing
///   else is; a keyed archive has no `match-path`), and left out when the value is kept as plain list.
/// - **Each run** writes the flipped flag through the preferences service (`PlistFileAccess.write`, journaled first), polls the test
///   item's frames every 10 ms until they are concealed (`writeToHiddenMs`, 3 s at most), puts the flag back (`undo(path:)`), and
///   polls until they are shown again (`restoreToShownMs`).
/// - **Records** `reencodedIdentical`: whether the list, decoded as a property list and encoded again with nothing changed
///   (`NestedPlistCodec`), is the same bytes, whichever codec is chosen (it isn't for every writer, and never for a keyed archive,
///   which is why `flip` exists); and `restored`: the flag holds what it did.
/// - **With `match-path`** it also records how many entries the list has before the first run (`entryCountBefore`), after each write
///   (`entryCountsAfterWrite`) and after the last run (`entryCountAfter`), and whether the test item's entry still matched exactly once
///   after every write (`matchedOnceAfterEachWrite`): macOS may rewrite the list itself, in another order and with other entries. A
///   list in which the entry doesn't match exactly once is refused before anything is changed.
///
/// Only the test item is touched.
enum ApprovalsFlipProbe {
    static let timeoutMs = 3000.0

    static func run(_ context: ProbeContext, _ recorder: inout ProbeRecorder) async {
        let options = context.options
        guard let flagText = options.string("flag-path") else {
            recorder.fail("Say where the flag is: --flag-path k:name (a place from the test item's entry, as k:…, i:… separated by /).")
            return
        }
        guard let flagPath = KeyPathText.path(from: flagText), !flagPath.isEmpty else {
            recorder.fail("The flag-path isn't in the form k:name or k:name/i:2.")
            return
        }
        guard !flagPath.contains(.anyElement) else {
            recorder.fail("The flag-path is one place, so it can't say * (any element).")
            return
        }
        guard !flagPath.contains(where: { if case .matchingPath = $0 { true } else { false } }) else {
            recorder.fail("The flag-path is a place from the entry, so it can't hold a step that finds an entry (mp:). --match-path finds the entry.")
            return
        }
        var matchPath: PlistKeyPath?
        if let matchText = options.string("match-path") {
            guard options.string("id-key") == nil else {
                recorder.fail("Give --id-key or --match-path, not both.")
                return
            }
            guard let steps = KeyPathText.path(from: matchText), !steps.isEmpty, !steps.contains(where: { if case .matchingPath = $0 { true } else { false } }) else {
                recorder.fail("The match-path isn't in the form k:name/*/k:name: steps k:…, i:… and m:…=… separated by /, and * for any element.")
                return
            }
            matchPath = steps
        }
        let codecID: PlistBlobCodecID
        let codec: (any PlistBlobCodec)?
        switch options.string("codec") {
        case nil: (codecID, codec) = (.none, nil)
        case "nested": (codecID, codec) = (PlistBlobCodecs.nested, NestedPlistCodec())
        case "flip": (codecID, codec) = (PlistBlobCodecs.flip, BinaryPlistFlip())
        default:
            recorder.fail("The codec is nested or flip.")
            return
        }
        guard let url = await GrantedFile.url(of: .controlCenterApprovals, in: context) else {
            recorder.fail(GrantedFile.missing(.controlCenterApprovals))
            return
        }
        let marker = context.fixtureBundleID
        let running = context.platform.runningApps()
        guard let pid = running.first(where: { $0.bundleID == marker })?.pid else {
            recorder.fail("Nothing to watch: \(marker) isn't running. Open MantelTestItem first.")
            return
        }

        // What the list is, and where the test item is in it.
        let value: PlistValue?
        do {
            value = try await context.plist.value(at: [], key: TrackedList.key, in: url)
        } catch {
            recorder.fail("The list couldn't be read: \(error.localizedDescription)")
            return
        }
        guard let value, let (bytes, kind) = TrackedList.bytes(of: value) else {
            recorder.fail("The file has no \(TrackedList.key) list that can be read as a property list.")
            return
        }
        switch (kind, codec == nil) {
        case (.blob, true):
            recorder.fail("\(TrackedList.key) is kept as a blob. Choose how to change it: --codec nested or --codec flip.")
            return
        case (.plainValue, false):
            recorder.fail("\(TrackedList.key) is kept as a plain list, which needs no codec. Leave out --codec.")
            return
        default:
            break
        }
        let root: PlistNode
        do {
            root = try PlistNode.parse(bytes).root
        } catch {
            recorder.fail("The list couldn't be read: \(error.localizedDescription)")
            return
        }
        let located = matchPath.map { ApprovalsLocator.find(in: root, marker: marker, matchPath: $0) }
            ?? ApprovalsLocator.find(in: root, marker: marker, idKey: options.string("id-key"))
        let found: ApprovalsLocator.Found
        switch located {
        case .success(let location): found = location
        case .failure(let refusal):
            recorder.fail(refusal.message)
            return
        }
        let path = found.path + flagPath
        // Where the entries are counted from: the list the entry is in, and the way to the ID that says which of them is the test item's.
        let counting = matchPath.map { Counting(list: found.prefix, way: $0, url: url, codec: codecID, marker: marker) }
        var entriesBefore: Counting.Counts?
        if let counting {
            guard let counts = await counting.read(context) else {
                recorder.fail("The list couldn't be read to count its entries, so nothing was changed.")
                return
            }
            guard counts.matching == 1 else {
                recorder.fail("The test item's entry matches \(counts.matching) times, not once, so nothing was changed.")
                return
            }
            entriesBefore = counts
        }

        // The flag as it is now, and what it would be flipped to.
        let original: PlistValue?
        do {
            original = try await context.plist.value(at: path, key: TrackedList.key, in: url, codec: codecID)
        } catch {
            recorder.fail("The flag couldn't be read: \(error.localizedDescription)")
            return
        }
        let flipped: PlistValue
        switch original {
        case .bool(let flag)?: flipped = .bool(!flag)
        case .integer(let number)? where number == 0 || number == 1: flipped = .integer(1 - number)
        case nil:
            recorder.fail("Nothing is at \(KeyPathText.text(for: found.shownPath + ApprovalsLocator.shown(flagPath, marker: marker))). Run approvals-decode to see the entry's keys.")
            return
        default:
            recorder.fail("What is at \(KeyPathText.text(for: found.shownPath + ApprovalsLocator.shown(flagPath, marker: marker))) isn't a flag (true or false, or 0 or 1).")
            return
        }
        recorder.measure("codec", codecID.rawValue)
        // Keys that are data (a bundle ID, a name) are not said in the report, here as anywhere.
        let shownPath = found.shownPath + ApprovalsLocator.shown(flagPath, marker: marker)
        recorder.measure("entryPath", KeyPathText.text(for: shownPath))
        if let idKey = found.shownIdKey { recorder.measure("idKey", idKey) }
        recorder.measure("wasFlag", original.map(Self.json) ?? .null)
        if kind == .blob {
            // Whether a list that is decoded as a property list and encoded again, with nothing changed, is the same bytes: what
            // `nested` would write for it, whichever codec is chosen (the flip codec changes one place in the bytes, and is always the
            // same bytes for a change to nothing, which says nothing). False for a keyed archive, which `nested` can't read, and for
            // anything that isn't a property list.
            var again: Data?
            do {
                again = try NestedPlistCodec.reencoded(bytes)
            } catch PlistBlobCodecError.tooLarge {
                recorder.note("The list is too large to compare with its own re-encoding (it refers to the same objects so many times that it is more values than Mantel reads), so reencodedIdentical is false.")
            } catch {
                again = nil
            }
            recorder.measure("reencodedIdentical", again == bytes)
            recorder.measure("blobByteCount", bytes.count)
        }

        guard let baseline = context.reader.extrasFrames(ofPID: pid), !baseline.isEmpty else {
            recorder.fail("\(marker) has no items in the menu bar to watch.")
            return
        }
        let runs = options.int("runs", default: 5, range: 1...10)
        recorder.measure("runs", runs)

        var hidden: [Double?] = []
        var shown: [Double?] = []
        var reads: [Double?] = []
        var countsAfterWrite: [Counting.Counts?] = []
        var cutShort = false
        var failed = false
        for run in 1...runs {
            let started = context.clock.now()
            recorder.changeBegan()
            do {
                try await context.plist.write([PathEdit(path: path, value: flipped)], key: TrackedList.key, in: url, strategy: .cfPreferences,
                                              codec: codecID)
                hidden.append(try await RevealLatencyProbe.pollFrames(context, pid: pid, since: started, timeoutMs: timeoutMs, reads: &reads) {
                    !RevealLatencyProbe.matches($0, baseline)
                })
                // After the latency is measured, so that it isn't part of it: macOS may have rewritten the list by now.
                if let counting { countsAfterWrite.append(await counting.read(context)) }
            } catch is CancellationError {
                cutShort = true
                recorder.note("The probe was cut short; the flag was put back.")
            } catch {
                failed = true
                recorder.fail("The flag couldn't be changed in run \(run): \(error.localizedDescription)")
            }

            // Put back, whatever happened above. A change that didn't get as far as the journal has nothing to put back.
            let undone = context.clock.now()
            do {
                try await context.plist.undo(path: path, key: TrackedList.key, in: url)
                recorder.changeUndone()
            } catch {
                recorder.undoFailed("The flag couldn't be put back: \(error.localizedDescription) Mantel puts it back when it next starts.")
                failed = true
            }
            if cutShort || failed { break }
            do {
                shown.append(try await RevealLatencyProbe.pollFrames(context, pid: pid, since: undone, timeoutMs: timeoutMs, reads: &reads) {
                    RevealLatencyProbe.matches($0, baseline)
                })
            } catch {
                cutShort = true
                recorder.note("The probe was cut short after the flag was put back.")
                break
            }
        }

        recorder.measure("writeToHiddenMs", LatencyStats(values: hidden).json())
        recorder.measure("restoreToShownMs", LatencyStats(values: shown).json())
        recorder.measure("pollReadMs", LatencyStats(values: reads).json(includingValues: false))
        let hiddenTimeouts = hidden.filter { $0 == nil }.count
        if hiddenTimeouts > 0 {
            recorder.note("\(hiddenTimeouts) runs saw no change in the menu bar within 3 s of the write.")
        }
        if shown.contains(where: { $0 == nil }) {
            recorder.note("The items weren't shown again within 3 s of the flag being put back in some runs.")
        }
        if let counting, let entriesBefore {
            recorder.measure("entryCountBefore", entriesBefore.entries)
            recorder.measure("entryCountsAfterWrite", .array(countsAfterWrite.map { $0.map { .number(Double($0.entries)) } ?? .null }))
            if !countsAfterWrite.isEmpty {
                recorder.measure("matchedOnceAfterEachWrite", countsAfterWrite.allSatisfy { $0?.matching == 1 })
            }
            if countsAfterWrite.contains(where: { $0 == nil }) {
                recorder.note("The list couldn't be read after some writes, so its entries weren't counted there.")
            }
            let after = await counting.read(context)
            recorder.measure("entryCountAfter", after.map { .number(Double($0.entries)) } ?? .null)
            if let after, after.entries != entriesBefore.entries {
                recorder.note("The list had \(entriesBefore.entries) entries before the probe and has \(after.entries) now: macOS changed it while the probe ran.")
            }
            if countsAfterWrite.contains(where: { ($0?.matching ?? 1) != 1 }) {
                recorder.note("After a write, the test item's entry didn't match exactly once: see entryCountsAfterWrite and matchedOnceAfterEachWrite.")
            }
        }
        // The flag holds what it did.
        let back = try? await context.plist.value(at: path, key: TrackedList.key, in: url, codec: codecID)
        recorder.measure("restored", recorder.restored && back == original)
        if let back, back != original {
            recorder.undoFailed("The flag isn't what it was after the probe. Mantel puts it back when it next starts.")
        }
    }

    private static func json(_ value: PlistValue) -> JSONValue {
        switch value {
        case .bool(let flag): .bool(flag)
        case .integer(let number): .number(Double(number))
        default: .null
        }
    }

    /// How the entries of the list are counted when the test item's entry is found by a way to its ID: how many the list has, and how
    /// many of them reach the test item's ID (`PlistValue.matchCount`), as the list is now.
    private struct Counting {
        struct Counts: Equatable {
            let entries: Int
            let matching: Int
        }

        let list: PlistKeyPath
        let way: PlistKeyPath
        let url: URL
        let codec: PlistBlobCodecID
        let marker: String

        /// Nil where the list can't be read now, or isn't a list.
        func read(_ context: ProbeContext) async -> Counts? {
            guard let value = try? await context.plist.value(at: list, key: TrackedList.key, in: url, codec: codec),
                  case .array(let elements) = value, let matching = value.matchCount(path: way, value: marker) else { return nil }
            return Counts(entries: elements.count, matching: matching)
        }
    }
}
