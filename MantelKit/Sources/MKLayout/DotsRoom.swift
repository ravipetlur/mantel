import CoreGraphics
import MKCore

/// What a read of the menu bar says of Mantel's dots (• and ••, and not its other items), and whether macOS has put one of them in the « menu.
///
/// macOS fills a bar from the right, and what doesn't fit goes in the « menu, the left-most icons first. Mantel's dots sit left of every
/// Shown app (Hidden and Always Hidden apps are concealed and take no room), so on a bar that is a little too narrow it is the dots
/// that go into the « and no app does: `OverflowInputs.overflowedApps(in:)`, which looks at apps, has nothing to move.
///
/// - **Only a bar that is shown counts** (`BarVisibility.shownBars`): a full-screen app hides a bar and everything on it.
/// - **A dot is in the « menu** of a display when the inventory says it is overflowed there (`MenuBarItem.overflowedOn`), however that was
///   found out: a slot in the pile that was tied to it, a pile that was lined up with another display's bar, its own frame reporting
///   itself in the place it would have in the opened menu, or (on macOS 27, which lists no slot for an icon it isn't drawing, and no «)
///   its saying that it is behind the notch or under the app's menus (`BarRegion`). The last is a place and not a menu, and the log says
///   so (`Verdict.inferred`).
/// - **When it can't be told** (a « shows and Mantel's dots aren't in the read or one of them has no place on that bar, or the dots say they
///   are in one and the same place, which is a frame left over from the middle of a change), it is said (`CantTell`) and nothing is done.
public enum DotsRoom {
    /// How wide a dot is taken to be when none has ever been seen on a bar: a status item's slot.
    public static let assumedWidth: CGFloat = 38

    /// Why Mantel can't tell what is in the « menu of a bar.
    public enum CantTell: String, Sendable, Equatable {
        /// Mantel's own icons aren't in the read at all.
        case noOwnIcons
        /// They are, but one has no place on this bar, and isn't known to be in its « either.
        case ownIconsNotPlaced
        /// Both dots say they are in one and the same place on this bar, which none can be: what they say is out of date.
        case ownIconsShareAFrame
        /// No « shows (macOS 27 lists none), and a dot has no slot on this bar and isn't known to be anywhere else on it.
        case dotHasNoSlot

        /// Said in the log, after "can't tell what is in it".
        public var reason: String {
            switch self {
            case .noOwnIcons: "Mantel's own icons weren't in what was read"
            case .ownIconsNotPlaced: "Mantel's own icons couldn't be placed on that bar"
            case .ownIconsShareAFrame: "Mantel's own icons said they were in one and the same place"
            case .dotHasNoSlot: "no slot on that bar is one of Mantel's"
            }
        }
    }

    /// Whether the read has Mantel's dots on a bar: it lists them, and each has a slot on at least one bar. At the launch macOS hasn't
    /// always placed them when the bar is first read; until a read has them, where a dot has no place says nothing yet.
    public static func dotsArePlaced(in inventory: Inventory) -> Bool {
        let dots = inventory.items.filter(\.isDot)
        return !dots.isEmpty && dots.allSatisfy { !$0.frames.isEmpty }
    }

    /// What a read says of the dots on each shown bar.
    public struct Verdict: Sendable, Equatable {
        /// The displays whose bar is shown and has a dot in its « menu, in the order of the bars.
        public var trapped: [String] = []
        /// The displays in `trapped` where the dots are known to be out of the way only by where they say they are (behind the notch or
        /// under the menus), with no slot or « to say so.
        public var inferred: Set<String> = []
        /// The displays whose bar is shown and has a « where it can't be told whether a dot is in it.
        public var cantTell: [String: CantTell] = [:]

        public init(trapped: [String] = [], inferred: Set<String> = [], cantTell: [String: CantTell] = [:]) {
            self.trapped = trapped
            self.inferred = inferred
            self.cantTell = cantTell
        }
    }

    /// Whether the read can say something of the dots, which needs telling the bars that are shown apart (a look at the window list): a
    /// « anywhere, a dot that is out of the way or shares a frame, or a dot that has no slot on some bar.
    public static func mayHaveAVerdict(in inventory: Inventory) -> Bool {
        if !inventory.chevrons.isEmpty { return true }
        let dots = inventory.items.filter(\.isDot)
        return dots.contains { $0.isOverflowed || !$0.sharesFrameOn.isEmpty }
            || inventory.bars.contains { bar in dots.contains { $0.frames[bar.displayUUID] == nil } }
    }

    /// What the read says of the dots on the bars that are shown (`shownBars`: the displays whose bar is on screen).
    public static func verdict(in inventory: Inventory, shownBars: Set<String>) -> Verdict {
        let dots = inventory.items.filter(\.isDot)
        var verdict = Verdict()
        for bar in inventory.bars where shownBars.contains(bar.displayUUID) {
            let display = bar.displayUUID
            // Dots that give one frame between them are out of date: nothing is told from them, a « or no «.
            if dots.contains(where: { $0.sharesFrameOn.contains(display) }) {
                verdict.cantTell[display] = .ownIconsShareAFrame
                continue
            }
            let trapped = dots.filter { $0.overflowedOn.contains(display) }
            if !trapped.isEmpty {
                verdict.trapped.append(display)
                if trapped.allSatisfy({ $0.inferredOverflowOn.contains(display) }) { verdict.inferred.insert(display) }
            } else if inventory.chevrons[display] != nil {
                if dots.isEmpty {
                    verdict.cantTell[display] = .noOwnIcons
                } else if dots.contains(where: { $0.frames[display] == nil }) {
                    verdict.cantTell[display] = .ownIconsNotPlaced
                }
            } else if dots.contains(where: { $0.frames[display] == nil }) {
                // No « is listed (macOS 27 lists none): a dot with no slot here may be anywhere, and nothing says where.
                verdict.cantTell[display] = .dotHasNoSlot
            }
        }
        return verdict
    }

