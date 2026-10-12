import Foundation
import MKCommands
import MKCore

/// A property list value the way the shape and the baseline see it: all of what a property list holds, and the reference to an
/// object that a keyed archive keeps (`uid`), which `PlistValue` can't hold.
indirect enum PlistNode: Equatable {
    case null, bool(Bool), integer(Int), real(Double), date, data, string(String), uid(Int)
    case array([PlistNode])
    case dictionary([String: PlistNode])

    /// The name of the kind of value, which is all that is ever reported of one that isn't a flag or a number.
    var typeName: String {
        switch self {
        case .null: "null"
        case .bool: "bool"
        case .integer: "integer"
        case .real: "real"
        case .date: "date"
        case .data: "data"
        case .string: "string"
        case .uid: "uid"
        case .array: "array"
        case .dictionary: "dictionary"
        }
    }

    /// How deep a value is followed, and how many values are read: a blob that is deeper or bigger is cut, and says so.
    static let maximumDepth = 24
    static let maximumNodes = 200_000

    /// A property list read from bytes: its value, and the format it is in (`binary`, `xml`, `openStep`).
    static func parse(_ blob: Data) throws -> (root: PlistNode, format: String) {
        let (root, format, _) = try parseWithLimit(blob)
        return (root, format)
    }

    /// The same, and whether it was cut at `maximumNodes` values (a list that refers to one object many times is a small blob and an
    /// enormous tree): what is past the limit is `null`.
    static func parseWithLimit(_ blob: Data) throws -> (root: PlistNode, format: String, truncated: Bool) {
        if blob.starts(with: BinaryPlist.magic) {
            let plist = try BinaryPlist(blob)
            var budget = maximumNodes
            let root = try node(of: plist.top, in: plist, depth: 0, budget: &budget)
            return (root, "binary", budget <= 0)
        }
        var format = PropertyListSerialization.PropertyListFormat.binary
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: blob, options: [], format: &format)
        } catch {
            throw PlistBlobCodecError.notAPropertyList
        }
        var budget = maximumNodes
        let name = format == .xml ? "xml" : format == .openStep ? "openStep" : "binary"
        let root = node(of: object, depth: 0, budget: &budget)
        return (root, name, budget <= 0)
    }

    private static func node(of object: Int, in plist: BinaryPlist, depth: Int, budget: inout Int) throws -> PlistNode {
        budget -= 1
        guard budget > 0, depth <= maximumDepth else { return .null }
        switch plist.objects[object] {
        case .null: return .null
        case .bool(let flag): return .bool(flag)
        case .integer(let number): return .integer(number)
        case .real(let number): return .real(number)
        case .date: return .date
        case .data: return .data
        case .string(let text): return .string(text)
        case .uid(let value): return .uid(value)
        case .array(let refs), .set(let refs):
            return .array(try refs.map { try node(of: $0, in: plist, depth: depth + 1, budget: &budget) })
        case .dictionary(let keys, let values):
            var entries: [String: PlistNode] = [:]
            for (key, value) in zip(keys, values) {
                guard let name = plist.string(key) else { continue }
                entries[name] = try node(of: value, in: plist, depth: depth + 1, budget: &budget)
            }
            return .dictionary(entries)
        }
    }

    private static func node(of object: Any, depth: Int, budget: inout Int) -> PlistNode {
        budget -= 1
        guard budget > 0, depth <= maximumDepth else { return .null }
        switch object {
        case let text as String: return .string(text)
        case is Date: return .date
        case is Data: return .data
        case let array as [Any]: return .array(array.map { node(of: $0, depth: depth + 1, budget: &budget) })
        case let dictionary as [String: Any]:
            return .dictionary(dictionary.mapValues { node(of: $0, depth: depth + 1, budget: &budget) })
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            return CFNumberIsFloatType(number as CFNumber) ? .real(number.doubleValue) : .integer(number.intValue)
        default:
            // The reference of a keyed archive, which has no value of its own to read here.
            return CFCopyTypeIDDescription(CFGetTypeID(object as CFTypeRef)) as String? == "CFKeyedArchiverUID" ? .uid(-1) : .null
        }
    }

    // MARK: Looking inside

    /// The keyed archive's list of objects, when this is the top of one.
    var archiveObjects: [PlistNode]? {
        guard case .dictionary(let top) = self, case .string? = top["$archiver"], case .array(let objects)? = top["$objects"] else {
            return nil
        }
        return objects
    }

    /// The text this holds, or the text of the archive object it refers to.
    func text(in objects: [PlistNode]?) -> String? {
        switch self {
        case .string(let text): return text
        case .uid(let index): if let objects, objects.indices.contains(index), case .string(let text) = objects[index] { return text }
        default: break
        }
        return nil
    }

    /// Whether `text` is a key or a string value anywhere inside.
    func contains(string text: String, depth: Int = 0) -> Bool {
        guard depth <= Self.maximumDepth else { return false }
        switch self {
        case .string(let held): return held == text
        case .dictionary(let entries): return entries.contains { $0.key == text || $0.value.contains(string: text, depth: depth + 1) }
        case .array(let elements): return elements.contains { $0.contains(string: text, depth: depth + 1) }
        default: return false
        }
    }

    /// Whether some way of following `steps` from this value ends at the string `target`: what a `matchingPath` step reads (see
    /// `PlistValue`), on the value the probes look at. A step that can't be taken, or is a `matchingPath`, is a way that ends nowhere.
    /// The value is a tree read within `maximumNodes` and no reference is followed, so no value is visited more than once for a step.
    func reaches(_ target: String, along steps: ArraySlice<KeyPathStep>) -> Bool {
        guard let step = steps.first else {
            if case .string(let held) = self { return held == target }
            return false
        }
        let rest = steps.dropFirst()
        switch (step, self) {
        case (.key(let key), .dictionary(let entries)):
            return entries[key]?.reaches(target, along: rest) ?? false
        case (.index(let position), .array(let elements)):
            return elements.indices.contains(position) && elements[position].reaches(target, along: rest)
        case (.matching(let key, let value), .array(let elements)):
            guard let element = elements.first(where: { element in
                guard case .dictionary(let entries) = element, case .string(let held)? = entries[key] else { return false }
                return held == value
            }) else { return false }
            return element.reaches(target, along: rest)
        case (.anyElement, .array(let elements)):
            return elements.contains { $0.reaches(target, along: rest) }
        default:
            return false
        }
    }

    /// The names of the classes an archive holds (`$classname`, and the names in each `$classes`, which are its superclasses), sorted.
    var archiveClassNames: [String] {
        guard let objects = archiveObjects else { return [] }
        var names: Set<String> = []
        for object in objects {
            guard case .dictionary(let entries) = object else { continue }
            if case .string(let name)? = entries["$classname"] { names.insert(name) }
            if case .array(let classes)? = entries["$classes"] {
                for case .string(let name) in classes { names.insert(name) }
            }
        }
        return names.sorted()
    }
}

