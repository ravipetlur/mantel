import Foundation
import MKCore

/// Where the tokens a write places go in macOS's table, by the places the apps that aren't written really have there.
///
/// `LayoutMath` places every token from widths it assumes: right for tokens that are all written together, and meaningless next to an app
/// that isn't written (an app whose items have no key, such as a nameless one the key match can't line up with its entries, stays where
/// macOS has it). A token written from those numbers would land wherever they fall among the unwritten apps' real distances, and any app
/// whose real place is in the way ends up on the wrong side of a dot, or of the divider. So, for every token a write would place
/// (Mantel's own items and resolved apps alike):
///
/// - **Written** is a token with a key and a distance. Every other token (an app's, and any of Mantel's own that is left out) is
///   **unwritten**: it stays where macOS has it, and every token that is written must keep its side of it.
/// - **An app's range** is the smallest and the largest distance of all its keys in the table (`Item-<n>` and named alike), leaving out
///   the keys this write sets. A distance only orders (R30b's branch W-A), so a range is a stretch of the order. An own item's place is
///   the distance of its own key in the table (a range of one point).
/// - **An app with no place in the table is no obstacle.** An app that has no key (one that isn't running has none, or a new one that
///   macOS hasn't given a key yet) has nothing to keep a token on a side of, and an app that isn't running (`ignoring` also holds those)
///   takes no room on the bar whatever keys the table still has for it. Neither keeps any token from being written.
/// - **An app out of the way** (`ignoring`) is not unwritten for this purpose: every key it has is among the modules that stay, and every
///   item of it has one, so it is right of anything a write can place (nothing is written below `systemStart`, which lies left of those
///   modules). This holds only because the resolver judges "among" by the left-most drawn staying module's own distance, and the floor is
///   `systemStart`, which counts every drawn module, those that come and go included. An app that has a key elsewhere too, or an item no key
///   can be found for, stays an obstacle.
/// - **A run** is the written tokens that sit side by side (no unwritten app between them). **Its gap** is above the largest distance of
///   every obstacle that must be right of the run, and below the smallest distance of every obstacle that must be left of it (a larger
///   distance is further left). Never below `systemStart` (the system items' end): with no obstacle to its right, a token goes just left of
///   the system items, not among them. With no obstacle to its left, the gap is as wide as the run needs (`assumedWidth` each).
/// - **Which obstacles a run goes by.** A run with one of Mantel's own items in it goes by every obstacle: an own item across an app is a
///   place no one chose. A run of apps goes by the obstacles whose places agree with the arrangement's order of them (the largest set
///   that does, `consistentChain`, with Mantel's own left-out items counting for the most): an app that can't be reordered and that the
///   table has elsewhere than the section it was seen in is not one that the person's change can put right, and it doesn't stop the apps
///   from being written. **Never across a dot, though:** a dot that isn't written (left out of this write) divides the sections, and an app
///   is not written to the other side of it than the arrangement has it, whether or not its place agrees with the others' (the table has
///   no entry for it yet, as on any Mac before Mantel's first write; or has the two dots the other way round). So a run of apps goes by
///   every left-out dot that has a place as well as by the chain, and one with no place in the table stops the apps as it stops the own
///   items (the divider, spacers and groups' icons don't divide sections, and keep the rule above). The runs are placed from the right,
///   each above the one to its right, so the arrangement's order holds whichever obstacles each went by.
/// - **The run is spread evenly in its gap**, in the arrangement's order. When no app is unwritten at all, the arrangement's own
///   distances stand (they are all from the same widths).
/// - **No gap, no write.** When the gap is empty (the obstacles' ranges overlap, or the table has them the other way round), or the place
///   of a left-out own item can't be told (it has no entry in the table), the own items of the run aren't written; when the gap of a run of
///   apps is empty, or the place of a left-out dot can't be told, they aren't either. They are reported (`notPlaced`), as an app whose order can't be written is. A token that is left
///   out this way is unwritten from then on, so the other runs go around it, and the tokens are worked out again until none more is left
///   out (the apps of a run that had own items in it are worked out again without them).
public enum OwnItemPlacer {
    /// What was decided for the tokens that are written.
    public struct Result: Sendable, Equatable {
        /// The distance of each token that is placed by the gaps; every other token keeps the arrangement's.
        public let distances: [LayoutToken: Double]
        /// The tokens that aren't written, in the order of the arrangement.
        public let notPlaced: [LayoutToken]
        /// The bundle IDs of the apps whose places closed a gap, or couldn't be told, for a run that has one of Mantel's own items in it:
        /// what kept those from being written. Sorted, once each.
        public let blockedBy: [String]

        public init(distances: [LayoutToken: Double], notPlaced: [LayoutToken], blockedBy: [String] = []) {
            self.distances = distances
            self.notPlaced = notPlaced
            self.blockedBy = blockedBy
        }
    }

    /// The smallest step between two tokens in a gap. The writer leaves a distance alone that is within 0.25 of the table's, and the places
    /// are rounded to 0.5: a step of 1 keeps every written place, and any place the table has within the writer's tolerance of it, inside the gap.
    private static let smallestStep = 1.0

