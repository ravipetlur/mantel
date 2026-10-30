import Testing

@testable import MKMenuBar

@Suite("Engine notes", .timeLimit(.minutes(2)))
struct EngineNotesTests {
    @Test func sideEffectsNameAirDrop() {
        #expect(EngineNotes.sideEffects.contains("AirDrop"))
        // Everything the allowlist takes along, in the words Diagnostics shows.
        #expect(EngineNotes.sideEffects == "While icons are hidden with the allowlist, macOS also hides Now Playing, Focus, Live Activities, AirDrop and the microphone and camera indicator.")
        for item in ["Now Playing", "Focus", "Live Activities", "AirDrop", "microphone and camera indicator"] {
            #expect(EngineNotes.sideEffects.contains(item), "\(item)")
        }
    }

    @Test func crashNoteSaysFiveSeconds() {
        #expect(EngineNotes.crashNote == "After a crash, hidden icons take about 5 seconds to come back.")
        #expect(EngineNotes.crashNote.contains("5 seconds"))
    }

    @Test func clockNoteSaysWhenEveryIconShows() {
        #expect(EngineNotes.clockNote == "Clicking the clock or Control Center shows every icon until what it opens closes.")
    }
}
