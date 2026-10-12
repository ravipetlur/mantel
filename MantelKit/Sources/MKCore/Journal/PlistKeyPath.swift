import Foundation

/// One step into a property list value.
public enum KeyPathStep: Codable, Sendable, Hashable {
    /// A dictionary key.
    case key(String)
    /// An array position. Never used for Apple's lists: macOS may insert an entry between a write and its undo, and an index
    /// would then point at another app's. Use `matching` or `matchingPath` there.
    case index(Int)
    /// The array element that is a dictionary whose `key` holds the string `value`.
    case matching(key: String, value: String)
    /// Any element of the array at this point. It is only said inside the `path` of a `matchingPath`, which tries every element;
    /// anywhere else it is an error (`KeyPathError.anyElementOutsideMatchingPath`), because a place to change can't be "any".
    case anyElement
    /// The one array element in which `path` reaches a string equal to `value`, wherever in the element that is: for a list whose
    /// entries hold their app's ID some levels down (`menuItemLocations`, any element, `bundle`, `_0`), where `matching` can't see it.
    ///
    /// - No element has it: `KeyPathError.noMatch`. More than one has it: `KeyPathError.ambiguousMatch`, because two entries
    ///   claiming one app means no one knows which to change.
    /// - `path` is a way to read, and is never changed: it holds `key`, `index`, `matching` and `anyElement` steps. A step of it that
    ///   is a `matchingPath` reaches nothing (nesting one has no text that reads back, and no use).
    case matchingPath(path: [KeyPathStep], value: String)

    /// Whether the step finds an entry of a list by what the entry holds, as `matching` and `matchingPath` do: an entry that has
    /// left the list since is a vanished entry, and the steps below it are what is left of a change, which is nothing.
    public var findsAnEntry: Bool {
        switch self {
        case .matching, .matchingPath: true
        case .key, .index, .anyElement: false
        }
    }
}

extension Array where Element == KeyPathStep {
    /// The position of the first step that is a `matchingPath` with another `matchingPath` in its way, or nil when there is none.
    ///
    /// The way of a `matchingPath` is only read, so a step that finds an entry inside it reaches nothing, and it has no text that reads
    /// back (`KeyPathText`). A path that has one is refused where a change is built from it, before anything is recorded.
    public var nestedMatchingPathStep: Int? {
        for (position, step) in enumerated() {
            guard case .matchingPath(let way, _) = step else { continue }
            if way.contains(where: { if case .matchingPath = $0 { true } else { false } }) { return position }
        }
        return nil
    }
}

/// How a path is written as text: one segment for each step, `/k:<key>`, `/i:<position>`, `/m:<key>=<value>`, `/*` and
/// `/mp:<sub-path>=<value>`. It is the form the journal keys its entries by, and the form a probe is given a place in.
///
/// - In `k:`, `m:` and the other forms outside a `mp:` segment, `/`, `=` and `%` inside a name are percent-encoded.
/// - A `mp:` segment holds the steps of its path in the same forms without the slash, joined by `,`: for example
///   `/mp:k:menuItemLocations,*,k:bundle,k:_0=com.example.app`. The sub-path ends at the last `=`, and the value is after it. Inside
///   one, `,` `=` `/` `%` and `*` in a name or the value are percent-encoded as well, so that a name can't be taken for one of the
///   separators. (The forms outside it keep their older encoding exactly, which is what an existing journal key was written with.)
/// - A segment of one form never reads as another: `mp:` is not `m:`, and `*` is neither a key nor a position.
public enum KeyPathText {
    public static func text(for path: PlistKeyPath) -> String {
        path.map(segment).joined()
    }

    public static func segment(_ step: KeyPathStep) -> String {
        switch step {
        case .key(let key): "/k:\(escape(key))"
        case .index(let position): "/i:\(position)"
        case .matching(let key, let value): "/m:\(escape(key))=\(escape(value))"
        case .anyElement: "/*"
        case .matchingPath(let path, let value): "/mp:\(path.map(subSegment).joined(separator: ","))=\(escapeInSubPath(value))"
        }
    }

    /// The path a text spells, with or without the slash before its first segment; nil when a segment isn't one of the forms, or a
    /// position isn't a number. An empty text is the empty path.
    public static func path(from text: String) -> PlistKeyPath? {
        var steps: PlistKeyPath = []
        let trimmed = text.hasPrefix("/") ? String(text.dropFirst()) : text
        guard !trimmed.isEmpty else { return [] }
        for part in trimmed.split(separator: "/", omittingEmptySubsequences: false) {
            guard let step = step(from: String(part)) else { return nil }
            steps.append(step)
        }
        return steps
    }

