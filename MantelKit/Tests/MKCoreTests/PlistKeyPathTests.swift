import Foundation
import Testing

@testable import MKCore

/// A list the way macOS keeps its approvals: dictionaries naming an app, in an order that can change under Mantel.
private let tracked: PlistValue = .dictionary([
    "apps": .array([
        .dictionary(["bundle": .string("com.example.one"), "allowed": .bool(true)]),
        .dictionary(["bundle": .string("com.example.two"), "allowed": .bool(false)]),
    ]),
    "count": .integer(2),
])

/// A list the way macOS keeps the "Allow in the Menu Bar" switches: an entry says whether it is allowed, and names its app some levels
/// down, in its locations (a bundle, or the path of a program that has none).
private func approval(_ allowed: Bool, _ locations: [PlistValue]) -> PlistValue {
    .dictionary(["isAllowed": .bool(allowed), "menuItemLocations": .array(locations)])
}

private func bundle(_ id: String) -> PlistValue {
    .dictionary(["bundle": .dictionary(["_0": .string(id)])])
}

private func program(_ path: String) -> PlistValue {
    .dictionary(["adhocBinary": .dictionary(["_0": .dictionary(["relative": .string(path)])])])
}

/// The way from an entry to its app's ID, for any of its locations.
private let wayToTheID: [KeyPathStep] = [.key("menuItemLocations"), .anyElement, .key("bundle"), .key("_0")]

private func entry(_ id: String) -> KeyPathStep { .matchingPath(path: wayToTheID, value: id) }

private let approvals: PlistValue = .array([
    approval(true, [bundle("com.example.one")]),
    approval(true, [program("Example Tools/exampled")]),
    approval(false, [program("Example Helper/helperd"), bundle("com.example.two")]),
    approval(true, [bundle("com.example.three"), bundle("com.example.three.helper")]),
])

@Suite("Plist key paths")
struct PlistKeyPathTests {
    @Test func aPathIsWrittenAsOneSegmentForEachStep() {
        let path: PlistKeyPath = [.key("apps"), .index(2), .matching(key: "bundle", value: "com.example.one"), .key("a/b=c%")]
        #expect(KeyPathText.text(for: path) == "/k:apps/i:2/m:bundle=com.example.one/k:a%2Fb%3Dc%25")
        #expect(KeyPathText.text(for: []) == "")
    }

    @Test func aPathReadsBackWhatWasWritten() {
        let path: PlistKeyPath = [.key("apps"), .index(2), .matching(key: "bundle", value: "com.example.one"), .key("a/b=c%")]
        #expect(KeyPathText.path(from: KeyPathText.text(for: path)) == path)
        #expect(KeyPathText.path(from: "k:apps/i:2") == [.key("apps"), .index(2)], "the first slash is optional")
        #expect(KeyPathText.path(from: "") == [])
        #expect(KeyPathText.path(from: "/") == [])
    }

    @Test(arguments: ["x:1", "k", "i:two", "m:bundle", "k:a%2", "k:a%ZZ", "/k:a//k:b", "k:a/", "m:a=b%",
                      "mp", "mp:", "mp:k:a", "mp:x:a=b", "mp:k:a,,k:b=c", "mp:k:a,=c", "mp:k:a%2=b", "mp:k:a=b%", "mp:k:a,mp:k:b=c=d", "*x", "**"])
    func aSegmentThatIsNotOneOfTheThreeFormsIsRefused(text: String) {
        #expect(KeyPathText.path(from: text) == nil)
    }

