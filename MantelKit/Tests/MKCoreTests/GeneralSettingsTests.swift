import Foundation
import MKTestSupport
import Synchronization
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

    @Test func newKeysDefaultWhenMissing() throws {
        let settings = GeneralSettings()
        #expect(settings.layout == LayoutSettings())
        #expect(settings.secondBar == SecondBarSettings())
        #expect(settings.dots == DotSettings())
        #expect(settings.layout.dotsPlacement == .betweenSections)
        #expect(!settings.layout.showAllWhileCommandDragging)
        #expect(settings.secondBar.opens == .whenNoRoom)
        #expect(settings.secondBar.position == .underDot)
        #expect(settings.secondBar.style == PanelStyle())
        #expect(settings.dots.style == .dots)

        // A file with none of the three, and one that has them empty, is the defaults.
        #expect(try decode("{}") == settings)
        #expect(try decode(#"{"layout":{},"secondBar":{},"dots":{}}"#) == settings)
        // A key missing inside one of them takes its own default and leaves the rest as the file says.
        let partial = try decode(#"{"layout":{"dotsPlacement":"besideClock"},"secondBar":{"position":"rightAligned","style":{"shadow":false}},"#
            + #""dots":{"style":{"kind":"chevrons"}}}"#)
        #expect(partial.layout == LayoutSettings(dotsPlacement: .besideClock, showAllWhileCommandDragging: false))
        #expect(partial.secondBar == SecondBarSettings(opens: .whenNoRoom, position: .rightAligned,
                                                       style: PanelStyle(background: .matchMenuBar, appearance: .matchMenuBar, border: nil, shadow: false)))
        #expect(partial.dots == DotSettings(style: .chevrons, alwaysDot: .whenNeeded, hideBothDots: false, showsDivider: false))

        // What was written reads back.
        var changed = GeneralSettings(onboardingCompleted: true, settingsPage: "layout")
        changed.layout = LayoutSettings(dotsPlacement: .besideClock, showAllWhileCommandDragging: true)
        changed.secondBar = SecondBarSettings(opens: .always, position: .rightAligned,
                                              style: PanelStyle(background: .material(.thick), appearance: .dark,
                                                                border: PanelBorder(color: RGBAColor(red: 1, green: 1, blue: 1, alpha: 0.5), width: 2), shadow: false))
        changed.dots = DotSettings(style: .symbol(hidden: "circle", always: "circle.fill"), alwaysDot: .always, hideBothDots: true, showsDivider: true)
        #expect(try JSONDecoder().decode(GeneralSettings.self, from: JSONEncoder().encode(changed)) == changed)
    }

    @Test func m2FileStillReads() async throws {
        // The file of a version that had none of the three new keys, as it is on disk: inside the store's envelope.
        let json = """
        {"version":1,"document":{"onboardingCompleted":true,"settingsPage":"layout",
         "reveal":{"hoverReveals":true,"clickReveals":false,"scrollReveals":true,"hoverDelayMilliseconds":500,"rehide":15},
         "hiding":{"method":"automatic","allowHidingClockAndControlCenter":true,"noRoomPolicy":"swap","automaticOverflow":false,
                   "showEverythingOnWideScreens":true,"wideScreenThreshold":4000}}}
        """
        let directory = paths.settings
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: directory.appending(path: GeneralSettings.fileName, directoryHint: .notDirectory))

        let store = SettingsStore(paths: paths)
        let settings = await store.load(GeneralSettings.self)
        #expect(settings.onboardingCompleted)
        #expect(settings.settingsPage == "layout")
        #expect(settings.reveal.hoverReveals)
        #expect(settings.reveal.scrollReveals)
        #expect(settings.reveal.hoverDelayMilliseconds == 500)
        #expect(settings.reveal.rehide == .seconds(15))
        #expect(settings.hiding.noRoomPolicy == .swap)
        #expect(settings.hiding.wideScreenThreshold == 4000)
        // What it never had is the defaults, and the file was read as it is: not set aside, and still saved.
        #expect(settings.layout == LayoutSettings())
        #expect(settings.secondBar == SecondBarSettings())
        #expect(settings.dots == DotSettings())
        #expect(await !store.isReadOnly(GeneralSettings.self))
        let corrupt = (try? FileManager.default.contentsOfDirectory(atPath: paths.backups.path(percentEncoded: false))) ?? []
        #expect(corrupt.isEmpty, "nothing was set aside: \(corrupt)")
    }

    @Test func anUnknownEnumValueDoesNotSetTheFileAside() async throws {
        // A file written by a later version, with a value of an enum this version doesn't have in each of the new settings: it is read
        // as far as this version can, the defaults are used for those values, and the file is not set aside as corrupt.
        let json = """
        {"version":1,"document":{"onboardingCompleted":true,"settingsPage":"layout",
         "layout":{"dotsPlacement":"onTheMoon","showAllWhileCommandDragging":true},
         "secondBar":{"opens":"sometimes","position":"leftAligned","style":{"appearance":"sepia","background":{"kind":"material","thickness":"thickest"},"shadow":false}},
         "dots":{"alwaysDot":"maybe","hideBothDots":true}}}
        """
        let directory = paths.settings
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: GeneralSettings.fileName, directoryHint: .notDirectory)
        try Data(json.utf8).write(to: file)

        let paths = paths
        let result = Mutex<(settings: GeneralSettings, readOnly: Bool)?>(nil)
        let lines = await LogCapture.lines {
            let store = SettingsStore(paths: paths)
            let settings = await store.load(GeneralSettings.self)
            let readOnly = await store.isReadOnly(GeneralSettings.self)
            result.withLock { $0 = (settings, readOnly) }
        }
        let loaded = try #require(result.withLock { $0 })
        let settings = loaded.settings
        #expect(settings.onboardingCompleted)
        #expect(settings.settingsPage == "layout")
        #expect(settings.layout == LayoutSettings(dotsPlacement: .betweenSections, showAllWhileCommandDragging: true))
        #expect(settings.secondBar.opens == .whenNoRoom)
        #expect(settings.secondBar.position == .underDot)
        #expect(settings.secondBar.style == PanelStyle(background: .material(.regular), appearance: .matchMenuBar, border: nil, shadow: false))
        #expect(settings.dots == DotSettings(style: .dots, alwaysDot: .whenNeeded, hideBothDots: true, showsDivider: false))
        #expect(!loaded.readOnly)
        #expect(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)), "the file is where it was")
        let setAside = (try? FileManager.default.contentsOfDirectory(atPath: paths.backups.path(percentEncoded: false))) ?? []
        #expect(setAside.isEmpty, "nothing was set aside: \(setAside)")
        for key in ["dotsPlacement", "opens", "position", "appearance", "thickness", "alwaysDot"] {
            #expect(lines.filter { $0.contains("the value of \(key) isn't one this version knows") }.count == 1, "\(key)")
        }
        #expect(!lines.contains { $0.contains("onTheMoon") || $0.contains("sepia") || $0.contains("thickest") }, "what the file held is not in the log")
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
