import Foundation

/// The words that tell a person which icons their words matched.
public extension IconQueryError {
    /// What `mantel icon` answers for `query`. When the error is the ambiguous one, a title that two or more of the matches share (two icons
    /// of one app) is said once, with how many icons carry it, so the list names each title once and says what to choose between.
    func answer(for query: String) -> String {
        guard case .ambiguous(let titles) = self else { return message(for: query) }
        var counts: [String: Int] = [:]
        var order: [String] = []
        for title in titles {
            if counts[title] == nil { order.append(title) }
            counts[title, default: 0] += 1
        }
        let listed = order.map { title in counts[title] == 1 ? title : "\(title) (\(counts[title] ?? 0) icons)" }
        return IconQueryError.ambiguous(listed).message(for: query)
    }
}
