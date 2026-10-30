import CoreGraphics
import MKCore
import Testing

@testable import MKLayout

@Suite("Layout verifier", .timeLimit(.minutes(1)))
struct LayoutVerifierTests {
    private typealias F = ArrangementFixtures
    private let a = F.app("a"), b = F.app("b"), c = F.app("c")

    /// The arrangement [a, b, c] (nothing else), with a key for each token named.
    private func arrangement(_ tokens: [LayoutToken], skipped: [ItemID] = []) -> LayoutArrangement {
        LayoutArrangement(tokens: tokens, distances: [:], skipped: skipped)
    }

    private func resolution(_ tokens: [LayoutToken]) -> LayoutKeyResolution {
        LayoutKeyResolution(keys: Dictionary(uniqueKeysWithValues: tokens.enumerated().map { ($1, "key\($0)") }), unresolved: [], memory: [:])
    }

    private func verdict(_ tokens: [LayoutToken], _ items: [MenuBarItem], keys: [LayoutToken]? = nil, skipped: [ItemID] = [],
                         bars: Set<String> = [Fixtures.display], frames: FramesAfterResort = .follow,
                         concealed: Set<String> = [], contested: Set<String> = []) -> LayoutVerdict {
        let read = contested.isEmpty ? F.inventory(items) : F.slotted(items, contested: contested)
        return LayoutVerifier.verdict(arrangement(tokens, skipped: skipped), resolution: resolution(keys ?? tokens), read: read,
                                      shownBars: bars, frames: frames, concealedApps: concealed)
    }

    @Test func matchingOrderPasses() {
        let tokens: [LayoutToken] = [.item(a), .item(b), .dot(.hidden), .divider, .item(c)]
        let items = [F.drawn(a, x: 100), F.drawn(b, x: 200), F.own(.hiddenDot, x: 300), F.own(.divider, x: 320), F.drawn(c, x: 400)]
        #expect(verdict(tokens, items) == .matches)
    }

    @Test func swappedAppsFail() {
        let tokens: [LayoutToken] = [.item(a), .item(b), .item(c)]
        #expect(verdict(tokens, [F.drawn(a, x: 100), F.drawn(b, x: 300), F.drawn(c, x: 200)]) == .differs)
    }

    @Test func unresolvedTokensIgnored() {
        let tokens: [LayoutToken] = [.item(a), .item(b), .item(c)]
        // b is out of order but has no key.
        let items = [F.drawn(a, x: 300), F.drawn(b, x: 100), F.drawn(c, x: 400)]
        #expect(verdict(tokens, items, keys: [.item(a), .item(c)]) == .matches)
    }

    @Test func skippedTokensIgnored() {
        let tokens: [LayoutToken] = [.item(a), .item(b), .item(c)]
        let items = [F.drawn(a, x: 300), F.drawn(b, x: 100), F.drawn(c, x: 400)]
        #expect(verdict(tokens, items, skipped: [b]) == .matches)
    }

    @Test func concealedTokensIgnored() {
        let tokens: [LayoutToken] = [.item(a), .item(b), .item(c)]
        let items = [F.drawn(a, x: 100), F.concealed(b), F.drawn(c, x: 300)]
        #expect(verdict(tokens, items) == .matches)
        // An item in the overflow isn't drawn either.
        #expect(verdict(tokens, [F.drawn(a, x: 300), F.drawn(b, x: 100, overflowed: true), F.drawn(c, x: 400)]) == .matches)
    }

    @Test func aConcealedOrContestedAppsLeftBehindFramesAreNotCompared() {
        let tokens: [LayoutToken] = [.item(a), .item(b), .item(c)]
        // b's frame is where it was last drawn: it reads as out of order, and its app is concealed (or contested).
        let items = [F.drawn(a, x: 100), F.drawn(b, x: 400), F.drawn(c, x: 300)]
        #expect(verdict(tokens, items) == .differs)
        #expect(verdict(tokens, items, concealed: [b.bundleID]) == .matches)
        #expect(verdict(tokens, items, contested: [b.bundleID]) == .matches)
        // Mantel's own dots are compared whatever the set says.
        let dots = [F.drawn(a, x: 100), F.own(.alwaysDot, x: 300), F.own(.hiddenDot, x: 200)]
        #expect(verdict([.item(a), .dot(.always), .dot(.hidden)], dots, concealed: [F.ownBundle]) == .differs)
    }

