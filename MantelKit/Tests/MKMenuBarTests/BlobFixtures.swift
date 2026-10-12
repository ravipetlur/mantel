import Foundation
import MKCore
import MKTestSupport
import Testing

@testable import MKMenuBar

/// A class that exists only to be archived: the archive then holds, for each instance, a dictionary of the keys it was encoded with
/// (`bundleID`, `allowed`, `order`), as an app's own class would leave it, which a dictionary archived as one doesn't.
final class ArchivedEntry: NSObject, NSCoding {
    let bundleID: String
    let allowed: Bool
    let order: Int
    /// A dictionary object of its own, archived as an object the entry refers to. Entries given the same instance refer to one object
    /// of the archive.
    let settings: NSDictionary?
    let label: String

    init(bundleID: String, allowed: Bool, order: Int, settings: NSDictionary? = nil, label: String = BlobFixtures.secretLabel) {
        self.bundleID = bundleID
        self.allowed = allowed
        self.order = order
        self.settings = settings
        self.label = label
    }

    func encode(with coder: NSCoder) {
        coder.encode(bundleID, forKey: "bundleID")
        coder.encode(allowed, forKey: "allowed")
        coder.encode(order, forKey: "order")
        coder.encode(label, forKey: "label")
        if let settings { coder.encode(settings, forKey: "settings") }
    }

    required init?(coder: NSCoder) {
        bundleID = coder.decodeObject(forKey: "bundleID") as? String ?? ""
        allowed = coder.decodeBool(forKey: "allowed")
        order = coder.decodeInteger(forKey: "order")
        label = coder.decodeObject(forKey: "label") as? String ?? ""
        settings = coder.decodeObject(forKey: "settings") as? NSDictionary
    }
}

/// The blobs the codec and shape tests are made from, built here from synthetic apps (`com.example.*`).
enum BlobFixtures {
    static let marker = "com.example.mantel.testitem"
    /// IDs and strings that must never come out of a report.
    static let secretID = "com.example.secret.other"
    static let secretText = "Quarterly Numbers.xlsx"
    /// A string value that is shaped like an identifier, which a report must not say any more than the others.
    static let secretLabel = "HomeNetwork"

    typealias Entry = (id: String, allowed: Bool, order: Int)

    /// A keyed archive of a list of `ArchivedEntry`: each entry's dictionary has `bundleID` (a reference to a string object),
    /// `allowed` (a true or false in the dictionary) and `order` (a number in it).
    static func archive(_ entries: [Entry]) -> Data {
        let list = entries.map { ArchivedEntry(bundleID: $0.id, allowed: $0.allowed, order: $0.order) } as NSArray
        return try! NSKeyedArchiver.archivedData(withRootObject: list, requiringSecureCoding: false)
    }

    /// A keyed archive of entries that each have a dictionary of settings (`visible`): `shared` gives them all one instance (one object
    /// of the archive), and otherwise each has its own, as distinct instances of the same content or of its own.
    static func archive(withSettings entries: [(id: String, allowed: Bool, visible: Bool)], shared: Bool) -> Data {
        let one = ["visible": entries.first?.visible ?? true] as NSDictionary
        let list = entries.enumerated().map { index, entry in
            ArchivedEntry(bundleID: entry.id, allowed: entry.allowed, order: index + 1,
                          settings: shared ? one : ["visible": entry.visible] as NSDictionary)
        } as NSArray
        return try! NSKeyedArchiver.archivedData(withRootObject: list, requiringSecureCoding: false)
    }

    /// A property list of entries that each have `settings`, with `visible` in them. With `shared`, they all hold the one dictionary
    /// instance, which a binary property list keeps as one object; otherwise each has its own.
    static func plainWithSettings(_ entries: [(id: String, visible: Bool)], shared: Bool = false) -> Data {
        let one = NSDictionary(dictionary: ["visible": entries.first?.visible ?? true])
        let list = entries.map { entry -> NSDictionary in
            ["bundleID": entry.id, "settings": shared ? one : NSDictionary(dictionary: ["visible": entry.visible])] as NSDictionary
        } as NSArray
        let top: NSDictionary = ["apps": list]
        return try! PropertyListSerialization.data(fromPropertyList: top, format: .binary, options: 0)
    }

