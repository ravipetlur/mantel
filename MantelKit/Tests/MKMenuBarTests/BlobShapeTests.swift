import Foundation
import MKCommands
import MKCore
import Testing

@testable import MKMenuBar

@Suite("Blob shape", .timeLimit(.minutes(1)))
struct BlobShapeTests {
    private let marker = BlobFixtures.marker

    /// Everything a report says, as the text it would be written as: what the tests look for strings in.
    private func text(_ value: JSONValue) throws -> String {
        try String(decoding: JSONCoding.encoder().encode(value), as: UTF8.self)
    }

    /// Every string in a report, its keys and its values, at any depth.
    private func strings(in value: JSONValue) -> [String] {
        switch value {
        case .string(let text): [text]
        case .array(let values): values.flatMap(strings(in:))
        case .object(let members): members.flatMap { [$0.key] + strings(in: $0.value) }
        case .null, .bool, .number: []
        }
    }

    /// What no report of the input may say: every string value of it, whatever it looks like, and every key that isn't said as it is.
    /// Exempt are the strings that are keys of the input (a dictionary archived as one has its keys as string objects, which are keys
    /// all the same), the system's own class names, and what the test allows. (A string value that is shaped like an identifier,
    /// `HomeNetwork`, is not exempt.)
    private func nothingOfTheInput(_ blob: Data, in report: JSONValue, allowing allowed: Set<String> = [],
                                   sourceLocation: SourceLocation = #_sourceLocation) throws {
        let (root, _) = try PlistNode.parse(blob)
        let view = root.archiveObjects.map { ArchiveView(objects: $0) }
        var values: Set<String> = []
        var keys: Set<String> = []
        var hiddenKeys: Set<String> = []
        func collect(_ node: PlistNode, depth: Int) {
            guard depth < 20 else { return }
            switch node {
            case .string(let text): values.insert(text)
            case .array(let elements): elements.forEach { collect($0, depth: depth + 1) }
            case .dictionary(let entries):
                for (key, value) in entries {
                    keys.insert(key)
                    if !ShownKey.isVerbatim(key, among: entries.count) { hiddenKeys.insert(key) }
                    collect(value, depth: depth + 1)
                }
                // The keys of a dictionary that was archived as one.
                if let view, case .dictionary(let archived)? = view.logical(node) {
                    for key in archived.keys {
                        keys.insert(key)
                        if !ShownKey.isVerbatim(key, among: archived.count) { hiddenKeys.insert(key) }
                    }
                }
            default: break
            }
        }
        collect(root, depth: 0)
        var forbidden = values.subtracting(keys).union(hiddenKeys)
        forbidden = forbidden.filter { !$0.hasPrefix("NS") && !$0.hasPrefix("__NS") && !allowed.contains($0) && !$0.isEmpty }
        #expect(!forbidden.isEmpty, "the input has strings to look for", sourceLocation: sourceLocation)
        let said = strings(in: report)
        for text in forbidden {
            #expect(!said.contains { $0.contains(text) }, "\(text) is said", sourceLocation: sourceLocation)
        }
    }

    private func object(_ value: JSONValue) throws -> [String: JSONValue] {
        guard case .object(let members) = value else {
            Issue.record("an object was expected")
            return [:]
        }
        return members
    }

    @Test func reportsTypesNotValues() throws {
        let blob = BlobFixtures.plainEntries([(marker, true, 7), (BlobFixtures.secretID, false, 9)])
        let report = try object(BlobShape.describe(blob, marker: marker))

        #expect(report["byteCount"] == .number(Double(blob.count)))
        #expect(report["magic"] == .string("62706c6973743030"), "bplist00")
        #expect(report["parsesAsPropertyList"] == .bool(true))
        #expect(report["plistFormat"] == .string("binary"))
        #expect(report["isKeyedArchive"] == .bool(false))
        #expect(report["entryCount"] == .number(1), "the top-level dictionary has one key, apps")

        // The structure: key names and the types of what is under them.
        let structureValue = try #require(report["structure"])
        let structure = try object(structureValue)
        let topEntriesValue = try #require(structure["entries"])
        let topEntries = try object(topEntriesValue)
        let appsValue = try #require(topEntries["apps"])
        let apps = try object(appsValue)
        #expect(apps["type"] == .string("array"))
        #expect(apps["count"] == .number(2))
        let firstValue = try #require(apps["first"])
        let first = try object(firstValue)
        let entriesValue = try #require(first["entries"])
        let entries = try object(entriesValue)
        #expect(entries["allowed"] == .string("bool"))
        #expect(entries["order"] == .string("integer"))
        #expect(entries["bundleID"] == .string("string"))
        #expect(entries["note"] == .string("string"))

        // No string value of the list, and no number or flag either, is anywhere in what is said.
        let said = try text(.object(report))
        #expect(!said.contains(BlobFixtures.secretText))
        #expect(!said.contains(BlobFixtures.secretID))
        try nothingOfTheInput(blob, in: .object(report))
        #expect(!said.contains(BlobFixtures.secretLabel), "a string value that looks like a name is not said either")
        #expect(entries["ssid"] == .string("string"))
        #expect(!said.contains(marker), "the test item's ID is looked for, and is not said")
        #expect(topEntries["apps"] != nil)
        #expect(structure["keyCount"] == .number(1))
        #expect(structure["redactedKeyCount"] == .number(0))
    }

