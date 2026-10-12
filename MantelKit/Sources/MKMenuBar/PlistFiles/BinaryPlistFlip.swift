import Foundation
import MKCore

/// Changes a true or false inside a binary property list (`bplist00`) in place, one place in the bytes and nothing else: no
/// other byte of the blob is touched, so what a writer of macOS's own made stays as it made it, which re-encoding the whole list
/// can't promise. A keyed archive (it holds object references, which `PlistValue` can't) is read through its list of objects: a
/// path follows a reference to the object it names.
///
/// - **Reading** (`value(at:)`) follows the path through dictionaries (`key`), arrays (`index`), the elements of an array that
///   are dictionaries holding a string (`matching`) and the one element of an array in which a path of its own reaches a string
///   (`matchingPath`, which is what finds an entry whose app is named some levels down; two elements that reach it are
///   `ambiguousMatch`, and none is `noMatch`). In an archive an element, or a value, that is a reference is followed to the
///   object it names, and a dictionary that was archived as one (`NS.keys` and `NS.objects`) is read as the dictionary it was, an
///   array archived as one (`NS.objects` alone) as the array.
/// - **The work** of following a path is limited, as reading a value is (`PlistValue.defaultNodeLimit`): each object looked at costs
///   what it holds, charged before it is looked into, so a list that refers to one object many times, followed by a path of steps for
///   any element, is refused (`tooLarge`) instead of being followed for as long as that takes.
/// - **Changing** (`setting`) takes a true or false at a place that holds one. If the object is used by that one place only, its
///   marker byte is flipped (`0x08` and `0x09`). A binary property list keeps a single object for every equal value, so most
///   flags share one: flipping it would change every entry that is true (or false). Then the one place is pointed at another
///   true or false object that the list already has, which is one reference of one or two bytes; and if there is none, nothing is
///   changed (`PlistBlobCodecError.sharedValue`). It never changes another entry's value: below the step that finds the entry (the
///   first `matching` or `matchingPath` step), every container the path goes through must belong to that place alone too (a settings
///   dictionary that two entries share is one object in the list, and is refused, as is an archive object that two entries refer
///   to). What a `matchingPath` reads to find the entry is not changed, and may be shared.
/// - **Refused**, with nothing changed: a blob that isn't `bplist00`, one that doesn't add up, a place that holds something other
///   than true or false, and a value that isn't one.
public struct BinaryPlistFlip: PlistBlobCodec {
    public init() {}

    public func value(at path: PlistKeyPath, in blob: Data) throws -> PlistValue? {
        let plist = try BinaryPlist(blob)
        let walker = FlipWalker(plist)
        let place: FlipWalker.Place
        do {
            place = try walker.locate(path)
        } catch is KeyPathError {
            // Not there (or not one place): nothing to read. A list too large to follow is not that, and is thrown.
            return nil
        }
        var remaining = PlistValue.defaultNodeLimit
        return try walker.value(of: place.valueObject, depth: 0, remaining: &remaining)
    }

    public func setting(_ value: PlistValue?, at path: PlistKeyPath, in blob: Data) throws -> Data {
        guard case .bool(let wanted)? = value else { throw PlistBlobCodecError.notABoolean }
        let plist = try BinaryPlist(blob)
        let walker = FlipWalker(plist)
        let place = try walker.locate(path)
        guard case .bool(let current) = plist.objects[place.valueObject] else { throw PlistBlobCodecError.notABoolean }
        guard current != wanted else { return blob }

        // What the change goes through, below the entry, must be this entry's alone: a container the list shares with another entry
        // would change that entry as well. (The flag itself may be shared; that is dealt with below.)
        let counts = plist.referenceCounts()
        guard walker.isAloneBelowTheEntry(place, counts: counts) else { throw PlistBlobCodecError.sharedValue }

        var changed = plist.bytes
        if walker.isUsedOnlyBy(place, counts: counts) || place.slot == nil {
            changed[plist.offsets[place.valueObject]] = wanted ? 0x09 : 0x08
            return changed
        }
        // Shared: this place is pointed at another object that holds what is wanted, if the list has one.
        guard let slot = place.slot, let replacement = walker.otherObject(holding: wanted, than: place),
              let position = plist.referencePosition(container: slot.container, index: slot.index),
              replacement < (1 << (8 * plist.referenceSize)) else { throw PlistBlobCodecError.sharedValue }
        for index in 0..<plist.referenceSize {
            changed[position + index] = UInt8((replacement >> (8 * (plist.referenceSize - 1 - index))) & 0xFF)
        }
        return changed
    }
}

