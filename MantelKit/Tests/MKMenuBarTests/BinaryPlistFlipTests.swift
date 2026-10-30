import Foundation
import MKCore
import Testing

@testable import MKMenuBar

@Suite("Binary plist flip", .timeLimit(.minutes(1)))
struct BinaryPlistFlipTests {
    private let flip = BinaryPlistFlip()
    private let marker = BlobFixtures.marker

    private func allowed(_ id: String) -> PlistKeyPath {
        [.key("$objects"), .matching(key: "bundleID", value: id), .key("allowed")]
    }

    /// One entry that is true, the others false: the true object belongs to one place.
    private var unique: Data {
        BlobFixtures.archive([(marker, true, 1), ("com.example.one", false, 2), ("com.example.two", false, 3)])
    }

    /// Two that are true: they share the one true object a binary property list keeps.
    private var shared: Data {
        BlobFixtures.archive([(marker, true, 1), ("com.example.one", true, 2), ("com.example.two", false, 3)])
    }

    @Test func flipsOnlyOneByte() throws {
        let blob = unique
        #expect(try flip.value(at: allowed(marker), in: blob) == .bool(true))

        let changed = try flip.setting(.bool(false), at: allowed(marker), in: blob)

        #expect(BlobFixtures.differingBytes(blob, changed) == 1, "no byte but the one marker is touched")
        let difference = try #require(BlobFixtures.firstDifference(blob, changed))
        #expect(difference.was == 0x09 && difference.now == 0x08, "true is 0x09 and false 0x08")
        #expect(try flip.value(at: allowed(marker), in: changed) == .bool(false))
        #expect(try flip.value(at: allowed("com.example.one"), in: changed) == .bool(false), "the others are as they were")
        // And back: the bytes are the original's again.
        #expect(try flip.setting(.bool(true), at: allowed(marker), in: changed) == blob)
        // Setting what is there changes nothing.
        #expect(try flip.setting(.bool(true), at: allowed(marker), in: blob) == blob)
    }