/// The work a report may do on one blob, as nodes looked at: one limit for the shape, the leaves, the search for the test item and the
/// reading of an archive's dictionaries. A keyed archive that refers to one object many times is a small blob that is a very large
/// tree when each reference is followed, so what is followed is counted, and a report that runs out says so (`truncated`) and keeps
/// what it had. (The walk of the leaves has a second one, of its own, for finding where the test item's ID is inside each entry of a
/// list: see `BlobShape.leavesWalk`.)
final class WorkBudget {
    private(set) var remaining: Int
    private(set) var isExhausted = false

    init(_ limit: Int = PlistNode.maximumNodes) {
        remaining = limit
    }

    private var noted = false

    /// True once, the first time it is asked after the work has run out: the place where that was noticed is where a walk says so.
    func noteExhaustion() -> Bool {
        guard isExhausted, !noted else { return false }
        noted = true
        return true
    }

    /// Takes `count` nodes of work. False when there aren't that many left, and from then on for everything.
    func spend(_ count: Int = 1) -> Bool {
        guard !isExhausted, remaining >= count else {
            isExhausted = true
            remaining = 0
            return false
        }
        remaining -= count
        return true
    }
}

/// A keyed archive's list of objects: where a reference leads, and a dictionary or an array that was archived as one read as what it
/// was. (An archived dictionary keeps its keys and its values as two lists of references, `NS.keys` and `NS.objects`; an archived
/// array keeps `NS.objects` alone.) The same view `FlipWalker` takes of a blob in bytes, for the reports.
struct ArchiveView {
    let objects: [PlistNode]
    let budget: WorkBudget

