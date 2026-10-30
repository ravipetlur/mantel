import Foundation
import MKCore
import MKTestSupport
import Testing

@testable import MKCore
@testable import MKLayout

@Suite("Profiles document", .timeLimit(.minutes(1)))
struct ProfilesDocumentTests {
    /// Held by the suite, and so for the whole test: the folder is deleted when the test is over.
    let folder = TemporaryFolder(prefix: "mantel-profiles")
    let clock = FakeClock()

    private var paths: MantelPaths {
        MantelPaths(root: folder.url.appending(path: "Support", directoryHint: .isDirectory),
                    logs: folder.url.appending(path: "Logs", directoryHint: .isDirectory))
    }

    private func decode(_ json: String) throws -> ProfilesDocument {
        try JSONDecoder().decode(ProfilesDocument.self, from: Data(json.utf8))
    }

    @Test func defaultsToOneDefaultProfile() {
        let document = ProfilesDocument()
        #expect(ProfilesDocument.fileName == "profiles.json")
        #expect(ProfilesDocument.currentVersion == 2)
        #expect(ProfilesDocument.defaultName == "Default")
        #expect(document.profiles == [Profile(name: "Default", sections: SectionModel())])
        #expect(document.activeProfileName == "Default")
        #expect(document.active == SectionModel())
    }

    @Test func persistsAsDefaultThroughStore() async throws {
        let store = SettingsStore(paths: paths, clock: clock)
        var document = await store.load(ProfilesDocument.self)
        #expect(document == ProfilesDocument())

        document.active.move(app: "com.example.a", to: .hidden)
        document.active.newItems = .alwaysHidden
        #expect(document.profiles.count == 1)
        await store.save(document)

        // Written when the debounce is over, on the fake clock.
        await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(500))
        await store.waitForDebounceTimers()

        let file = try Data(contentsOf: paths.settings.appending(path: "profiles.json"))
        let root = try #require(try JSONSerialization.jsonObject(with: file) as? [String: Any])
        #expect(root["version"] as? Int == 2)
        let stored = try #require(root["document"] as? [String: Any])
        #expect(stored["activeProfileName"] as? String == "Default")
        let profiles = try #require(stored["profiles"] as? [[String: Any]])
        #expect(profiles.count == 1)
        #expect(profiles.first?["name"] as? String == "Default")
        let sections = try #require(profiles.first?["sections"] as? [String: Any])
        #expect(sections["newItems"] as? String == "alwaysHidden")

        let reopened = SettingsStore(paths: paths, clock: clock)
        let loaded = await reopened.load(ProfilesDocument.self)
        #expect(loaded == document)
        #expect(loaded.active.section(ofApp: "com.example.a") == .hidden)
        #expect(loaded.active.newItems == .alwaysHidden)
    }

    @Test func missingActiveProfileFallsBackToDefault() throws {
        // Nothing in the file: the one Default profile, empty.
        #expect(try decode("{}") == ProfilesDocument())

        // Profiles but none the active one: the active profile becomes Default, made empty.
        let empty = try decode(#"{"profiles":[],"activeProfileName":"Gone"}"#)
        #expect(empty.activeProfileName == "Default")
        #expect(empty.profiles == [Profile(name: "Default", sections: SectionModel())])
        #expect(empty.active == SectionModel())

        // A Default that is there is used as it is, not replaced.
        var kept = SectionModel()
        kept.move(app: "com.example.a", to: .hidden)
        let other = Profile(name: "Other", sections: SectionModel())
        let withDefault = ProfilesDocument(profiles: [other, Profile(name: "Default", sections: kept)], activeProfileName: "Gone")
        #expect(withDefault.activeProfileName == "Default")
        #expect(withDefault.profiles.count == 2)
        #expect(withDefault.active == kept)

        // Setting the sections of a document whose active profile went missing makes Default.
        var broken = ProfilesDocument()
        broken.profiles = []
        #expect(broken.active == SectionModel())
        broken.active = kept
        #expect(broken.activeProfileName == "Default")
        #expect(broken.profiles == [Profile(name: "Default", sections: kept)])

        // A profile that is there and named is the active one; keys this version doesn't know are ignored.
        let named = try decode(#"{"profiles":[{"name":"Work","sections":{"newItems":"hidden"},"extra":true}],"activeProfileName":"Work","more":1}"#)
        #expect(named.activeProfileName == "Work")
        #expect(named.active.newItems == .hidden)
        #expect(named.profiles.count == 1)
    }
}