    /// - Parameters:
    ///   - keys: the table key of each token that is to be written (`LayoutKeyResolution.keys`).
    ///   - table: the table as it is now.
    ///   - systemStart: where the apps' items begin (`LayoutMath.systemStart`): nothing is written below it.
    ///   - ignoring: the apps that are out of the way or not running (`LayoutKeyResolution.outOfTheWay`, `.notRunning`): their tokens are not
    ///     obstacles.
    public static func place(_ arrangement: LayoutArrangement, keys: [LayoutToken: String], table: LayoutTableSnapshot,
                             systemStart: Double, ignoring: Set<String> = []) -> Result {
        // A token that can't be placed isn't written, so it stays where macOS has it, and the other tokens must go around that place too:
        // it counts as unwritten from then on, and every run is worked out again.
        var dropped: Set<LayoutToken> = []
        var blockers: Set<String> = []
        while true {
            let result = pass(arrangement, keys: keys, table: table, systemStart: systemStart, ignoring: ignoring, dropped: dropped)
            blockers.formUnion(result.blockedBy)
            let fresh = Set(result.notPlaced).subtracting(dropped)
            if fresh.isEmpty {
                let left = dropped.union(result.notPlaced)
                return Result(distances: result.distances, notPlaced: arrangement.tokens.filter(left.contains), blockedBy: blockers.sorted())
            }
            dropped.formUnion(fresh)
        }
    }

    private typealias Range = (low: Double, high: Double)
    private typealias Obstacle = (index: Int, owner: String?, range: Range)

    private static func pass(_ arrangement: LayoutArrangement, keys: [LayoutToken: String], table: LayoutTableSnapshot,
                             systemStart: Double, ignoring: Set<String>, dropped: Set<LayoutToken>) -> Result {
        let tokens = arrangement.tokens
        func isWritten(_ token: LayoutToken) -> Bool {
            keys[token] != nil && arrangement.distances[token] != nil && !dropped.contains(token)
        }
        let writtenKeys = Set(tokens.filter(isWritten).compactMap { keys[$0] })
        func range(ofApp bundleID: String) -> Range? {
            let values = table.statusKeys(ofApp: bundleID).filter { !writtenKeys.contains($0) }.compactMap { table.distances[$0] }
            guard let low = values.min(), let high = values.max() else { return nil }
            return (low, high)
        }

        // The unwritten tokens, by their place in the arrangement. An app is unwritten when it has no key or no distance, and so is a token
        // of Mantel's own that was left out: it stays at its own key's distance. One with no place in the table (an app that has no key,
        // as one that isn't running has none) is no obstacle: nothing says where it is, so nothing is kept on a side of it.
        var unwritten: [Obstacle] = []
        // An own item that is left out and that the table has no place for: where it is can't be told, so no own item can keep a side of it.
        var ownWithoutPlace = false
        // The same for a dot: it divides the sections, so an app can't be written either side of it when its place can't be told.
        var dotWithoutPlace = false
        // The left-out dots that have a place: every run goes by them.
        var dotIndexes: Set<Int> = []
        for (index, token) in tokens.enumerated() where !isWritten(token) {
            if let bundleID = appBundle(token) {
                if ignoring.contains(bundleID) { continue }
                // An app with no key has no place in the table to keep a token on a side of.
                if let range = range(ofApp: bundleID) { unwritten.append((index, bundleID, range)) }
            } else if let key = keys[token] {
                let isDot: Bool
                if case .dot = token { isDot = true } else { isDot = false }
                if let distance = table.distances[key] {
                    unwritten.append((index, nil, (distance, distance)))
                    if isDot { dotIndexes.insert(index) }
                } else {
                    ownWithoutPlace = true
                    if isDot { dotWithoutPlace = true }
                }
            }
        }
        guard !unwritten.isEmpty || ownWithoutPlace else { return Result(distances: [:], notPlaced: []) }

        var distances: [LayoutToken: Double] = [:]
        var notPlaced: [LayoutToken] = []
        var blockers: Set<String> = []
        var windows: [(run: [LayoutToken], hasOwnItem: Bool, lower: Double, upper: Double?, blockers: [String?])] = []
        // What a run of apps goes by: the chain, and every dot that is left out whether the chain holds it or not.
        let chain = consistentChain(of: unwritten)
        let chainIndexes = Set(chain.map(\.index)).union(dotIndexes)
        let appObstacles = unwritten.filter { chainIndexes.contains($0.index) }
        let obstacleIndexes = Set(unwritten.map(\.index))
        var index = 0
        while index < tokens.count {
            guard isWritten(tokens[index]) else {
                index += 1
                continue
            }
            // A run is the written tokens with no obstacle between them: a token that is neither written nor an obstacle (an app that
            // isn't there) doesn't part two of them.
            var run: [LayoutToken] = []
            var end = index
            var next = index
            while next < tokens.count {
                if isWritten(tokens[next]) {
                    run.append(tokens[next])
                    next += 1
                    end = next
                } else if obstacleIndexes.contains(next) {
                    break
                } else {
                    next += 1
                }
            }
            let start = index
            index = end
            let hasOwnItem = run.contains { appBundle($0) == nil }
            // One of Mantel's own items across an app is a place no one chose: it keeps its side of every obstacle there is. (An own item
            // that is left out and has no place in the table leaves no side to keep.) A run of apps keeps its side of the obstacles whose
            // places agree with the arrangement's order of them: one whose place in the table is against it (an app that can't be
            // reordered, in the section it was seen in) is not one that the person's change can put right, and it doesn't stop the apps.
            let leftOf: [Obstacle], rightOf: [Obstacle]
            if hasOwnItem {
                guard !ownWithoutPlace else {
                    notPlaced += run.filter { appBundle($0) == nil }
                    continue
                }
                leftOf = unwritten.filter { $0.index < start }
                rightOf = unwritten.filter { $0.index >= end }
            } else {
                guard !dotWithoutPlace else {
                    notPlaced += run
                    continue
                }
                leftOf = appObstacles.filter { $0.index < start }
                rightOf = appObstacles.filter { $0.index >= end }
            }

            let lowest = rightOf.map(\.range.high).max()
            let highest = leftOf.map(\.range.low).min()
            windows.append((run, hasOwnItem, max(systemStart, lowest ?? systemStart), highest, 
                            rightOf.filter { $0.range.high == lowest }.map(\.owner) + leftOf.filter { $0.range.low == highest }.map(\.owner)))
        }

        // The runs are placed from the right, each above the one to its right: the obstacles each run was worked out against differ (a run
        // of apps goes by the ones that touch it, an own item by all of them), and the arrangement's order of the runs holds whatever they are.
        var rightmost = systemStart
        for window in windows.reversed() {
            let run = window.run
            let lower = max(window.lower, rightmost)
            let upper = window.upper ?? lower + Double(run.count + 1) * Double(LayoutMath.assumedWidth)
            guard upper > lower, (upper - lower) / Double(run.count + 1) >= smallestStep else {
                // The apps of a run with own items are worked out again once these are left out.
                notPlaced += window.hasOwnItem ? run.filter { appBundle($0) == nil } : run
                // The ones whose places set the two ends of the gap.
                if window.hasOwnItem { blockers.formUnion(window.blockers.compactMap { $0 }) }
                continue
            }
            let step = (upper - lower) / Double(run.count + 1)
            let exact = run.indices.map { upper - step * Double($0 + 1) }
            let rounded = exact.map { ($0 * 2).rounded() / 2 }
            let usable = zip(rounded, rounded.dropFirst()).allSatisfy { $0 > $1 } && (rounded.first ?? 0) < upper && (rounded.last ?? 0) > lower
            let chosen = usable ? rounded : exact
            for (token, distance) in zip(run, chosen) { distances[token] = distance }
            rightmost = chosen.first ?? rightmost
        }
        return Result(distances: distances, notPlaced: notPlaced, blockedBy: blockers.sorted())
    }

