import CoreGraphics
import MKCore

/// Whether the bar shows the order that was written.
public enum LayoutVerdict: Sendable, Equatable {
    case matches
    case differs
    /// Too little is drawn to compare.
    case cantTell
}

public enum LayoutVerifier {
    /// Compares the arrangement with what each shown bar draws. On a bar, only the drawn items whose token has a key
    /// (`resolution.keys`), and the dots, are compared: their order left to right must be the arrangement's. An item that is unresolved,
    /// skipped, concealed or in the overflow is left out, and so are the spacers and the groups' icons (they can't be told apart). An app in
    /// `concealedApps`, or one the read says is contested, is left out as well: the frames it has are where it was last drawn, and say
    /// nothing of the order now (Mantel's own dots are always compared). With `.lag` (the apps' own frames are behind a re-sort), only what
    /// a slot names counts: the items that name themselves, and the dots.
    ///
    /// A bar with fewer than two to compare says nothing. When no bar says anything, it is `.cantTell`; when one disagrees, `.differs`.
    public static func verdict(_ arrangement: LayoutArrangement, resolution: LayoutKeyResolution, read: Inventory,
                               shownBars: Set<String>, frames: FramesAfterResort,
                               concealedApps: Set<String>) -> LayoutVerdict {
        var rank: [LayoutToken: Int] = [:]
        for (index, token) in arrangement.tokens.enumerated() where rank[token] == nil { rank[token] = index }
        let skipped = Set(arrangement.skipped)

        var compared = false
        for bar in shownBars.sorted() {
            var drawn: [(x: CGFloat, rank: Int)] = []
            for item in read.items {
                guard let token = LayoutToken.drawn(item), let place = rank[token] else { continue }
                if case .item(let id) = token, skipped.contains(id) { continue }
                let isDot = item.ownKind?.isDot == true
                guard isDot || resolution.keys[token] != nil else { continue }
                if !isDot, concealedApps.contains(item.ownerBundleID) || read.contestedApps.contains(item.ownerBundleID) { continue }
                if frames == .lag, !namesItself(item) { continue }
                guard !item.overflowedOn.contains(bar), let frame = item.frames[bar] else { continue }
                drawn.append((frame.midX, place))
            }
            guard drawn.count >= 2 else { continue }
            compared = true
            let ranks = drawn.sorted { $0.x < $1.x }.map(\.rank)
            if zip(ranks, ranks.dropFirst()).contains(where: { $0 > $1 }) { return .differs }
        }
        return compared ? .matches : .cantTell
    }

    /// Whether a slot names the item: it has an identifier of its own, or is one of the dots.
    static func namesItself(_ item: MenuBarItem) -> Bool {
        if item.ownKind?.isDot == true { return true }
        if case .identifier = item.id.key { return true }
        return false
    }
}
