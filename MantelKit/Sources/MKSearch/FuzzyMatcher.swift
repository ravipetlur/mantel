import Foundation

/// How well a query matches a text, and which characters of the text it matched.
public struct FuzzyMatch: Sendable, Equatable {
    /// Higher is better. See `FuzzyMatcher.match` for what each kind of match scores.
    public let score: Int
    /// The offsets, in characters, of the matched characters in the text as it was given (not as it was normalized), in order.
    public let matchedOffsets: [Int]

    public init(score: Int, matchedOffsets: [Int]) {
        self.score = score
        self.matchedOffsets = matchedOffsets
    }
}

/// Matching what the person typed against the names of icons and actions.
public enum FuzzyMatcher {
    /// The text as it is compared: lowercased, accents and other diacritics folded (`Café` is `cafe`), runs of whitespace one space, and
    /// none at either end.
    public static func normalized(_ text: String) -> String {
        PreparedText(text).string
    }

    /// How well `query` matches `candidate`, or nil when it doesn't. Both are normalized first, so case, accents and spacing don't matter.
    ///
    /// | The query | Score |
    /// |---|---|
    /// | is the candidate | 1000 |
    /// | starts the candidate | 900 less the characters the candidate has over the query, and at least 800 |
    /// | is the initials of the candidate's words, in order (`gc` for `Green Compass`) | 700 |
    /// | starts one of the candidate's words (`com` for `Green Compass`) | 650 |
    /// | has all its characters in the candidate, in order | 300, and 15 for each that starts a word, and 10 for each that follows the one before it directly, and less 2 for each character of the candidate between the first and the last that isn't matched; at least 1 |
    ///
    /// A match of the last kind never scores more than 649, so it never outranks a word's start. An empty query matches nothing.
    public static func match(_ query: String, in candidate: String) -> FuzzyMatch? {
        match(PreparedText(query), in: PreparedText(candidate))
    }

    // MARK: Scoring

    static let exactScore = 1000
    static let prefixScore = 900
    static let prefixFloor = 800
    static let initialsScore = 700
    static let wordStartScore = 650
    static let subsequenceBase = 300
    static let subsequenceCeiling = wordStartScore - 1
    private static let wordStartBonus = 15
    private static let adjacentBonus = 10
    private static let skipPenalty = 2

    /// The match of a query against a candidate that are both prepared already (see `PreparedText`).
    static func match(_ query: PreparedText, in candidate: PreparedText) -> FuzzyMatch? {
        let q = query.codes
        let c = candidate.codes
        // Most candidates are out at the first two checks: every character the query has is among the candidate's, and then in order.
        guard !q.isEmpty else { return nil }
        guard q.count <= c.count, query.characterSet & ~candidate.characterSet == 0, isSubsequence(q, of: c) else {
            // A space the query has is no character of a candidate that has none there (`w f` for `Web-Foo`), but its initials can still be it,
            // or the words typed apart can be ones the candidate writes as one (`wi fi` for `Wi-Fi`, `web f` for `Web-Foo`): the query again
            // without its spaces.
            guard q.contains(PreparedText.space) else { return nil }
            if let positions = initials(of: query, in: candidate) { return result(initialsScore, positions: positions, in: candidate) }
            let joined = q.filter { $0 != PreparedText.space }
            guard !joined.isEmpty else { return nil }
            return match(PreparedText(String(String.UnicodeScalarView(joined.compactMap(Unicode.Scalar.init)))), in: candidate)
        }

        if q == c {
            return result(exactScore, positions: Array(0..<q.count), in: candidate)
        }
        if c.starts(with: q) {
            return result(max(prefixFloor, prefixScore - (c.count - q.count)), positions: Array(0..<q.count), in: candidate)
        }
        if let positions = initials(of: query, in: candidate) {
            return result(initialsScore, positions: positions, in: candidate)
        }
        if let start = wordStart(of: q, in: candidate) {
            return result(wordStartScore, positions: Array(start..<(start + q.count)), in: candidate)
        }
        let (score, positions) = bestSubsequence(of: q, in: candidate)
        return result(min(max(subsequenceBase + score, 1), subsequenceCeiling), positions: positions, in: candidate)
    }