    init(objects: [PlistNode], budget: WorkBudget = WorkBudget()) {
        self.objects = objects
        self.budget = budget
    }

    /// How many references are followed one after the other: a reference to a reference ends, and a cycle with it.
    private static let hops = 4

    /// What a reference leads to; any other node as it is.
    func target(of node: PlistNode) -> PlistNode {
        var current = node
        for _ in 0..<Self.hops {
            guard case .uid(let index) = current, objects.indices.contains(index) else { return current }
            current = objects[index]
        }
        return current
    }

    /// The node as what was archived: references followed; an archived dictionary as a dictionary (its keys are the strings the keys
    /// lead to, its values the references the values are; what is only the archive's own, `$class`, is left out), an archived array as
    /// an array of references. Nil when the work is used up: each call costs a node, and an archived dictionary as many as it has keys.
    func logical(_ node: PlistNode) -> PlistNode? {
        guard budget.spend(1) else { return nil }
        let resolved = target(of: node)
        guard case .dictionary(let entries) = resolved else { return resolved }
        let keys = entries["NS.keys"].map(target(of:)), values = entries["NS.objects"].map(target(of:))
        if case .array(let keyReferences)? = keys, case .array(let valueReferences)? = values {
            guard budget.spend(keyReferences.count) else { return nil }
            var archived: [String: PlistNode] = [:]
            for (position, reference) in keyReferences.enumerated() where position < valueReferences.count {
                if case .string(let name) = target(of: reference) { archived[name] = valueReferences[position] }
            }
            return .dictionary(archived)
        }
        if case .array(let valueReferences)? = values, keys == nil { return .array(valueReferences) }
        return resolved
    }

    /// The text a node is or leads to.
    func text(of node: PlistNode) -> String? {
        if case .string(let text) = target(of: node) { return text }
        return nil
    }
}

/// What the probes may say of a key's name, which can be data: a bundle ID, a network's name, a file's. A key is said as it is only
/// when it looks like a name that is part of a format: no `.` and no `/`, at most 40 characters, an identifier (`allowed`,
/// `bundleIdentifier`, `$objects`, `_flags`), and in a dictionary of no more than 8 keys (a dictionary that is a list of apps or of
/// networks has a key for each, which are data though they look like names). The keys a keyed archive is made of (`NS.keys`,
/// `NS.objects`, `$class`, `$classname`, `$classes`, `$archiver`, `$version`, `$top`, `$objects`) are said as they are in any. Any
/// other key is `‹key›`. The one name that is said of an app is the test item's own, which is Mantel's, and is `‹test item›` where a
/// key is the test item's ID.
enum ShownKey {
    static let redacted = "‹key›"
    static let testItem = "‹test item›"
    private static let archiveKeys: Set<String> = ["NS.keys", "NS.objects", "$class", "$classname", "$classes", "$archiver", "$version",
                                                   "$top", "$objects"]
    static let longestKey = 40
    /// A dictionary of more keys than this is keyed by data.
    static let mostKeysOfAFormat = 8

    /// Whether the key is said as it is, in a dictionary of `siblings` keys (the key itself counted).
    static func isVerbatim(_ key: String, among siblings: Int = 1) -> Bool {
        if archiveKeys.contains(key) { return true }
        guard siblings <= mostKeysOfAFormat, key.utf8.count <= longestKey else { return false }
        return isIdentifier(key)
    }