/// The places of a binary property list, followed by a path.
struct FlipWalker {
    /// Where a reference is: the container that holds it, and its number among the container's references.
    struct Slot: Equatable {
        let container: Int
        let index: Int
    }

    /// What a path ends at: the place that refers to it (nil for the top object), the object the place refers to, and the object
    /// that has the value (the same, unless the place refers to an archive's object by its number). `trail` is each step's place, from
    /// the first `matching` step on (from the first step when there is none), with the object that held the step's slot.
    struct Place {
        let slot: Slot?
        let referredObject: Int
        let valueObject: Int
        var trail: [Step] = []
    }

    /// One step of the way to a place: where it ended, and what the slot it took was in.
    struct Step {
        let place: Place
        /// The container the slot is in, and the object the step started from. They differ when the container is a list of an
        /// archived dictionary (`NS.objects`), which the dictionary refers to.
        let container: Int
        let start: Int
    }

    enum View {
        case array([Slot])
        case dictionary([(key: String, slot: Slot)])
    }

    let plist: BinaryPlist
    /// The objects of the keyed archive, when the top object is its dictionary: where an archive's references lead.
    private let archive: [Int]?

    init(_ plist: BinaryPlist) {
        self.plist = plist
        if case .dictionary(let keys, let values) = plist.objects[plist.top] {
            var objectsList: [Int]?
            var isArchive = false
            for (key, value) in zip(keys, values) {
                if plist.string(key) == "$archiver" { isArchive = true }
                if plist.string(key) == "$objects", case .array(let refs) = plist.objects[value] { objectsList = refs }
            }
            archive = isArchive ? objectsList : nil
        } else {
            archive = nil
        }
    }

    /// The object a reference to `object` stands for: an archive's object when it is a reference to one.
    func resolve(_ object: Int) -> Int {
        guard case .uid(let index) = plist.objects[object], let archive, archive.indices.contains(index) else { return object }
        return archive[index]
    }

    func target(of slot: Slot) -> Int {
        plist.references(of: slot.container)[slot.index]
    }

    /// What a container object holds, as a list of places or as named places.
    func view(of object: Int) -> View? {
        switch plist.objects[object] {
        case .array(let refs), .set(let refs):
            return .array(refs.indices.map { Slot(container: object, index: $0) })
        case .dictionary(let keys, _):
            var entries: [(key: String, slot: Slot)] = []
            for (position, key) in keys.enumerated() {
                if let name = plist.string(key) { entries.append((name, Slot(container: object, index: keys.count + position))) }
            }
            // A dictionary or an array that was archived: its keys and its values are lists of references.
            let references = plist.references(of: object)
            let objectsEntry = entries.first { $0.key == "NS.objects" }
            if let objectsEntry, case .array(let valueRefs) = plist.objects[references[objectsEntry.slot.index]] {
                let valueList = references[objectsEntry.slot.index]
                if let keysEntry = entries.first(where: { $0.key == "NS.keys" }),
                   case .array(let keyRefs) = plist.objects[references[keysEntry.slot.index]] {
                    for (position, keyRef) in keyRefs.enumerated() where position < valueRefs.count {
                        if let name = plist.string(resolve(keyRef)) { entries.append((name, Slot(container: valueList, index: position))) }
                    }
                } else {
                    return .array(valueRefs.indices.map { Slot(container: valueList, index: $0) })
                }
            }
            return .dictionary(entries)
        default:
            return nil
        }
    }