    private static func result(_ score: Int, positions: [Int], in candidate: PreparedText) -> FuzzyMatch {
        var offsets: [Int] = []
        offsets.reserveCapacity(positions.count)
        for position in positions {
            let offset = candidate.origins[position]
            // A character that was folded into several (`ß` into `ss`) is one in the text the person sees.
            if offsets.last != offset { offsets.append(offset) }
        }
        return FuzzyMatch(score: score, matchedOffsets: offsets)
    }

    private static func isSubsequence(_ query: [UInt32], of candidate: [UInt32]) -> Bool {
        var next = 0
        for code in candidate where code == query[next] {
            next += 1
            if next == query.count { return true }
        }
        return false
    }

    /// The positions of the candidate's word starts that the query's characters (leaving out its spaces) are, in order; nil when they
    /// aren't all there.
    private static func initials(of query: PreparedText, in candidate: PreparedText) -> [Int]? {
        let c = candidate.codes
        var positions: [Int] = []
        var from = 0
        for code in query.codes where code != PreparedText.space {
            while from < c.count, !(candidate.wordStarts[from] && c[from] == code) { from += 1 }
            guard from < c.count else { return nil }
            positions.append(from)
            from += 1
        }
        return positions.isEmpty ? nil : positions
    }

    /// Where the first word that starts with the query starts, or nil.
    private static func wordStart(of query: [UInt32], in candidate: PreparedText) -> Int? {
        let c = candidate.codes
        guard c.count >= query.count else { return nil }
        for start in 0...(c.count - query.count) where candidate.wordStarts[start] && c[start] == query[0] {
            var offset = 1
            while offset < query.count, c[start + offset] == query[offset] { offset += 1 }
            if offset == query.count { return start }
        }
        return nil
    }

    /// The best way to lay the query's characters over the candidate's, in order, by what a subsequence scores (without the base), and the
    /// positions it uses. The query is known to be a subsequence of the candidate.
    ///
    /// Only the places where a character of the query is in the candidate are worked out: for each, the best score of laying the query up
    /// to it, and which place of the character before it that was from. A character can only be where the leftmost match of those before
    /// it and the rightmost match of those after it leave room for.
    private static func bestSubsequence(of query: [UInt32], in candidate: PreparedText) -> (score: Int, positions: [Int]) {
        let c = candidate.codes
        let rows = query.count
        let impossible = Int.min / 2

        var left = [Int](repeating: 0, count: rows)
        var matched = 0
        for column in 0..<c.count where matched < rows && c[column] == query[matched] {
            left[matched] = column
            matched += 1
        }
        var right = [Int](repeating: 0, count: rows)
        matched = rows - 1
        for column in stride(from: c.count - 1, through: 0, by: -1) where matched >= 0 && c[column] == query[matched] {
            right[matched] = column
            matched -= 1
        }

        // Flat lists of every place a query character is at (`columns`), its best score, and the index in these lists of the place of
        // the character before it that gave that score. `rowStart[row]` is where the places of the row's character begin.
        var columns: [Int] = []
        var scores: [Int] = []
        var parents: [Int] = []
        var rowStart = [Int](repeating: 0, count: rows + 1)
        for row in 0..<rows {
            rowStart[row] = columns.count
            // The places of the character before this one that are two or more columns back are kept as the best of their score plus twice
            // their column, so that a gap's cost is taken off when one is used: `score - 2 * (column - earlier - 1)`.
            let previousEnd = rowStart[row]
            var next = row == 0 ? previousEnd : rowStart[row - 1]
            var far = impossible
            var farIndex = -1
            for column in left[row]...right[row] where c[column] == query[row] {
                var best = impossible
                var parent = -1
                if row == 0 {
                    best = 0
                } else {
                    while next < previousEnd, columns[next] <= column - 2 {
                        if scores[next] > impossible, scores[next] + skipPenalty * columns[next] > far {
                            far = scores[next] + skipPenalty * columns[next]
                            farIndex = next
                        }
                        next += 1
                    }
                    if next < previousEnd, columns[next] == column - 1, scores[next] > impossible {
                        best = scores[next] + adjacentBonus
                        parent = next
                    }
                    if farIndex >= 0, far - skipPenalty * (column - 1) > best {
                        best = far - skipPenalty * (column - 1)
                        parent = farIndex
                    }
                }
                columns.append(column)
                scores.append(best > impossible ? best + (candidate.wordStarts[column] ? wordStartBonus : 0) : impossible)
                parents.append(parent)
            }
        }
        rowStart[rows] = columns.count

        var last = -1
        var lastScore = impossible
        for place in rowStart[rows - 1]..<columns.count where scores[place] > lastScore {
            lastScore = scores[place]
            last = place
        }
        var positions = [Int](repeating: 0, count: rows)
        var place = last
        for row in stride(from: rows - 1, through: 0, by: -1) {
            positions[row] = columns[place]
            place = parents[place]
        }
        return (lastScore, positions)
    }
}

