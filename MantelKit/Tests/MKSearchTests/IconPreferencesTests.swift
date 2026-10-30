import Foundation
import MKCore
import MKTestSupport
import Synchronization
import Testing

@Suite("Icon preferences", .timeLimit(.minutes(1)))
struct IconPreferencesTests {
    /// Held by the suite, and so for the whole test: the folder is deleted when the test is over.
    let folder = TemporaryFolder(prefix: "mantel-icons")

    private let weather = ItemID(bundleID: "com.example.weather", key: .identifier("weather.temp"))
    private let sync = ItemID(bundleID: "com.example.sync", key: .index(2))
    private let wifi = ItemID.system("wifi")

    private func decode(_ json: String) throws -> IconPreferences {
        try JSONDecoder().decode(IconPreferences.self, from: Data(json.utf8))
    }

    @Test func roundTrip() async throws {
        #expect(IconPreferences.fileName == "icons.json")
        #expect(IconPreferences.currentVersion == 1)
        #expect(IconPreferences() == IconPreferences(searchNames: [:], hotkeyActions: [:], recentPicks: []))

        let preferences = IconPreferences(
            searchNames: [weather: ["forecast", "rain"], sync: ["backup"], wifi: ["network"]],
            hotkeyActions: [weather: .show, sync: .click(.left), wifi: .click(.right), ItemID(bundleID: "com.example.notes", key: .index(0)): .click(.option)],
            recentPicks: ["icon:com.example.sync#2", "action:showHidden", "icon:system:wifi"])

        // Through the settings store, as the app keeps it: a file in the settings folder, read by another store.
        let paths = MantelPaths(root: folder.url.appending(path: "Support", directoryHint: .isDirectory),
                                logs: folder.url.appending(path: "Logs", directoryHint: .isDirectory))
        let writer = SettingsStore(paths: paths, clock: FakeClock())
        _ = await writer.load(IconPreferences.self)
        await writer.save(preferences)
        await writer.flush()
        let reloaded = await SettingsStore(paths: paths, clock: FakeClock()).load(IconPreferences.self)
        #expect(reloaded == preferences)

        // The file names icons by their text form, and each hotkey action by what it does.
        let text = try String(contentsOf: paths.settings.appending(path: "icons.json"), encoding: .utf8)
        #expect(text.contains(#""com.example.weather::weather.temp""#))
        #expect(text.contains(#""com.example.sync#2""#))
        #expect(text.contains(#""system:wifi""#))
        #expect(text.contains(#""kind" : "show""#))
        #expect(text.contains(#""click" : "right""#))
        let envelope = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(envelope["version"] as? Int == 1)

        // And as bare JSON.
        #expect(try JSONDecoder().decode(IconPreferences.self, from: JSONEncoder().encode(preferences)) == preferences)
        #expect(try JSONDecoder().decode(IconPreferences.self, from: JSONEncoder().encode(IconPreferences())) == IconPreferences())
    }

