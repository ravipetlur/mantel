import MKUpdate
import Testing

@Suite("Version numbers", .timeLimit(.minutes(2)))
struct VersionNumberTests {
    func version(_ text: String) throws -> VersionNumber {
        try #require(VersionNumber(text))
    }

    @Test(arguments: [("1.2.3", "1.2.3"), ("v1.2.3", "1.2.3"), ("0.0.0", "0.0.0"), ("10.20.30", "10.20.30"), ("v1.10.0", "1.10.0")])
    func readsThreeNumbersWithAnOptionalLeadingV(text: String, printed: String) throws {
        #expect(try version(text).description == printed)
    }

    /// Exactly three plain numbers: no suffix, no leading zero, no sign, no space, no other digits, nothing too big.
    @Test(arguments: [
        "", "v", "1", "1.2", "1.2.3.4", "1.2.3-beta", "1.2.3+build5", "1.2.3rc1", "1.2.x", "01.2.3", "1.02.3", "1.2.03",
        "1..3", "1.2.", ".1.2", "-1.2.3", "+1.2.3", " 1.2.3", "1.2.3 ", "1.2.3\n", "V1.2.3", "vv1.2.3", "1,2,3",
        "\u{661}.\u{662}.\u{663}", "99999999999999999999.0.0",
    ])
    func rejectsAnythingElse(text: String) {
        #expect(VersionNumber(text) == nil)
    }

    /// Numbers, not text: 1.10.0 is newer than 1.9.9.
    @Test func comparesNumericallyAndAVDoesNotChangeTheValue() throws {
        #expect(try version("1.10.0") > version("1.9.9"))
        #expect(try version("1.0.10") > version("1.0.9"))
        #expect(try version("2.0.0") > version("1.99.99"))
        #expect(try version("1.2.3") < version("1.3.0"))
        #expect(try version("v1.2.3") == version("1.2.3"))
        let shuffled = try ["1.10.0", "1.2.0", "v1.9.9", "0.9.0", "1.2.10", "1.2.9"].map(version)
        #expect(shuffled.sorted().map(\.description) == ["0.9.0", "1.2.0", "1.2.9", "1.2.10", "1.9.9", "1.10.0"])
    }
}