    /// `[A-Za-z_$][A-Za-z0-9_$]*`, which has no `.` and no `/` in it. (By hand: it is asked of every key of every dictionary looked at,
    /// and a pattern is much slower.)
    private static func isIdentifier(_ key: String) -> Bool {
        var first = true
        for byte in key.utf8 {
            let isLetter = (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || byte == 0x5F || byte == 0x24
            let isDigit = byte >= 0x30 && byte <= 0x39
            guard isLetter || (isDigit && !first) else { return false }
            first = false
        }
        return !first
    }

    /// How the key is said: as it is, `‹test item›` for the test item's ID, `‹key›` for any other.
    static func text(_ key: String, marker: String, among siblings: Int = 1) -> String {
        if key == marker { return testItem }
        return isVerbatim(key, among: siblings) ? key : redacted
    }

    /// Whether a step with this key says nothing about another app, so that what is below it may have its value said: a key that is
    /// said as it is, or the test item's.
    static func isOpen(_ key: String, marker: String, among siblings: Int = 1) -> Bool {
        key == marker || isVerbatim(key, among: siblings)
    }
}

/// What a blob that is kept as bytes inside a plist key looks like, without what it says: its size, what it begins with, whether
/// it is a property list and in what format, whether it is a keyed archive and of what classes, the shape of what is inside (names
/// of keys that are part of the format, and types, never a string value), and whether the test item is in it.
public enum BlobShape {
    /// How deep the structure is described.
    static let structureDepth = 6
    static let maximumKeys = 300

    /// The report of a blob. `marker` is the test item's bundle ID: it is looked for, and the entry that holds it is described by
    /// its keys and types; no other string is ever reported, and no other app's ID.
    ///
    /// The work is limited (`WorkBudget`): a report that runs out has `"truncated": true`, says `‹truncated›` where it stopped, and
    /// keeps what it had.
    public static func describe(_ blob: Data, marker: String) -> JSONValue {
        var report: [String: JSONValue] = [
            "byteCount": .number(Double(blob.count)),
            "magic": .string(blob.prefix(8).map { String(format: "%02x", $0) }.joined()),
        ]
        guard let (root, format, parseCut) = try? PlistNode.parseWithLimit(blob) else {
            report["parsesAsPropertyList"] = .bool(false)
            report["isKeyedArchive"] = .bool(false)
            report["markerFound"] = .bool(false)
            report["truncated"] = .bool(false)
            return .object(report)
        }
        let budget = WorkBudget()
        report["parsesAsPropertyList"] = .bool(true)
        report["plistFormat"] = .string(format)
        let objects = root.archiveObjects
        let view = objects.map { ArchiveView(objects: $0, budget: budget) }
        report["isKeyedArchive"] = .bool(objects != nil)
        if objects != nil { report["archiveClasses"] = .array(classes(root.archiveClassNames).map(JSONValue.string)) }
        report["structure"] = shape(of: root, depth: 0, marker: marker, view: nil, budget: budget)
        report["entryCount"] = entryCount(of: root, objects: objects).map { .number(Double($0)) } ?? .null
        report["markerFound"] = .bool(root.contains(string: marker))
        report["markerEntryShape"] = markerEntry(in: root, marker: marker, view: view, budget: budget).map {
            shape(of: $0, depth: 0, marker: marker, view: view, budget: budget)
        } ?? .null
        report["truncated"] = .bool(budget.isExhausted || parseCut)
        return .object(report)
    }

    /// The class names an archive may say: the system's (`NS…`, `__NS…`), sorted, then `‹class›` for each other one.
    static func classes(_ names: [String]) -> [String] {
        let system = names.filter { $0.hasPrefix("NS") || $0.hasPrefix("__NS") }
        return system + Array(repeating: "‹class›", count: names.count - system.count)
    }

    /// What a report says where the work ran out.
    static let truncatedMarker = "‹truncated›"