    /// Follows the path from the top object. Throws what `PlistValue.setting` does for a step that can't be taken, and
    /// `PlistBlobCodecError.tooLarge` when the objects looked at add up to more than a value may be (`PlistValue.defaultNodeLimit`).
    func locate(_ path: PlistKeyPath) throws -> Place {
        var place = Place(slot: nil, referredObject: plist.top, valueObject: resolve(plist.top))
        var trail: [Step] = []
        var foundTheEntry = false
        var budget = PlistValue.defaultNodeLimit
        let hasAnEntryStep = path.contains(where: \.findsAnEntry)
        for (stepNumber, step) in path.enumerated() {
            if case .anyElement = step { throw KeyPathError.anyElementOutsideMatchingPath(step: stepNumber) }
            try spend(cost(of: place.valueObject), &budget)
            guard let view = view(of: place.valueObject) else { throw KeyPathError.notAContainer(step: stepNumber) }
            let slot: Slot
            switch (step, view) {
            case (.key(let name), .dictionary(let entries)):
                guard let entry = entries.first(where: { $0.key == name }) else { throw KeyPathError.noMatch(step: stepNumber) }
                slot = entry.slot
            case (.index(let position), .array(let slots)):
                guard slots.indices.contains(position) else { throw KeyPathError.indexOutOfRange(step: stepNumber) }
                slot = slots[position]
            case (.matching(let key, let value), .array(let slots)):
                var found: Slot?
                for candidate in slots {
                    let element = target(of: candidate)
                    try spend(cost(of: resolve(element)), &budget)
                    if holds(key: key, value: value, in: resolve(element)) {
                        found = candidate
                        break
                    }
                }
                guard let found else { throw KeyPathError.noMatch(step: stepNumber) }
                slot = found
            case (.matchingPath(let subPath, let value), .array(let slots)):
                slot = try slotReaching(value, along: subPath, in: slots, step: stepNumber, budget: &budget)
            default:
                throw KeyPathError.notAContainer(step: stepNumber)
            }
            let start = place.valueObject
            let referred = target(of: slot)
            place = Place(slot: slot, referredObject: referred, valueObject: resolve(referred))
            // Below the step that finds the entry (the first `matching` or `matchingPath`), or everywhere when no step does.
            if foundTheEntry || !hasAnEntryStep { trail.append(Step(place: place, container: slot.container, start: start)) }
            if step.findsAnEntry { foundTheEntry = true }
        }
        place.trail = trail
        return place
    }

    // MARK: The work of following a path

    /// Takes `amount` from the work that is left, before the work it is for is done; throws `tooLarge` when there isn't that much.
    private func spend(_ amount: Int, _ budget: inout Int) throws {
        budget -= amount
        guard budget >= 0 else { throw PlistBlobCodecError.tooLarge }
    }

    /// What looking into an object costs: the object, what it holds, and, for a dictionary that was archived as one, the two lists it
    /// keeps its keys and values in (`view(of:)` reads those too).
    private func cost(of object: Int) -> Int {
        switch plist.objects[object] {
        case .array(let refs), .set(let refs):
            return 1 + refs.count
        case .dictionary(let keys, let values):
            var cost = 1 + keys.count + values.count
            for (key, value) in zip(keys, values) {
                guard let name = plist.string(key), name == "NS.keys" || name == "NS.objects" else { continue }
                if case .array(let refs) = plist.objects[value] { cost += refs.count }
            }
            return cost
        default:
            return 1
        }
    }

    /// The one slot of an array whose element reaches a string equal to `value` along `path`: `noMatch` when no element does and
    /// `ambiguousMatch` when more than one does (two slots that hold the same object are two).
    private func slotReaching(_ value: String, along path: [KeyPathStep], in slots: [Slot], step: Int, budget: inout Int) throws -> Slot {
        var found: Slot?
        for slot in slots {
            guard try reaches(value, from: target(of: slot), along: path[...], budget: &budget) else { continue }
            if found != nil { throw KeyPathError.ambiguousMatch(step: step) }
            found = slot
        }
        guard let found else { throw KeyPathError.noMatch(step: step) }
        return found
    }

    /// Whether some way of following `steps` from `object` (the object a place refers to) ends at a string equal to `target`. The
    /// steps are read as `locate` reads them, and a step for any element tries every element; a step that can't be taken, or is a
    /// `matchingPath` (which a path that is only read can't hold), is a way that ends nowhere.
    ///
    /// Every object visited is charged before it is looked into (`cost(of:)`): where a list refers to one object many times over, the
    /// ways that lead through it are as many as the references multiply to, and the work is what stops them.
    private func reaches(_ target: String, from object: Int, along steps: ArraySlice<KeyPathStep>, budget: inout Int) throws -> Bool {
        let current = resolve(object)
        guard let step = steps.first else {
            try spend(1, &budget)
            return plist.string(current) == target
        }
        try spend(cost(of: current), &budget)
        guard let view = view(of: current) else { return false }
        let rest = steps.dropFirst()
        switch (step, view) {
        case (.key(let name), .dictionary(let entries)):
            guard let entry = entries.first(where: { $0.key == name }) else { return false }
            return try reaches(target, from: self.target(of: entry.slot), along: rest, budget: &budget)
        case (.index(let position), .array(let slots)):
            guard slots.indices.contains(position) else { return false }
            return try reaches(target, from: self.target(of: slots[position]), along: rest, budget: &budget)
        case (.matching(let key, let value), .array(let slots)):
            for slot in slots {
                let element = self.target(of: slot)
                try spend(cost(of: resolve(element)), &budget)
                if holds(key: key, value: value, in: resolve(element)) {
                    return try reaches(target, from: element, along: rest, budget: &budget)
                }
            }
            return false
        case (.anyElement, .array(let slots)):
            for slot in slots {
                if try reaches(target, from: self.target(of: slot), along: rest, budget: &budget) { return true }
            }
            return false
        default:
            return false
        }
    }