    private static func step(from part: String) -> KeyPathStep? {
        if part.hasPrefix("mp:") {
            return matchingPath(from: String(part.dropFirst(3)))
        }
        return simpleStep(from: part)
    }

    /// A step that has no steps of its own: what a `mp:` segment's path is made of, and a segment of any other form.
    private static func simpleStep(from part: String) -> KeyPathStep? {
        if part == "*" {
            return .anyElement
        }
        if part.hasPrefix("k:") {
            return unescape(String(part.dropFirst(2))).map(KeyPathStep.key)
        }
        if part.hasPrefix("i:") {
            return Int(part.dropFirst(2)).map(KeyPathStep.index)
        }
        if part.hasPrefix("m:") {
            let pair = part.dropFirst(2).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, let key = unescape(String(pair[0])), let value = unescape(String(pair[1])) else { return nil }
            return .matching(key: key, value: value)
        }
        return nil
    }

    /// What follows `mp:`: the steps joined by `,`, then `=` and the value. The value has no `=` in it (it is encoded), so the last `=`
    /// is the one that ends the steps, a `m:` step's own among them.
    private static func matchingPath(from text: String) -> KeyPathStep? {
        guard let equals = text.lastIndex(of: "="), let value = unescape(String(text[text.index(after: equals)...])) else { return nil }
        let steps = text[..<equals]
        var path: [KeyPathStep] = []
        if !steps.isEmpty {
            for part in steps.split(separator: ",", omittingEmptySubsequences: false) {
                guard let step = simpleStep(from: String(part)) else { return nil }
                path.append(step)
            }
        }
        return .matchingPath(path: path, value: value)
    }

    /// A step of a `mp:` segment's path. (A `matchingPath` in one has no text that reads back: reading the text refuses it, and a path
    /// that has one is refused where a change is built from it, `nestedMatchingPathStep`. A path with one reaches nothing.)
    private static func subSegment(_ step: KeyPathStep) -> String {
        switch step {
        case .key(let key): "k:\(escapeInSubPath(key))"
        case .index(let position): "i:\(position)"
        case .matching(let key, let value): "m:\(escapeInSubPath(key))=\(escapeInSubPath(value))"
        case .anyElement: "*"
        case .matchingPath: String(segment(step).dropFirst())
        }
    }

    static func escape(_ name: String) -> String {
        name.replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: "/", with: "%2F")
            .replacingOccurrences(of: "=", with: "%3D")
    }

    /// The same, and `,` and `*` as well: inside a `mp:` segment those are separators and the step for any element.
    static func escapeInSubPath(_ name: String) -> String {
        escape(name)
            .replacingOccurrences(of: ",", with: "%2C")
            .replacingOccurrences(of: "*", with: "%2A")
    }

    /// The name with its percent-encoding undone; nil for an encoding that isn't one this uses (a stray `%`).
    static func unescape(_ text: String) -> String? {
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character == "%" else {
                result.append(character)
                index = text.index(after: index)
                continue
            }
            let code = text[index...].prefix(3)
            switch code {
            case "%25": result.append("%")
            case "%2F": result.append("/")
            case "%3D": result.append("=")
            case "%2C": result.append(",")
            case "%2A": result.append("*")
            default: return nil
            }
            index = text.index(index, offsetBy: 3)
        }
        return result
    }
}

/// Where inside a property list value a change is made: the steps from the top-level value to the value changed.
public typealias PlistKeyPath = [KeyPathStep]

/// Why a step of a key path couldn't be taken. `step` is the position, in the path, of the step that failed.
public enum KeyPathError: Error, Equatable, LocalizedError {
    /// The step needs a dictionary or an array, and the value there is something else.
    case notAContainer(step: Int)
    /// No element of the array matches the step.
    case noMatch(step: Int)
    /// More than one element of the array matches the step (`matchingPath`), so it isn't known which one is meant.
    case ambiguousMatch(step: Int)
    /// The array has no element at the position.
    case indexOutOfRange(step: Int)
    /// The step says "any element" and isn't inside the path of a `matchingPath`: a place to read or change is one place.
    case anyElementOutsideMatchingPath(step: Int)
    /// The step is a `matchingPath` that has another `matchingPath` in its way. The way is only read, and a nested step has no text
    /// to be recorded by.
    case nestedMatchingPath(step: Int)