    @Test func resolvesMatchingThroughUIDs() throws {
        // The entry's `bundleID` is a reference to a string object of the archive; the path finds the entry by that string.
        let blob = unique
        #expect(try flip.value(at: allowed("com.example.one"), in: blob) == .bool(false))
        #expect(try flip.value(at: allowed(marker), in: blob) == .bool(true))
        #expect(try flip.value(at: [.key("$objects"), .matching(key: "bundleID", value: marker), .key("order")], in: blob) == .integer(1))
        #expect(try flip.value(at: allowed("com.example.absent"), in: blob) == nil)
        #expect(try flip.value(at: [.key("$objects"), .matching(key: "bundleID", value: marker), .key("nothing")], in: blob) == nil)

        // The same through a dictionary that was archived as one: its keys and values are lists of references.
        let archived = BlobFixtures.dictionaryArchive([(marker, true, 1), ("com.example.one", false, 2)])
        #expect(try flip.value(at: allowed(marker), in: archived) == .bool(true))
        #expect(try flip.value(at: allowed("com.example.one"), in: archived) == .bool(false))
        #expect(try flip.value(at: [.key("$objects"), .matching(key: "bundleID", value: marker), .key("order")], in: archived) == .integer(1))

        // A step that finds nothing is the error the other codecs give.
        #expect(throws: KeyPathError.noMatch(step: 1)) {
            try flip.setting(.bool(false), at: [.key("$objects"), .matching(key: "bundleID", value: "com.example.absent"), .key("allowed")], in: blob)
        }
    }

    @Test func aDictionaryArchivedAsOneIsFlippedThroughItsReferences() throws {
        // Each value is a reference to an object of the archive, and the true and the false are objects of their own.
        let blob = BlobFixtures.dictionaryArchive([(marker, true, 1), ("com.example.one", false, 2)])
        let changed = try flip.setting(.bool(false), at: allowed(marker), in: blob)
        #expect(try flip.value(at: allowed(marker), in: changed) == .bool(false))
        #expect(try flip.value(at: allowed("com.example.one"), in: changed) == .bool(false))
        #expect(BlobFixtures.differingBytes(blob, changed) <= 2, "one marker byte, or one reference")
        let back = try flip.setting(.bool(true), at: allowed(marker), in: changed)
        #expect(try flip.value(at: allowed(marker), in: back) == .bool(true))
        #expect(try flip.value(at: allowed("com.example.one"), in: back) == .bool(false))
    }

    @Test func refusesNonBoolean() throws {
        let blob = unique
        let order: PlistKeyPath = [.key("$objects"), .matching(key: "bundleID", value: marker), .key("order")]
        // A number is not a flag, and nothing is changed.
        #expect(throws: PlistBlobCodecError.notABoolean) { try flip.setting(.bool(true), at: order, in: blob) }
        // A value that isn't a flag is not what the place takes.
        #expect(throws: PlistBlobCodecError.notABoolean) { try flip.setting(.integer(1), at: allowed(marker), in: blob) }
        #expect(throws: PlistBlobCodecError.notABoolean) { try flip.setting(nil, at: allowed(marker), in: blob) }
        #expect(throws: PlistBlobCodecError.notABoolean) { try flip.setting(.string("yes"), at: allowed(marker), in: blob) }
        // The string the entry is found by is a string, not a flag.
        #expect(throws: PlistBlobCodecError.notABoolean) {
            try flip.setting(.bool(true), at: [.key("$objects"), .matching(key: "bundleID", value: marker), .key("bundleID")], in: blob)
        }
    }

    @Test func refusesNonBplist() {
        #expect(throws: PlistBlobCodecError.notABinaryPlist) { try flip.setting(.bool(true), at: [.key("allowed")], in: BlobFixtures.plainXML()) }
        #expect(throws: PlistBlobCodecError.notABinaryPlist) { try flip.value(at: [.key("allowed")], in: BlobFixtures.plainXML()) }
        #expect(throws: PlistBlobCodecError.notABinaryPlist) { try flip.value(at: [], in: Data("nothing".utf8)) }
        #expect(throws: PlistBlobCodecError.notABinaryPlist) { try flip.value(at: [], in: Data()) }
    }

    @Test func aDamagedBlobIsRefusedAndNothingIsReadPastItsEnd() throws {
        let blob = unique
        // Cut anywhere: the trailer isn't at the end any more, or what it names isn't there.
        for length in stride(from: 8, to: blob.count, by: 17) {
            #expect(throws: PlistBlobCodecError.self) { try flip.value(at: [], in: blob.prefix(length)) }
        }
        // A trailer that names more objects than the blob can hold, and an offset table that points outside.
        var wrongCount = blob
        wrongCount[wrongCount.count - 24] = 0x7F
        #expect(throws: PlistBlobCodecError.damaged) { try flip.value(at: [], in: wrongCount) }
        var wrongTable = blob
        wrongTable[wrongTable.count - 1] = 0xFF
        #expect(throws: PlistBlobCodecError.self) { try flip.value(at: [], in: wrongTable) }
    }

    // MARK: Values the list shares

    @Test func aTrueThatTwoEntriesShareIsNotFlippedForBoth() throws {
        let blob = shared
        let changed = try flip.setting(.bool(false), at: allowed(marker), in: blob)

        #expect(try flip.value(at: allowed(marker), in: changed) == .bool(false))
        #expect(try flip.value(at: allowed("com.example.one"), in: changed) == .bool(true), "the other entry that was true is still true")
        #expect(try flip.value(at: allowed("com.example.two"), in: changed) == .bool(false))
        // One reference was pointed at the false object the list has: a byte or two, and the rest is as it was.
        #expect(BlobFixtures.differingBytes(blob, changed) <= 2)
        // And it can be put back the same way.
        let back = try flip.setting(.bool(true), at: allowed(marker), in: changed)
        #expect(try flip.value(at: allowed(marker), in: back) == .bool(true))
        #expect(try flip.value(at: allowed("com.example.one"), in: back) == .bool(true))
        #expect(try flip.value(at: allowed("com.example.two"), in: back) == .bool(false))
    }

    @Test func aSharedValueWithNoOtherToPointAtIsRefusedAndNothingIsChanged() throws {
        // Every entry is true, so there is no false object to point one of them at, and flipping the one would flip them all.
        let blob = BlobFixtures.archive([(marker, true, 1), ("com.example.one", true, 2)])
        #expect(throws: PlistBlobCodecError.sharedValue) { try flip.setting(.bool(false), at: allowed(marker), in: blob) }
    }

    @Test func aReferenceToATrueIsFlippedOnlyWhenNothingElseRefersToIt() throws {
        // Archived as dictionaries, every value is a reference to an object of the archive.
        let alone = BlobFixtures.dictionaryArchive([(marker, true, 1), ("com.example.one", false, 2)])
        let flipped = try flip.setting(.bool(false), at: allowed(marker), in: alone)
        #expect(try flip.value(at: allowed(marker), in: flipped) == .bool(false))
        #expect(try flip.value(at: allowed("com.example.one"), in: flipped) == .bool(false))

        let both = BlobFixtures.dictionaryArchive([(marker, true, 1), ("com.example.one", true, 2), ("com.example.two", false, 3)])
        let changed = try flip.setting(.bool(false), at: allowed(marker), in: both)
        #expect(try flip.value(at: allowed(marker), in: changed) == .bool(false))
        #expect(try flip.value(at: allowed("com.example.one"), in: changed) == .bool(true))
        #expect(try flip.value(at: allowed("com.example.two"), in: changed) == .bool(false))
    }

    // MARK: What the path goes through below the entry

    private func visible(_ id: String) -> PlistKeyPath {
        [.key("$objects"), .matching(key: "bundleID", value: id), .key("settings"), .key("visible")]
    }

    @Test func aSettingsDictionaryThatTwoEntriesShareIsRefusedInAnArchive() throws {
        // One instance given to both entries: one object of the archive, which both refer to. Flipping the test item's `visible` would
        // flip the other entry's. (The only true in the list is its, and there is a false: it is not the flag that is refused.)
        let blob = BlobFixtures.archive(withSettings: [(marker, false, true), ("com.example.one", false, true), ("com.example.two", false, false)],
                                        shared: true)
        #expect(try flip.value(at: visible(marker), in: blob) == .bool(true))
        #expect(throws: PlistBlobCodecError.sharedValue) { try flip.setting(.bool(false), at: visible(marker), in: blob) }
        #expect(throws: PlistBlobCodecError.sharedValue) { try flip.setting(.bool(false), at: visible("com.example.one"), in: blob) }
    }

    @Test func settingsOfEqualContentThatAreNotOneInstanceAreEachFlippedAlone() throws {
        // Foundation doesn't keep one object for two dictionaries of equal content, so these are three settings of their own. The
        // `true` that the test item's and the other entry's share is an NSNumber (one object of the archive), which is not the
        // settings: the test item's `visible` is pointed at the `false` the third entry has, and only the test item's changes.
        let blob = BlobFixtures.archive(withSettings: [(marker, false, true), ("com.example.one", false, true), ("com.example.two", false, false)],
                                        shared: false)
        let changed = try flip.setting(.bool(false), at: visible(marker), in: blob)

        #expect(try flip.value(at: visible(marker), in: changed) == .bool(false))
        #expect(try flip.value(at: visible("com.example.one"), in: changed) == .bool(true), "the other entry's is still true")
        #expect(try flip.value(at: visible("com.example.two"), in: changed) == .bool(false))
        // Foundation says the same of the bytes that were written.
        let decoded = try BlobFixtures.decodedEntries(changed)
        #expect(decoded.map(\.bundleID) == [marker, "com.example.one", "com.example.two"])
        #expect(decoded.map { $0.settings?["visible"] as? Bool } == [false, true, false])
        #expect(decoded.map(\.allowed) == [false, false, false])
        #expect(decoded.map(\.order) == [1, 2, 3])
        #expect(BlobFixtures.differingBytes(blob, changed) <= 2)
        // And it goes back the same way.
        let back = try flip.setting(.bool(true), at: visible(marker), in: changed)
        #expect(try BlobFixtures.decodedEntries(back).map { $0.settings?["visible"] as? Bool } == [true, true, false])
    }

    @Test func aSettingsDictionaryThatTwoEntriesShareIsRefusedInAPlainList() throws {
        // Both entries hold one settings dictionary, and the only true in the list is in it.
        let blob = BlobFixtures.plainWithSettings([(marker, true), ("com.example.one", true)], shared: true)
        let path: PlistKeyPath = [.key("apps"), .matching(key: "bundleID", value: marker), .key("settings"), .key("visible")]
        #expect(try flip.value(at: path, in: blob) == .bool(true))
        #expect(throws: PlistBlobCodecError.sharedValue) { try flip.setting(.bool(false), at: path, in: blob) }
        #expect(throws: PlistBlobCodecError.sharedValue) {
            try flip.setting(.bool(false), at: [.key("apps"), .matching(key: "bundleID", value: "com.example.one"), .key("settings"), .key("visible")], in: blob)
        }
    }

    @Test func anUnsharedSettingsDictionaryFlipsOneEntryOnly() throws {
        // (See also `settingsOfEqualContentThatAreNotOneInstanceAreEachFlippedAlone`, which reads the result back with Foundation.)
        // The test item's settings are its own: a true that no other entry has.
        let archived = BlobFixtures.archive(withSettings: [(marker, false, true), ("com.example.one", false, false)], shared: false)
        let changed = try flip.setting(.bool(false), at: visible(marker), in: archived)
        #expect(try flip.value(at: visible(marker), in: changed) == .bool(false))
        #expect(try flip.value(at: visible("com.example.one"), in: changed) == .bool(false), "it was false, and is")
        #expect(BlobFixtures.differingBytes(archived, changed) <= 2)

        let plain = BlobFixtures.plainWithSettings([(marker, true), ("com.example.one", false)])
        let path: PlistKeyPath = [.key("apps"), .matching(key: "bundleID", value: marker), .key("settings"), .key("visible")]
        let flipped = try flip.setting(.bool(false), at: path, in: plain)
        #expect(BlobFixtures.differingBytes(plain, flipped) == 1)
        #expect(try flip.value(at: path, in: flipped) == .bool(false))
        #expect(try flip.value(at: [.key("apps"), .matching(key: "bundleID", value: "com.example.one"), .key("settings"), .key("visible")], in: flipped) == .bool(false))
    }

    @Test func anObjectNothingReachableRefersToDoesNotMakeAFlagShared() throws {
        // Foundation's writer leaves a copy of a shared dictionary, and of what is in it, that nothing refers to. What the copy refers
        // to is not shared with it in any way that matters, so the one true that the real dictionary has is used once.
        let blob = BlobFixtures.plainWithSettings([(marker, true), ("com.example.one", true)], shared: true)
        let plist = try BinaryPlist(blob)
        let counts = plist.referenceCounts()
        let trues = plist.objects.indices.filter { plist.objects[$0] == .bool(true) }
        #expect(trues.count >= 1)
        #expect(trues.map { counts[$0] }.reduce(0, +) == 1, "one reference to a true, from the dictionary the entries share: \(counts)")
        #expect(counts.contains(0), "and the writer left an object that nothing refers to")
    }

    @Test(.timeLimit(.minutes(1)))
    func deeplySharedPlistIsRefusedNotExpanded() throws {
        // 24 levels of a list of two references to the level below: a few hundred bytes, and sixteen million values if each is followed.
        let blob = BlobFixtures.deeplySharedPlist(levels: 24)
        #expect(blob.count < 1000)
        #expect(throws: PlistBlobCodecError.tooLarge) { try flip.value(at: [], in: blob) }
        let object = try PropertyListSerialization.propertyList(from: blob, format: nil)
        #expect(PlistValue.converting(object) == .tooLarge)
        // A place in it, a single value, is still read: what is refused is expanding the whole.
        #expect(try flip.value(at: [.index(0), .index(0)], in: BlobFixtures.deeplySharedPlist(levels: 3)) != nil)
        #expect(PlistValue.converting(try PropertyListSerialization.propertyList(from: BlobFixtures.deeplySharedPlist(levels: 5), format: nil))
                != .tooLarge, "a small one is converted")
    }

    // MARK: What a blob can make the reader allocate

    /// A blob with one big array, and `objects` table entries that all point at it: each would be read again as an array of its own.
    private func amplifying(objects: Int, references: Int) -> Data {
        var bytes = Data("bplist00".utf8)
        let arrayOffset = bytes.count
        // An array of `references` references of two bytes each, all to object 0 (the array itself).
        bytes.append(0xAF)
        bytes.append(0x11)
        bytes.append(UInt8(references >> 8))
        bytes.append(UInt8(references & 0xFF))
        for _ in 0..<references { bytes.append(contentsOf: [0, 0]) }
        let tableStart = bytes.count
        for _ in 0..<objects { bytes.append(contentsOf: [UInt8(arrayOffset >> 8), UInt8(arrayOffset & 0xFF)]) }
        var trailer = Data(count: 32)
        trailer[6] = 2
        trailer[7] = 2
        func put(_ value: Int, at index: Int) { for byte in 0..<8 { trailer[index + byte] = UInt8((value >> (8 * (7 - byte))) & 0xFF) } }
        put(objects, at: 8)
        put(0, at: 16)
        put(tableStart, at: 24)
        return bytes + trailer
    }

    @Test(.timeLimit(.minutes(1)))
    func aBlobWhoseTableEntriesAllPointAtOneBigArrayIsDamaged() throws {
        // 4,000 objects that are each 10,000 references would be 40 million references out of a 20 KB blob.
        let blob = amplifying(objects: 4000, references: 10_000)
        #expect(blob.count < 40_000)
        #expect(throws: PlistBlobCodecError.damaged) { try flip.value(at: [], in: blob) }
        #expect(throws: PlistBlobCodecError.damaged) { try flip.setting(.bool(true), at: [.index(0)], in: blob) }
    }

    @Test func aBlobThatAsksForOneArrayAndNoMoreIsRead() throws {
        // The same blob with one table entry is an array that refers to itself: odd, and within what the object area holds.
        let one = amplifying(objects: 1, references: 100)
        let plist = try BinaryPlist(one)
        #expect(plist.objects.count == 1)
        // Two entries at one offset ask for twice what the object area has room for.
        #expect(throws: PlistBlobCodecError.damaged) { try BinaryPlist(amplifying(objects: 2, references: 100)) }
    }

    // MARK: A list that isn't an archive

    @Test func aPlainBinaryListIsReadByKeysAndPositions() throws {
        let blob = BlobFixtures.plainBinary()
        #expect(try flip.value(at: [.index(0), .key("bundleID")], in: blob) == .string(marker))
        #expect(try flip.value(at: [.matching(key: "bundleID", value: marker), .key("bundleID")], in: blob) == .string(marker))
        #expect(try flip.value(at: [.index(1), .key("allowed")], in: blob) == .bool(true))
        #expect(try flip.value(at: [.index(3), .index(2)], in: blob) == .integer(3))
        #expect(try flip.value(at: [.index(9)], in: blob) == nil)
        // A flag in a list that has no other true is flipped where it is.
        let changed = try flip.setting(.bool(false), at: [.index(1), .key("allowed")], in: blob)
        #expect(BlobFixtures.differingBytes(blob, changed) == 1)
        #expect(try flip.value(at: [.index(1), .key("allowed")], in: changed) == .bool(false))
    }

    @Test func aReferenceInsideAValueIsNotAValueOfMantels() throws {
        // The whole entry holds references, which a `PlistValue` can't, and it says so instead of leaving them out.
        #expect(throws: PlistBlobCodecError.containsReferences) {
            try flip.value(at: [.key("$objects"), .matching(key: "bundleID", value: marker)], in: unique)
        }
    }

    // MARK: An entry that names its app some levels down

    private func entry(_ id: String) -> PlistKeyPath {
        [.matchingPath(path: [.key("menuItemLocations"), .anyElement, .key("bundle"), .key("_0")], value: id)]
    }

    private func flag(_ id: String) -> PlistKeyPath { entry(id) + [.key("isAllowed")] }

    /// The list as Foundation reads it back, in the order it holds the entries.
    private func decoded(_ blob: Data) throws -> [NSDictionary] {
        try #require(PropertyListSerialization.propertyList(from: blob, format: nil) as? [NSDictionary])
    }

    @Test func matchingPathFlipsOneEntryLeavingTheRestAlone() throws {
        // Three entries are true and share the one true object a binary list keeps; one is false, which the test item's is pointed at.
        let blob = BlobFixtures.approvalsList(BlobFixtures.approvals(testItem: true))
        #expect(try flip.value(at: flag(marker), in: blob) == .bool(true))

        let changed = try flip.setting(.bool(false), at: flag(marker), in: blob)

        #expect(BlobFixtures.differingBytes(blob, changed) <= 2, "one reference of a byte or two, and no other byte")
        #expect(try flip.value(at: flag(marker), in: changed) == .bool(false))
        let before = try decoded(blob), after = try decoded(changed)
        #expect(after.count == before.count)
        for (position, (was, now)) in zip(before, after).enumerated() {
            if position == 2 {
                #expect(now["isAllowed"] as? Bool == false)
                #expect(now["menuItemLocations"] as? NSArray == was["menuItemLocations"] as? NSArray)
            } else {
                #expect(now == was, "entry \(position)")
            }
        }
        for id in ["com.example.one", "com.example.three", "com.example.three.helper"] {
            #expect(try flip.value(at: flag(id), in: changed) == .bool(true), "\(id) is as it was")
        }
        // And back: the bytes are the original's.
        #expect(try flip.setting(.bool(true), at: flag(marker), in: changed) == blob)
        // What is there is left as it is.
        #expect(try flip.setting(.bool(true), at: flag(marker), in: blob) == blob)
    }

    @Test func matchingPathFindsTheEntryWhereverItIsAndTheSecondPlace() throws {
        let entries = BlobFixtures.approvals(testItem: true)
        for order in [[2, 0, 1, 3, 4], [4, 3, 2, 1, 0], [0, 1, 3, 4, 2]] {
            let blob = BlobFixtures.approvalsList(order.map { entries[$0] })
            let changed = try flip.setting(.bool(false), at: flag(marker), in: blob)
            let after = try decoded(changed)
            #expect(after.map { $0["isAllowed"] as? Bool } == order.map { $0 == 2 ? false : entries[$0].isAllowed }, "\(order)")
        }
        // The ID is in the second place of its entry, after a program that has none.
        let blob = BlobFixtures.approvalsList(entries)
        #expect(try flip.value(at: flag("com.example.two"), in: blob) == .bool(false))
        #expect(try flip.value(at: flag("com.example.three.helper"), in: blob) == .bool(true))
        // The whole entry can be read, and holds no references of the list's.
        #expect(try flip.value(at: entry("com.example.one"), in: blob)?.value(at: [.key("isAllowed")]) == .bool(true))
    }

    @Test func matchingPathNoMatchAmbiguousAndAnyElementOutsideItAreRefused() throws {
        let entries = BlobFixtures.approvals()
        let blob = BlobFixtures.approvalsList(entries)
        #expect(try flip.value(at: flag("com.example.absent"), in: blob) == nil)
        #expect(throws: KeyPathError.noMatch(step: 0)) { try flip.setting(.bool(false), at: flag("com.example.absent"), in: blob) }

        // Two entries claim one app: nothing is read, and nothing is changed.
        let twice = BlobFixtures.approvalsList(entries + [BlobFixtures.Approval(marker, allowed: false)])
        #expect(try flip.value(at: flag(marker), in: twice) == nil)
        #expect(throws: KeyPathError.ambiguousMatch(step: 0)) { try flip.setting(.bool(false), at: flag(marker), in: twice) }
        // Two places of one entry that both hold the ID are still one entry.
        let both = BlobFixtures.approvalsList([BlobFixtures.Approval(allowed: true, locations: [.bundle(marker), .bundle(marker)]),
                                               BlobFixtures.Approval("com.example.one", allowed: false)])
        #expect(try flip.value(at: flag(marker), in: both) == .bool(true))

        // "Any element" is for the way to the ID only.
        #expect(throws: KeyPathError.anyElementOutsideMatchingPath(step: 0)) { try flip.setting(.bool(false), at: [.anyElement], in: blob) }
        #expect(throws: KeyPathError.anyElementOutsideMatchingPath(step: 1)) {
            try flip.setting(.bool(false), at: [.index(0), .anyElement], in: blob)
        }
        #expect(try flip.value(at: [.anyElement, .key("isAllowed")], in: blob) == nil)
        // A way that is itself a match reaches nothing.
        let nested: PlistKeyPath = [.matchingPath(path: [.matchingPath(path: [.key("menuItemLocations")], value: "x")], value: "y")]
        #expect(throws: KeyPathError.noMatch(step: 0)) { try flip.setting(.bool(false), at: nested + [.key("isAllowed")], in: blob) }
    }

    @Test func matchingPathRefusesAContainerBelowTheEntryThatTwoEntriesShare() throws {
        // Two entries hold one settings dictionary (one object of the list), and the test item's flag is in it: flipping it would flip
        // the other entry's too.
        let shared = NSDictionary(dictionary: ["visible": true])
        func list(settings: [NSDictionary]) throws -> Data {
            let entries: [[String: Any]] = [
                ["isAllowed": false, "menuItemLocations": [["bundle": ["_0": marker]]], "settings": settings[0]],
                ["isAllowed": false, "menuItemLocations": [["bundle": ["_0": "com.example.one"]]], "settings": settings[1]],
                ["isAllowed": false, "menuItemLocations": [["bundle": ["_0": "com.example.two"]]], "settings": ["visible": false] as NSDictionary],
            ]
            return try PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0)
        }
        let visible: PlistKeyPath = entry(marker) + [.key("settings"), .key("visible")]

        let blob = try list(settings: [shared, shared])
        #expect(try flip.value(at: visible, in: blob) == .bool(true))
        #expect(throws: PlistBlobCodecError.sharedValue) { try flip.setting(.bool(false), at: visible, in: blob) }

        // Settings of their own (the true is shared, which is dealt with: the false the list has is pointed at) are flipped alone.
        let own = try list(settings: [["visible": true], ["visible": true]])
        let changed = try flip.setting(.bool(false), at: visible, in: own)
        #expect(try flip.value(at: visible, in: changed) == .bool(false))
        #expect(try flip.value(at: entry("com.example.one") + [.key("settings"), .key("visible")], in: changed) == .bool(true))
        #expect(BlobFixtures.differingBytes(own, changed) <= 2)
    }

    @Test func matchingPathFollowsReferencesInAnArchive() throws {
        // In an archive an entry's ID is a reference to a string object: the way to it follows that, as `matching` does.
        let blob = unique
        let byID: PlistKeyPath = [.key("$objects"), .matchingPath(path: [.key("bundleID")], value: marker), .key("allowed")]
        #expect(try flip.value(at: byID, in: blob) == .bool(true))
        let changed = try flip.setting(.bool(false), at: byID, in: blob)
        #expect(try flip.value(at: allowed(marker), in: changed) == .bool(false))
        #expect(BlobFixtures.differingBytes(blob, changed) == 1)
        let archived = BlobFixtures.dictionaryArchive([(marker, true, 1), ("com.example.one", false, 2)])
        #expect(try flip.value(at: byID, in: archived) == .bool(true))
        #expect(throws: KeyPathError.noMatch(step: 1)) {
            try flip.setting(.bool(false), at: [.key("$objects"), .matchingPath(path: [.key("bundleID")], value: "com.example.absent"), .key("allowed")], in: blob)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func matchingPathOverAListThatRefersToItsPartsManyTimesIsRefusedNotFollowed() throws {
        // 30 levels, each a list of two references to the level below: a way of thirty steps for any element has 2^30 ways to follow.
        var builder = BplistBuilder()
        _ = builder.sharedChain(levels: 30)
        let blob = builder.data()
        let way = Array(repeating: KeyPathStep.anyElement, count: 31)
        let nothing: PlistKeyPath = [.matchingPath(path: way, value: "nothing")]

        #expect(throws: PlistBlobCodecError.tooLarge) { try flip.setting(.bool(true), at: nothing + [.index(0)], in: blob) }
        #expect(throws: PlistBlobCodecError.tooLarge, "reading doesn't take it for a place that isn't there") { try flip.value(at: nothing, in: blob) }
        // A way that is within the limit is followed, on the same kind of list: 12 levels of two references is 2,048 ways to the string.
        var small = BplistBuilder()
        _ = small.sharedChain(levels: 12)
        let ways = Array(repeating: KeyPathStep.anyElement, count: 11)
        #expect(throws: KeyPathError.noMatch(step: 0), "the string isn't that one") {
            try flip.setting(.bool(true), at: [.matchingPath(path: ways, value: "absent")], in: small.data())
        }
        #expect(throws: KeyPathError.ambiguousMatch(step: 0), "both of the top list's references lead to it") {
            try flip.setting(.bool(true), at: [.matchingPath(path: ways, value: "x")], in: small.data())
        }
        #expect(try flip.value(at: [.matchingPath(path: ways, value: "x")], in: small.data()) == nil, "so nothing is read")
    }

    // MARK: Through the file access

    @Test func theFileAccessCanUseItForAPlaceInAKeyedArchive() async throws {
        let folder = TemporaryFolderForBlobs()
        let access = folder.access(codec: flip)
        let blob = unique
        try folder.write(["blob": blob, "keep": "me"])

        try await access.write([PathEdit(path: allowed(marker), value: .bool(false))], key: "blob", in: folder.plist,
                               codec: folder.codecID)
        #expect(try await access.value(at: allowed(marker), key: "blob", in: folder.plist, codec: folder.codecID) == .bool(false))

        try await access.undo(path: allowed(marker), key: "blob", in: folder.plist)
        #expect(try await access.value(at: allowed(marker), key: "blob", in: folder.plist, codec: folder.codecID) == .bool(true))
        #expect(try folder.blob(key: "blob") == blob, "the bytes are the original's, entirely")
    }
}