    /// Whether everything the path goes through below the entry belongs to its place alone: each container it enters (the last step's
    /// flag excepted, which is dealt with by the caller), and the list an archived dictionary keeps its values in.
    func isAloneBelowTheEntry(_ place: Place, counts: [Int]) -> Bool {
        for (position, step) in place.trail.enumerated() {
            let isLast = position == place.trail.count - 1
            if !isLast, !isUsedOnlyBy(step.place, counts: counts) { return false }
            if step.container != step.start, counts[step.container] != 1 { return false }
        }
        return true
    }

    /// Whether the object is a dictionary that holds the string `value` under `key`.
    private func holds(key: String, value: String, in object: Int) -> Bool {
        guard case .dictionary(let entries)? = view(of: object) else { return false }
        guard let entry = entries.first(where: { $0.key == key }) else { return false }
        return plist.string(resolve(target(of: entry.slot))) == value
    }

    // MARK: Sharing

    /// Whether the value object is used by this place alone, so that changing it changes nothing else: for an object that the place
    /// refers to directly, that it is referred to once; for one an archive reference names, that the reference is used once, no
    /// other reference names the object, and nothing but the archive's own list refers to it.
    func isUsedOnlyBy(_ place: Place, counts: [Int]) -> Bool {
        guard place.referredObject != place.valueObject else { return counts[place.valueObject] == 1 }
        guard let archive else { return false }
        var uses = 0
        for (number, object) in plist.objects.enumerated() {
            if case .uid(let index) = object, archive.indices.contains(index), archive[index] == place.valueObject { uses += counts[number] }
        }
        return uses == 1 && counts[place.valueObject] == 1
    }

    /// Another object that holds `wanted` and that the place could refer to in the way it does now: a true or false object, or an
    /// archive reference to one.
    func otherObject(holding wanted: Bool, than place: Place) -> Int? {
        for (number, object) in plist.objects.enumerated() where number != place.referredObject {
            if place.referredObject == place.valueObject {
                if case .bool(wanted) = object { return number }
            } else if case .uid = object, case .bool(wanted) = plist.objects[resolve(number)] {
                return number
            }
        }
        return nil
    }

    // MARK: Values

    /// The value an object holds as a `PlistValue`. Nil for a null (a property list value of Mantel's has none); a reference
    /// inside it can't be held (`containsReferences`).
    ///
    /// Each object read costs one of `remaining`: a list that refers to one object many times is a small blob and an enormous tree
    /// (`tooLarge`).
    func value(of object: Int, depth: Int, remaining: inout Int) throws -> PlistValue? {
        guard depth <= PlistNode.maximumDepth else { throw PlistBlobCodecError.damaged }
        remaining -= 1
        guard remaining >= 0 else { throw PlistBlobCodecError.tooLarge }
        switch plist.objects[object] {
        case .null: return nil
        case .bool(let flag): return .bool(flag)
        case .integer(let number): return .integer(number)
        case .real(let number): return .real(number)
        case .date(let seconds): return .date(Date(timeIntervalSinceReferenceDate: seconds))
        case .data(let bytes): return .data(bytes)
        case .string(let text): return .string(text)
        case .uid: throw PlistBlobCodecError.containsReferences
        case .array(let refs), .set(let refs):
            return .array(try refs.compactMap { try value(of: $0, depth: depth + 1, remaining: &remaining) })
        case .dictionary(let keys, let values):
            var entries: [String: PlistValue] = [:]
            for (key, value) in zip(keys, values) {
                guard let name = plist.string(key), let held = try self.value(of: value, depth: depth + 1, remaining: &remaining) else { continue }
                entries[name] = held
            }
            return .dictionary(entries)
        }
    }
}
