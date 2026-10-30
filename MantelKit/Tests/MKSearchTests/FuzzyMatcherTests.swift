import Testing

@testable import MKSearch

@Suite("Fuzzy matcher", .timeLimit(.minutes(1)))
struct FuzzyMatcherTests {
    /// One kind of match against "Green Compass", what it scores, and a query for the next kind down.
    struct Kind: Sendable, CustomTestStringConvertible {
        let name: String
        let query: String
        let score: Int
        let nextDown: String?

        var testDescription: String { name }
    }

    static let compass = "Green Compass"

    static let kinds: [Kind] = [
        Kind(name: "exact", query: "green compass", score: 1000, nextDown: "green"),
        // 900, less the 8 characters the candidate has over the query.
        Kind(name: "prefix", query: "green", score: 892, nextDown: "gc"),
        Kind(name: "initials", query: "gc", score: 700, nextDown: "compass"),
        Kind(name: "word start", query: "compass", score: 650, nextDown: "gcmp"),
        // g starts a word (15); c starts a word (15) after 5 skipped (-10); m after 1 skipped (-2); p follows it directly (10).
        Kind(name: "subsequence", query: "gcmp", score: 328, nextDown: nil),
    ]

    @Test(arguments: kinds)
    func exactBeatsPrefixBeatsInitialsBeatsWordStartBeatsSubsequence(kind: Kind) throws {
        let match = try #require(FuzzyMatcher.match(kind.query, in: Self.compass))
        #expect(match.score == kind.score)
        if let nextDown = kind.nextDown {
            let lower = try #require(FuzzyMatcher.match(nextDown, in: Self.compass))
            #expect(match.score > lower.score, "\(kind.query) outranks \(nextDown)")
        }
    }

    @Test func prefixNeverScoresBelowEightHundred() throws {
        // A long candidate, a short query: 900 less the 146 characters over would be 754.
        let long = "Sync " + String(repeating: "x", count: 145)
        #expect(try #require(FuzzyMatcher.match("sync", in: long)).score == 800)
        let near = "Syncs"
        #expect(try #require(FuzzyMatcher.match("sync", in: near)).score == 899)
    }

    @Test func subsequenceNeverOutranksAWordStart() throws {
        // A long query that is in the middle of a long word: ten for each character after the first would pass 650.
        let word = String(repeating: "abcdefghij", count: 6)
        let query = String(word.dropFirst(3).prefix(50))
        let match = try #require(FuzzyMatcher.match(query, in: word))
        #expect(match.score == 649)
    }

    @Test func diacriticsFolded() throws {
        #expect(FuzzyMatcher.normalized("Café") == "cafe")
        #expect(FuzzyMatcher.normalized("Crème Brûlée") == "creme brulee")
        #expect(FuzzyMatcher.normalized("  Wi   Fi\t Settings \n") == "wi fi settings")
        #expect(FuzzyMatcher.normalized("") == "")

        // Both sides are folded, so either may have the accents.
        #expect(try #require(FuzzyMatcher.match("cafe", in: "Café")).score == 1000)
        #expect(try #require(FuzzyMatcher.match("Café", in: "cafe")).score == 1000)
        #expect(try #require(FuzzyMatcher.match("CAFÉ", in: "Le café")).score == 650)
        // The same letter, written as a letter and a combining accent.
        #expect(try #require(FuzzyMatcher.match("cafe", in: "Cafe\u{301}")).score == 1000)
    }

    @Test func queryWithSpaceReachesInitialsOfCandidateWithNone() throws {
        // The space the query has is no character of these candidates, but `w f` is still the initials of their words.
        let hyphen = try #require(FuzzyMatcher.match("w f", in: "Web-Foo"))
        #expect(hyphen.score == 700)
        #expect(hyphen.matchedOffsets == [0, 4])
        #expect(try #require(FuzzyMatcher.match("w f", in: "Web-Foo Bar")).score == 700)
        // A candidate whose words aren't parted is one word: not its initials, but the query without its space is still in it.
        #expect(try #require(FuzzyMatcher.match("g c", in: "GreenCompass")).score < 650)
        // Not initials: `f` doesn't start a word in `Wxf`, but `wf` is in it, in order.
        #expect(FuzzyMatcher.match("w f", in: "Wxf") != nil)
        #expect(FuzzyMatcher.match("w f", in: "Fxw") == nil, "the query without its space isn't in it either")
    }

