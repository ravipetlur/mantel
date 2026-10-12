import Foundation

/// Why a blob couldn't be read, or changed in place, as a property list.
public enum PlistBlobCodecError: Error, Equatable, LocalizedError {
    /// The blob is a keyed archive (it holds object references), which `NestedPlistCodec` can't hold.
    case isAnArchive
    /// The blob isn't a property list at all.
    case notAPropertyList
    /// The blob isn't a binary property list (`bplist00`), the only form that is changed in place.
    case notABinaryPlist
    /// A binary property list whose table or objects don't add up.
    case damaged
    /// The place holds something that isn't true or false, or a value that isn't was asked for.
    case notABoolean
    /// The true or false the place refers to is used by other entries too, and no other one exists to point this entry at.
    case sharedValue
    /// The value has object references inside it, which a property list value of Mantel's can't hold.
    case containsReferences
    /// The value refers to the same objects so many times that it is more values than Mantel reads.
    case tooLarge

    public var errorDescription: String? {
        switch self {
        case .isAnArchive: "This list is an archive; use the flip codec"
        case .notAPropertyList: "This value isn't a property list."
        case .notABinaryPlist: "This value isn't a binary property list, so it can't be changed in place."
        case .damaged: "This binary property list is damaged, so Mantel left it alone."
        case .notABoolean: "Only a true or false value can be changed in place."
        case .sharedValue:
            "This true or false is shared with other entries, and there is no other one to point this entry at, so it can't be changed without changing them too."
        case .containsReferences: "This value holds references to other objects, which Mantel can't read as a plain value."
        case .tooLarge: "This value is too large to read whole."
        }
    }
}

/// A binary property list (`bplist00`), read as the objects it holds and where each is in the bytes.
///
/// The layout is the one Apple documents for the format: the 8-byte magic, the objects, an offset table with the position of each
/// object, and a 32-byte trailer that gives the sizes of the table's entries and of an object reference, the number of objects,
/// the top object and where the table is. Every read is checked against the length of the blob, so a damaged or hostile blob is
/// refused (`damaged`) and never read past its end.
///
/// An object is held by its number. A container holds the numbers of what it contains, which is how the format shares one object
/// between many places (a `true` that is used by every entry that is true is a single object).
///
/// Nothing a blob says makes the reader allocate more than the blob can hold: the table entries of a blob may be made to point at one
/// object, which would be read again for each, so what is read in all (references of containers, bytes of strings and data) is
/// limited to what the object area holds; a blob that asks for more is `damaged`.
struct BinaryPlist {
    enum Object: Equatable {
        case null
        case bool(Bool)
        case integer(Int)
        case real(Double)
        /// Seconds from 2001-01-01.
        case date(Double)
        case data(Data)
        case string(String)
        /// A reference to an object of a keyed archive: its position in the archive's list of objects.
        case uid(Int)
        case array([Int])
        case set([Int])
        /// The numbers of the key objects and of the value objects.
        case dictionary(keys: [Int], values: [Int])
    }

    static let magic = Data("bplist00".utf8)
    private static let trailerSize = 32
    /// More objects than this are not a property list Mantel reads: it is refused rather than allocated.
    private static let maximumObjects = 500_000

    let bytes: Data
    private(set) var objects: [Object] = []
    /// Where each object begins (its marker byte).
    private(set) var offsets: [Int] = []
    /// Where a container's first reference is, for the objects that are containers.
    private(set) var referencesStart: [Int: Int] = [:]
    let referenceSize: Int
    let top: Int
    /// What the objects may hold in all, and what has been read so far: references of containers, and bytes of strings and data. A
    /// blob whose objects are distinct holds no more than the object area has room for.
    private var referencesAllowed = 0
    private var referencesRead = 0
    private var bytesAllowed = 0
    private var bytesRead = 0

