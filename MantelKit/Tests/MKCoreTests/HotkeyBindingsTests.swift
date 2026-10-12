import Foundation
import MKTestSupport
import Testing

@testable import MKCore

@Suite("HotkeyBindings", .timeLimit(.minutes(1)))
struct HotkeyBindingsTests {
    /// Held by the suite, and so for the whole test: the folder is deleted when the test is over.
    let folder = TemporaryFolder(prefix: "mantel-hotkeys")

    private var paths: MantelPaths {
        MantelPaths(root: folder.url.appending(path: "Support", directoryHint: .isDirectory),
                    logs: folder.url.appending(path: "Logs", directoryHint: .isDirectory))
    }

    private let combo = KeyCombo(keyCode: KeyCode.k, modifiers: [.control, .option, .command])

    @Test func theFileIsHotkeysJsonAtVersionOne() {
        #expect(HotkeyBindings.fileName == "hotkeys.json")
        #expect(HotkeyBindings.currentVersion == 1)
    }

    @Test func everyActionStartsUnassigned() {
        #expect(HotkeyBindings().bindings.isEmpty)
    }

    @Test func itRoundTripsThroughTheStore() async {
        let store = SettingsStore(paths: paths)
        var bindings = await store.load(HotkeyBindings.self)
        #expect(bindings == HotkeyBindings())

        bindings.bindings[.openSettings] = combo
        bindings.bindings[HotkeyID(rawValue: "another-action")] = KeyCombo(keyCode: KeyCode.f5, modifiers: [])
        await store.save(bindings)
        await store.flush()

        let reopened = SettingsStore(paths: paths)
        let loaded = await reopened.load(HotkeyBindings.self)
        #expect(loaded == bindings)
        #expect(loaded.bindings[.openSettings] == combo)
    }

    @Test func theFileIsAnObjectKeyedByActionWithNamedModifiers() async throws {
        let store = SettingsStore(paths: paths)
        _ = await store.load(HotkeyBindings.self)
        await store.save(HotkeyBindings(bindings: [.openSettings: combo]))
        await store.flush()

        let data = try Data(contentsOf: paths.settings.appending(path: "hotkeys.json"))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["version"] as? Int == 1)
        let document = try #require(root["document"] as? [String: Any])
        let bindings = try #require(document["bindings"] as? [String: Any])
        let binding = try #require(bindings["open-settings"] as? [String: Any])
        #expect(binding["keyCode"] as? Int == Int(KeyCode.k))
        #expect(binding["modifiers"] as? [String] == ["control", "option", "command"])
    }

    @Test func aFileWithoutBindingsIsTheDefaults() throws {
        #expect(try JSONDecoder().decode(HotkeyBindings.self, from: Data("{}".utf8)) == HotkeyBindings())
    }

    @Test func aKeyThisVersionDoesNotKnowIsIgnored() throws {
        let json = #"{"bindings":{},"somethingNew":[1,2]}"#
        #expect(try JSONDecoder().decode(HotkeyBindings.self, from: Data(json.utf8)) == HotkeyBindings())
    }

    @Test func anActionThisVersionDoesNotKnowIsKept() async {
        // A newer Mantel's action must survive a save by this one.
        let future = HotkeyID(rawValue: "future-action")
        let store = SettingsStore(paths: paths)
        _ = await store.load(HotkeyBindings.self)
        await store.save(HotkeyBindings(bindings: [future: combo, .openSettings: combo]))
        await store.flush()
        let loaded = await SettingsStore(paths: paths).load(HotkeyBindings.self)
        #expect(loaded.bindings[future] == combo)
    }

    @Test func aCorruptFileIsSetAsideAndTheDefaultsLoad() async throws {
        try FileManager.default.createDirectory(at: paths.settings, withIntermediateDirectories: true)
        // A key code that isn't a number: not a file this version can read at all.
        try Data(#"{"version":1,"document":{"bindings":{"open-settings":{"keyCode":"K","modifiers":["command"]}}}}"#.utf8)
            .write(to: paths.settings.appending(path: "hotkeys.json"))
        let store = SettingsStore(paths: paths)
        #expect(await store.load(HotkeyBindings.self) == HotkeyBindings())
        #expect(!FileManager.default.fileExists(atPath: paths.settings.appending(path: "hotkeys.json").path))
    }

    @Test func unknownModifierSkipsOnlyThatBinding() throws {
        let json = """
        {"bindings": {
          "open-settings": {"keyCode": 40, "modifiers": ["control", "option", "command"]},
          "other-action": {"keyCode": 41, "modifiers": ["command", "hyper"]},
          "third-action": {"keyCode": 96, "modifiers": []}
        }}
        """
        let loaded = try JSONDecoder().decode(HotkeyBindings.self, from: Data(json.utf8))
        #expect(loaded.bindings.keys.map(\.rawValue).sorted() == ["open-settings", "third-action"])
        #expect(loaded.bindings[.openSettings] == KeyCombo(keyCode: 40, modifiers: [.control, .option, .command]))
        #expect(loaded.bindings[HotkeyID(rawValue: "third-action")] == KeyCombo(keyCode: 96, modifiers: []))
    }

    @Test func aFileWithAnUnknownModifierIsNotSetAside() async throws {
        // The one binding that can't be read is left out and logged; the file stays where it is and the rest loads.
        try FileManager.default.createDirectory(at: paths.settings, withIntermediateDirectories: true)
        let file = paths.settings.appending(path: "hotkeys.json")
        try Data(#"{"version":1,"document":{"bindings":{"open-settings":{"keyCode":40,"modifiers":["hyper"]},"kept":{"keyCode":41,"modifiers":["command"]}}}}"#.utf8)
            .write(to: file)
        let loaded = await SettingsStore(paths: paths).load(HotkeyBindings.self)
        #expect(loaded.bindings == [HotkeyID(rawValue: "kept"): KeyCombo(keyCode: 41, modifiers: .command)])
        #expect(FileManager.default.fileExists(atPath: file.path), "the file wasn't moved")
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.settings.path).allSatisfy { !$0.contains("corrupt") })
    }

    @Test func theModifierNamesAreTheOnesTheFileFormatHas() {
        // The list is part of the file format: changing it takes a new version of the document.
        #expect(ModifierSet(names: ["control", "option", "shift", "command", "function"]) == [.control, .option, .shift, .command, .function])
        #expect(ModifierSet(names: ["Command"]) == nil, "names are exact")
        #expect(ModifierSet(names: []) == [])
        #expect(ModifierSet.unknownNames(in: ["command", "hyper", "meta"]) == ["hyper", "meta"])
        #expect(HotkeyBindings.currentVersion == 1)
    }

    @Test func actionIdsAreWrittenAsPlainStrings() throws {
        let id = HotkeyID(rawValue: "open-settings")
        #expect(HotkeyID.openSettings == id)
        let data = try JSONEncoder().encode([id])
        #expect(String(decoding: data, as: UTF8.self) == #"["open-settings"]"#)
        #expect(try JSONDecoder().decode([HotkeyID].self, from: data) == [id])
    }

    // MARK: The actions

    @Test func openMantelSettingsKeepsItsIdAndTitle() {
        #expect(HotkeyAction.all.first?.id == .openSettings)
        #expect(HotkeyAction.openSettings.title == "Open Mantel settings")
        #expect(HotkeyAction.title(for: .openSettings) == "Open Mantel settings")
        #expect(HotkeyAction.title(for: HotkeyID(rawValue: "nothing")) == nil)
    }
}
