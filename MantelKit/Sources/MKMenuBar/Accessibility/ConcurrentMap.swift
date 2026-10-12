import Foundation

/// Running work on many things at once, with a limit.
enum ConcurrentMap {
    /// `transform` for each item, at most `limit` at a time, results in the order of the items. The work of the reads this is for
    /// blocks (it is Accessibility calls), so the limit keeps it from taking every thread the system has.
    static func map<Item: Sendable, Result: Sendable>(
        _ items: [Item], limit: Int, _ transform: @escaping @Sendable (Item) async -> Result
    ) async -> [Result] {
        await withTaskGroup(of: (Int, Result).self) { group in
            var results: [Result?] = Array(repeating: nil, count: items.count)
            var next = 0
            func addNext() {
                guard next < items.count else { return }
                let index = next
                let item = items[index]
                next += 1
                group.addTask { (index, await transform(item)) }
            }
            for _ in 0..<min(max(limit, 1), items.count) { addNext() }
            while let (index, result) = await group.next() {
                results[index] = result
                addNext()
            }
            return results.compactMap { $0 }
        }
    }
}
