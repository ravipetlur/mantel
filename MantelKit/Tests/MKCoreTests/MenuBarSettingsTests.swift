import Foundation
import MKTestSupport
import Testing

@testable import MKCore

@Suite("Menu bar settings", .timeLimit(.minutes(1)))
struct MenuBarSettingsTests {
    /// Held by the suite, and so for the whole test: the folder is deleted when the test is over.
    let folder = TemporaryFolder(prefix: "mantel-menubar-settings")

    private var paths: MantelPaths {
        MantelPaths(root: folder.url.appending(path: "Support", directoryHint: .isDirectory),
                    logs: folder.url.appending(path: "Logs", directoryHint: .isDirectory))
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test func thePointerIsListenedToOnlyWhileSomethingUsesIt() {
        #expect(!RevealSettings().usesPointer, "all three are off by default")
        var settings = RevealSettings()
        settings.hoverReveals = true
        #expect(settings.usesPointer)
        settings = RevealSettings()
        settings.clickReveals = true
        #expect(settings.usesPointer)
        settings = RevealSettings()
        settings.scrollReveals = true
        #expect(settings.usesPointer)
        // The delays change nothing about it.
        settings = RevealSettings()
        settings.rehide = .never
        settings.hoverDelayMilliseconds = 800
        #expect(!settings.usesPointer)
    }

    @Test func defaultsMatchTheSpec() {
        let reveal = RevealSettings()
        #expect(!reveal.hoverReveals)
        #expect(!reveal.clickReveals)
        #expect(!reveal.scrollReveals)
        #expect(reveal.hoverDelayMilliseconds == 300)
        #expect(reveal.rehide == .seconds(10))

        let hiding = HidingSettings()
        #expect(hiding.method == .automatic)
        #expect(!hiding.allowHidingClockAndControlCenter)
        #expect(hiding.noRoomPolicy == .secondBar)
        #expect(hiding.automaticOverflow)
        #expect(!hiding.showEverythingOnWideScreens)
        #expect(hiding.wideScreenThreshold == 3000)

        let general = GeneralSettings()
        #expect(general.reveal == reveal)
        #expect(general.hiding == hiding)

        #expect(HidingMethodChoice.allCases == [.automatic, .systemSettingsSwitches, .wideSpacer])
        #expect(NoRoomPolicy.allCases == [.secondBar, .swap, .hideAppMenus])
    }

    @Test func missingKeysGiveDefaults() throws {
        // A file written before the two keys existed.
        let old = try decode(GeneralSettings.self, #"{"onboardingCompleted":true,"settingsPage":"about"}"#)
        #expect(old == GeneralSettings(onboardingCompleted: true, settingsPage: "about"))
        #expect(try decode(GeneralSettings.self, "{}") == GeneralSettings())

        // Empty objects, and objects that hold only some of the keys.
        #expect(try decode(GeneralSettings.self, #"{"reveal":{},"hiding":{}}"#) == GeneralSettings())
        let someReveal = try decode(RevealSettings.self, #"{"hoverReveals":true}"#)
        var expectedReveal = RevealSettings()
        expectedReveal.hoverReveals = true
        #expect(someReveal == expectedReveal)
        let someHiding = try decode(HidingSettings.self, #"{"method":"systemSettingsSwitches","wideScreenThreshold":4200}"#)
        var expectedHiding = HidingSettings()
        expectedHiding.method = .systemSettingsSwitches
        expectedHiding.wideScreenThreshold = 4200
        #expect(someHiding == expectedHiding)

        // A key this version doesn't know is ignored.
        #expect(try decode(RevealSettings.self, #"{"somethingNew":[1,2],"clickReveals":true}"#).clickReveals)
    }

    @Test func aSavedWideSpacerIsReadAsAutomatic() async throws {
        // The way isn't offered any more, but a file that says it still decodes, and is read as Automatic.
        let saved = try decode(HidingSettings.self, #"{"method":"wideSpacer","wideScreenThreshold":4200,"noRoomPolicy":"swap"}"#)
        #expect(saved.method == .automatic)
        // Nothing else the file says is lost with it.
        var expected = HidingSettings()
        expected.wideScreenThreshold = 4200
        expected.noRoomPolicy = .swap
        #expect(saved == expected)
        #expect(try decode(GeneralSettings.self, #"{"hiding":{"method":"wideSpacer"}}"#).hiding.method == .automatic)

        // The value is still there to be decoded; Settings doesn't offer it.
        #expect(HidingMethodChoice(rawValue: "wideSpacer") == .wideSpacer)
        #expect(!HidingMethodChoice.wideSpacer.isOffered)
        #expect(HidingMethodChoice.allCases.filter(\.isOffered) == [.automatic, .systemSettingsSwitches])

        // And it is written as what it was read as, so the next save leaves no wide spacer in the file.
        let data = try JSONEncoder().encode(saved)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["method"] as? String == "automatic")
        #expect(HidingSettings.noLongerOfferedLine == "the saved hiding method is no longer offered; Mantel uses Automatic")
    }

    @Test func aNoRoomChoiceFromANewerMantelDoesNotLoseTheRestOfTheFile() async throws {
        let saved = try decode(HidingSettings.self, #"{"noRoomPolicy":"somethingNew","wideScreenThreshold":4200,"automaticOverflow":false}"#)
        var expected = HidingSettings()
        expected.wideScreenThreshold = 4200
        expected.automaticOverflow = false
        #expect(saved == expected, "the choice takes its default; everything else the file says is kept")
        let whole = try decode(GeneralSettings.self, #"{"hiding":{"noRoomPolicy":"somethingNew","method":"systemSettingsSwitches"},"onboardingCompleted":true}"#)
        #expect(whole.hiding.noRoomPolicy == .secondBar)
        #expect(whole.hiding.method == .systemSettingsSwitches)
        #expect(whole.onboardingCompleted)
        #expect(try decode(HidingSettings.self, #"{"noRoomPolicy":"swap"}"#).noRoomPolicy == .swap, "a known choice is still read")
    }

    @Test func aHidingMethodFromANewerMantelDoesNotLoseTheRestOfTheFile() async throws {
        let saved = try decode(HidingSettings.self, #"{"method":"somethingNew","noRoomPolicy":"swap","automaticOverflow":false}"#)
        #expect(saved.method == .automatic, "the method takes its default")
        #expect(saved.noRoomPolicy == .swap && !saved.automaticOverflow, "everything else the file says is kept")
        let whole = try decode(GeneralSettings.self, #"{"hiding":{"method":"somethingNew"},"onboardingCompleted":true}"#)
        #expect(whole.onboardingCompleted, "and the rest of the settings file is read")
        #expect(try decode(HidingSettings.self, #"{"method":"systemSettingsSwitches"}"#).method == .systemSettingsSwitches)
    }

    @Test func generalSettingsRoundTripWithNestedValues() async throws {
        var settings = GeneralSettings(onboardingCompleted: true, settingsPage: "advanced")
        settings.reveal = RevealSettings(hoverReveals: true, clickReveals: true, scrollReveals: true, hoverDelayMilliseconds: 800,
                                         rehide: .seconds(60))
        settings.hiding = HidingSettings(method: .systemSettingsSwitches, allowHidingClockAndControlCenter: true, noRoomPolicy: .swap,
                                         automaticOverflow: false, showEverythingOnWideScreens: true, wideScreenThreshold: 5600)

        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(GeneralSettings.self, from: data) == settings)

        // And through the store, as the file Mantel writes.
        let store = SettingsStore(paths: paths)
        _ = await store.load(GeneralSettings.self)
        await store.save(settings)
        await store.flush()
        let reopened = SettingsStore(paths: paths)
        #expect(await reopened.load(GeneralSettings.self) == settings)

        let file = try Data(contentsOf: paths.settings.appending(path: "settings.json"))
        let root = try #require(try JSONSerialization.jsonObject(with: file) as? [String: Any])
        let document = try #require(root["document"] as? [String: Any])
        let reveal = try #require(document["reveal"] as? [String: Any])
        #expect(reveal["hoverDelayMilliseconds"] as? Int == 800)
        #expect(reveal["rehide"] as? Int == 60)
        let hiding = try #require(document["hiding"] as? [String: Any])
        #expect(hiding["method"] as? String == "systemSettingsSwitches")
        #expect(hiding["noRoomPolicy"] as? String == "swap")
        #expect(hiding["wideScreenThreshold"] as? Int == 5600)
    }

    @Test func rehideNeverRoundTrips() throws {
        var reveal = RevealSettings()
        reveal.rehide = .never
        let data = try JSONEncoder().encode(reveal)
        let decoded = try JSONDecoder().decode(RevealSettings.self, from: data)
        #expect(decoded.rehide == .never)
        #expect(decoded == reveal)

        // The file says it in words, and a number of seconds as a number.
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["rehide"] as? String == "never")
        #expect(try decode(RehideDelay.self, "15") == .seconds(15))
        #expect(try decode(RehideDelay.self, #""never""#) == .never)
        #expect(throws: DecodingError.self) { try decode(RehideDelay.self, #""sometimes""#) }
        #expect(throws: DecodingError.self) { try decode(RehideDelay.self, "true") }
    }

    @Test func outOfRangeSettingsAreSnappedOnDecode() throws {
        // The wide screen threshold is clamped to 1000...10000 and snapped to a step of 100 (the higher of two that are as near).
        let thresholds = [(-5, 1000), (0, 1000), (999, 1000), (1000, 1000), (1049, 1000), (1050, 1100), (3000, 3000), (3049, 3000),
                          (3050, 3100), (9999, 10000), (10000, 10000), (250_000, 10000)]
        for (stored, expected) in thresholds {
            let settings = try decode(HidingSettings.self, #"{"wideScreenThreshold":\#(stored)}"#)
            #expect(settings.wideScreenThreshold == expected, "\(stored) is read as \(expected)")
        }

        // The hover delay is the nearest of 100, 200, 300, 500 and 800 (the lower of two that are as near).
        let delays = [(-3, 100), (0, 100), (100, 100), (150, 100), (151, 200), (250, 200), (300, 300), (400, 300), (401, 500),
                      (650, 500), (651, 800), (800, 800), (5000, 800)]
        for (stored, expected) in delays {
            let settings = try decode(RevealSettings.self, #"{"hoverDelayMilliseconds":\#(stored)}"#)
            #expect(settings.hoverDelayMilliseconds == expected, "\(stored) ms is read as \(expected)")
        }

        // The rehide seconds are the nearest of 5, 10, 15, 30 and 60; never stays never.
        let seconds = [(-1, 5), (0, 5), (7, 5), (8, 10), (12, 10), (13, 15), (20, 15), (22, 15), (23, 30), (45, 30), (46, 60), (3600, 60)]
        for (stored, expected) in seconds {
            #expect(try decode(RehideDelay.self, "\(stored)") == .seconds(expected), "\(stored) s is read as \(expected)")
        }
        #expect(try decode(RehideDelay.self, #""never""#) == .never)

        // Values the settings offer come back as they were, nested in the file as Mantel writes it; those that don't are snapped there too.
        for choice in RehideDelay.choices {
            #expect(try decode(RehideDelay.self, "\(choice)") == .seconds(choice))
        }
        let nested = try decode(GeneralSettings.self,
                                #"{"reveal":{"hoverDelayMilliseconds":420,"rehide":50},"hiding":{"wideScreenThreshold":1234}}"#)
        #expect(nested.reveal.hoverDelayMilliseconds == 500)
        #expect(nested.reveal.rehide == .seconds(60))
        #expect(nested.hiding.wideScreenThreshold == 1200)
        #expect(try decode(GeneralSettings.self, "{}") == GeneralSettings())
    }

    @Test func extremeStoredValuesSnapWithoutCrashing() throws {
        // A file edited by hand can hold the smallest and largest numbers there are; reading one must not take Mantel down at launch.
        for stored in [Int.min, Int.min + 1, -1, Int.max - 1, Int.max] {
            let low = stored < 0
            let reveal = try decode(RevealSettings.self, #"{"hoverDelayMilliseconds":\#(stored),"rehide":\#(stored)}"#)
            #expect(reveal.hoverDelayMilliseconds == (low ? 100 : 800), "\(stored) ms is read as the nearest delay")
            #expect(reveal.rehide == .seconds(low ? 5 : 60), "\(stored) s is read as the nearest delay")

            // Each on its own, and the rehide delay by itself.
            #expect(try decode(RevealSettings.self, #"{"hoverDelayMilliseconds":\#(stored)}"#).hoverDelayMilliseconds == (low ? 100 : 800))
            #expect(try decode(RevealSettings.self, #"{"rehide":\#(stored)}"#).rehide == .seconds(low ? 5 : 60))
            #expect(try decode(RehideDelay.self, "\(stored)") == .seconds(low ? 5 : 60))

            // The wide screen threshold is clamped before it is measured, so it was never at risk.
            #expect(try decode(HidingSettings.self, #"{"wideScreenThreshold":\#(stored)}"#).wideScreenThreshold == (low ? 1000 : 10000))
        }
    }
}