    /// The largest set of obstacles whose places agree with the order they have in the arrangement (each one's places all below those of
    /// the one before it: a larger distance is further left), Mantel's own items counting for more than any number of apps so that the
    /// set keeps them when it can. The others are where the table has them against the arrangement; nothing a write of the apps can do puts
    /// that right, so they don't stop the apps.
    private static func consistentChain(of obstacles: [Obstacle]) -> [Obstacle] {
        func weight(_ obstacle: Obstacle) -> Int { obstacle.owner == nil ? 10_000 : 1 }
        var best = obstacles.map(weight)
        var before = Array(repeating: -1, count: obstacles.count)
        for i in obstacles.indices {
            for j in 0..<i where obstacles[i].range.high < obstacles[j].range.low && best[j] + weight(obstacles[i]) > best[i] {
                best[i] = best[j] + weight(obstacles[i])
                before[i] = j
            }
        }
        guard var at = best.indices.max(by: { best[$0] < best[$1] }) else { return [] }
        var chain: [Obstacle] = []
        while at >= 0 {
            chain.append(obstacles[at])
            at = before[at]
        }
        return chain.reversed()
    }

    /// The arrangement as it is written: the placed tokens at their places, and the ones that couldn't be placed left out.
    public static func applying(_ result: Result, to arrangement: LayoutArrangement) -> LayoutArrangement {
        let left = Set(result.notPlaced)
        var distances = arrangement.distances
        for token in left { distances[token] = nil }
        for (token, distance) in result.distances { distances[token] = distance }
        return LayoutArrangement(tokens: arrangement.tokens.filter { !left.contains($0) }, distances: distances, skipped: arrangement.skipped)
    }

    // MARK: Kinds

    private static func appBundle(_ token: LayoutToken) -> String? {
        if case .item(let id) = token, !id.isSystem, id.bundleID != OwnItems.owner { return id.bundleID }
        return nil
    }
}
