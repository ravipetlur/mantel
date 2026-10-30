import MKCore

/// A candidate with its texts prepared for matching, so that matching it costs nothing but the matching.
struct PreparedCandidate: Sendable {
    /// What a match on a part of the candidate scores, out of ten, against what the same match on its title would.
    private static let subtitleWeight = 6
    private static let weakTermWeight = 8

    let candidate: SearchCandidate
    private let title: PreparedText
    private let subtitle: PreparedText?
    private let terms: [PreparedText]
    private let weakTerms: [PreparedText]
    /// The title as it is sorted by.
    let sortTitle: String

    init(_ candidate: SearchCandidate) {
        self.candidate = candidate
        title = PreparedText(candidate.title)
        subtitle = candidate.subtitle.map(PreparedText.init)
        terms = candidate.terms.map(PreparedText.init)
        weakTerms = candidate.weakTerms.map(PreparedText.init)
        sortTitle = title.string
    }

    /// The best a query scores against the candidate (not counting its boost), or nil when nothing of it matches. The title's matched
    /// offsets come with it when the title is what scored best.
    ///
    /// The score is the best of the title's, the subtitle's at 0.6, each term's, and each weak term's at 0.8. Where two are equally good
    /// the title wins.
    func score(for query: PreparedText) -> (score: Int, titleOffsets: [Int])? {
        var best: (score: Int, titleOffsets: [Int])?
        func consider(_ score: Int, _ offsets: [Int]) {
            if best == nil || score > best!.score { best = (score, offsets) }
        }
        if let match = FuzzyMatcher.match(query, in: title) { consider(match.score, match.matchedOffsets) }
        if let subtitle, let match = FuzzyMatcher.match(query, in: subtitle) { consider(max(1, match.score * Self.subtitleWeight / 10), []) }
        for term in terms {
            if let match = FuzzyMatcher.match(query, in: term) { consider(match.score, []) }
        }
        for term in weakTerms {
            if let match = FuzzyMatcher.match(query, in: term) { consider(max(1, match.score * Self.weakTermWeight / 10), []) }
        }
        return best
    }

    /// Whether this is listed above `other` when their scores are the same: by title, then by ID.
    func sortsBefore(_ other: PreparedCandidate) -> Bool {
        if sortTitle != other.sortTitle { return sortTitle < other.sortTitle }
        if candidate.title != other.candidate.title { return candidate.title < other.candidate.title }
        return candidate.id < other.candidate.id
    }
}

/// The command bar's search: it asks its providers what they offer when the bar opens, and answers each query from that.
///
/// - **A query** is matched against each candidate's title, subtitle and other names (`PreparedCandidate.score`). A candidate's
///   `boost` and a boost for the person's recent picks are added: 60 for the newest, 3 less for each place down.
/// - **The results** are the best `limit`, by score, then title, then ID.
/// - **No query** lists the recent picks that are still on offer, newest first, then the candidates that are `suggested` (the Hidden
///   icons) in the order they were offered, up to `limit`.
public actor CommandBarSearch {
    /// How many results there are at most.
    public static let limit = 12

    private static let newestPickBoost = 60
    private static let pickBoostStep = 3

    private let providers: [any CommandBarProvider]
    private var recents: [String]
    private var recentBoosts: [String: Int] = [:]
    private var snapshot: [PreparedCandidate] = []
    private var snapshotIndex: [String: Int] = [:]
    /// How many times `open()` has been called: only the latest call's answers are kept.
    private var openings = 0

    /// `recents` are the result IDs the person picked before, newest first.
    public init(providers: [any CommandBarProvider], recents: [String]) {
        self.providers = providers
        self.recents = Array(recents.prefix(IconPreferences.maxRecentPicks))
        recentBoosts = Self.boosts(for: self.recents)
    }

    /// Asks every provider what it offers, once, and keeps the answers (prepared for matching) until the next time this is called. A
    /// candidate whose ID an earlier provider's candidate has is left out. When calls overlap, the answers of the one that began last are
    /// kept, whichever finishes first.
    public func open() async {
        openings += 1
        let opening = openings
        let offered = await withTaskGroup(of: (Int, [SearchCandidate]).self) { group in
            for (index, provider) in providers.enumerated() {
                group.addTask { (index, await provider.candidates()) }
            }
            var answers: [Int: [SearchCandidate]] = [:]
            for await (index, candidates) in group { answers[index] = candidates }
            return providers.indices.flatMap { answers[$0] ?? [] }
        }
        guard opening == openings else { return }
        var prepared: [PreparedCandidate] = []
        var index: [String: Int] = [:]
        prepared.reserveCapacity(offered.count)
        for candidate in offered where index[candidate.id] == nil {
            index[candidate.id] = prepared.count
            prepared.append(PreparedCandidate(candidate))
        }
        snapshot = prepared
        snapshotIndex = index
    }

    /// The best results for what was typed, from what the providers offered when the bar opened.
    public func results(for query: String) -> [SearchResult] {
        let prepared = PreparedText(query)
        guard !prepared.isEmpty else { return listedWithoutQuery() }

        var matches: [(candidate: PreparedCandidate, score: Int, offsets: [Int])] = []
        for candidate in snapshot {
            guard let match = candidate.score(for: prepared) else { continue }
            matches.append((candidate, match.score + candidate.candidate.boost + (recentBoosts[candidate.candidate.id] ?? 0), match.titleOffsets))
        }
        matches.sort { left, right in
            left.score != right.score ? left.score > right.score : left.candidate.sortsBefore(right.candidate)
        }
        return matches.prefix(Self.limit).map { SearchResult(candidate: $0.candidate.candidate, score: $0.score, titleOffsets: $0.offsets) }
    }

    /// The person chose a result: it is the newest recent pick now. Returns the recent picks as they are, for saving.
    public func picked(_ id: String) -> [String] {
        var updated = recents
        updated.removeAll { $0 == id }
        updated.insert(id, at: 0)
        recents = Array(updated.prefix(IconPreferences.maxRecentPicks))
        recentBoosts = Self.boosts(for: recents)
        return recents
    }

    private func listedWithoutQuery() -> [SearchResult] {
        var listed: [SearchResult] = []
        var seen: Set<String> = []
        for id in recents {
            guard listed.count < Self.limit, let place = snapshotIndex[id], seen.insert(id).inserted else { continue }
            listed.append(SearchResult(candidate: snapshot[place].candidate, score: recentBoosts[id] ?? 0, titleOffsets: []))
        }
        for candidate in snapshot where candidate.candidate.suggested {
            guard listed.count < Self.limit else { break }
            if seen.insert(candidate.candidate.id).inserted {
                listed.append(SearchResult(candidate: candidate.candidate, score: 0, titleOffsets: []))
            }
        }
        return listed
    }

    /// The boost of each recent pick: the newest's, and a step less for each one after it. (An ID that is there twice has the newer's.)
    private static func boosts(for recents: [String]) -> [String: Int] {
        var boosts: [String: Int] = [:]
        for (place, id) in recents.enumerated() where boosts[id] == nil {
            boosts[id] = newestPickBoost - pickBoostStep * place
        }
        return boosts
    }
}
