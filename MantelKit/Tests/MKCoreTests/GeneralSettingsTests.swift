import Foundation
import MKTestSupport
import Testing

@testable import MKCore

@Suite("GeneralSettings", .timeLimit(.minutes(1)))
struct GeneralSettingsTests {
    /// Held by the suite, and so for the whole test: the folder is deleted when the test is over.
    let folder = TemporaryFolder(prefix: "mantel-general")

    private var paths: MantelPaths {
        MantelPaths(root: folder.url.appending(path: "Support", directoryHint: .isDirectory),
                    logs: folder.url.appending(path: "Logs", directoryHint: .isDirectory))
    }

    private func decode(_ json: String) throws -> GeneralSettings {
        try JSONDecoder().decode(GeneralSettings.self, from: Data(json.utf8))
    }

    @Test func theDefaults() {
        let settings = GeneralSettings()
        #expect(!settings.onboardingCompleted)
        #expect(settings.settingsPage == nil)
    }

    @Test func theFileIsSettingsJsonAtVersionOne() {
        #expect(GeneralSettings.fileName == "settings.json")
        #expect(GeneralSettings.currentVersion == 1)
    }

    @Test func aFileWithoutAKeyFallsBackToItsDefault() throws {
        // A key added later must not make an older file unreadable.
        #expect(try decode("{}") == GeneralSettings())
        #expect(try decode(#"{"settingsPage":"about"}"#) == GeneralSettings(onboardingCompleted: false, settingsPage: "about"))
        #expect(try decode(#"{"onboardingCompleted":true}"#) == GeneralSettings(onboardingCompleted: true, settingsPage: nil))
    }

    @Test func aKeyThisVersionDoesNotKnowIsIgnored() throws {
        #expect(try decode(#"{"onboardingCompleted":true,"somethingNew":[1,2]}"#).onboardingCompleted)
    }

    @Test func itRoundTripsThroughTheStore() async throws {
        let store = SettingsStore(paths: paths)
        var settings = await store.load(GeneralSettings.self)
        #expect(settings == GeneralSettings())

        settings.onboardingCompleted = true
        settings.settingsPage = "permissions"
        await store.save(settings)
        await store.flush()

        let reopened = SettingsStore(paths: paths)
        #expect(await reopened.load(GeneralSettings.self)
            == GeneralSettings(onboardingCompleted: true, settingsPage: "permissions"))
    }

    @Test func aMissingFileIsTheDefaults() async {
        let store = SettingsStore(paths: paths)
        #expect(await store.load(GeneralSettings.self) == GeneralSettings())
        #expect(await !store.isReadOnly(GeneralSettings.self))
    }
}
