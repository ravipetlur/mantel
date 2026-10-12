import Foundation
import Testing

@testable import MKCore

@Suite("Reveal choices", .timeLimit(.minutes(1)))
struct RevealChoicesTests {
    @Test func theHoverDelaysAreTheFiveSettingsOffers() {
        #expect(RevealChoices.hoverDelays.map(\.title) == ["0.1 s", "0.2 s", "0.3 s", "0.5 s", "0.8 s"])
        #expect(RevealChoices.hoverDelays.map(\.value) == RevealSettings.hoverDelayChoices)
    }

    @Test func theRehideDelaysAreTheSixSettingsOffers() {
        #expect(RevealChoices.rehideDelays.map(\.title) == ["5 seconds", "10 seconds", "15 seconds", "30 seconds", "1 minute", "Never"])
        #expect(RevealChoices.rehideDelays.map(\.value)
            == [.seconds(5), .seconds(10), .seconds(15), .seconds(30), .seconds(60), .never])
    }

    @Test func theDefaultsAreAmongTheChoices() {
        let defaults = RevealSettings()
        #expect(RevealChoices.hoverDelays.contains { $0.value == defaults.hoverDelayMilliseconds })
        #expect(RevealChoices.rehideDelays.contains { $0.value == defaults.rehide })
    }

    @Test func everyValueASettingsFileCanHoldIsAmongTheChoices() throws {
        // A file's number is read as the nearest choice, so what the pickers show always has a row.
        for milliseconds in [0, 50, 149, 151, 400, 650, 5000, -3] {
            let settings = try JSONDecoder().decode(RevealSettings.self, from: Data(#"{"hoverDelayMilliseconds": \#(milliseconds)}"#.utf8))
            #expect(RevealChoices.hoverDelays.contains { $0.value == settings.hoverDelayMilliseconds })
        }
        for seconds in [0, 1, 7, 12, 22, 45, 61, 600] {
            let settings = try JSONDecoder().decode(RevealSettings.self, from: Data(#"{"rehide": \#(seconds)}"#.utf8))
            #expect(RevealChoices.rehideDelays.contains { $0.value == settings.rehide })
        }
    }

    @Test func titlesOutsideTheChoicesStillRead() {
        #expect(RevealChoices.hoverDelayTitle(milliseconds: 1000) == "1.0 s")
        #expect(RevealChoices.hoverDelayTitle(milliseconds: 1500) == "1.5 s")
        #expect(RevealChoices.hoverDelayTitle(milliseconds: 250) == "250 ms")
        #expect(RevealChoices.hoverDelayTitle(milliseconds: 0) == "0 ms")
        #expect(RevealChoices.rehideTitle(.seconds(120)) == "2 minutes")
        #expect(RevealChoices.rehideTitle(.seconds(90)) == "90 seconds")
        #expect(RevealChoices.rehideTitle(.seconds(1)) == "1 second")
    }
}