    /// The types of what is in a value, down to `structureDepth`. With a `view` of a keyed archive, a reference is followed to what it
    /// leads to, and an archived dictionary or array is described as the dictionary or array it was. Each value looked at, and each
    /// entry said of it, costs the `budget` a node; what is left undone when it runs out is `‹truncated›`.
    /// - A dictionary says how many keys it has (`keyCount`), how many of them are not said (`redactedKeyCount`), the shape of what is
    ///   under each key that is said (`ShownKey`), the shape of what is under the test item's key, and, for the keys that aren't said,
    ///   how many there are, the types of what they hold and the shape under the first of them.
    /// - An array says its length, the types of its elements and the shape of the first.
    static func shape(of value: PlistNode, depth: Int, marker: String, view: ArchiveView?, budget: WorkBudget) -> JSONValue {
        guard budget.spend(1) else { return .string(truncatedMarker) }
        var read = value
        if let view {
            guard let logical = view.logical(value) else { return .string(truncatedMarker) }
            read = logical
        }
        switch read {
        case .dictionary(let entries):
            let count = entries.count
            guard budget.spend(count) else { return .string(truncatedMarker) }
            let hidden = entries.keys.filter { !ShownKey.isOpen($0, marker: marker, among: count) }.sorted()
            var object: [String: JSONValue] = ["type": .string("dictionary"), "keyCount": .number(Double(count)),
                                               "redactedKeyCount": .number(Double(hidden.count))]
            guard depth < structureDepth else { return .object(object) }
            var described: [String: JSONValue] = [:]
            let said = entries.keys.filter { ShownKey.isOpen($0, marker: marker, among: count) }.sorted()
            for key in said.prefix(maximumKeys) {
                described[ShownKey.text(key, marker: marker, among: count)] = shape(of: entries[key]!, depth: depth + 1, marker: marker,
                                                                                     view: view, budget: budget)
            }
            if let first = hidden.first {
                var types: Set<String> = []
                for key in hidden {
                    guard let type = typeName(of: entries[key]!, view: view, budget: budget) else {
                        types.insert(truncatedMarker)
                        break
                    }
                    types.insert(type)
                }
                described[ShownKey.redacted] = .object([
                    "count": .number(Double(hidden.count)),
                    "valueTypes": .array(types.sorted().map(JSONValue.string)),
                    "first": shape(of: entries[first]!, depth: depth + 1, marker: marker, view: view, budget: budget),
                ])
            }
            object["entries"] = .object(described)
            if said.count > maximumKeys { object["truncated"] = .bool(true) }
            return .object(object)
        case .array(let elements):
            guard budget.spend(elements.count) else { return .string(truncatedMarker) }
            var types: Set<String> = []
            for element in elements {
                guard let type = typeName(of: element, view: view, budget: budget) else {
                    types.insert(truncatedMarker)
                    break
                }
                types.insert(type)
            }
            var object: [String: JSONValue] = ["type": .string("array"), "count": .number(Double(elements.count)),
                                               "elementTypes": .array(types.sorted().map(JSONValue.string))]
            if let first = elements.first, depth < structureDepth {
                object["first"] = shape(of: first, depth: depth + 1, marker: marker, view: view, budget: budget)
            }
            return .object(object)
        default:
            return .string(read.typeName)
        }
    }

    /// The kind of value a node is, as a view of an archive reads it; nil when the work is used up.
    private static func typeName(of node: PlistNode, view: ArchiveView?, budget: WorkBudget) -> String? {
        guard budget.spend(1) else { return nil }
        guard let view else { return node.typeName }
        return view.logical(node)?.typeName
    }

    /// How many entries the list has: the top-level array or dictionary, or the objects of an archive.
    private static func entryCount(of root: PlistNode, objects: [PlistNode]?) -> Int? {
        if let objects { return objects.count }
        switch root {
        case .array(let elements): return elements.count
        case .dictionary(let entries): return entries.count
        default: return nil
        }
    }

    /// The entry that holds the marker: in an archive, the object, read as what was archived, that has the marker's string as one of
    /// its values (or the one a dictionary keyed by it has for it); otherwise the element of the list, the outermost one on the way
    /// to the marker, that has it anywhere inside it (an entry that holds its app's ID some levels down is the whole entry, not the
    /// dictionary the ID is in), or, where there is no list, the value under a key that is the marker, or the dictionary that has it
    /// as a value. Nil when there is none, and when the work ran out before it was found.
    static func markerEntry(in root: PlistNode, marker: String, view: ArchiveView?, budget: WorkBudget) -> PlistNode? {
        if let view {
            for object in view.objects {
                guard let logical = view.logical(object) else { return nil }
                guard case .dictionary(let entries) = logical, budget.spend(entries.count) else { continue }
                if let keyed = entries[marker] { return view.logical(keyed) }
                if entries.values.contains(where: { view.text(of: $0) == marker }) { return logical }
            }
            return nil
        }
        return search(root, marker: marker, depth: 0, element: nil)
    }