    /// A keyed archive of one entry (the test item's) whose `settings` are a dictionary of `width` keys that all lead to one instance of
    /// the dictionary of the level below, `levels` deep: a few hundred bytes of archive, and a tree of `width ^ levels` values when each
    /// reference is followed. (Foundation writes the one instance once.)
    static func sharedGraphArchive(width: Int, levels: Int) -> Data {
        var level: NSDictionary = ["leaf": 1]
        for _ in 0..<levels {
            var next: [String: Any] = [:]
            for index in 0..<width { next["k\(index)"] = level }
            level = next as NSDictionary
        }
        let entry: NSDictionary = ["bundleID": marker, "allowed": true, "settings": level]
        return try! NSKeyedArchiver.archivedData(withRootObject: [entry] as NSArray, requiringSecureCoding: false)
    }

    /// A keyed archive of `holders` entries that each hold one dictionary of `keys` keys: the same instance, so one object of the archive
    /// that is `holders * keys` places when each reference is followed.
    static func sharedBigDictionaryArchive(keys: Int, holders: Int) -> Data {
        var big: [String: Any] = [:]
        for index in 0..<keys { big["k\(index)"] = index }
        let shared = big as NSDictionary
        let entries = (0..<holders).map { ["bundleID": index($0), "settings": shared] as NSDictionary } as NSArray
        return try! NSKeyedArchiver.archivedData(withRootObject: entries, requiringSecureCoding: false)
    }

    private static func index(_ number: Int) -> String { number == 0 ? marker : "com.example.holder\(number)" }

    /// A binary property list of a few hundred bytes that is `2 ^ levels` values when each reference is followed: a list of two
    /// references to the list of the level below, `levels` deep. (Written by hand: Foundation's writer won't keep one object for
    /// the lists, and would write them all out.)
    static func deeplySharedPlist(levels: Int) -> Data {
        var builder = BplistBuilder()
        _ = builder.sharedChain(levels: levels)
        return builder.data()
    }

    /// A list of `apps` that holds an entry (`bundleID`, `allowed`) for the test item and, beside it, the deeply shared list.
    static func approvalsWithDeeplySharedList(levels: Int) -> Data {
        var builder = BplistBuilder()
        let top = builder.reserve()
        let appsKey = builder.add(.string("apps"))
        let apps = builder.reserve()
        let entry = builder.reserve()
        let bundleKey = builder.add(.string("bundleID")), bundle = builder.add(.string(marker))
        let allowedKey = builder.add(.string("allowed")), allowed = builder.add(.bool(true))
        let hostile = builder.sharedChain(levels: levels)
        builder.set(top, .dictionary([(appsKey, apps)]))
        builder.set(apps, .array([entry, hostile]))
        builder.set(entry, .dictionary([(bundleKey, bundle), (allowedKey, allowed)]))
        return builder.data(top: top)
    }

    // MARK: A list shaped like macOS's approvals

    /// Where an entry of the approvals list says its app is: a bundle ID, or the path of a program that has none.
    enum Location {
        case bundle(String)
        case program(String)

        fileprivate var object: [String: Any] {
            switch self {
            case .bundle(let id): ["bundle": ["_0": id]]
            case .program(let path): ["adhocBinary": ["_0": ["relative": path]]]
            }
        }
    }

    /// One entry of the approvals list: whether the app is allowed, and where it says it is (an app can have more than one place).
    struct Approval {
        let isAllowed: Bool
        let locations: [Location]

        init(_ id: String, allowed: Bool) {
            self.init(allowed: allowed, locations: [.bundle(id)])
        }