    public var errorDescription: String? {
        switch self {
        case .notAContainer: "The setting isn't shaped the way Mantel expects, so Mantel left it alone."
        case .noMatch: "An entry Mantel expected in a list isn't there."
        case .ambiguousMatch: "More than one entry in a list matches, so Mantel can't tell which one to change and left them alone."
        case .indexOutOfRange: "A list is shorter than Mantel expected."
        case .anyElementOutsideMatchingPath: "Mantel tried to change a setting without saying which entry, so it left the setting alone."
        case .nestedMatchingPath: "Mantel was asked to change a place it can't record, so it left the setting alone."
        }
    }
}

/// How a value inside a plist file's top-level key is stored, so that a path can be followed into it: `none` is a value
/// that is edited as it is. A string rather than an enum, so that a journal written by a newer build, with a codec this one
/// doesn't know, still decodes: its entry then fails to restore (`PlistAccessError.codecMissing`) and stays in the journal.
public struct PlistBlobCodecID: RawRepresentable, Codable, Sendable, Hashable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// The top-level value is edited as it is.
    public static let none = PlistBlobCodecID(rawValue: "none")

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// What Mantel last wrote at the place a journal entry is for.
public enum WrittenValue: Codable, Sendable, Equatable {
    case value(PlistValue)
    /// Mantel removed what was there.
    case removed
}

extension PlistValue {
    /// The value at `path`, or nil when anything along the way is absent or isn't a container of the kind the step needs.
    /// An empty path is the value itself.
    public func value(at path: PlistKeyPath) -> PlistValue? {
        var current = self
        for step in path {
            switch (step, current) {
            case (.key(let key), .dictionary(let entries)):
                guard let next = entries[key] else { return nil }
                current = next
            case (.index(let position), .array(let elements)):
                guard elements.indices.contains(position) else { return nil }
                current = elements[position]
            case (.matching(let key, let value), .array(let elements)):
                guard let position = Self.position(matching: key, value: value, in: elements) else { return nil }
                current = elements[position]
            case (.matchingPath(let subPath, let value), .array(let elements)):
                // Nothing when no element has it, and nothing when more than one does: `setting` says which of the two it is.
                guard case .one(let position) = Self.selection(path: subPath, value: value, in: elements) else { return nil }
                current = elements[position]
            default:
                // Including `anyElement`, which only a `matchingPath` can say.
                return nil
            }
        }
        return current
    }

    /// How many elements of this array `.matchingPath(path:value:)` would select: none, one, or more. Nil when this isn't an
    /// array. For a caller that wants to say which of the three it found.
    public func matchCount(path: [KeyPathStep], value: String) -> Int? {
        guard case .array(let elements) = self else { return nil }
        return elements.filter { $0.reaches(value, along: path[...]) }.count
    }

    /// Whether following `path` from this value comes to a `matchingPath` that more than one element satisfies, before any step that
    /// can't be taken. `value(at:)` gives nil for that and for an entry that isn't there; this tells the two apart.
    public func hasAmbiguousMatch(at path: PlistKeyPath) -> Bool {
        var current = self
        for step in path {
            switch (step, current) {
            case (.key(let key), .dictionary(let entries)):
                guard let next = entries[key] else { return false }
                current = next
            case (.index(let position), .array(let elements)):
                guard elements.indices.contains(position) else { return false }
                current = elements[position]
            case (.matching(let key, let value), .array(let elements)):
                guard let position = Self.position(matching: key, value: value, in: elements) else { return false }
                current = elements[position]
            case (.matchingPath(let subPath, let value), .array(let elements)):
                switch Self.selection(path: subPath, value: value, in: elements) {
                case .several: return true
                case .none: return false
                case .one(let position): current = elements[position]
                }
            default:
                return false
            }
        }
        return false
    }

    /// This value with `value` at `path`; `nil` removes what is there (a dictionary entry, or an array element).
    ///
    /// - Dictionaries missing along the path are made (a `nil` that has nothing to remove changes nothing, and makes none).
    /// - A missing array element, or a step that matches nothing, is an error: Mantel never invents an entry in a list that
    ///   belongs to macOS or to another app.
    /// - A `matchingPath` that more than one element satisfies is an error too (`ambiguousMatch`), and a step for any element
    ///   outside the path of a `matchingPath` is (`anyElementOutsideMatchingPath`).
    /// - An empty path has nothing to put the value in, so it is an error too (`noMatch(step: 0)`).
    public func setting(_ value: PlistValue?, at path: PlistKeyPath) throws(KeyPathError) -> PlistValue {
        guard !path.isEmpty else { throw .noMatch(step: 0) }
        return try Self.set(value, in: self, steps: path[...], offset: 0) ?? self
    }

    // MARK: Walking