    @Test func missingKeysTakeDefaultsAndUnknownKeysAreIgnored() throws {
        #expect(try decode("{}") == IconPreferences())
        #expect(try decode(#"{"recentPicks":["action:openSettings"]}"#) == IconPreferences(recentPicks: ["action:openSettings"]))
        let withExtras = try decode(#"{"searchNames":{"com.example.sync#2":["backup"]},"somethingNew":{"a":1},"recentPicks":[]}"#)
        #expect(withExtras == IconPreferences(searchNames: [sync: ["backup"]]))
    }

    @Test func hotkeyActionsHaveTheirTitlesAndForms() throws {
        #expect(IconHotkeyAction.show.title == "Show")
        #expect(IconHotkeyAction.click(.left).title == "Show and click")
        #expect(IconHotkeyAction.click(.right).title == "Show and right-click")
        #expect(IconHotkeyAction.click(.option).title == "Show and option-click")

        for action in [IconHotkeyAction.show] + ClickKind.allCases.map(IconHotkeyAction.click) {
            #expect(try JSONDecoder().decode(IconHotkeyAction.self, from: JSONEncoder().encode(action)) == action)
        }
        let show = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(IconHotkeyAction.show)) as? [String: String])
        #expect(show == ["kind": "show"])
        let right = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(IconHotkeyAction.click(.right))) as? [String: String])
        #expect(right == ["kind": "click", "click": "right"])
    }

    @Test func itemIDKeysAreObjectKeys() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode([weather: 1, sync: 2, wifi: 3])
        #expect(String(decoding: data, as: UTF8.self) == #"{"com.example.sync#2":2,"com.example.weather::weather.temp":1,"system:wifi":3}"#)
        #expect(try JSONDecoder().decode([ItemID: Int].self, from: data) == [weather: 1, sync: 2, wifi: 3])
    }

    @Test func badKeySkipped() async throws {
        let json = """
        {
          "searchNames": {
            "com.example.sync#2": ["backup"],
            "this is not an icon": ["secret name"],
            "com.example.weather::": ["another secret"]
          },
          "hotkeyActions": {
            "com.example.sync#2": {"kind": "click", "click": "right"},
            "also not an icon": {"kind": "show"},
            "com.example.weather::weather.temp": {"kind": "teleport"}
          },
          "recentPicks": ["icon:com.example.sync#2"]
        }
        """
        let read = Mutex<IconPreferences?>(nil)
        let lines = await LogCapture.lines {
            read.withLock { $0 = try? JSONDecoder().decode(IconPreferences.self, from: Data(json.utf8)) }
        }

        // The file is read, without what couldn't be.
        let preferences = try #require(read.withLock { $0 })
        #expect(preferences.searchNames == [sync: ["backup"]])
        #expect(preferences.hotkeyActions == [sync: .click(.right)])
        #expect(preferences.recentPicks == ["icon:com.example.sync#2"])

        // Each skipped entry is counted in the log, and nothing it held is: not the keys, not the names.
        let mentions = lines.filter { $0.contains("[icons]") }
        #expect(mentions.count == 1, "\(mentions)")
        #expect(mentions.first?.contains("4 saved entries") == true)
        #expect(mentions.first?.contains("icons.json") == true)
        #expect(!lines.contains { $0.contains("this is not an icon") || $0.contains("secret") || $0.contains("teleport") || $0.contains("also not") })
    }

    @Test func namesTrimmedAndCapped() throws {
        let long = String(repeating: "x", count: 60)
        let json = """
        {"searchNames": {
          "com.example.weather::weather.temp": ["  forecast  ", "", "   ", "rain\\n", "\(long)", "a", "b", "c", "d"],
          "com.example.sync#2": ["", "  "],
          "system:wifi": ["network"]
        }}
        """
        let preferences = try decode(json)
        // Trimmed, the empty ones gone, each at most 40 characters, and five of them at most.
        #expect(preferences.searchNames[weather] == ["forecast", "rain", String(repeating: "x", count: 40), "a", "b"])
        // An icon whose names are all empty has none.
        #expect(preferences.searchNames[sync] == nil)
        #expect(preferences.searchNames[wifi] == ["network"])

        // The same wherever the names come from: the initializer, a change, and the helper the editor uses.
        #expect(IconPreferences(searchNames: [weather: ["  one ", "", "two"]]).searchNames[weather] == ["one", "two"])
        var edited = IconPreferences()
        edited.searchNames[weather] = ["  padded  ", ""]
        #expect(edited.searchNames[weather] == ["padded"])
        edited.searchNames[weather] = (1...9).map { "name \($0)" }
        #expect(edited.searchNames[weather]?.count == IconPreferences.maxNamesPerItem)
        edited.searchNames[weather] = [" "]
        #expect(edited.searchNames[weather] == nil)
        #expect(IconPreferences.cleanedNames(["  a  ", "", "b"]) == ["a", "b"])

        // A cut that ends on a space doesn't leave it: 39 characters, a space, and a letter.
        let spaced = String(repeating: "y", count: 39) + " z"
        #expect(IconPreferences.cleanedNames([spaced]) == [String(repeating: "y", count: 39)])
        // Characters, not bytes: 40 of an accented letter is kept whole.
        let accented = String(repeating: "é", count: 45)
        #expect(IconPreferences.cleanedNames([accented]) == [String(repeating: "é", count: 40)])

        // What is written is what was kept.
        let written = try JSONEncoder().encode(preferences)
        #expect(try JSONDecoder().decode(IconPreferences.self, from: written) == preferences)
    }

    @Test func recentsCappedAtTwenty() throws {
        let picks = (0..<25).map { "icon:com.example.app#\($0)" }
        let json = #"{"recentPicks": [\#(picks.map { "\"\($0)\"" }.joined(separator: ","))]}"#
        let preferences = try decode(json)
        #expect(preferences.recentPicks == Array(picks.prefix(20)), "the newest are first, so the oldest are the ones dropped")
        #expect(IconPreferences.maxRecentPicks == 20)

        #expect(IconPreferences(recentPicks: picks).recentPicks.count == 20)
        var edited = IconPreferences()
        edited.recentPicks = picks
        #expect(edited.recentPicks == Array(picks.prefix(20)))
        edited.recentPicks.insert("action:showAll", at: 0)
        #expect(edited.recentPicks.count == 20)
        #expect(edited.recentPicks.first == "action:showAll")
        #expect(edited.recentPicks.last == picks[18])
    }
}