    /// `element` is the element of the outermost list on the way here, which is what is found when the marker is found below it.
    private static func search(_ node: PlistNode, marker: String, depth: Int, element: PlistNode?) -> PlistNode? {
        guard depth <= PlistNode.maximumDepth else { return nil }
        switch node {
        case .dictionary(let entries):
            if let entry = entries[marker] { return element ?? entry }
            if entries.values.contains(.string(marker)) { return element ?? node }
            for key in entries.keys.sorted() {
                if let found = search(entries[key]!, marker: marker, depth: depth + 1, element: element) { return found }
            }
        case .array(let elements):
            for inner in elements {
                if let found = search(inner, marker: marker, depth: depth + 1, element: element ?? inner) { return found }
            }
        default:
            break
        }
        return nil
    }

    // MARK: Leaves

    /// A leaf of the value: its type, and its value when it is a flag or a number at a place that says nothing about another app. More
    /// than one leaf can have a path when a step of it is `‹key›` (the keys that aren't said): then `count` says how many, and the
    /// value is left out.
    struct Leaf: Equatable {
        let type: String
        let value: JSONValue?
        let count: Int

        init(type: String, value: JSONValue?, count: Int = 1) {
            self.type = type
            self.value = value
            self.count = count
        }

        func merged(with other: Leaf) -> Leaf {
            Leaf(type: type == other.type ? type : "mixed", value: value == other.value ? value : nil, count: count + other.count)
        }
    }

    /// Every leaf, by its path in the journal's segment form (`/k:…`, `/i:…`, `/m:…`, `/mp:…`, `/*`): the test item's entry in an array
    /// is written `/m:<key>=<test item>` when the entry holds its ID under a key of its own, and `/mp:<way to the ID>=<test item>`
    /// when the ID is further down in it (`/mp:k:menuItemLocations,*,k:bundle,k:_0=<test item>`: the same path wherever macOS puts
    /// the entry); any other element is by its position. A key is said as `ShownKey` says it. Only flags and whole numbers have a
    /// value, and only at paths none of whose steps is a key that isn't said (what is under `‹key›` has its type only, and leaves
    /// under the same path are counted). Nil for a blob that isn't a property list.
    ///
    /// In a list that has an entry written `/mp:…` the other entries are written `/*`, with their type and no value, counted: the
    /// order a writer puts the entries in is its own, and a position would say something else of the same entry each time it moves.
    ///
    /// In a keyed archive the tree that is walked is what was archived, from `$top`: a reference is followed to what it leads to (a
    /// flag or a number has its type and value), and a dictionary or an array that was archived as one is the dictionary or array it
    /// was. The archive's own list of objects is not walked: a place in it moves when the archive is written again, and is no
    /// place of the list.
    ///
    /// The work is limited (`WorkBudget`): when it runs out the walk stops, the place it stopped at is a leaf of type `‹truncated›`,
    /// and `truncated` is true; what was gathered is kept. Finding where the ID is inside the entries of a list has a limit of its own
    /// (looking in an entry that is as large as the blob is allowed isn't to leave nothing for describing what is in the others);
    /// when that runs out, an entry it hadn't found is written by its position, and `truncated` is true as well.
    static func leavesWalk(of blob: Data, marker: String) -> (leaves: [String: Leaf], truncated: Bool)? {
        guard let (root, _, parseCut) = try? PlistNode.parseWithLimit(blob) else { return nil }
        var leaves: [String: Leaf] = [:]
        let budget = WorkBudget()
        let locating = WorkBudget()
        if let objects = root.archiveObjects, case .dictionary(let top) = root {
            let view = ArchiveView(objects: objects, budget: budget)
            for key in top.keys.sorted() where key != "$objects" {
                walk(top[key]!, path: KeyPathText.segment(.key(ShownKey.text(key, marker: marker, among: top.count))),
                     open: ShownKey.isOpen(key, marker: marker, among: top.count), view: view, marker: marker, depth: 1, budget: budget,
                     locating: locating, into: &leaves)
            }
        } else {
            walk(root, path: "", open: true, view: nil, marker: marker, depth: 0, budget: budget, locating: locating, into: &leaves)
        }
        return (leaves, budget.isExhausted || locating.isExhausted || parseCut)
    }