    /// The container with `value` set at the steps; nil when nothing changes (removing what isn't there).
    private static func set(_ value: PlistValue?, in container: PlistValue, steps: ArraySlice<KeyPathStep>,
                            offset: Int) throws(KeyPathError) -> PlistValue? {
        guard let step = steps.first else { return value }
        let rest = steps.dropFirst()
        let isLast = rest.isEmpty

        switch (step, container) {
        case (.key(let key), .dictionary(var entries)):
            if isLast {
                guard let value else {
                    guard entries[key] != nil else { return nil }
                    entries[key] = nil
                    return .dictionary(entries)
                }
                entries[key] = value
                return .dictionary(entries)
            }
            let child: PlistValue
            if let existing = entries[key] {
                child = existing
            } else {
                // Nothing to remove below a dictionary that isn't there. Below one that is to be made, the next step must be a
                // key too: an array can't be made, because its elements are what is looked for.
                guard value != nil else { return nil }
                switch rest.first {
                case .key?: child = .dictionary([:])
                case .index?: throw .indexOutOfRange(step: offset + 1)
                case .matching?, .matchingPath?: throw .noMatch(step: offset + 1)
                case .anyElement?: throw .anyElementOutsideMatchingPath(step: offset + 1)
                case nil: child = .dictionary([:])
                }
            }
            guard let changed = try set(value, in: child, steps: rest, offset: offset + 1) else { return nil }
            entries[key] = changed
            return .dictionary(entries)

        case (.index(let position), .array(var elements)):
            guard elements.indices.contains(position) else { throw .indexOutOfRange(step: offset) }
            return try setElement(value, at: position, in: &elements, rest: rest, offset: offset)

        case (.matching(let key, let matchValue), .array(var elements)):
            guard let position = position(matching: key, value: matchValue, in: elements) else { throw .noMatch(step: offset) }
            return try setElement(value, at: position, in: &elements, rest: rest, offset: offset)

        case (.matchingPath(let subPath, let matchValue), .array(var elements)):
            switch selection(path: subPath, value: matchValue, in: elements) {
            case .none: throw .noMatch(step: offset)
            case .several: throw .ambiguousMatch(step: offset)
            case .one(let position): return try setElement(value, at: position, in: &elements, rest: rest, offset: offset)
            }

        case (.anyElement, _):
            throw .anyElementOutsideMatchingPath(step: offset)

        default:
            throw .notAContainer(step: offset)
        }
    }

    /// The array with the element at `position` replaced, removed (when `value` is nil and this is the last step) or changed
    /// below.
    private static func setElement(_ value: PlistValue?, at position: Int, in elements: inout [PlistValue],
                                   rest: ArraySlice<KeyPathStep>, offset: Int) throws(KeyPathError) -> PlistValue? {
        if rest.isEmpty {
            if let value {
                elements[position] = value
            } else {
                elements.remove(at: position)
            }
            return .array(elements)
        }
        guard let changed = try set(value, in: elements[position], steps: rest, offset: offset + 1) else { return nil }
        elements[position] = changed
        return .array(elements)
    }

    /// The first element that is a dictionary whose `key` holds the string `value`.
    private static func position(matching key: String, value: String, in elements: [PlistValue]) -> Int? {
        elements.firstIndex { element in
            guard case .dictionary(let entries) = element, case .string(let held)? = entries[key] else { return false }
            return held == value
        }
    }

    /// Which elements a `matchingPath` selects.
    private enum Selection {
        case none, one(Int), several
    }

    /// The elements in which `path` reaches `value`, told apart no further than none, one and more than one (the search stops at the
    /// second).
    private static func selection(path: [KeyPathStep], value: String, in elements: [PlistValue]) -> Selection {
        var found: Int?
        for (position, element) in elements.enumerated() where element.reaches(value, along: path[...]) {
            if found != nil { return .several }
            found = position
        }
        return found.map(Selection.one) ?? .none
    }

    /// Whether some way of following `steps` from this value ends at the string `target`. A step that is an array position or a
    /// match follows what it names, a step for any element tries each element, and a step that can't be taken, or can't be one in a
    /// path that is only read (a `matchingPath`), is a way that ends nowhere.
    ///
    /// The value is a tree already read within a limit (`PlistValue.defaultNodeLimit`), and no reference is followed, so no value is
    /// visited more than once for a step of the path: the work is the size of the tree, times the length of the path at most.
    private func reaches(_ target: String, along steps: ArraySlice<KeyPathStep>) -> Bool {
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
            guard let position = Self.position(matching: key, value: value, in: elements) else { return false }
            return elements[position].reaches(target, along: rest)
        case (.anyElement, .array(let elements)):
            return elements.contains { $0.reaches(target, along: rest) }
        default:
            return false
        }
    }
}