    @Test func valueAtNestedKeysAndIndices() {
        #expect(tracked.value(at: []) == tracked, "an empty path is the value itself")
        #expect(tracked.value(at: [.key("count")]) == .integer(2))
        #expect(tracked.value(at: [.key("apps"), .index(1), .key("bundle")]) == .string("com.example.two"))
        #expect(tracked.value(at: [.key("apps"), .index(0), .key("allowed")]) == .bool(true))

        #expect(tracked.value(at: [.key("missing")]) == nil)
        #expect(tracked.value(at: [.key("apps"), .index(2)]) == nil, "past the end")
        #expect(tracked.value(at: [.key("apps"), .index(-1)]) == nil, "before the start")
        #expect(tracked.value(at: [.key("count"), .key("deeper")]) == nil, "an integer holds nothing")
        #expect(tracked.value(at: [.index(0)]) == nil, "a dictionary has no positions")
        #expect(tracked.value(at: [.key("apps"), .key("x")]) == nil, "an array has no keys")
    }

    @Test func settingMakesMissingDictionaries() throws {
        let made = try PlistValue.dictionary([:]).setting(.integer(5), at: [.key("a"), .key("b"), .key("c")])
        #expect(made == .dictionary(["a": .dictionary(["b": .dictionary(["c": .integer(5)])])]))

        // What was there stays: only the one path changes.
        let added = try tracked.setting(.integer(9), at: [.key("extra"), .key("deep")])
        #expect(added.value(at: [.key("extra"), .key("deep")]) == .integer(9))
        #expect(added.value(at: [.key("count")]) == .integer(2))
        #expect(added.value(at: [.key("apps")]) == tracked.value(at: [.key("apps")]))

        // An existing entry is replaced, and the rest of its dictionary is as it was.
        let flipped = try tracked.setting(.bool(false), at: [.key("apps"), .matching(key: "bundle", value: "com.example.one"), .key("allowed")])
        #expect(flipped.value(at: [.key("apps"), .index(0), .key("allowed")]) == .bool(false))
        #expect(flipped.value(at: [.key("apps"), .index(0), .key("bundle")]) == .string("com.example.one"))
        #expect(flipped.value(at: [.key("apps"), .index(1)]) == tracked.value(at: [.key("apps"), .index(1)]))
    }

    @Test func settingNilRemoves() throws {
        let withoutCount = try tracked.setting(nil, at: [.key("count")])
        #expect(withoutCount.value(at: [.key("count")]) == nil)
        #expect(withoutCount.value(at: [.key("apps")]) == tracked.value(at: [.key("apps")]))

        // A matching element is taken out of its list, and the others stay in order.
        let withoutOne = try tracked.setting(nil, at: [.key("apps"), .matching(key: "bundle", value: "com.example.one")])
        #expect(withoutOne.value(at: [.key("apps")]) == .array([.dictionary(["bundle": .string("com.example.two"), "allowed": .bool(false)])]))

        // Removing what isn't there changes nothing, and makes no dictionaries on the way.
        #expect(try tracked.setting(nil, at: [.key("nothing")]) == tracked)
        #expect(try tracked.setting(nil, at: [.key("nothing"), .key("deeper")]) == tracked)
    }

    @Test func matchingFindsElementByKeyValue() {
        let second = tracked.value(at: [.key("apps"), .matching(key: "bundle", value: "com.example.two")])
        #expect(second == .dictionary(["bundle": .string("com.example.two"), "allowed": .bool(false)]))
        #expect(tracked.value(at: [.key("apps"), .matching(key: "bundle", value: "com.example.two"), .key("allowed")]) == .bool(false))

        // Where it is in the list doesn't matter: with an entry inserted in front, the same path finds the same app.
        guard case .array(let elements)? = tracked.value(at: [.key("apps")]) else {
            Issue.record("the fixture has a list")
            return
        }
        let inserted = PlistValue.dictionary(["apps": .array([.dictionary(["bundle": .string("com.example.new")])] + elements)])
        let path: PlistKeyPath = [.key("apps"), .matching(key: "bundle", value: "com.example.one"), .key("allowed")]
        #expect(tracked.value(at: path) == .bool(true))
        #expect(inserted.value(at: path) == .bool(true))
        #expect(inserted.value(at: [.key("apps"), .index(0), .key("allowed")]) == nil, "an index would have pointed at the new entry")

        // A value that isn't a string never matches.
        #expect(tracked.value(at: [.key("apps"), .matching(key: "allowed", value: "true")]) == nil)
    }