    @Test func aKeyedArchiveSaysItsClassesAndSaysUidForItsReferences() throws {
        let blob = BlobFixtures.archive([(marker, true, 1), (BlobFixtures.secretID, false, 2)])
        let report = try object(BlobShape.describe(blob, marker: marker))
        #expect(report["isKeyedArchive"] == .bool(true))
        #expect(report["plistFormat"] == .string("binary"))
        guard case .array(let classes)? = report["archiveClasses"] else {
            Issue.record("the classes are a list")
            return
        }
        #expect(classes.contains(.string("NSArray")))
        #expect(classes.contains(.string("NSObject")))
        #expect(classes.contains(.string("‹class›")), "the class that was archived is the test's own, and is not said")
        #expect(!classes.contains { if case .string(let name) = $0 { name.hasSuffix("ArchivedEntry") } else { false } })
        // The entries of the archive are objects: its count is the objects it holds.
        if case .number(let count)? = report["entryCount"] { #expect(count >= 6) } else { Issue.record("an entry count") }

        // Where an entry refers to another object, the type is said to be uid.
        let said = try text(.object(report))
        #expect(said.contains("\"uid\""))
        #expect(said.contains("\"$objects\""), "keys that are part of the format are said as they are")
        #expect(!said.contains(BlobFixtures.secretID))
        try nothingOfTheInput(blob, in: .object(report))
    }

    @Test func customArchiveClassNamesAreRedacted() throws {
        let blob = BlobFixtures.archive([(marker, true, 1)])
        let report = try object(BlobShape.describe(blob, marker: marker))
        guard case .array(let classes)? = report["archiveClasses"] else {
            Issue.record("the classes are a list")
            return
        }
        let names = classes.compactMap { if case .string(let name) = $0 { name } else { nil } }
        #expect(names.filter { $0 != "‹class›" }.allSatisfy { $0.hasPrefix("NS") || $0.hasPrefix("__NS") }, "\(names)")
        #expect(names.filter { $0 == "‹class›" }.count == 1, "one for the one class of the archive that isn't the system's")
        #expect(!(try text(.object(report))).contains("ArchivedEntry"))
        // The classes of a dictionary archived as one are all the system's.
        let system = try object(BlobShape.describe(BlobFixtures.dictionaryArchive([(marker, true, 1)]), marker: marker))
        guard case .array(let systemClasses)? = system["archiveClasses"] else {
            Issue.record("the classes are a list")
            return
        }
        #expect(!systemClasses.contains(.string("‹class›")))
        #expect(systemClasses.contains(.string("NSDictionary")))
    }

    @Test func markerFoundWithoutReportingOthers() throws {
        let blob = BlobFixtures.archive([(BlobFixtures.secretID, true, 1), (marker, false, 2), ("com.example.third", true, 3)])
        let report = try object(BlobShape.describe(blob, marker: marker))
        #expect(report["markerFound"] == .bool(true))

        // The entry of the test item: its keys and the types of what they hold.
        let entryValue = try #require(report["markerEntryShape"])
        let entry = try object(entryValue)
        let keysValue = try #require(entry["entries"])
        let keys = try object(keysValue)
        #expect(keys["bundleID"] == .string("string"), "the ID is held by reference, which is followed to its type")
        #expect(keys["allowed"] == .string("bool"))
        #expect(keys["order"] == .string("integer"))

        let said = try text(.object(report))
        #expect(!said.contains(BlobFixtures.secretID), "another app's ID is never said")
        #expect(!said.contains("com.example.third"))
        try nothingOfTheInput(blob, in: .object(report))
        #expect(!said.contains(marker), "the match is a yes or a no: the string that matched is not said")
        // The test item's own ID is Mantel's, but a match is only ever a yes or a no.
        let absent = try object(BlobShape.describe(BlobFixtures.archive([(BlobFixtures.secretID, true, 1)]), marker: marker))
        #expect(absent["markerFound"] == .bool(false))
        #expect(absent["markerEntryShape"] == .null)
    }

    @Test func bundleIDLikeKeysAreRedacted() throws {
        // The approvals could be a dictionary keyed by bundle ID: those keys are other apps' IDs.
        let keyed: [String: Any] = ["com.example.one": ["allowed": true], "com.example.two": ["allowed": false]]
        let blob = try PropertyListSerialization.data(fromPropertyList: keyed, format: .binary, options: 0)
        let report = try object(BlobShape.describe(blob, marker: marker))
        let said = try text(.object(report))

        #expect(!said.contains("com.example"), "no part of an app's ID is said")
        let structureValue = try #require(report["structure"])
        let structure = try object(structureValue)
        #expect(structure["keyCount"] == .number(2))
        #expect(structure["redactedKeyCount"] == .number(2))
        let entriesValue = try #require(structure["entries"])
        let entries = try object(entriesValue)
        #expect(Set(entries.keys) == ["‹key›"], "what is under the keys that aren't said is said once, with how many there are")
        let groupValue = try #require(entries["‹key›"])
        let group = try object(groupValue)
        #expect(group["count"] == .number(2))
        #expect(group["valueTypes"] == .array([.string("dictionary")]))
        let firstValue = try #require(group["first"])
        let first = try object(firstValue)
        #expect(try object(try #require(first["entries"]))["allowed"] == .string("bool"))
        #expect(report["markerFound"] == .bool(false))
        try nothingOfTheInput(blob, in: .object(report))
    }

    @Test func theTestItemsKeyIsSaidAsTheTestItemAndItsEntryIsDescribed() throws {
        let keyed: [String: Any] = [BlobFixtures.secretID: ["allowed": true], marker: ["allowed": false], "com.example.third": ["allowed": true]]
        let blob = try PropertyListSerialization.data(fromPropertyList: keyed, format: .binary, options: 0)
        let report = try object(BlobShape.describe(blob, marker: marker))
        let said = try text(.object(report))

        #expect(!said.contains(marker), "even the test item's ID is not said as a key")
        #expect(said.contains("‹test item›"))
        #expect(report["markerFound"] == .bool(true))
        let structureValue = try #require(report["structure"])
        let structure = try object(structureValue)
        #expect(structure["keyCount"] == .number(3))
        #expect(structure["redactedKeyCount"] == .number(2), "the test item's key is not one of the keys that were hidden")
        let entryValue = try #require(report["markerEntryShape"])
        let entry = try object(entryValue)
        let entriesValue = try #require(entry["entries"])
        #expect(try object(entriesValue)["allowed"] == .string("bool"))
        try nothingOfTheInput(blob, in: .object(report))
        // The same each time.
        #expect(try text(.object(try object(BlobShape.describe(blob, marker: marker)))) == said)
    }

    @Test func identifierKeysStay() throws {
        let longest = String(repeating: "a", count: 40)
        let tooLong = String(repeating: "a", count: 41)
        let kept: [String] = ["allowed", "bundleIdentifier", "$objects", "_flags", "$class", "A1_b2$", longest, "NS.keys", "NS.objects", "$classname",
                              "$classes", "$archiver", "$version", "$top"]
        let hidden: [String] = ["com.example.one", "a.b", "path/to", "Home Wi-Fi", "bundle-id", "1abc", "", tooLong, "caf\u{e9}", "NS.other", "$a.b"]
        // Dictionaries of 4 keys each (and 7 of them in the one above), so that it is the key and not the number of them that decides.
        func groups(_ keys: [String], prefix: String) -> [String: Any] {
            var result: [String: Any] = [:]
            for (number, start) in stride(from: 0, to: keys.count, by: 4).enumerated() {
                result["\(prefix)\(number)"] = Dictionary(uniqueKeysWithValues: keys[start..<min(start + 4, keys.count)].map { ($0, true as Any) })
            }
            return result
        }
        let blob = try PropertyListSerialization.data(fromPropertyList: groups(kept, prefix: "kept").merging(groups(hidden, prefix: "hidden")) { $1 },
                                                      format: .binary, options: 0)

        let report = try object(BlobShape.describe(blob, marker: marker))
        let said = try text(.object(report))
        for key in kept { #expect(said.contains("\"\(key)\""), "\(key) is said") }
        for key in hidden where key.count > 3 { #expect(!said.contains(key), "\(key) is not said") }
        #expect(!said.contains(tooLong))
        for key in kept { #expect(ShownKey.isVerbatim(key, among: 4)) }
        for key in hidden { #expect(!ShownKey.isVerbatim(key, among: 4)) }

        // What each dictionary says of itself: the kept ones as they are, the others as `‹key›`.
        let structureValue = try #require(report["structure"])
        let structure = try object(structureValue)
        #expect(structure["keyCount"] == .number(7))
        #expect(structure["redactedKeyCount"] == .number(0), "the groups' own names are identifiers")
        let topValue = try #require(structure["entries"])
        let top = try object(topValue)
        let keptValue = try #require(top["kept0"])
        let hiddenValue = try #require(top["hidden0"])
        let keptGroup = try object(keptValue), hiddenGroup = try object(hiddenValue)
        #expect(keptGroup["redactedKeyCount"] == .number(0))
        #expect(hiddenGroup["keyCount"] == .number(4))
        #expect(hiddenGroup["redactedKeyCount"] == .number(4))
    }

    @Test func manyKeyedDictionaryRedactsEvenIdentifierKeys() throws {
        // A list of apps or networks keyed by names that have no dot in them: with more than 8 keys it is keyed by data.
        let names = ["Dropbox", "Safari", "Slack", "HomeNetwork", "Office", "Garage", "Cafe", "Library", "Studio"]
        var many: [String: Any] = [:]
        for name in names { many[name] = ["allowed": true] }
        many[marker] = ["allowed": false]
        let blob = try PropertyListSerialization.data(fromPropertyList: many, format: .binary, options: 0)
        let report = try object(BlobShape.describe(blob, marker: marker))
        let said = try text(.object(report))

        for name in names { #expect(!said.contains(name), "\(name) is not said") }
        let structureValue = try #require(report["structure"])
        let structure = try object(structureValue)
        #expect(structure["keyCount"] == .number(10))
        #expect(structure["redactedKeyCount"] == .number(9), "the test item's key is the one that is not hidden")
        let entriesValue = try #require(structure["entries"])
        let entries = try object(entriesValue)
        #expect(Set(entries.keys) == ["‹key›", "‹test item›"])
        try nothingOfTheInput(blob, in: .object(report))

        // The same keys in a dictionary of 8 are said: it is no list of them.
        var few: [String: Any] = [:]
        for name in names.prefix(8) { few[name] = true }
        let small = try PropertyListSerialization.data(fromPropertyList: few, format: .binary, options: 0)
        let smallReport = try object(BlobShape.describe(small, marker: marker))
        let smallStructureValue = try #require(smallReport["structure"])
        let smallStructure = try object(smallStructureValue)
        let smallEntriesValue = try #require(smallStructure["entries"])
        #expect(Set(try object(smallEntriesValue).keys) == Set(names.prefix(8)))

        // And the leaves of the many-keyed one: another app's flag has no value and no name, the test item's has both.
        let leaves = try #require(BlobShape.leaves(of: blob, marker: marker))
        #expect(leaves["/k:‹key›/k:allowed"] == BlobShape.Leaf(type: "bool", value: nil, count: 9))
        #expect(leaves["/k:‹test item›/k:allowed"] == BlobShape.Leaf(type: "bool", value: .bool(false)))
        // The keys of a keyed archive are said however many there are.
        let archive = BlobFixtures.archive([(marker, true, 1)])
        let archiveSaid = try text(BlobShape.describe(archive, marker: marker))
        #expect(archiveSaid.contains("\"$objects\"") && archiveSaid.contains("\"$top\"") && archiveSaid.contains("\"$archiver\""))
    }

    // MARK: The work a report may do

    @Test(.timeLimit(.minutes(1)))
    func sharedArchiveGraphIsBoundedByTheBudget() throws {
        // 8 keys that each lead to one instance of the level below, 6 levels: a tree of 8^6 dictionaries once each reference is followed.
        let blob = BlobFixtures.sharedGraphArchive(width: 8, levels: 6)
        #expect(blob.count < 5000)
        let report = try object(BlobShape.describe(blob, marker: marker))

        #expect(report["truncated"] == .bool(true))
        #expect(report["markerFound"] == .bool(true), "what was gathered before the limit is kept")
        let entryValue = try #require(report["markerEntryShape"])
        let entry = try object(entryValue)
        #expect(entry["keyCount"] == .number(3))
        let said = try text(.object(report))
        #expect(said.contains(BlobShape.truncatedMarker), "the report says where it stopped")
        #expect(!said.contains(marker) && !said.contains("com.example"))
        // However big the tree, what is said of it is not: every visit costs, so what is said is bounded by the work.
        #expect(strings(in: .object(report)).count < 400_000)

        // The leaves stop the same way, with the place where they stopped as a leaf, and keep the ones before it.
        let walk = try #require(BlobShape.leavesWalk(of: blob, marker: marker))
        #expect(walk.truncated)
        #expect(walk.leaves.values.contains { $0.type == BlobShape.truncatedMarker })
        #expect(walk.leaves["/k:$top/k:root/m:bundleID=\(marker)/k:allowed"] == BlobShape.Leaf(type: "bool", value: .bool(true)))
        #expect(walk.leaves.count < 400_000)
    }

    @Test(.timeLimit(.minutes(1)))
    func largeSharedDictionaryLeavesAreBounded() throws {
        // One dictionary of 4,000 keys that 100 entries hold: 400,000 places when each is followed, past the work a report may do.
        let blob = BlobFixtures.sharedBigDictionaryArchive(keys: 4000, holders: 100)
        let walk = try #require(BlobShape.leavesWalk(of: blob, marker: marker))
        #expect(walk.truncated)
        #expect(walk.leaves.values.contains { $0.type == BlobShape.truncatedMarker })
        #expect(!walk.leaves.isEmpty)
        // The test item's entry is the first, and has what was gathered of it.
        #expect(walk.leaves["/k:$top/k:root/m:bundleID=\(marker)/k:settings/k:‹key›"]?.type == "integer")

        let report = try object(BlobShape.describe(blob, marker: marker))
        #expect(report["truncated"] != nil)
        try nothingOfTheInput(blob, in: .object(report))
    }

    @Test func aListThatFitsTheBudgetIsNotTruncated() throws {
        for blob in [BlobFixtures.plainEntries([(marker, true, 1), ("com.example.one", false, 2)]), BlobFixtures.archive([(marker, true, 1)]),
                     BlobFixtures.dictionaryArchive([(marker, true, 1), ("com.example.one", false, 2)]),
                     BlobFixtures.archive(withSettings: [(marker, false, true), ("com.example.one", false, false)], shared: true),
                     BlobFixtures.sharedGraphArchive(width: 2, levels: 3)] {
            let report = try object(BlobShape.describe(blob, marker: marker))
            #expect(report["truncated"] == .bool(false))
            #expect(!(try text(.object(report))).contains(BlobShape.truncatedMarker))
            let walk = try #require(BlobShape.leavesWalk(of: blob, marker: marker))
            #expect(!walk.truncated)
            #expect(!walk.leaves.values.contains { $0.type == BlobShape.truncatedMarker })
        }
        #expect(try object(BlobShape.describe(Data([0xFF, 0x01]), marker: marker))["truncated"] == .bool(false))
    }

    @Test func aBlobThatIsTooLargeAsATreeIsTruncatedBeforeItIsReported() throws {
        let report = try object(BlobShape.describe(BlobFixtures.deeplySharedPlist(levels: 24), marker: marker))
        #expect(report["truncated"] == .bool(true))
        #expect(report["parsesAsPropertyList"] == .bool(true))
        let walk = try #require(BlobShape.leavesWalk(of: BlobFixtures.deeplySharedPlist(levels: 24), marker: marker))
        #expect(walk.truncated)
    }

    @Test func theWorkBudgetSpendsAndRunsOutForGood() {
        let budget = WorkBudget(10)
        #expect(budget.spend(4))
        #expect(budget.spend())
        #expect(budget.remaining == 5)
        #expect(!budget.spend(6), "more than is left")
        #expect(budget.isExhausted)
        #expect(!budget.spend(), "and nothing after it, however small")
        #expect(budget.remaining == 0)
    }

    // MARK: A keyed archive of dictionaries

    @Test func markerEntryShapeIsPresentForAnArchivedDictionary() throws {
        let blob = BlobFixtures.dictionaryArchive([(marker, true, 1), (BlobFixtures.secretID, false, 2)])
        let report = try object(BlobShape.describe(blob, marker: marker))
        #expect(report["markerFound"] == .bool(true))
        // The entry is described as the dictionary it was archived from, its values by what they lead to.
        let entryValue = try #require(report["markerEntryShape"], "the entry is found through NS.keys and NS.objects")
        let entry = try object(entryValue)
        let entriesValue = try #require(entry["entries"])
        let entries = try object(entriesValue)
        #expect(entries["bundleID"] == .string("string"))
        #expect(entries["allowed"] == .string("bool"))
        #expect(entries["order"] == .string("integer"))
        #expect(entries["label"] == .string("string"))
        #expect(entry["keyCount"] == .number(4))
        let said = try text(.object(report))
        #expect(!said.contains(BlobFixtures.secretID) && !said.contains(BlobFixtures.secretLabel))
        try nothingOfTheInput(blob, in: .object(report))
    }

    @Test(arguments: [true, false])
    func aFlippedFlagInAnArchiveIsOneChangedLeafUnderTheTestItemsPath(custom: Bool) throws {
        func archive(_ allowed: Bool) -> Data {
            let entries: [BlobFixtures.Entry] = [(marker, allowed, 1), ("com.example.one", false, 2), ("com.example.two", true, 3)]
            return custom ? BlobFixtures.archive(entries) : BlobFixtures.dictionaryArchive(entries)
        }
        let before = archive(true), after = archive(false)
        let baseline = try #require(BlobShape.leaves(of: before, marker: marker))
        let current = try #require(BlobShape.leaves(of: after, marker: marker))

        // The test item's entry, found by the string its `bundleID` leads to, with its flag and number by value.
        let path = "/k:$top/k:root/m:bundleID=\(marker)"
        #expect(baseline["\(path)/k:allowed"] == BlobShape.Leaf(type: "bool", value: .bool(true)))
        #expect(baseline["\(path)/k:order"] == BlobShape.Leaf(type: "integer", value: .number(1)))
        #expect(baseline["\(path)/k:bundleID"] == BlobShape.Leaf(type: "string", value: nil), "a reference to a string is a string, and has no value")
        // Another entry is by its place in the list.
        #expect(baseline["/k:$top/k:root/i:1/k:allowed"]?.value == .bool(false))

        // The archive is written again with the flag changed, and its objects in another order: that is the one leaf that changed.
        let changed = BlobShape.changes(from: baseline, to: current)
        #expect(changed == [.object(["path": .string("\(path)/k:allowed"), "wasType": .string("bool"), "nowType": .string("bool"),
                                     "was": .bool(true), "now": .bool(false)])], "\(changed)")
        try nothingOfTheInput(before, in: .array(baseline.keys.sorted().map(JSONValue.string)), allowing: [marker])
        try nothingOfTheInput(before, in: .array(changed), allowing: [marker])
    }

    @Test func somethingThatIsNotAPropertyListSaysSoAndNothingElse() throws {
        let report = try object(BlobShape.describe(Data("plain text".utf8), marker: marker))
        #expect(report["parsesAsPropertyList"] == .bool(false))
        #expect(report["isKeyedArchive"] == .bool(false))
        #expect(report["markerFound"] == .bool(false))
        #expect(report["byteCount"] == .number(10))
        #expect(report["structure"] == nil)
        #expect(try text(.object(report)).contains("plain text") == false)
    }

    @Test func anXMLListSaysItsFormat() throws {
        let report = try object(BlobShape.describe(BlobFixtures.plainXML(), marker: marker))
        #expect(report["plistFormat"] == .string("xml"))
        #expect(report["parsesAsPropertyList"] == .bool(true))
    }

    // MARK: Leaves, for the baseline and the comparison

    @Test func compareListsChangedBooleanLeaves() throws {
        let before = BlobFixtures.plainEntries([(marker, true, 1), (BlobFixtures.secretID, true, 2)])
        let after = BlobFixtures.plainEntries([(marker, false, 1), (BlobFixtures.secretID, true, 2)])
        let baseline = try #require(BlobShape.leaves(of: before, marker: marker))
        let current = try #require(BlobShape.leaves(of: after, marker: marker))
        // Every leaf is kept with its type, and a flag or number with its value, by a path in the journal's segment form.
        let path = "/k:apps/m:bundleID=\(marker)/k:allowed"
        #expect(baseline[path] == BlobShape.Leaf(type: "bool", value: .bool(true)))
        #expect(baseline["/k:apps/m:bundleID=\(marker)/k:order"] == BlobShape.Leaf(type: "integer", value: .number(1)))
        #expect(baseline["/k:apps/m:bundleID=\(marker)/k:note"] == BlobShape.Leaf(type: "string", value: nil), "a string has a type and no value")
        #expect(baseline["/k:apps/i:1/k:allowed"] == BlobShape.Leaf(type: "bool", value: .bool(true)), "another app's entry is by position")

        let changed = BlobShape.changes(from: baseline, to: current)
        #expect(changed == [.object(["path": .string(path), "wasType": .string("bool"), "nowType": .string("bool"),
                                     "was": .bool(true), "now": .bool(false)])])
        #expect(BlobShape.changes(from: baseline, to: baseline).isEmpty)

        // No string, and no other app's ID, is in a leaf or a path.
        let said = try text(.array(baseline.keys.sorted().map(JSONValue.string)))
        #expect(!said.contains(BlobFixtures.secretID))
        #expect(!said.contains(BlobFixtures.secretText))
        try nothingOfTheInput(before, in: .array(baseline.keys.sorted().map(JSONValue.string)), allowing: [marker])
        try nothingOfTheInput(before, in: .array(changed), allowing: [marker])
    }

    @Test func compareRedactsAppKeyedSteps() throws {
        // A list keyed by bundle ID: another app's entry has its type and no value, its key is `‹key›`, and its flag changing is only
        // seen as the count of leaves of that kind; the test item's entry, which can be told by its ID, has its value.
        func list(testItem: Bool, one: Bool) throws -> Data {
            let keyed: [String: Any] = [marker: ["allowed": testItem, "order": 1], "com.example.one": ["allowed": one, "order": 2],
                                        "com.example.two": ["allowed": true, "order": 3]]
            return try PropertyListSerialization.data(fromPropertyList: keyed, format: .binary, options: 0)
        }
        let before = try list(testItem: true, one: true)
        let after = try list(testItem: false, one: false)
        let baseline = try #require(BlobShape.leaves(of: before, marker: marker))
        let current = try #require(BlobShape.leaves(of: after, marker: marker))

        #expect(baseline["/k:‹test item›/k:allowed"] == BlobShape.Leaf(type: "bool", value: .bool(true)))
        #expect(baseline["/k:‹test item›/k:order"] == BlobShape.Leaf(type: "integer", value: .number(1)))
        // The other two apps' leaves share a path, and say their type and how many there are.
        #expect(baseline["/k:‹key›/k:allowed"] == BlobShape.Leaf(type: "bool", value: nil, count: 2))
        #expect(baseline["/k:‹key›/k:order"] == BlobShape.Leaf(type: "integer", value: nil, count: 2), "not even a number is said there")
        #expect(baseline.count == 4)

        let changed = BlobShape.changes(from: baseline, to: current)
        #expect(changed == [.object(["path": .string("/k:‹test item›/k:allowed"), "wasType": .string("bool"), "nowType": .string("bool"),
                                     "was": .bool(true), "now": .bool(false)])],
                "another app's flag changing is not seen, and says nothing of it")
        let said = try text(.array(changed))
        #expect(!said.contains("com.example"))
        #expect(!said.contains(marker), "the test item's key is not its ID in a path")
        try nothingOfTheInput(before, in: .array(baseline.keys.sorted().map(JSONValue.string)))
        try nothingOfTheInput(before, in: .array(changed))

        // An app that appears under a key that isn't said is a change in how many there are.
        let more = try PropertyListSerialization.data(fromPropertyList: [marker: ["allowed": true, "order": 1], "com.example.one": ["allowed": true, "order": 2],
                                                                        "com.example.two": ["allowed": true, "order": 3], "com.example.three": ["allowed": true, "order": 4]] as [String: Any],
                                                      format: .binary, options: 0)
        let grown = BlobShape.changes(from: baseline, to: try #require(BlobShape.leaves(of: more, marker: marker)))
        #expect(grown.count == 2)
        #expect(grown.contains(.object(["path": .string("/k:‹key›/k:allowed"), "wasType": .string("bool"), "nowType": .string("bool"),
                                        "wasCount": .number(2), "nowCount": .number(3)])))
        #expect(!(try text(.array(grown))).contains("com.example"))
    }

    @Test func aStepInAnArrayThatHoldsAKeyThatIsDataIsNotSaid() throws {
        // The test item's entry is found by an ID held under a key that is not an identifier: the key is `‹key›`, and nothing below the
        // entry has its value said.
        let entries: [[String: Any]] = [["com.example.id": marker, "allowed": true], ["com.example.id": "com.example.other", "allowed": false]]
        let blob = try PropertyListSerialization.data(fromPropertyList: ["apps": entries], format: .binary, options: 0)
        let leaves = try #require(BlobShape.leaves(of: blob, marker: marker))
        #expect(leaves["/k:apps/m:‹key›=\(marker)/k:allowed"] == BlobShape.Leaf(type: "bool", value: nil))
        #expect(!(try text(.array(leaves.keys.sorted().map(JSONValue.string)))).contains("com.example.other"))
        #expect(!(try text(.array(leaves.keys.sorted().map(JSONValue.string)))).contains("com.example.id"), "the key that is data isn't said")
    }

    @Test func aLeafThatAppearedOrWentIsSaidToo() throws {
        let one = try #require(BlobShape.leaves(of: BlobFixtures.plainEntries([(marker, true, 1)]), marker: marker))
        let two = try #require(BlobShape.leaves(of: BlobFixtures.plainEntries([(marker, true, 1), ("com.example.third", false, 5)]), marker: marker))
        let appeared = BlobShape.changes(from: one, to: two)
        #expect(appeared.count == 5, "the five leaves of the new entry")
        let gone = BlobShape.changes(from: two, to: one)
        #expect(gone.count == 5)
        let flag = gone.first { if case .object(let o) = $0, o["path"] == .string("/k:apps/i:1/k:allowed") { true } else { false } }
        #expect(flag == .object(["path": .string("/k:apps/i:1/k:allowed"), "wasType": .string("bool"), "nowType": .null, "was": .bool(false)]))
    }

    @Test func leavesOfAnArchiveAreByTheirPlaceInTheListAndNotInTheArchive() throws {
        let before = BlobFixtures.archive([(marker, true, 1), ("com.example.third", false, 2)])
        let after = BlobFixtures.archive([(marker, false, 1), ("com.example.third", false, 2)])
        let baseline = try #require(BlobShape.leaves(of: before, marker: marker))
        let current = try #require(BlobShape.leaves(of: after, marker: marker))
        let path = "/k:$top/k:root/m:bundleID=\(marker)/k:allowed"
        #expect(baseline[path]?.value == .bool(true), "the test item's entry, found by the string its reference leads to")
        #expect(!baseline.keys.contains { $0.contains("$objects") }, "a place in the archive's own list moves when it is written again")
        let changed = BlobShape.changes(from: baseline, to: current)
        #expect(changed.count == 1)
        guard case .object(let record)? = changed.first else {
            Issue.record("a changed leaf is an object")
            return
        }
        #expect(record["path"] == .string(path))
        #expect(try text(.array(baseline.keys.sorted().map(JSONValue.string))).contains("com.example.third") == false)
    }

    @Test func somethingThatIsNotAPropertyListHasNoLeaves() {
        #expect(BlobShape.leaves(of: Data([0xFF, 0x00, 0x01, 0x02]), marker: marker) == nil)
    }

    // MARK: A list whose entries hold their app's ID some levels down

    /// The object under `key` of an object (a report, a shape).
    private func member(_ key: String, of members: [String: JSONValue]) throws -> [String: JSONValue] {
        let found = try #require(members[key], "\(key)")
        return try object(found)
    }

    private func approvals(testItem: Bool = true, order: [Int] = [0, 1, 2, 3, 4]) -> Data {
        let entries = BlobFixtures.approvals(testItem: testItem)
        return BlobFixtures.approvalsList(order.map { entries[$0] })
    }

    /// The path the test item's entry has, whatever place it is in.
    private var entryPath: String { "/mp:k:menuItemLocations,*,k:bundle,k:_0=\(marker)" }

    @Test func markerEntryShapeIsTheContainingEntry() throws {
        let blob = approvals()
        let report = try object(BlobShape.describe(blob, marker: marker))

        #expect(report["markerFound"] == .bool(true))
        // The shape of the whole entry of the test item, not of the dictionary its ID is in.
        let entry = try member("markerEntryShape", of: report)
        #expect(entry["type"] == .string("dictionary"))
        #expect(entry["keyCount"] == .number(2))
        let entries = try member("entries", of: entry)
        #expect(Set(entries.keys) == ["isAllowed", "menuItemLocations"])
        #expect(entries["isAllowed"] == .string("bool"))
        let locations = try member("menuItemLocations", of: entries)
        #expect(locations["type"] == .string("array"))
        #expect(locations["count"] == .number(1))
        #expect(entries["bundle"] == nil && entries["_0"] == nil, "not the inner dictionary")
        // The first place of the entry is described by its keys and types, never by what it says.
        let place = try member("first", of: locations)
        #expect(try member("entries", of: place)["bundle"] != nil)

        let said = try text(.object(report))
        #expect(!said.contains(marker), "the match is a yes or a no")
        #expect(!said.contains("com.example.one") && !said.contains("exampled"))
        try nothingOfTheInput(blob, in: .object(report))

        // The same wherever the entry is: first, or last.
        for order in [[2, 0, 1, 3, 4], [0, 1, 3, 4, 2]] {
            let other = try object(BlobShape.describe(approvals(order: order), marker: marker))
            #expect(other["markerEntryShape"] == report["markerEntryShape"], "\(order)")
        }
        // Where the test item's ID is held under a key of the entry itself, the entry is the same thing it always was.
        let direct = try object(BlobShape.describe(BlobFixtures.plainEntries([(marker, true, 1), (BlobFixtures.secretID, false, 2)]), marker: marker))
        let directEntry = try member("markerEntryShape", of: direct)
        #expect(try member("entries", of: directEntry)["bundleID"] == .string("string"))
        // And not in the list at all: nothing.
        let absent = try object(BlobShape.describe(BlobFixtures.approvalsList([BlobFixtures.Approval("com.example.one", allowed: true)]), marker: marker))
        #expect(absent["markerEntryShape"] == .null && absent["markerFound"] == .bool(false))
    }

    @Test func compareShowsOneLeafUnderMatchingPathDespiteReorder() throws {
        let before = approvals(testItem: true)
        // macOS writes the list again with the switch off, and its entries in another order.
        let after = approvals(testItem: false, order: [4, 3, 1, 2, 0])
        let baseline = try #require(BlobShape.leaves(of: before, marker: marker))
        let current = try #require(BlobShape.leaves(of: after, marker: marker))

        // The test item's entry has one path, and its flag has a value there.
        #expect(baseline["\(entryPath)/k:isAllowed"] == BlobShape.Leaf(type: "bool", value: .bool(true)))
        #expect(current["\(entryPath)/k:isAllowed"] == BlobShape.Leaf(type: "bool", value: .bool(false)))
        #expect(baseline["\(entryPath)/k:menuItemLocations/mp:k:bundle,k:_0=\(marker)/k:bundle/k:_0"] == BlobShape.Leaf(type: "string", value: nil),
                "a place of the entry is found the same way, and a string has no value")
        // The other entries are counted under one path, with their types and no value: where they are in the list is not what they are.
        #expect(baseline["/*/k:isAllowed"] == BlobShape.Leaf(type: "bool", value: nil, count: 4))
        #expect(!baseline.keys.contains { $0.hasPrefix("/i:") }, "no entry is by its position")

        let changed = BlobShape.changes(from: baseline, to: current)
        #expect(changed == [.object(["path": .string("\(entryPath)/k:isAllowed"), "wasType": .string("bool"), "nowType": .string("bool"),
                                     "was": .bool(true), "now": .bool(false)])], "\(changed)")
        // Reordering alone is no change at all.
        #expect(BlobShape.changes(from: baseline, to: try #require(BlobShape.leaves(of: approvals(order: [3, 1, 4, 2, 0]), marker: marker))).isEmpty)
        #expect(BlobShape.changes(from: baseline, to: baseline).isEmpty)

        // No other app's ID, no program's path and no string value is in a path or a change.
        let paths = JSONValue.array(baseline.keys.sorted().map(JSONValue.string))
        try nothingOfTheInput(before, in: paths, allowing: [marker])
        try nothingOfTheInput(before, in: .array(changed), allowing: [marker])
        let said = try text(paths)
        #expect(!said.contains("com.example.one") && !said.contains("exampled") && !said.contains("helperd"))

        // An entry that appears or goes is a change in how many there are, which is not seen as a leaf of its own.
        let more = BlobFixtures.approvalsList(BlobFixtures.approvals() + [BlobFixtures.Approval("com.example.four", allowed: true)])
        let grown = BlobShape.changes(from: baseline, to: try #require(BlobShape.leaves(of: more, marker: marker)))
        #expect(!grown.isEmpty)
        #expect(!(try text(.array(grown))).contains("com.example.four"))
    }

    @Test func aKeyThatIsDataOnTheWayToTheIDIsNotSaidAndHidesTheValues() throws {
        // The way to the ID goes through a key that is data (a name with dots in it): it is `‹key›`, and what is below the entry has a type
        // and no value. A key that is an identifier is said, and the values stay.
        let entries: [[String: Any]] = [
            ["isAllowed": true, "order": 4, "places": ["com.example.slot": ["_0": marker]]],
            ["isAllowed": false, "order": 5, "places": ["com.example.other": ["_0": "com.example.other.app"]]],
        ]
        let blob = try PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0)

        let leaves = try #require(BlobShape.leaves(of: blob, marker: marker))
        let way = "/mp:k:places,k:‹key›,k:_0=\(marker)"
        #expect(leaves["\(way)/k:isAllowed"] == BlobShape.Leaf(type: "bool", value: nil), "the way says nothing that is the app's, but is not fully said either")
        #expect(leaves["\(way)/k:order"] == BlobShape.Leaf(type: "integer", value: nil))
        let paths = JSONValue.array(leaves.keys.sorted().map(JSONValue.string))
        try nothingOfTheInput(blob, in: paths, allowing: [marker])
        let pathText = try text(paths)
        #expect(!pathText.contains("slot") && !pathText.contains("other"))

        let said = try object(BlobShape.describe(blob, marker: marker))
        try nothingOfTheInput(blob, in: .object(said), allowing: [])
        #expect(said["markerFound"] == .bool(true))
    }

    @Test(.timeLimit(.minutes(1)))
    func findingTheIDInAHugeEntryIsBoundedAndKeepsTheWalkItsOwnWork() throws {
        // The test item's entry, and beside it an entry that refers to its own parts so many times that it is sixteen million values.
        let blob = BlobFixtures.approvalsWithDeeplySharedList(levels: 24)
        let walk = try #require(BlobShape.leavesWalk(of: blob, marker: marker))
        #expect(walk.truncated)
        #expect(walk.leaves["/k:apps/m:bundleID=\(marker)/k:allowed"] == BlobShape.Leaf(type: "bool", value: .bool(true)))

        // An entry that has the ID further down, and beside it a huge one: what is looked in is limited, and the first is still found.
        var builder = BplistBuilder()
        let top = builder.reserve()
        let entry = builder.reserve(), places = builder.reserve(), place = builder.reserve()
        let placesKey = builder.add(.string("places")), idKey = builder.add(.string("_0")), id = builder.add(.string(marker))
        let flagKey = builder.add(.string("isAllowed")), flag = builder.add(.bool(true))
        let hostile = builder.sharedChain(levels: 24)
        builder.set(top, .array([entry, hostile]))
        builder.set(entry, .dictionary([(flagKey, flag), (placesKey, places)]))
        builder.set(places, .array([place]))
        builder.set(place, .dictionary([(idKey, id)]))
        let nested = try #require(BlobShape.leavesWalk(of: builder.data(top: top), marker: marker))
        #expect(nested.truncated)
        #expect(nested.leaves["/mp:k:places,*,k:_0=\(marker)/k:isAllowed"]?.value == .bool(true))
    }

    @Test func theApprovalsFixturesHoldOnlyExampleApps() throws {
        // Every bundle ID of the fixture is a made-up one, and every program path is too: nothing of the person's own apps is in a test.
        func strings(in value: Any) -> [String] {
            switch value {
            case let text as String: [text]
            case let list as [Any]: list.flatMap(strings(in:))
            case let dictionary as [String: Any]: dictionary.flatMap { [$0.key] + strings(in: $0.value) }
            default: []
            }
        }
        let list = try PropertyListSerialization.propertyList(from: approvals(), format: nil)
        let all = strings(in: list)
        let ids = all.filter { $0.contains(".") && !$0.contains(" ") }
        #expect(!ids.isEmpty)
        #expect(ids.allSatisfy { $0.hasPrefix("com.example.") }, "\(ids)")
        #expect(all.filter { $0.contains("/") }.allSatisfy { $0.hasPrefix("Example ") })
        #expect(marker.hasPrefix("com.example."))
        #expect(BlobFixtures.secretID.hasPrefix("com.example."))
    }
}