    /// Reads the blob; throws `notABinaryPlist` for bytes that don't begin with the magic, and `damaged` for any that don't add up.
    init(_ blob: Data) throws {
        bytes = Data(blob)
        guard bytes.starts(with: Self.magic) else { throw PlistBlobCodecError.notABinaryPlist }
        guard bytes.count >= Self.magic.count + Self.trailerSize else { throw PlistBlobCodecError.damaged }

        let trailer = bytes.count - Self.trailerSize
        let offsetSize = Int(bytes[trailer + 6])
        referenceSize = Int(bytes[trailer + 7])
        let count = try Self.integer(in: bytes, at: trailer + 8, size: 8)
        top = try Self.integer(in: bytes, at: trailer + 16, size: 8)
        let tableStart = try Self.integer(in: bytes, at: trailer + 24, size: 8)
        guard (1...8).contains(offsetSize), (1...8).contains(referenceSize), count > 0, count <= Self.maximumObjects,
              top >= 0, top < count, tableStart >= Self.magic.count, tableStart <= trailer,
              count * offsetSize <= trailer - tableStart else { throw PlistBlobCodecError.damaged }

        referencesAllowed = (tableStart - Self.magic.count) / referenceSize
        bytesAllowed = tableStart - Self.magic.count
        for index in 0..<count {
            let offset = try Self.integer(in: bytes, at: tableStart + index * offsetSize, size: offsetSize)
            guard offset >= Self.magic.count, offset < tableStart else { throw PlistBlobCodecError.damaged }
            offsets.append(offset)
        }
        for index in 0..<count {
            objects.append(try readObject(number: index, at: offsets[index], objectCount: count, endOfObjects: tableStart))
        }
    }

    // MARK: Reading an object

    private mutating func readObject(number: Int, at start: Int, objectCount: Int, endOfObjects: Int) throws -> Object {
        let marker = bytes[start]
        let kind = marker >> 4
        let info = Int(marker & 0x0F)
        switch kind {
        case 0x0:
            switch info {
            case 0x0, 0xF: return .null
            case 0x8: return .bool(false)
            case 0x9: return .bool(true)
            default: throw PlistBlobCodecError.damaged
            }
        case 0x1:
            // 1, 2, 4 and 8 bytes; a 16-byte integer is not one Mantel reads.
            guard info <= 3 else { throw PlistBlobCodecError.damaged }
            let size = 1 << info
            try require(start + 1 + size <= endOfObjects)
            let raw = try Self.unsigned(in: bytes, at: start + 1, size: size)
            return .integer(size == 8 ? Int(Int64(bitPattern: raw)) : Int(raw))
        case 0x2:
            guard info == 2 || info == 3 else { throw PlistBlobCodecError.damaged }
            let size = 1 << info
            try require(start + 1 + size <= endOfObjects)
            let bits = try Self.unsigned(in: bytes, at: start + 1, size: size)
            return .real(size == 4 ? Double(Float(bitPattern: UInt32(truncatingIfNeeded: bits))) : Double(bitPattern: bits))
        case 0x3:
            guard info == 3 else { throw PlistBlobCodecError.damaged }
            try require(start + 9 <= endOfObjects)
            return .date(Double(bitPattern: try Self.unsigned(in: bytes, at: start + 1, size: 8)))
        case 0x4:
            let (length, body) = try lengthAndBody(info: info, at: start, endOfObjects: endOfObjects)
            try require(body + length <= endOfObjects)
            try spend(bytes: length)
            return .data(Data(bytes[body..<(body + length)]))
        case 0x5, 0x7:
            let (length, body) = try lengthAndBody(info: info, at: start, endOfObjects: endOfObjects)
            try require(body + length <= endOfObjects)
            try spend(bytes: length)
            let text = String(data: bytes[body..<(body + length)], encoding: kind == 0x5 ? .ascii : .utf8)
            guard let text else { throw PlistBlobCodecError.damaged }
            return .string(text)
        case 0x6:
            let (length, body) = try lengthAndBody(info: info, at: start, endOfObjects: endOfObjects)
            try require(length <= endOfObjects, body + length * 2 <= endOfObjects)
            try spend(bytes: length * 2)
            guard let text = String(data: bytes[body..<(body + length * 2)], encoding: .utf16BigEndian) else {
                throw PlistBlobCodecError.damaged
            }
            return .string(text)
        case 0x8:
            let size = info + 1
            try require(start + 1 + size <= endOfObjects)
            return .uid(try Self.integer(in: bytes, at: start + 1, size: size))
        case 0xA, 0xC:
            let (length, body) = try lengthAndBody(info: info, at: start, endOfObjects: endOfObjects)
            let refs = try readReferences(count: length, at: body, objectCount: objectCount, endOfObjects: endOfObjects)
            referencesStart[number] = body
            return kind == 0xA ? .array(refs) : .set(refs)
        case 0xD:
            let (length, body) = try lengthAndBody(info: info, at: start, endOfObjects: endOfObjects)
            let refs = try readReferences(count: length * 2, at: body, objectCount: objectCount, endOfObjects: endOfObjects)
            referencesStart[number] = body
            return .dictionary(keys: Array(refs[..<length]), values: Array(refs[length...]))
        default:
            throw PlistBlobCodecError.damaged
        }
    }