    @Test func everyShownBarMustAgree() {
        let tokens: [LayoutToken] = [.item(a), .item(b)]
        // Each item is one item with a frame on each display.
        func both(_ id: ItemID, main: CGFloat, other: CGFloat) -> MenuBarItem {
            MenuBarItem(id: id, ownerBundleID: id.bundleID, appName: nil, label: nil,
                        frames: [Fixtures.display: CGRect(x: main, y: 0, width: 30, height: 24), "other": CGRect(x: other, y: 0, width: 30, height: 24)],
                        overflowedOn: [], isMantel: false)
        }
        let agreeing = [both(a, main: 100, other: 100), both(b, main: 200, other: 200)]
        #expect(verdict(tokens, agreeing, bars: [Fixtures.display, "other"]) == .matches)
        let disagreeing = [both(a, main: 100, other: 300), both(b, main: 200, other: 200)]
        #expect(verdict(tokens, disagreeing, bars: [Fixtures.display, "other"]) == .differs)
        #expect(verdict(tokens, disagreeing, bars: [Fixtures.display]) == .matches)
    }

    @Test func hiddenBarIgnored() {
        let tokens: [LayoutToken] = [.item(a), .item(b)]
        let items = [MenuBarItem(id: a, ownerBundleID: a.bundleID, appName: nil, label: nil,
                                 frames: [Fixtures.display: CGRect(x: 100, y: 0, width: 30, height: 24), "hidden": CGRect(x: 300, y: 0, width: 30, height: 24)],
                                 overflowedOn: [], isMantel: false),
                     MenuBarItem(id: b, ownerBundleID: b.bundleID, appName: nil, label: nil,
                                 frames: [Fixtures.display: CGRect(x: 200, y: 0, width: 30, height: 24), "hidden": CGRect(x: 100, y: 0, width: 30, height: 24)],
                                 overflowedOn: [], isMantel: false)]
        #expect(verdict(tokens, items, bars: [Fixtures.display]) == .matches)
        #expect(verdict(tokens, items, bars: ["hidden"]) == .differs)
    }

    @Test func nothingComparableIsCantTell() {
        let tokens: [LayoutToken] = [.item(a), .item(b)]
        #expect(verdict(tokens, [F.drawn(a, x: 100), F.concealed(b)]) == .cantTell)
        #expect(verdict(tokens, []) == .cantTell)
        #expect(verdict(tokens, [F.drawn(a, x: 100), F.drawn(b, x: 200)], bars: []) == .cantTell)
        // Spacers can't be told apart on the bar, and aren't compared.
        let spacer = OwnItems.itemID(SpacerID(rawValue: "0000abcd"))
        #expect(verdict([.item(a), .item(spacer)], [F.drawn(a, x: 100), F.own(.spacer, x: 200)]) == .cantTell)
    }

    @Test func dotsAreComparedWithoutAKey() {
        let tokens: [LayoutToken] = [.item(a), .dot(.hidden)]
        let items = [F.drawn(a, x: 300), F.own(.hiddenDot, x: 100)]
        #expect(verdict(tokens, items, keys: [.item(a)]) == .differs)
    }

    @Test func framesLagComparesIdentifierSlotsOnly() {
        let nameless = F.nameless("n", 0)
        let tokens: [LayoutToken] = [.item(a), .item(nameless), .dot(.hidden)]
        // The nameless item's frame is behind the re-sort and says it is left of a; the slots that name themselves agree.
        let items = [F.drawn(a, x: 100), F.drawn(nameless, x: 50), F.own(.hiddenDot, x: 300)]
        #expect(verdict(tokens, items, frames: .follow) == .differs)
        #expect(verdict(tokens, items, frames: .lag) == .matches)
        // With only one identifier-named slot and the dots left to compare, and one of them missing, nothing can be told.
        #expect(verdict(tokens, [F.drawn(nameless, x: 50), F.own(.hiddenDot, x: 300)], frames: .lag) == .cantTell)
    }
}