        init(allowed: Bool, locations: [Location]) {
            isAllowed = allowed
            self.locations = locations
        }

        /// The entry as a property list holds it.
        var object: [String: Any] {
            ["isAllowed": isAllowed, "menuItemLocations": locations.map(\.object)]
        }
    }

    /// The entries of an approvals list, as synthetic apps (`com.example.*`) with both kinds of place, in an order a writer might leave
    /// them in: the test item's is in the middle, and its switch is `testItem`.
    static func approvals(testItem: Bool = true) -> [Approval] {
        [
            Approval("com.example.one", allowed: true),
            Approval(allowed: true, locations: [.program("Example Tools/exampled")]),
            Approval(marker, allowed: testItem),
            Approval(allowed: false, locations: [.program("Example Helper/helperd"), .bundle("com.example.two")]),
            Approval(allowed: true, locations: [.bundle("com.example.three"), .bundle("com.example.three.helper")]),
        ]
    }

    /// The approvals list as a binary property list: an array of entries, as macOS keeps it in `trackedApplications`.
    static func approvalsList(_ entries: [Approval]) -> Data {
        try! PropertyListSerialization.data(fromPropertyList: entries.map(\.object), format: .binary, options: 0)
    }

    /// A keyed archive of a list of dictionaries: each is archived as `NS.keys` and `NS.objects`, lists of references.
    static func dictionaryArchive(_ entries: [Entry]) -> Data {
        let list = entries.map { ["bundleID": $0.id, "allowed": $0.allowed, "order": $0.order, "label": secretLabel] as NSDictionary } as NSArray
        return try! NSKeyedArchiver.archivedData(withRootObject: list, requiringSecureCoding: false)
    }

    /// A property list of a list of one-key dictionaries and a list of numbers: written in one order only, so that writing it again
    /// gives the same bytes.
    static func plainBinary() -> Data {
        let list: [Any] = [["bundleID": marker], ["allowed": true], [secretID: false], [1, 2, 3]]
        return try! PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0)
    }

    static func plainXML() -> Data {
        try! PropertyListSerialization.data(fromPropertyList: [["allowed": true], ["order": 2]] as [Any], format: .xml, options: 0)
    }

    /// A property list of entries by app, each with its own keys.
    static func plainEntries(_ entries: [Entry], format: PropertyListSerialization.PropertyListFormat = .binary) -> Data {
        let list = entries.map { ["bundleID": $0.id, "allowed": $0.allowed, "order": $0.order, "note": secretText, "ssid": secretLabel] as [String: Any] }
        return try! PropertyListSerialization.data(fromPropertyList: ["apps": list], format: format, options: 0)
    }

    /// How many bytes of `a` differ from `b` at the same place; a different length is more than any number of them.
    /// Reads a keyed archive of `ArchivedEntry` back with Foundation: the entries, in order.
    static func decodedEntries(_ archive: Data) throws -> [ArchivedEntry] {
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archive)
        unarchiver.requiresSecureCoding = false
        unarchiver.setClass(ArchivedEntry.self, forClassName: NSStringFromClass(ArchivedEntry.self))
        defer { unarchiver.finishDecoding() }
        guard let list = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? [ArchivedEntry] else { throw CocoaError(.coderReadCorrupt) }
        return list
    }

    static func differingBytes(_ a: Data, _ b: Data) -> Int {
        guard a.count == b.count else { return Int.max }
        return zip(a, b).filter { $0 != $1 }.count
    }

    static func firstDifference(_ a: Data, _ b: Data) -> (offset: Int, was: UInt8, now: UInt8)? {
        for (index, pair) in zip(a, b).enumerated() where pair.0 != pair.1 { return (index, pair.0, pair.1) }
        return nil
    }
}

/// A folder with a plist file in it and a `PlistFileAccess` over it that reads and writes the file itself (never the preferences
/// service), with a codec registered. Held by the test, so that the folder lasts for it.
struct TemporaryFolderForBlobs {
    let folder = TemporaryFolder(prefix: "mantel-blobs")
    let codecID = PlistBlobCodecID(rawValue: "blob")