    @Test func noMatchIsAnError() {
        #expect(throws: KeyPathError.noMatch(step: 1)) {
            try tracked.setting(.bool(true), at: [.key("apps"), .matching(key: "bundle", value: "com.example.gone"), .key("allowed")])
        }
        #expect(throws: KeyPathError.noMatch(step: 1), "removing a match that isn't there is an error too") {
            try tracked.setting(nil, at: [.key("apps"), .matching(key: "bundle", value: "com.example.gone")])
        }
        #expect(throws: KeyPathError.indexOutOfRange(step: 1)) {
            try tracked.setting(.integer(1), at: [.key("apps"), .index(5)])
        }
        #expect(throws: KeyPathError.notAContainer(step: 1)) {
            try tracked.setting(.integer(1), at: [.key("count"), .key("deeper")])
        }
        #expect(throws: KeyPathError.notAContainer(step: 0)) {
            try PlistValue.string("x").setting(.integer(1), at: [.key("a")])
        }
        // A list is never made: its elements are what is looked for.
        #expect(throws: KeyPathError.noMatch(step: 1)) {
            try PlistValue.dictionary([:]).setting(.integer(1), at: [.key("apps"), .matching(key: "bundle", value: "x")])
        }
        #expect(throws: KeyPathError.indexOutOfRange(step: 1)) {
            try PlistValue.dictionary([:]).setting(.integer(1), at: [.key("apps"), .index(0)])
        }
        #expect(throws: KeyPathError.noMatch(step: 0), "an empty path has nowhere to put it") {
            try tracked.setting(.integer(1), at: [])
        }
    }

    @Test func codableRoundTrip() throws {
        let path: PlistKeyPath = [.key("apps"), .index(3), .matching(key: "bundle", value: "com.example.one"), .key("a/b=c%d")]
        let data = try JSONCoding.encoder().encode(path)
        #expect(try JSONCoding.decoder().decode(PlistKeyPath.self, from: data) == path)

        // Steps are distinct values: the same text as a key, an index or a match never compares equal.
        #expect(KeyPathStep.key("1") != KeyPathStep.index(1))
        #expect(Set<KeyPathStep>([.key("a"), .key("a"), .matching(key: "a", value: "b")]).count == 2)
    }

    @Test func errorsSayWhatHappenedInPlainWords() {
        #expect(KeyPathError.notAContainer(step: 2).errorDescription?.isEmpty == false)
        #expect(KeyPathError.noMatch(step: 1).errorDescription?.isEmpty == false)
        #expect(KeyPathError.indexOutOfRange(step: 1).errorDescription?.isEmpty == false)
        #expect(KeyPathError.ambiguousMatch(step: 1).errorDescription?.isEmpty == false)
        #expect(KeyPathError.anyElementOutsideMatchingPath(step: 1).errorDescription?.isEmpty == false)
        // In words for the person: no "any element" from the key paths' own jargon.
        #expect(KeyPathError.anyElementOutsideMatchingPath(step: 1).errorDescription?.contains("any element") == false)
    }

    // MARK: A match by a way to the ID

    @Test func matchingPathFindsNestedID() throws {
        #expect(approvals.value(at: [entry("com.example.one")]) == approval(true, [bundle("com.example.one")]))
        #expect(approvals.value(at: [entry("com.example.one"), .key("isAllowed")]) == .bool(true))
        #expect(approvals.value(at: [entry("com.example.three.helper"), .key("isAllowed")]) == .bool(true), "any of an entry's IDs finds it")

        // Setting changes that entry's flag and nothing else.
        let changed = try approvals.setting(.bool(false), at: [entry("com.example.one"), .key("isAllowed")])
        #expect(changed.value(at: [entry("com.example.one"), .key("isAllowed")]) == .bool(false))
        #expect(changed.value(at: [.index(0), .key("isAllowed")]) == .bool(false))
        for position in 1...3 { #expect(changed.value(at: [.index(position)]) == approvals.value(at: [.index(position)])) }
        #expect(changed.value(at: [.index(0), .key("menuItemLocations")]) == approvals.value(at: [.index(0), .key("menuItemLocations")]))

        // The entry as a whole can be taken out, and the others stay in order.
        let without = try approvals.setting(nil, at: [entry("com.example.one")])
        #expect(without.value(at: []) == .array(Array([1, 2, 3].map { approvals.value(at: [.index($0)])! })))
    }

    @Test func matchingPathAnyElementTriesEveryLocation() {
        // The ID is in the second place of its entry, after a program that has no ID; and in the third of another's.
        let list: PlistValue = .array([
            approval(true, [program("Example Tools/exampled"), bundle("com.example.second")]),
            approval(false, [program("Example Tools/other"), program("Example Tools/more"), bundle("com.example.third")]),
        ])
        #expect(list.value(at: [entry("com.example.second"), .key("isAllowed")]) == .bool(true))
        #expect(list.value(at: [entry("com.example.third"), .key("isAllowed")]) == .bool(false))
        #expect(list.matchCount(path: wayToTheID, value: "com.example.second") == 1)
        // A program's path is a string too, but not at the place the way leads to.
        #expect(list.value(at: [entry("Example Tools/exampled")]) == nil)
        // A way with no `anyElement` reads one place only: the first.
        let firstPlaceOnly: PlistKeyPath = [.matchingPath(path: [.key("menuItemLocations"), .index(0), .key("bundle"), .key("_0")], value: "com.example.second")]
        #expect(list.value(at: firstPlaceOnly) == nil)
        let secondPlaceOnly: PlistKeyPath = [.matchingPath(path: [.key("menuItemLocations"), .index(1), .key("bundle"), .key("_0")], value: "com.example.second")]
        #expect(list.value(at: secondPlaceOnly) != nil)
    }

    @Test func matchingPathNoElementIsNoMatch() {
        #expect(approvals.value(at: [entry("com.example.absent")]) == nil)
        #expect(approvals.matchCount(path: wayToTheID, value: "com.example.absent") == 0)
        #expect(throws: KeyPathError.noMatch(step: 0)) {
            try approvals.setting(.bool(false), at: [entry("com.example.absent"), .key("isAllowed")])
        }
        #expect(throws: KeyPathError.noMatch(step: 1), "removing an entry that isn't there is an error too") {
            try PlistValue.dictionary(["list": approvals]).setting(nil, at: [.key("list"), entry("com.example.absent")])
        }
        // A list is never made for it.
        #expect(throws: KeyPathError.noMatch(step: 1)) {
            try PlistValue.dictionary([:]).setting(.bool(false), at: [.key("list"), entry("com.example.one")])
        }
        // A value that is not an array has no elements.
        #expect(throws: KeyPathError.notAContainer(step: 0)) {
            try PlistValue.string("x").setting(.bool(false), at: [entry("com.example.one")])
        }
        #expect(approvals.matchCount(path: wayToTheID, value: "com.example.one") == 1)
        #expect(PlistValue.string("x").matchCount(path: wayToTheID, value: "x") == nil)
    }

    @Test func matchingPathTwoElementsIsAmbiguous() throws {
        // Two entries claim one app: which one to change isn't known, so nothing is.
        let list: PlistValue = .array([
            approval(true, [bundle("com.example.one")]),
            approval(false, [program("Example Tools/exampled"), bundle("com.example.one")]),
            approval(true, [bundle("com.example.two")]),
        ])
        #expect(list.matchCount(path: wayToTheID, value: "com.example.one") == 2)
        #expect(list.value(at: [entry("com.example.one")]) == nil, "nothing is read from it either")
        #expect(throws: KeyPathError.ambiguousMatch(step: 0)) {
            try list.setting(.bool(false), at: [entry("com.example.one"), .key("isAllowed")])
        }
        #expect(throws: KeyPathError.ambiguousMatch(step: 1)) {
            try PlistValue.dictionary(["list": list]).setting(nil, at: [.key("list"), entry("com.example.one")])
        }
        // The one app that has one entry is still found.
        #expect(try list.setting(.bool(false), at: [entry("com.example.two"), .key("isAllowed")]).value(at: [.index(2), .key("isAllowed")]) == .bool(false))
        // Two places of one entry that both say the ID are one entry, not two.
        let twice: PlistValue = .array([approval(true, [bundle("com.example.one"), bundle("com.example.one")])])
        #expect(twice.matchCount(path: wayToTheID, value: "com.example.one") == 1)
    }

    @Test func anyElementOutsideMatchingPathIsAnError() {
        #expect(throws: KeyPathError.anyElementOutsideMatchingPath(step: 0)) {
            try approvals.setting(.bool(false), at: [.anyElement, .key("isAllowed")])
        }
        #expect(throws: KeyPathError.anyElementOutsideMatchingPath(step: 1)) {
            try PlistValue.dictionary(["list": approvals]).setting(.bool(false), at: [.key("list"), .anyElement])
        }
        #expect(throws: KeyPathError.anyElementOutsideMatchingPath(step: 1), "also where the dictionary before it is made") {
            try PlistValue.dictionary([:]).setting(.bool(false), at: [.key("list"), .anyElement])
        }
        #expect(throws: KeyPathError.anyElementOutsideMatchingPath(step: 0), "whatever the value is") {
            try PlistValue.string("x").setting(.bool(false), at: [.anyElement])
        }
        #expect(approvals.value(at: [.anyElement]) == nil, "a place that is read is one place")
        #expect(approvals.value(at: [.anyElement, .key("isAllowed")]) == nil)
        // And a way that is only read holds no match of its own.
        let nested: PlistKeyPath = [.matchingPath(path: [.matchingPath(path: wayToTheID, value: "com.example.one")], value: "x")]
        #expect(approvals.value(at: nested) == nil)
        #expect(throws: KeyPathError.noMatch(step: 0)) { try approvals.setting(.bool(true), at: nested) }
    }

    @Test func matchingPathSurvivesReorder() throws {
        guard case .array(let elements) = approvals else {
            Issue.record("the fixture is a list")
            return
        }
        // The entry of com.example.two is the third, and its switch is off.
        let two = elements[2]
        let turnedOn = approval(true, [program("Example Helper/helperd"), bundle("com.example.two")])
        let path: PlistKeyPath = [entry("com.example.two"), .key("isAllowed")]
        let orders: [[PlistValue]] = [
            elements, elements.reversed(), Array(elements.dropFirst(2)) + Array(elements.prefix(2)),
            [elements[3], elements[1], elements[0], elements[2]],
        ]
        for order in orders {
            let list = PlistValue.array(order)
            #expect(list.value(at: path) == .bool(false), "found wherever it is")
            let changed = try list.setting(.bool(true), at: path)
            // Only that entry changed, and every entry is where it was in the list.
            #expect(changed == .array(order.map { $0 == two ? turnedOn : $0 }))
        }
        // An index would have pointed at another app's entry after the list was reordered.
        #expect(PlistValue.array(elements.reversed()).value(at: [.index(2), .key("isAllowed")]) == .bool(true))
    }

    @Test func matchingPathCodableRoundTrip() throws {
        let path: PlistKeyPath = [.key("list"), entry("com.example.one"), .key("menuItemLocations"), .index(1),
                                  .matchingPath(path: [.matching(key: "a", value: "b"), .anyElement, .index(0)], value: "v,w=x/y*z%")]
        let data = try JSONCoding.encoder().encode(path)
        #expect(try JSONCoding.decoder().decode(PlistKeyPath.self, from: data) == path)
        #expect(try JSONCoding.decoder().decode([KeyPathStep].self, from: JSONCoding.encoder().encode([KeyPathStep.anyElement])) == [.anyElement])
        #expect(Set<KeyPathStep>([entry("a"), entry("a"), entry("b"), .anyElement, .anyElement]).count == 3)
        #expect(entry("a") != KeyPathStep.matching(key: "a", value: "a"))

        // A path written before these steps existed is read as it always was.
        let old = try JSONCoding.encoder().encode([KeyPathStep.key("apps"), .index(3), .matching(key: "bundle", value: "com.example.one")])
        #expect(try JSONCoding.decoder().decode([KeyPathStep].self, from: old) == [.key("apps"), .index(3), .matching(key: "bundle", value: "com.example.one")])
    }

    @Test func nestedMatchingPathIsRefused() {
        let inner = entry("com.example.one")
        let nested: PlistKeyPath = [.key("list"), .matchingPath(path: [.key("a"), inner], value: "x"), .key("isAllowed")]
        #expect(nested.nestedMatchingPathStep == 1, "the step that has another in its way")
        #expect(([entry("com.example.one"), .key("isAllowed")] as PlistKeyPath).nestedMatchingPathStep == nil)
        #expect(([] as PlistKeyPath).nestedMatchingPathStep == nil)
        #expect(([.key("list"), .matching(key: "a", value: "b"), .matchingPath(path: [.anyElement, .key("a")], value: "x")] as PlistKeyPath)
            .nestedMatchingPathStep == nil, "every other step may be in the way")
        #expect(KeyPathError.nestedMatchingPath(step: 1).errorDescription
            == "Mantel was asked to change a place it can't record, so it left the setting alone.")

        // The text such a path would have is no text that reads back: the journal key of a change like that would name nothing.
        #expect(KeyPathText.path(from: KeyPathText.text(for: nested)) == nil)
        // And reading refuses every spelling of one.
        for text in ["mp:mp:k:a=b=c", "mp:k:a,mp:k:b=c=d", "mp:*,mp:k:menuItemLocations,*,k:bundle,k:_0=com.example.one=x", "k:list/mp:mp:k:a=b=c/k:isAllowed"] {
            #expect(KeyPathText.path(from: text) == nil, "\(text)")
        }
        // A way that is only read holds no match of its own.
        #expect(approvals.value(at: [.matchingPath(path: [.matchingPath(path: wayToTheID, value: "com.example.one")], value: "x")]) == nil)
    }

    @Test func aDoubledEntryIsToldApartFromAnAbsentOne() throws {
        guard case .array(let elements) = approvals else {
            Issue.record("the fixture is a list")
            return
        }
        let path: PlistKeyPath = [entry("com.example.one"), .key("isAllowed")]
        #expect(approvals.value(at: path) == .bool(true))
        #expect(!approvals.hasAmbiguousMatch(at: path), "one entry: nothing is ambiguous")
        #expect(!approvals.hasAmbiguousMatch(at: [entry("com.example.absent"), .key("isAllowed")]), "none: not ambiguous either")
        let doubled = PlistValue.array(elements + [approval(false, [bundle("com.example.one")])])
        #expect(doubled.value(at: path) == nil, "nothing is read from a doubled entry")
        #expect(doubled.hasAmbiguousMatch(at: path))
        #expect(doubled.hasAmbiguousMatch(at: [entry("com.example.one")]))
        #expect(!doubled.hasAmbiguousMatch(at: [entry("com.example.two"), .key("isAllowed")]), "another app's entry is still one")
        #expect(PlistValue.dictionary(["list": doubled]).hasAmbiguousMatch(at: [.key("list"), entry("com.example.one"), .key("isAllowed")]))
        #expect(!PlistValue.string("x").hasAmbiguousMatch(at: path))
    }

    // MARK: The same, as text

    @Test func matchingPathTextRoundTrips() {
        // The form the journal keys an entry by, and a probe is given a place in.
        #expect(KeyPathText.text(for: [entry("com.example.app")]) == "/mp:k:menuItemLocations,*,k:bundle,k:_0=com.example.app")
        #expect(KeyPathText.text(for: [.key("list"), entry("com.example.app"), .key("isAllowed")])
                == "/k:list/mp:k:menuItemLocations,*,k:bundle,k:_0=com.example.app/k:isAllowed")
        #expect(KeyPathText.text(for: [.anyElement]) == "/*")

        // Names and values that hold the characters that mean something: `,` `=` `/` `%` and `*`.
        let awkward = "a,b=c/d%e*f"
        let paths: [PlistKeyPath] = [
            [entry("com.example.app")],
            [.key("list"), entry("com.example.app"), .key("isAllowed")],
            [.matchingPath(path: [.key(awkward), .anyElement, .key(awkward)], value: awkward)],
            [.matchingPath(path: [.matching(key: awkward, value: awkward), .index(3), .anyElement, .key("*"), .key(","), .key("="), .key("%")], value: "*")],
            [.matchingPath(path: [.key("%2C"), .key("%2A"), .key("%25")], value: "%3D")],
            [.matchingPath(path: [], value: "the element is the string")],
            [.matchingPath(path: [.key("k")], value: ""), .matchingPath(path: [.anyElement], value: "second")],
            [.anyElement, .anyElement, .key("*")],
        ]
        for path in paths {
            let text = KeyPathText.text(for: path)
            #expect(KeyPathText.path(from: text) == path, "\(text)")
            #expect(KeyPathText.path(from: String(text.dropFirst())) == path, "the first slash is optional: \(text)")
            // No separator of the form is left bare inside a name: the text has as many segments as the path has steps.
            #expect(text.split(separator: "/", omittingEmptySubsequences: false).count == path.count + 1, "\(text)")
        }
        // The command-line form: steps joined by `/`, with `*` for any element.
        #expect(KeyPathText.path(from: "k:menuItemLocations/*/k:bundle/k:_0") == wayToTheID)
        #expect(KeyPathText.path(from: "mp:k:menuItemLocations,*,k:bundle,k:_0=com.example.app/k:isAllowed") == [entry("com.example.app"), .key("isAllowed")])
        #expect(KeyPathText.path(from: "mp:=v") == [.matchingPath(path: [], value: "v")])
    }

    @Test func matchingPathTextNeverCollidesWithMatching() {
        // `m:` and `mp:` are told apart by the form, whatever the names are.
        let pairs: [(KeyPathStep, KeyPathStep)] = [
            (.matching(key: "k", value: "v"), .matchingPath(path: [.key("k")], value: "v")),
            (.matching(key: "p:k:a", value: "v"), .matchingPath(path: [.key("a")], value: "v")),
            (.matching(key: "p", value: ":k:a=v"), .matchingPath(path: [.key("a")], value: "v")),
            (.matching(key: "a,b", value: "c"), .matchingPath(path: [.key("a"), .key("b")], value: "c")),
            (.matching(key: "*", value: "*"), .matchingPath(path: [.anyElement], value: "*")),
            (.key("mp:k:a=v"), .matchingPath(path: [.key("a")], value: "v")),
            (.key("*"), .anyElement),
        ]
        for (matching, matchingPath) in pairs {
            let one = KeyPathText.segment(matching), other = KeyPathText.segment(matchingPath)
            #expect(one != other, "\(one)")
            #expect(KeyPathText.path(from: one) == [matching], "\(one)")
            #expect(KeyPathText.path(from: other) == [matchingPath], "\(other)")
        }
        // The older forms are written as they always were: a `,` or a `*` in a name is not encoded there.
        #expect(KeyPathText.text(for: [.key("a,b*c"), .matching(key: "x,y", value: "*")]) == "/k:a,b*c/m:x,y=*")
        #expect(KeyPathText.path(from: "/k:a,b*c/m:x,y=*") == [.key("a,b*c"), .matching(key: "x,y", value: "*")])
    }

    @Test func findsAnEntryIsWhatTheMatchingStepsDo() {
        #expect(KeyPathStep.matching(key: "a", value: "b").findsAnEntry)
        #expect(entry("a").findsAnEntry)
        #expect(!KeyPathStep.key("a").findsAnEntry && !KeyPathStep.index(0).findsAnEntry && !KeyPathStep.anyElement.findsAnEntry)
    }
}