    @Test func wordsTypedApartFindACandidateThatWritesThemAsOne() throws {
        #expect(FuzzyMatcher.match("wi fi", in: "Wi-Fi") != nil)
        #expect(FuzzyMatcher.match("web f", in: "Web-Foo") != nil, "found by `web`, and by `web f` too")
        #expect(FuzzyMatcher.match("wi fi", in: "Bluetooth") == nil)
    }

    @Test func noMatchIsNil() {
        #expect(FuzzyMatcher.match("xyz", in: Self.compass) == nil)
        // Every character is there, but not in this order.
        #expect(FuzzyMatcher.match("ecg", in: Self.compass) == nil)
        // A query longer than the candidate can't be in it.
        #expect(FuzzyMatcher.match("green compass plus", in: Self.compass) == nil)
        // Nothing typed, and nothing to match.
        #expect(FuzzyMatcher.match("", in: Self.compass) == nil)
        #expect(FuzzyMatcher.match("   ", in: Self.compass) == nil)
        #expect(FuzzyMatcher.match("a", in: "") == nil)
    }

    @Test func offsetsMapToOriginal() throws {
        // Initials: the first letter of each word.
        #expect(try #require(FuzzyMatcher.match("gc", in: Self.compass)).matchedOffsets == [0, 6])
        // A prefix and a word's start.
        #expect(try #require(FuzzyMatcher.match("gre", in: Self.compass)).matchedOffsets == [0, 1, 2])
        #expect(try #require(FuzzyMatcher.match("comp", in: Self.compass)).matchedOffsets == [6, 7, 8, 9])
        // A subsequence.
        #expect(try #require(FuzzyMatcher.match("gcmp", in: Self.compass)).matchedOffsets == [0, 6, 8, 9])

        // Offsets count the text as it was written: a run of spaces is several characters there, and one when matched.
        #expect(try #require(FuzzyMatcher.match("wf", in: "Wi   Fi")).matchedOffsets == [0, 5])
        #expect(try #require(FuzzyMatcher.match("wi f", in: "Wi   Fi")).matchedOffsets == [0, 1, 2, 5])
        // A leading space isn't a character that is matched, but it is one that is counted.
        #expect(try #require(FuzzyMatcher.match("mail", in: "  Mail")).matchedOffsets == [2, 3, 4, 5])
        // A letter with an accent is one character, folded or not.
        #expect(try #require(FuzzyMatcher.match("cc", in: "Café Crème")).matchedOffsets == [0, 5])
        #expect(try #require(FuzzyMatcher.match("fecr", in: "Café Crème")).matchedOffsets == [2, 3, 5, 6])
        // One character that folds to two is one offset.
        #expect(try #require(FuzzyMatcher.match("strasse", in: "Straße")).matchedOffsets == [0, 1, 2, 3, 4, 5])
    }

    @Test func consecutiveRunsScoreHigher() throws {
        let together = try #require(FuzzyMatcher.match("abc", in: "xabcx"))
        let apart = try #require(FuzzyMatcher.match("abc", in: "xaxbxcx"))
        // Two characters directly after the one before: 300 + 10 + 10. Two skipped characters: 300 - 2 - 2.
        #expect(together.score == 320)
        #expect(apart.score == 296)
        #expect(together.score > apart.score)

        // The same letters in a longer gap score less than in a shorter one.
        let near = try #require(FuzzyMatcher.match("ac", in: "xaxcx"))
        let far = try #require(FuzzyMatcher.match("ac", in: "xaxxxcx"))
        #expect(near.score > far.score)
    }

