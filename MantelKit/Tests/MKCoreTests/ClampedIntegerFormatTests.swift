import Foundation
import Testing

@testable import MKCore

@Suite("Clamped integer format", .timeLimit(.minutes(1)))
struct ClampedIntegerFormatTests {
    private let format = ClampedIntegerFormat(range: 1000...10000, step: 100)

    private func parse(_ text: String) throws -> Int {
        try format.parseStrategy.parse(text)
    }

    @Test func aNumberIsWrittenAsPlainDigits() {
        #expect(format.format(3000) == "3000")
        #expect(format.format(10000) == "10000")
    }

    @Test func aNumberInRangeIsReadAsItIs() throws {
        #expect(try parse("3000") == 3000)
        #expect(try parse(" 4500 ") == 4500)
        #expect(try parse("+1200") == 1200)
    }

    @Test func aNumberOutsideTheRangeIsBroughtInsideWhenItIsRead() throws {
        #expect(try parse("50") == 1000)
        #expect(try parse("0") == 1000)
        #expect(try parse("-30") == 1000)
        #expect(try parse("99999") == 10000)
        #expect(try parse("99999999999999999999999") == 10000)
        #expect(try parse("-99999999999999999999999") == 1000)
    }

    @Test func aNumberBetweenStepsIsReadAsTheNearestStep() throws {
        #expect(try parse("1234") == 1200)
        #expect(try parse("1250") == 1300)
        #expect(try parse("1249") == 1200)
        #expect(try parse("9951") == 10000)
    }

    @Test func groupedDigitsAreRead() throws {
        #expect(try parse("3,000") == 3000)
        #expect(try parse("3 000") == 3000)
        #expect(try parse("3’000") == 3000)
    }

    @Test(arguments: ["", "  ", "abc", "12a", "1.5", "--5", "+", "-", "٣٠٠٠"])
    func textThatIsNotANumberIsRefused(text: String) {
        #expect(throws: ClampedIntegerFormat.Strategy.NotANumber.self) { try parse(text) }
    }

    @Test func aFormatWithoutAStepTakesAnyWholeNumberInRange() throws {
        let plain = ClampedIntegerFormat(range: 5...50)
        #expect(try plain.parseStrategy.parse("17") == 17)
        #expect(try plain.parseStrategy.parse("1") == 5)
        #expect(try plain.parseStrategy.parse("51") == 50)
    }

    @Test func aStepThatDoesNotEndTheRangeNeverReadsPastIt() {
        // Steps of 4 from 0: 0, 4, 8, 10 is the end, not 12.
        #expect(ClampedIntegerFormat.clamped(10, to: 0...10, step: 4) == 10)
        #expect(ClampedIntegerFormat.clamped(11, to: 0...10, step: 4) == 10)
    }

    @Test func theFieldForTheWideScreenThresholdReadsWhatTheSettingsFileDoes() throws {
        let field = HidingSettings.wideScreenThresholdFormat
        for typed in [0, 999, 1234, 3050, 9999, 20000] {
            let fromFile = try JSONDecoder().decode(HidingSettings.self, from: Data(#"{"wideScreenThreshold": \#(typed)}"#.utf8))
            #expect(try field.parseStrategy.parse(String(typed)) == fromFile.wideScreenThreshold)
        }
    }

    @Test func theFormatRoundTripsThroughItsOwnCodable() throws {
        let data = try JSONEncoder().encode(format)
        #expect(try JSONDecoder().decode(ClampedIntegerFormat.self, from: data) == format)
    }
}
