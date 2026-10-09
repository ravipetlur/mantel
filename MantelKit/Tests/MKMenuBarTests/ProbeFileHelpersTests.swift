import Foundation
import MKCommands
import MKCore
import Testing

@testable import MKMenuBar

@Suite("Plist shape", .timeLimit(.minutes(1)))
struct PlistShapeTests {
    @Test func aShapeHasKeyNamesAndTypesButNeverValues() throws {
        let value = PlistValue.dictionary([
            "com.example.app": .dictionary(["allowed": .bool(true), "label": .string("SECRET-LABEL"), "since": .integer(12345)]),
            "com.example.other": .bool(false),
        ])
        let described = PlistShape.describe(value)
        let data = try JSONEncoder().encode(described)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("SECRET-LABEL"))
        #expect(!text.contains("12345"))
        #expect(text.contains("com.example.app"))
        #expect(text.contains("allowed"))

        guard case .object(let object) = described, case .object(let entries)? = object["entries"] else {
            Issue.record("a dictionary is described by its entries")
            return
        }
        #expect(entries["com.example.other"] == .string("bool"))
        #expect(object["count"] == .number(2))
    }

    @Test func anArrayIsItsLengthAndTheTypesOfItsElements() {
        let described = PlistShape.describe(.array([.string("a"), .integer(1), .string("b")]))
        guard case .object(let object) = described else {
            Issue.record("an array is described by an object")
            return
        }
        #expect(object["type"] == .string("array"))
        #expect(object["count"] == .number(3))
        #expect(object["elementTypes"] == .array([.string("integer"), .string("string")]))
        #expect(object["first"] == .string("string"))
    }

    @Test func aDeepValueIsCutAtTheDepthLimit() {
        let deep = PlistValue.dictionary(["a": .dictionary(["b": .dictionary(["c": .dictionary(["d": .bool(true)])])])])
        guard case .object(let top) = PlistShape.describe(deep, maxDepth: 2),
              case .object(let one)? = top["entries"],
              case .object(let a)? = one["a"],
              case .object(let two)? = a["entries"],
              case .object(let b)? = two["b"] else {
            Issue.record("two levels are described")
            return
        }
        #expect(b["entries"] == nil, "the third level is only counted")
        #expect(b["count"] == .number(1))
    }

    @Test func aHugeDictionaryIsCutAndSaysSo() {
        var entries: [String: PlistValue] = [:]
        for index in 0..<50 { entries["key\(index)"] = .bool(true) }
        guard case .object(let object) = PlistShape.describe(.dictionary(entries), maxKeys: 10),
              case .object(let described)? = object["entries"] else {
            Issue.record("described")
            return
        }
        #expect(described.count == 10)
        #expect(object["truncated"] == .bool(true))
        #expect(object["count"] == .number(50))
    }

    @Test func containsFindsAKeyOrAStringValueAnywhere() {
        let value = PlistValue.dictionary(["list": .array([.dictionary(["id": .string("com.example.fixture.testitem")])]),
                                           "com.example.keyed": .bool(true)])
        #expect(PlistShape.contains(value, string: "com.example.fixture.testitem"))
        #expect(PlistShape.contains(value, string: "com.example.keyed"))
        #expect(!PlistShape.contains(value, string: "com.example.missing"))
        #expect(!PlistShape.contains(.bool(true), string: "true"))
    }
}

@Suite("Approvals editor", .timeLimit(.minutes(1)))
struct ApprovalsEditorTests {
    private let app = "com.example.mantel.testitem"

    @Test func aDictionaryOfFlagsFlipsTheAppsFlag() throws {
        let tracked = PlistValue.dictionary([app: .bool(true), "com.example.other": .bool(true)])
        let flip = try #require(ApprovalsEditor.flipped(tracked, bundleID: app))
        #expect(flip.value == .dictionary([app: .bool(false), "com.example.other": .bool(true)]))
        #expect(flip.wasAllowed)
        #expect(flip.path == "trackedApplications[\(app)]")
    }

    @Test func aDictionaryOfDictionariesFlipsTheFlagWhoseNameSaysAllow() throws {
        let tracked = PlistValue.dictionary([app: .dictionary(["isAllowed": .bool(false), "name": .string("x")])])
        let flip = try #require(ApprovalsEditor.flipped(tracked, bundleID: app))
        #expect(flip.value == .dictionary([app: .dictionary(["isAllowed": .bool(true), "name": .string("x")])]))
        #expect(!flip.wasAllowed)
        #expect(flip.path == "trackedApplications[\(app)].isAllowed")
    }

    @Test func anArrayOfDictionariesFindsTheOneThatNamesTheApp() throws {
        let tracked = PlistValue.array([
            .dictionary(["bundleIdentifier": .string("com.example.other"), "allowed": .bool(true)]),
            .dictionary(["bundleIdentifier": .string(app), "allowed": .integer(1)]),
        ])
        let flip = try #require(ApprovalsEditor.flipped(tracked, bundleID: app))
        #expect(flip.value == .array([
            .dictionary(["bundleIdentifier": .string("com.example.other"), "allowed": .bool(true)]),
            .dictionary(["bundleIdentifier": .string(app), "allowed": .integer(0)]),
        ]))
        #expect(flip.path == "trackedApplications[1].allowed")
    }

    @Test func anAppThatIsNotThereOrHasNoFlagIsNil() {
        #expect(ApprovalsEditor.flipped(.dictionary(["com.example.other": .bool(true)]), bundleID: app) == nil)
        #expect(ApprovalsEditor.flipped(.dictionary([app: .dictionary(["name": .string("x")])]), bundleID: app) == nil)
        #expect(ApprovalsEditor.flipped(.dictionary([app: .string("surprise")]), bundleID: app) == nil)
        #expect(ApprovalsEditor.flipped(.string("not a container"), bundleID: app) == nil)
        #expect(ApprovalsEditor.flipped(.array([.string(app)]), bundleID: app) == nil)
    }

    @Test func aCountThatIsNotAFlagIsNotFlipped() {
        #expect(ApprovalsEditor.flipped(.dictionary([app: .integer(7)]), bundleID: app) == nil)
    }
}

@Suite("Layout keys", .timeLimit(.minutes(1)))
struct LayoutKeysTests {
    @Test func aKeysPrefixIsItsFormat() {
        #expect(LayoutKeys.prefix(of: "status:com.example.app::autosave") == "status:")
        #expect(LayoutKeys.prefix(of: "module:Clock") == "module:")
        #expect(LayoutKeys.prefix(of: "plainkey") == "other")
        #expect(LayoutKeys.prefix(of: "a-very-long-prefix-that-is-surely-a-name:rest") == "other", "a name is not a format")
    }

    @Test func aStatusKeyNamesItsApp() {
        #expect(LayoutKeys.bundleID(ofStatusKey: "status:com.example.app::mantel.fixture.one") == "com.example.app")
        #expect(LayoutKeys.bundleID(ofStatusKey: "module:Clock") == nil)
        #expect(LayoutKeys.bundleID(ofStatusKey: "status:::x") == nil)
        #expect(LayoutKeys.bundleID(ofStatusKey: "status:no-separator") == nil)
    }
}
