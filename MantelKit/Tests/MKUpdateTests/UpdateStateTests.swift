import Foundation
import MKCore
import MKTestSupport
import MKUpdate
import Testing

/// What the updater remembers, in a file of its own under Mantel's folder, read leniently and written the way the other files are.
@Suite("The updater's state file", .timeLimit(.minutes(2)))
struct UpdateStateTests {
    let folder = TemporaryFolder(prefix: "mantel-update-state")

    private var paths: MantelPaths {
        MantelPaths(root: folder.url.appending(path: "Support", directoryHint: .isDirectory),
                    logs: folder.url.appending(path: "Logs", directoryHint: .isDirectory))
    }

    @Test func theLastCheckAndTheSkippedVersionSurviveARestart() async throws {
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        let store = SettingsStore(paths: paths)
        var state = await store.load(UpdateState.self)
        #expect(state == UpdateState())
        state.lastCheck = when
        state.skippedVersion = "1.3.0"
        await store.save(state)
        await store.flush()

        let later = SettingsStore(paths: paths)
        let loaded = await later.load(UpdateState.self)
        #expect(loaded.lastCheck == when)
        #expect(loaded.skippedVersion == "1.3.0")
        #expect(UpdateState.fileName == "update-state.json")
    }

    /// A value that can't be read is read as missing, so a file written by another version still opens and a check is made.
    @Test(arguments: [
        #"{}"#, #"{"lastCheck":"yesterday","skippedVersion":7}"#, #"{"lastCheck":12,"skippedVersion":null}"#,
    ])
    func aValueThatCantBeReadIsReadAsMissing(json: String) throws {
        let state = try JSONCoding.decoder().decode(UpdateState.self, from: Data(json.utf8))
        #expect(state == UpdateState())
    }
}
