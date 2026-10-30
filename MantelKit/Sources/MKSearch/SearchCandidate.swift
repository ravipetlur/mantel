import MKCore

/// What a search result is, and so what choosing it does.
public enum SearchResultKind: Sendable, Equatable {
    case icon(ItemID)
    case action(CommandBarActionID)

    /// The stable ID of a candidate of this kind: `icon:<ItemID text>` or `action:<raw value>`.
    public var candidateID: String {
        switch self {
        case .icon(let item): "icon:" + item.string
        case .action(let action): "action:" + action.rawValue
        }
    }
}

/// One thing the command bar can find: what it is called, and what else it is found by.
public struct SearchCandidate: Sendable, Equatable {
    /// Stable between searches and launches: `icon:<ItemID>` or `action:<raw>`. The command bar remembers recent picks by it.
    public let id: String
    public let kind: SearchResultKind
    public let title: String
    public let subtitle: String?
    /// Other names it is found by, which score as the title does.
    public let terms: [String]
    /// Names it is found by that count for less than the title's: a match scores four fifths of what it would as a term. An icon's label
    /// is one.
    public let weakTerms: [String]
    /// Added to the score of every match. Negative to put the candidate below others that match as well.
    public let boost: Int
    /// Listed when nothing has been typed, after the recent picks.
    public let suggested: Bool

    public init(id: String, kind: SearchResultKind, title: String, subtitle: String? = nil, terms: [String] = [], weakTerms: [String] = [],
                boost: Int = 0, suggested: Bool = false) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.terms = terms
        self.weakTerms = weakTerms
        self.boost = boost
        self.suggested = suggested
    }
}

/// A candidate that matched, and how well.
public struct SearchResult: Sendable, Equatable, Identifiable {
    public let candidate: SearchCandidate
    public let score: Int
    /// The offsets, in characters, of the title's characters that the query matched, for drawing them in bold. Empty when the title isn't
    /// what matched best.
    public let titleOffsets: [Int]

    public var id: String { candidate.id }

    public init(candidate: SearchCandidate, score: Int, titleOffsets: [Int]) {
        self.candidate = candidate
        self.score = score
        self.titleOffsets = titleOffsets
    }
}
