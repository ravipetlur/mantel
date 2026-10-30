import Foundation
import MKCore
import Testing

@testable import MKMenuBar

@Suite("Nested plist codec", .timeLimit(.minutes(1)))
struct NestedPlistCodecTests {
    private let codec = NestedPlistCodec()
    private let marker = BlobFixtures.marker

    @Test func binaryRoundTripIsIdentical() throws {
        // A list written in one order only (no dictionary here has two keys): written again it is the same bytes.
        let blob = BlobFixtures.plainBinary()
        // Setting what is there changes nothing either, and the format stays binary.
        let same = try codec.setting(.bool(true), at: [.index(1), .key("allowed")], in: blob)
        #expect(same == blob)
        #expect(same.starts(with: Data("bplist00".utf8)))
    }

    @Test func settingAnEqualValueReturnsTheBlobUnchanged() throws {
        // A list written the way another writer might: a Foundation re-encoding of it is not these bytes.
        let xml = Data("""
        <?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><array><dict><key>isAllowed</key><true/><key>menuItemLocations</key><array><dict><key>bundle</key><dict><key>_0</key><string>com.example.one</string></dict></dict></array></dict></array></plist>
        """.utf8)
        let flag: PlistKeyPath = entry("com.example.one") + [.key("isAllowed")]

        // What is there is asked for: nothing is written, and the bytes are the very bytes that came in.
        #expect(try codec.setting(.bool(true), at: flag, in: xml) == xml)
        // So is a removal of a place that isn't there.
        #expect(try codec.setting(nil, at: entry("com.example.one") + [.key("note")], in: xml) == xml)
        // A change is a change, and the list is written again.
        let changed = try codec.setting(.bool(false), at: flag, in: xml)
        #expect(changed != xml)
        #expect(try codec.value(at: flag, in: changed) == .bool(false))
        // A place that can't be taken is still an error, for an equal value too: nothing was found to be equal.
        #expect(throws: KeyPathError.noMatch(step: 0)) {
            try codec.setting(.bool(true), at: entry("com.example.absent") + [.key("isAllowed")], in: xml)
        }
        #expect(throws: KeyPathError.noMatch(step: 0)) {
            try codec.setting(nil, at: entry("com.example.absent") + [.key("isAllowed")], in: xml)
        }
    }

    @Test func xmlKeepsXML() throws {
        let blob = BlobFixtures.plainXML()
        #expect(blob.starts(with: Data("<?xml".utf8)))
        let changed = try codec.setting(.bool(false), at: [.index(0), .key("allowed")], in: blob)
        #expect(changed.starts(with: Data("<?xml".utf8)), "XML stays XML")
        #expect(try codec.value(at: [.index(0), .key("allowed")], in: changed) == .bool(false))
        #expect(try codec.value(at: [.index(1), .key("order")], in: changed) == .integer(2), "the rest of it is as it was")
    }

    @Test func setsAtMatchingPath() throws {
        let blob = BlobFixtures.plainEntries([(marker, true, 1), ("com.example.one", true, 2)])
        let allowed: (String) -> PlistKeyPath = { [.key("apps"), .matching(key: "bundleID", value: $0), .key("allowed")] }

        let changed = try codec.setting(.bool(false), at: allowed(marker), in: blob)

        #expect(try codec.value(at: allowed(marker), in: changed) == .bool(false))
        #expect(try codec.value(at: allowed("com.example.one"), in: changed) == .bool(true), "another entry's flag is its own")
        #expect(try codec.value(at: [.key("apps"), .matching(key: "bundleID", value: marker), .key("order")], in: changed) == .integer(1))
        #expect(try codec.value(at: allowed("com.example.absent"), in: changed) == nil)
        #expect(throws: KeyPathError.noMatch(step: 1)) { try codec.setting(.bool(false), at: allowed("com.example.absent"), in: blob) }
        #expect(throws: KeyPathError.self) { try codec.setting(.bool(false), at: [.key("apps"), .key("x")], in: blob) }
    }

    // MARK: The approvals list: the ID is some levels down in an entry

    private func entry(_ id: String) -> PlistKeyPath {
        [.matchingPath(path: [.key("menuItemLocations"), .anyElement, .key("bundle"), .key("_0")], value: id)]
    }

    /// The list as Foundation reads it: an array of entries, in the order it holds them.
    private func decoded(_ blob: Data) throws -> [NSDictionary] {
        try #require(PropertyListSerialization.propertyList(from: blob, format: nil) as? [NSDictionary])
    }

    @Test func setsIsAllowedThroughMatchingPathLeavingOthersAndOrderAlone() throws {
        let entries = BlobFixtures.approvals(testItem: true)
        let blob = BlobFixtures.approvalsList(entries)
        let flag: PlistKeyPath = entry(marker) + [.key("isAllowed")]
        #expect(try codec.value(at: flag, in: blob) == .bool(true))

        let changed = try codec.setting(.bool(false), at: flag, in: blob)

        #expect(try codec.value(at: flag, in: changed) == .bool(false))
        let before = try decoded(blob), after = try decoded(changed)
        #expect(before.count == 5 && after.count == 5, "no entry was added or taken out")
        // The test item's entry is the third, and is the only one that is different: the same dictionary with the flag turned off.
        for (position, (was, now)) in zip(before, after).enumerated() {
            if position == 2 {
                #expect(now != was)
                #expect(now.value(forKey: "menuItemLocations") as? NSArray == was.value(forKey: "menuItemLocations") as? NSArray, "its places are as they were")
                #expect(now["isAllowed"] as? Bool == false && was["isAllowed"] as? Bool == true)
            } else {
                #expect(now == was, "entry \(position) is as it was, in the same place")
            }
        }
        // Every other flag, found by the ID of an app that has a program and a bundle, or a second bundle, is its own.
        #expect(try codec.value(at: entry("com.example.one") + [.key("isAllowed")], in: changed) == .bool(true))
        #expect(try codec.value(at: entry("com.example.two") + [.key("isAllowed")], in: changed) == .bool(false))
        #expect(try codec.value(at: entry("com.example.three.helper") + [.key("isAllowed")], in: changed) == .bool(true))
        // The ID that isn't there, and two entries that have it.
        #expect(throws: KeyPathError.noMatch(step: 0)) { try codec.setting(.bool(false), at: entry("com.example.absent") + [.key("isAllowed")], in: blob) }
        let twice = BlobFixtures.approvalsList(entries + [BlobFixtures.Approval(marker, allowed: false)])
        #expect(throws: KeyPathError.ambiguousMatch(step: 0)) { try codec.setting(.bool(false), at: flag, in: twice) }
        #expect(try codec.value(at: flag, in: twice) == nil)
    }

    @Test func binaryFormatKept() throws {
        let blob = BlobFixtures.approvalsList(BlobFixtures.approvals())
        let changed = try codec.setting(.bool(false), at: entry(marker) + [.key("isAllowed")], in: blob)
        #expect(changed.starts(with: Data("bplist00".utf8)))
        var format = PropertyListSerialization.PropertyListFormat.xml
        _ = try PropertyListSerialization.propertyList(from: changed, options: [], format: &format)
        #expect(format == .binary)
        // And the other format stays the other: a list that is XML is written as XML.
        let xml = try PropertyListSerialization.data(fromPropertyList: try decoded(blob), format: .xml, options: 0)
        let changedXML = try codec.setting(.bool(false), at: entry(marker) + [.key("isAllowed")], in: xml)
        #expect(changedXML.starts(with: Data("<?xml".utf8)))
        #expect(try codec.value(at: entry(marker) + [.key("isAllowed")], in: changedXML) == .bool(false))
    }

    @Test func theFileAccessChangesAndRestoresTheEntryWhereverMacOSPutsIt() async throws {
        let folder = TemporaryFolderForBlobs()
        let access = folder.access(codec: codec)
        let blob = BlobFixtures.approvalsList(BlobFixtures.approvals())
        try folder.write(["blob": blob])
        let flag: PlistKeyPath = entry(marker) + [.key("isAllowed")]

        try await access.write([PathEdit(path: flag, value: .bool(false))], key: "blob", in: folder.plist, codec: folder.codecID)
        #expect(try await access.value(at: flag, key: "blob", in: folder.plist, codec: folder.codecID) == .bool(false))

        // macOS writes the whole list again, in another order.
        let written = try folder.blob(key: "blob")
        let reversed = try PropertyListSerialization.data(fromPropertyList: Array(try decoded(written).reversed()), format: .binary, options: 0)
        try folder.write(["blob": reversed])
        try await access.undo(path: flag, key: "blob", in: folder.plist)

        let back = try folder.blob(key: "blob")
        #expect(try codec.value(at: flag, in: back) == .bool(true))
        #expect(try decoded(back) == Array(try decoded(BlobFixtures.approvalsList(BlobFixtures.approvals())).reversed()), "the others, in the order macOS left them")
    }

    @Test func refusesArchiveWithUIDs() {
        let archive = BlobFixtures.archive([(marker, true, 1)])
        let message = "This list is an archive; use the flip codec"
        #expect(throws: PlistBlobCodecError.isAnArchive) { try codec.value(at: [], in: archive) }
        #expect(throws: PlistBlobCodecError.isAnArchive) { try codec.setting(.bool(false), at: [.key("$objects")], in: archive) }
        #expect(PlistBlobCodecError.isAnArchive.errorDescription == message)
    }

    @Test func somethingThatIsNotAPropertyListIsRefused() {
        #expect(throws: PlistBlobCodecError.notAPropertyList) { try codec.value(at: [], in: Data("not a list".utf8)) }
    }

    @Test func theFileAccessCanUseItForAPlaceInABlob() async throws {
        let folder = TemporaryFolderForBlobs()
        let access = folder.access(codec: codec)
        let blob = BlobFixtures.plainEntries([(marker, true, 1), ("com.example.one", true, 2)], format: .xml)
        try folder.write(["blob": blob])
        let place: PlistKeyPath = [.key("apps"), .matching(key: "bundleID", value: marker), .key("allowed")]

        try await access.write([PathEdit(path: place, value: .bool(false))], key: "blob", in: folder.plist, codec: folder.codecID)
        #expect(try await access.value(at: place, key: "blob", in: folder.plist, codec: folder.codecID) == .bool(false))
        #expect(try folder.blob(key: "blob").starts(with: Data("<?xml".utf8)))

        try await access.undo(path: place, key: "blob", in: folder.plist)
        #expect(try await access.value(at: place, key: "blob", in: folder.plist, codec: folder.codecID) == .bool(true))
    }
}