    /// The room the dots that are in the « menu of a display need there, in points: what each's slot was last seen to take, or
    /// `assumedWidth` for one that was never seen with a slot (the width its own frame says is the icon's, and a slot is wider).
    public static func neededWidth(on display: String, in inventory: Inventory, widths: ItemWidthCache) -> CGFloat {
        inventory.items
            .filter { $0.isDot && $0.overflowedOn.contains(display) }
            .reduce(CGFloat.zero) { $0 + (widths.slotWidth(of: $1.id) ?? assumedWidth) }
    }

    /// The room the dots that are out of the way need on a display, for deciding whether apps fit with them: what `neededWidth(on:in:widths:)`
    /// says on a bar that is shown, and nothing on one that isn't (a full-screen app has it, and the dots aren't going to be seen there).
    public static func neededWidth(on display: String, in inventory: Inventory, widths: ItemWidthCache, shownBars: Set<String>) -> CGFloat {
        shownBars.contains(display) ? neededWidth(on: display, in: inventory, widths: widths) : 0
    }

    /// The places the dots that are out of the way on a display say they are at, left to right: empty when none of them has one (a slot or
    /// a « put them out of the way, and not a place).
    public static func dotPlaces(on display: String, in inventory: Inventory) -> [CGRect] {
        inventory.items
            .filter { $0.isDot && $0.overflowedOn.contains(display) }
            .compactMap { $0.strayFrames[display] }
            .sorted { $0.minX < $1.minX }
    }

    /// The shown bars where a dot is in the «, with the Shown apps that could be moved to make room, left to right (`inferred`: the
    /// displays where that was told by the dot's place alone).
    ///
    /// An app is one of them when it is Shown and none of its icons is in that bar's « itself (the apps that are get moved by what is
    /// overflowed, not for the dots). The ones to choose from are those that have a place on that bar in this read, from the left: it is
    /// their icons that take room there. Only when none has (the read didn't place any of them on that bar) are the others a guess: from
    /// where each was last seen on that bar (`BarOrder`), and then in the order of the inventory (the order of the slots).
    public static func trappedBars(_ displays: [String], inferred: Set<String> = [], in inventory: Inventory, sections: SectionModel,
                                   widths: ItemWidthCache, order: BarOrder) -> [AutoOverflowTracker.TrappedBar] {
        displays.map { display in
            let slotOrder = Dictionary(uniqueKeysWithValues: inventory.appsWithItems.enumerated().map { ($1, $0) })
            let candidates = inventory.appsWithItems.filter { app in
                sections.section(ofApp: app) == .shown
                    && !inventory.items(ofApp: app).contains { $0.overflowedOn.contains(display) }
            }
            func left(_ app: String) -> CGFloat? {
                BarOrder.leftEdge(ofApp: app, on: display, in: inventory) ?? order.leftEdge(ofApp: app, on: display)
            }
            let drawnHere = candidates.filter { BarOrder.leftEdge(ofApp: $0, on: display, in: inventory) != nil }
            let pool = drawnHere.isEmpty ? candidates : drawnHere
            let sorted = pool.sorted { a, b in
                switch (left(a), left(b)) {
                case let (x?, y?): (x, slotOrder[a] ?? 0) < (y, slotOrder[b] ?? 0)
                case (_?, nil): true
                case (nil, _?): false
                case (nil, nil): (slotOrder[a] ?? 0) < (slotOrder[b] ?? 0)
                }
            }
            return AutoOverflowTracker.TrappedBar(
                displayUUID: display, neededWidth: neededWidth(on: display, in: inventory, widths: widths),
                apps: sorted.map { AutoOverflowTracker.ConcealableApp(bundleID: $0, width: widths.width(ofApp: $0, in: inventory)) },
                isInferred: inferred.contains(display), dotPlaces: dotPlaces(on: display, in: inventory))
        }
    }
}

/// Where the apps' icons were last seen on each bar, from the left: what puts the Shown apps of a bar in order when a read can't say.
///
/// Every display draws the same icons in the same order, so an app that was left of another on a bar is left of it on any other, and the
/// order stays true until the apps change. What a read doesn't show of an app (it didn't answer, its icons weren't placed) never
/// clears what was known of it.
public struct BarOrder: Sendable, Equatable {
    private var edges: [String: [String: CGFloat]] = [:]

    public init() {}

    /// The left edge of the app's left-most icon that is drawn on the display's bar in this read, or nil when none is: an icon in that
    /// bar's « isn't drawn there, and neither is one with no frame on it.
    public static func leftEdge(ofApp bundleID: String, on display: String, in inventory: Inventory) -> CGFloat? {
        inventory.items(ofApp: bundleID)
            .filter { !$0.overflowedOn.contains(display) }
            .compactMap { $0.frames[display]?.minX }
            .min()
    }

    /// Notes where the apps' icons are on each bar, in this read.
    public mutating func update(from inventory: Inventory) {
        for app in inventory.appsWithItems {
            for bar in inventory.bars {
                if let edge = Self.leftEdge(ofApp: app, on: bar.displayUUID, in: inventory) {
                    edges[app, default: [:]][bar.displayUUID] = edge
                }
            }
        }
    }

    /// Where the app's left-most icon was the last time it was drawn on the display's bar.
    public func leftEdge(ofApp bundleID: String, on display: String) -> CGFloat? {
        edges[bundleID]?[display]
    }
}