    var plist: URL { folder.url.appending(path: "sample.plist") }
    private var paths: MantelPaths {
        MantelPaths(root: folder.url.appending(path: "Mantel", directoryHint: .isDirectory),
                    logs: folder.url.appending(path: "Logs", directoryHint: .isDirectory))
    }

    func write(_ dictionary: [String: Any]) throws {
        try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0).write(to: plist)
    }

    func access(codec: any PlistBlobCodec) -> PlistFileAccess {
        let journal = Journal(file: folder.url.appending(path: "journal.json"), clock: SteppingClock())
        return PlistFileAccess(journal: journal, paths: paths, grants: nil, codecs: [codecID: codec], io: .filesOnly, clock: SteppingClock())
    }

    /// The bytes of the blob under `key` in the file, as the file holds them.
    func blob(key: String) throws -> Data {
        let data = try Data(contentsOf: plist)
        let top = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        return try #require(top[key] as? Data)
    }
}


/// A binary property list written by hand, so that a test can make objects that are used many times over, which Foundation's own
/// writer doesn't. References are one byte (fewer than 256 objects), and offsets two.
struct BplistBuilder {
    enum Object {
        case string(String), bool(Bool), integer(Int)
        case array([Int])
        case dictionary([(key: Int, value: Int)])
        case reserved
    }

    private(set) var objects: [Object] = []

    @discardableResult
    mutating func add(_ object: Object) -> Int {
        objects.append(object)
        return objects.count - 1
    }

    /// A place for an object that is given later (`set`), so that others can refer to it first.
    mutating func reserve() -> Int { add(.reserved) }

    mutating func set(_ number: Int, _ object: Object) { objects[number] = object }

    /// `levels` lists, each of two references to the next, and a string at the end; the first is returned.
    mutating func sharedChain(levels: Int) -> Int {
        let first = objects.count
        for level in 0..<levels { add(.array([first + level + 1, first + level + 1])) }
        add(.string("x"))
        return first
    }

    func data(top: Int = 0) -> Data {
        var bytes = Data("bplist00".utf8)
        var offsets: [Int] = []
        for object in objects {
            offsets.append(bytes.count)
            switch object {
            case .reserved: bytes.append(0x00)
            case .bool(let flag): bytes.append(flag ? 0x09 : 0x08)
            case .integer(let number):
                bytes.append(0x11)
                bytes.append(contentsOf: [UInt8(number >> 8 & 0xFF), UInt8(number & 0xFF)])
            case .string(let text):
                let utf8 = Array(text.utf8)
                if utf8.count < 15 {
                    bytes.append(0x50 | UInt8(utf8.count))
                } else {
                    bytes.append(contentsOf: [0x5F, 0x10, UInt8(utf8.count)])
                }
                bytes.append(contentsOf: utf8)
            case .array(let refs):
                bytes.append(0xA0 | UInt8(refs.count))
                bytes.append(contentsOf: refs.map { UInt8($0) })
            case .dictionary(let pairs):
                bytes.append(0xD0 | UInt8(pairs.count))
                bytes.append(contentsOf: pairs.map { UInt8($0.key) })
                bytes.append(contentsOf: pairs.map { UInt8($0.value) })
            }
        }
        let tableStart = bytes.count
        for offset in offsets { bytes.append(contentsOf: [UInt8(offset >> 8 & 0xFF), UInt8(offset & 0xFF)]) }
        var trailer = Data(count: 32)
        trailer[6] = 2
        trailer[7] = 1
        func put(_ value: Int, at index: Int) { for byte in 0..<8 { trailer[index + byte] = UInt8((value >> (8 * (7 - byte))) & 0xFF) } }
        put(objects.count, at: 8)
        put(top, at: 16)
        put(tableStart, at: 24)
        return bytes + trailer
    }
}