    /// The length an object says it has (in the marker, or in an integer object after it) and where its body begins.
    private func lengthAndBody(info: Int, at start: Int, endOfObjects: Int) throws -> (length: Int, body: Int) {
        guard info == 0xF else { return (info, start + 1) }
        try require(start + 2 <= endOfObjects)
        let marker = bytes[start + 1]
        guard marker >> 4 == 0x1, marker & 0x0F <= 3 else { throw PlistBlobCodecError.damaged }
        let size = 1 << Int(marker & 0x0F)
        try require(start + 2 + size <= endOfObjects)
        let length = try Self.integer(in: bytes, at: start + 2, size: size)
        guard length >= 0, length <= endOfObjects else { throw PlistBlobCodecError.damaged }
        return (length, start + 2 + size)
    }

    /// Counts what is about to be read against what the object area can hold, before any of it is allocated.
    private mutating func spend(references count: Int) throws {
        referencesRead += count
        guard referencesRead <= referencesAllowed else { throw PlistBlobCodecError.damaged }
    }

    private mutating func spend(bytes count: Int) throws {
        bytesRead += count
        guard bytesRead <= bytesAllowed else { throw PlistBlobCodecError.damaged }
    }

    private mutating func readReferences(count: Int, at start: Int, objectCount: Int, endOfObjects: Int) throws -> [Int] {
        try require(count >= 0, count <= endOfObjects, start + count * referenceSize <= endOfObjects)
        try spend(references: count)
        var refs: [Int] = []
        refs.reserveCapacity(count)
        for index in 0..<count {
            let ref = try Self.integer(in: bytes, at: start + index * referenceSize, size: referenceSize)
            guard ref >= 0, ref < objectCount else { throw PlistBlobCodecError.damaged }
            refs.append(ref)
        }
        return refs
    }

    private func require(_ conditions: Bool...) throws {
        guard conditions.allSatisfy({ $0 }) else { throw PlistBlobCodecError.damaged }
    }

    /// A big-endian unsigned number of `size` bytes (at most 8) at `position`.
    static func unsigned(in bytes: Data, at position: Int, size: Int) throws -> UInt64 {
        guard size >= 1, size <= 8, position >= 0, position + size <= bytes.count else { throw PlistBlobCodecError.damaged }
        var value: UInt64 = 0
        for index in 0..<size { value = value << 8 | UInt64(bytes[bytes.startIndex + position + index]) }
        return value
    }

    /// The same as a number a count or a position can be: one that is too big to be either is never read as one (it comes out
    /// negative, which every check of a count or a position refuses).
    static func integer(in bytes: Data, at position: Int, size: Int) throws -> Int {
        Int(truncatingIfNeeded: try unsigned(in: bytes, at: position, size: size))
    }

    // MARK: Looking at the objects

    /// How many places refer to each object (the top object counts as one place). Only places that can be reached from the top object
    /// count: a writer can leave objects that nothing refers to (a copy of a dictionary, say), and what they refer to is not shared
    /// with them in any way that matters.
    func referenceCounts() -> [Int] {
        var counts = [Int](repeating: 0, count: objects.count)
        var seen = [Bool](repeating: false, count: objects.count)
        var pending = [top]
        seen[top] = true
        counts[top] += 1
        while let number = pending.popLast() {
            for ref in references(of: number) {
                counts[ref] += 1
                if !seen[ref] {
                    seen[ref] = true
                    pending.append(ref)
                }
            }
        }
        return counts
    }

    /// Where reference number `index` of container `container` is in the bytes, counting a dictionary's keys first and then its
    /// values. Nil when the object isn't a container, or has no such reference.
    func referencePosition(container: Int, index: Int) -> Int? {
        guard let start = referencesStart[container], index >= 0 else { return nil }
        let count: Int
        switch objects[container] {
        case .array(let refs), .set(let refs): count = refs.count
        case .dictionary(let keys, let values): count = keys.count + values.count
        default: return nil
        }
        return index < count ? start + index * referenceSize : nil
    }

    /// The numbers an object's references hold, in the order `referencePosition` counts them.
    func references(of container: Int) -> [Int] {
        switch objects[container] {
        case .array(let refs), .set(let refs): refs
        case .dictionary(let keys, let values): keys + values
        default: []
        }
    }

    /// The string an object holds, if it is one.
    func string(_ object: Int) -> String? {
        if case .string(let text) = objects[object] { return text }
        return nil
    }
}