    /// The leaves of a blob, without whether the walk was cut.
    static func leaves(of blob: Data, marker: String) -> [String: Leaf]? {
        leavesWalk(of: blob, marker: marker)?.leaves
    }

    private static func walk(_ value: PlistNode, path: String, open: Bool, view: ArchiveView?, marker: String, depth: Int,
                             budget: WorkBudget, locating: WorkBudget, into leaves: inout [String: Leaf]) {
        guard depth <= PlistNode.maximumDepth else { return }
        // Each place looked at costs a node; the place where the work runs out is said, once.
        guard budget.spend(1) else {
            if budget.noteExhaustion() { recordTruncation(at: path, into: &leaves) }
            return
        }
        var node = value
        if let view {
            guard let logical = view.logical(value) else {
                if budget.noteExhaustion() { recordTruncation(at: path, into: &leaves) }
                return
            }
            node = logical
        }
        switch node {
        case .dictionary(let entries):
            let count = entries.count
            guard budget.spend(count) else {
                if budget.noteExhaustion() { recordTruncation(at: path, into: &leaves) }
                return
            }
            for key in entries.keys.sorted() {
                walk(entries[key]!, path: path + KeyPathText.segment(.key(ShownKey.text(key, marker: marker, among: count))),
                     open: open && ShownKey.isOpen(key, marker: marker, among: count), view: view, marker: marker, depth: depth + 1,
                     budget: budget, locating: locating, into: &leaves)
            }
        case .array(let elements):
            guard budget.spend(elements.count) else {
                if budget.noteExhaustion() { recordTruncation(at: path, into: &leaves) }
                return
            }
            // Where the ID is, in each element that doesn't hold it under a key of its own (a plain list only: an archive's entries do).
            let furtherDown = view == nil ? elements.map { location(of: marker, furtherThanAKeyIn: $0, locating: locating) } : []
            let byTheWayToTheID = furtherDown.contains { $0 != nil }
            for (position, element) in elements.enumerated() {
                guard !budget.isExhausted else {
                    if budget.noteExhaustion() { recordTruncation(at: path, into: &leaves) }
                    return
                }
                if let entry = markerKey(of: element, marker: marker, view: view, budget: budget) {
                    walk(element, path: path + KeyPathText.segment(.matching(key: entry.shown, value: marker)),
                         open: open && entry.isOpen, view: view, marker: marker, depth: depth + 1, budget: budget, locating: locating,
                         into: &leaves)
                } else if let way = furtherDown.indices.contains(position) ? furtherDown[position] : nil {
                    walk(element, path: path + KeyPathText.segment(.matchingPath(path: way.steps, value: marker)),
                         open: open && way.isOpen, view: view, marker: marker, depth: depth + 1, budget: budget, locating: locating,
                         into: &leaves)
                } else if byTheWayToTheID {
                    walk(element, path: path + KeyPathText.segment(.anyElement), open: false, view: view, marker: marker, depth: depth + 1,
                         budget: budget, locating: locating, into: &leaves)
                } else {
                    walk(element, path: path + KeyPathText.segment(.index(position)), open: open, view: view, marker: marker,
                         depth: depth + 1, budget: budget, locating: locating, into: &leaves)
                }
            }
        case .bool(let flag):
            record(Leaf(type: "bool", value: open ? .bool(flag) : nil), at: path, into: &leaves)
        case .integer(let number):
            record(Leaf(type: "integer", value: open ? .number(Double(number)) : nil), at: path, into: &leaves)
        default:
            record(Leaf(type: node.typeName, value: nil), at: path, into: &leaves)
        }
    }

    /// The place where the work ran out: a leaf of type `‹truncated›` of its own, under the path the walk was at.
    private static func recordTruncation(at path: String, into leaves: inout [String: Leaf]) {
        leaves[path + KeyPathText.segment(.key(truncatedMarker))] = Leaf(type: truncatedMarker, value: nil)
    }

    private static func record(_ leaf: Leaf, at path: String, into leaves: inout [String: Leaf]) {
        leaves[path] = leaves[path].map { $0.merged(with: leaf) } ?? leaf
    }