/// A text made ready to be matched: normalized, with each character's place in the text it came from, and which characters start a word.
/// Matching many candidates against one query prepares each text once.
struct PreparedText: Sendable, Equatable {
    static let space: UInt32 = 0x20

    /// The normalized text, as Unicode scalar values.
    let codes: [UInt32]
    /// For each of `codes`, the offset of the character it came from in the original text.
    let origins: [Int]
    /// For each of `codes`, whether it starts a word: a letter or a digit after anything that isn't one (or at the start).
    let wordStarts: [Bool]
    /// Which characters the text has, as bits (a character is the bit of its value modulo 64, so several share one). A query can only be in
    /// a text that has every bit of its own.
    let characterSet: UInt64

    var isEmpty: Bool { codes.isEmpty }

    var string: String {
        var scalars = String.UnicodeScalarView()
        for code in codes {
            if let scalar = Unicode.Scalar(code) { scalars.append(scalar) }
        }
        return String(scalars)
    }

    init(_ text: String) {
        var codes: [UInt32] = []
        var origins: [Int] = []
        codes.reserveCapacity(text.utf8.count)
        origins.reserveCapacity(text.utf8.count)
        // A run of whitespace waits here, as the offset of its first character, until a character that isn't whitespace follows it, so
        // that whitespace at the end is dropped and a run in the middle is one space.
        var pendingSpace: Int?
        for (offset, character) in text.enumerated() {
            if character.isWhitespace {
                if !codes.isEmpty, pendingSpace == nil { pendingSpace = offset }
                continue
            }
            if let space = pendingSpace {
                codes.append(Self.space)
                origins.append(space)
                pendingSpace = nil
            }
            if let ascii = character.asciiValue {
                codes.append(ascii >= 65 && ascii <= 90 ? UInt32(ascii) + 32 : UInt32(ascii))
                origins.append(offset)
            } else {
                for scalar in String(character).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).unicodeScalars {
                    codes.append(scalar.value)
                    origins.append(offset)
                }
            }
        }
        self.codes = codes
        self.origins = origins
        var characterSet: UInt64 = 0
        for code in codes { characterSet |= 1 << UInt64(code % 64) }
        self.characterSet = characterSet

        var starts = [Bool](repeating: false, count: codes.count)
        var previousInWord = false
        for (index, code) in codes.enumerated() {
            let inWord = Self.isWordCharacter(code)
            starts[index] = inWord && !previousInWord
            // An apostrophe doesn't end a word (`Mantel's`), but doesn't start one either.
            previousInWord = inWord || code == 0x27 || code == 0x2019
        }
        wordStarts = starts
    }

    private static func isWordCharacter(_ code: UInt32) -> Bool {
        if code < 128 {
            return (code >= 97 && code <= 122) || (code >= 48 && code <= 57) || (code >= 65 && code <= 90)
        }
        guard let scalar = Unicode.Scalar(code) else { return false }
        return scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }
}
