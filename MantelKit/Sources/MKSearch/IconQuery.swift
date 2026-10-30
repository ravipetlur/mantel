import Foundation
import MKCore

/// Why words didn't name one icon.
public enum IconQueryError: Error, Equatable, LocalizedError {
    /// Nothing matched. Carries the query.
    case noMatch(String)
    /// Several icons matched about as well. Carries the titles of the best of them.
    case ambiguous([String])

    public var errorDescription: String? {
        switch self {
        case .noMatch(let query):
            message(for: query)
        case .ambiguous(let titles):
            "Several icons match: \(titles.joined(separator: ", ")). Use one of their IDs from “mantel icons”."
        }
    }

    /// What to tell the person who typed `query`.
    public func message(for query: String) -> String {
        switch self {
        case .noMatch:
            "Nothing in the menu bar matches “\(query)”. Run “mantel icons” to see them."
        case .ambiguous(let titles):
            "“\(query)” matches several icons: \(titles.joined(separator: ", ")). Use one of their IDs from “mantel icons”."
        }
    }
}

/// Finds the one icon a person's words name, for the verbs that take an icon as words (`mantel icon show <words>`).
public enum IconQuery {
    /// What a match has to score to count.
    static let minimumScore = 300
    /// The next best match is too close to decide between them when it scores at least this much of the best's, in tenths.
    private static let closeTenths = 9
    private static let mostTitles = 5

    /// The icon `query` names, in `entries`.
    ///
    /// - **An icon's ID** (`IconSearchEntry.item`, in its text form) is that icon, whatever else matches.
    /// - **Otherwise** the words are matched as the command bar matches them, and the best match that scores at least 300 is the icon.
    /// - **A second match within 10 % of the best** is too close to choose between: the error carries the titles of the closest, two to
    ///   five.
    /// - **No match** is an error with the query.
    public static func resolve(_ query: String, in entries: [IconSearchEntry]) -> Result<ItemID, IconQueryError> {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let named = entries.first(where: { $0.item.string == words }) {
            return .success(named.item)
        }
        let prepared = PreparedText(words)
        guard !prepared.isEmpty else { return .failure(.noMatch(words)) }

        var matches: [(entry: IconSearchEntry, candidate: PreparedCandidate, score: Int)] = []
        for entry in entries {
            let candidate = PreparedCandidate(entry.candidate)
            if let match = candidate.score(for: prepared), match.score >= minimumScore {
                matches.append((entry, candidate, match.score))
            }
        }
        matches.sort { left, right in
            left.score != right.score ? left.score > right.score : left.candidate.sortsBefore(right.candidate)
        }
        guard let best = matches.first else { return .failure(.noMatch(words)) }

        let close = matches.prefix { $0.score * 10 >= best.score * closeTenths }
        if close.count > 1 {
            return .failure(.ambiguous(close.prefix(mostTitles).map { $0.entry.title }))
        }
        return .success(best.entry.item)
    }
}