    /// Where the marker is inside an element that doesn't hold it as a value of its own (such an element is `/m:`, and has no way to
    /// say): see `location(of:in:locating:)`.
    private static func location(of marker: String, furtherThanAKeyIn element: PlistNode,
                                 locating: WorkBudget) -> (steps: [KeyPathStep], isOpen: Bool)? {
        if case .dictionary(let entries) = element, locating.spend(entries.count), entries.values.contains(.string(marker)) { return nil }
        return location(of: marker, in: element, locating: locating)
    }

    /// Where the marker is inside an element: the steps to the first string equal to it, going by the sorted keys, as a path of a
    /// `matchingPath` says them (a key as `ShownKey` says it, and any element for each list), and whether none of the keys on the way is
    /// one that isn't said. Nil when it isn't inside, and when `locating` ran out.
    ///
    /// Each value looked at costs `locating` a node, and a dictionary as many as it has keys, before it is looked into.
    private static func location(of marker: String, in node: PlistNode, locating: WorkBudget,
                                 depth: Int = 0) -> (steps: [KeyPathStep], isOpen: Bool)? {
        guard depth <= PlistNode.maximumDepth, locating.spend(1) else { return nil }
        switch node {
        case .string(let text):
            return text == marker ? ([], true) : nil
        case .dictionary(let entries):
            guard locating.spend(entries.count) else { return nil }
            for key in entries.keys.sorted() {
                guard let found = location(of: marker, in: entries[key]!, locating: locating, depth: depth + 1) else { continue }
                let step = KeyPathStep.key(ShownKey.text(key, marker: marker, among: entries.count))
                return ([step] + found.steps, found.isOpen && ShownKey.isOpen(key, marker: marker, among: entries.count))
            }
        case .array(let elements):
            guard locating.spend(elements.count) else { return nil }
            for element in elements {
                if let found = location(of: marker, in: element, locating: locating, depth: depth + 1) {
                    return ([.anyElement] + found.steps, found.isOpen)
                }
            }
        default:
            break
        }
        return nil
    }

    /// The key of an element (read as what it was archived as, in an archive) under which the marker is held, the first by name: as it
    /// is said, and whether it is a key that may be said. Nil for an element that isn't a dictionary or doesn't hold the marker, and
    /// when the work ran out (the walk notices it next).
    private static func markerKey(of element: PlistNode, marker: String, view: ArchiveView?, budget: WorkBudget) -> (shown: String, isOpen: Bool)? {
        var read = element
        if let view {
            guard let logical = view.logical(element) else { return nil }
            read = logical
        }
        guard case .dictionary(let entries) = read, budget.spend(entries.count) else { return nil }
        let held: (PlistNode) -> String? = { node in view?.text(of: node) ?? { if case .string(let text) = node { text } else { nil } }() }
        guard let key = entries.keys.sorted().first(where: { held(entries[$0]!) == marker }) else { return nil }
        return (ShownKey.text(key, marker: marker, among: entries.count), ShownKey.isVerbatim(key, among: entries.count))
    }

    /// The leaves that differ from `baseline`: ones that are in both and changed (type, value or count), ones the baseline doesn't have
    /// and ones it has that are gone. Each as `{path, wasType, nowType}`, with `was` and `now` for a flag or a number that may be said
    /// and `wasCount` and `nowCount` for a path with more than one leaf.
    static func changes(from baseline: [String: Leaf], to current: [String: Leaf]) -> [JSONValue] {
        var changed: [JSONValue] = []
        for path in Set(baseline.keys).union(current.keys).sorted() {
            let before = baseline[path], after = current[path]
            guard before != after else { continue }
            var record: [String: JSONValue] = ["path": .string(path), "wasType": before.map { .string($0.type) } ?? .null,
                                               "nowType": after.map { .string($0.type) } ?? .null]
            if let value = before?.value { record["was"] = value }
            if let value = after?.value { record["now"] = value }
            if let count = before?.count, count != 1 { record["wasCount"] = .number(Double(count)) }
            if let count = after?.count, count != 1 { record["nowCount"] = .number(Double(count)) }
            changed.append(.object(record))
        }
        return changed
    }
}