    @Test func wordsStartAfterAnythingThatIsNotALetterOrDigit() throws {
        #expect(try #require(FuzzyMatcher.match("wf", in: "Wi-Fi")).score == 700)
        // An apostrophe doesn't end a word, and doesn't start one: the s in "Mantel's" isn't an initial.
        #expect(try #require(FuzzyMatcher.match("mm", in: "Mantel's Menu")).score == 700)
        #expect(try #require(FuzzyMatcher.match("ms", in: "Mantel's Menu")).score < 650)
        #expect(try #require(FuzzyMatcher.match("fi", in: "Wi-Fi")).score == 650)
        #expect(try #require(FuzzyMatcher.match("mail", in: "(Mail)")).score == 650)
    }

    @Test func caseDoesntMatter() throws {
        #expect(try #require(FuzzyMatcher.match("GREEN", in: "green")).score == 1000)
        #expect(try #require(FuzzyMatcher.match("gc", in: "GREEN COMPASS")).score == 700)
    }

    // MARK: The best placement

    /// A small, repeatable source of numbers (SplitMix64), so that the same texts are tried on every run.
    private struct Repeatable: RandomNumberGenerator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var mixed = state
            mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
            mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
            return mixed ^ (mixed >> 31)
        }
    }

    /// What laying `query` at `places` in `text` scores as a subsequence, before the base: 15 for each that starts a word, 10 for each that
    /// follows the one before it directly, and less 2 for each character between the first and the last that isn't one of them.
    private func gain(_ places: [Int], in text: [Character]) -> Int {
        var total = 0
        for (index, place) in places.enumerated() {
            let startsWord = (text[place].isLetter || text[place].isNumber) && (place == 0 || !(text[place - 1].isLetter || text[place - 1].isNumber))
            if startsWord { total += 15 }
            if index > 0 {
                total += places[index - 1] == place - 1 ? 10 : -2 * (place - places[index - 1] - 1)
            }
        }
        return total
    }

    /// The best `gain` of any way to lay `query` over `text`, in order, by trying all of them; nil when there is none.
    private func bestGain(of query: [Character], in text: [Character]) -> Int? {
        func best(from row: Int, after previous: Int, placed: [Int]) -> Int? {
            guard row < query.count else { return gain(placed, in: text) }
            var found: Int?
            for column in (previous + 1)..<max(text.count, previous + 1) where text[column] == query[row] {
                if let candidate = best(from: row + 1, after: column, placed: placed + [column]) {
                    found = max(found ?? candidate, candidate)
                }
            }
            return found
        }
        return best(from: 0, after: -1, placed: [])
    }

    @Test func subsequenceScoreIsTheBestPlacement() throws {
        var random = Repeatable(state: 7)
        let alphabet = Array("aabbc -d")
        var tried = 0
        for _ in 0..<3000 {
            let text = FuzzyMatcher.normalized(String((0..<Int.random(in: 6...14, using: &random)).map { _ in alphabet.randomElement(using: &random)! }))
            let query = FuzzyMatcher.normalized(String((0..<Int.random(in: 2...5, using: &random)).map { _ in alphabet.randomElement(using: &random)! }))
            let characters = Array(text)
            // A query with a space that can't be laid over the text as it is, is laid without its spaces (words typed apart that the text
            // writes as one): that is the query the match is of.
            let joined = query.replacingOccurrences(of: " ", with: "")
            let laid = bestGain(of: Array(query), in: characters) == nil && query.contains(" ") ? joined : query
            guard let match = FuzzyMatcher.match(query, in: text) else {
                // Nothing laid over the text, in order, is what no match means.
                #expect(laid.isEmpty || bestGain(of: Array(laid), in: characters) == nil, "\(query) in \(text)")
                continue
            }
            // A subsequence scores below every other kind of match.
            guard match.score < 650 else { continue }
            tried += 1
            let expected = try #require(bestGain(of: Array(laid), in: characters), "\(query) in \(text)")
            #expect(match.score == min(max(300 + expected, 1), 649), "\(query) in \(text)")

            // The offsets are a way to lay it, and one that scores what is said.
            #expect(match.matchedOffsets.map { characters[$0] } == Array(laid), "\(query) in \(text)")
            #expect(match.matchedOffsets == match.matchedOffsets.sorted())
            #expect(300 + gain(match.matchedOffsets, in: characters) == match.score || match.score == 649 || match.score == 1, "\(query) in \(text)")
        }
        #expect(tried > 100, "enough of the texts were subsequences to mean something")
    }
}
