import CoreGraphics
import Foundation
import MKCore
import Testing

@testable import MKLayout

/// A read that is missing an app's icons isn't followed; two reads in a row that agree are the bar as it is.
@Suite("Follow trust")
struct FollowTrustTests {
    private func read(unclaimed: Int) -> Inventory {
        let bar = MenuBarGeometry(displayUUID: "main", rect: CGRect(x: 0, y: 0, width: 1000, height: 24), notch: nil)
        let slots = (0..<unclaimed).map { CGRect(x: CGFloat($0) * 30, y: 0, width: 28, height: 24) }
        return Inventory(capturedAt: Date(timeIntervalSince1970: 0), bars: [bar], items: [], chevrons: [:], reach: [], problems: [],
                         untiedSlots: unclaimed == 0 ? [:] : ["main": slots])
    }

    @Test func theFirstReadIsTrusted() {
        var trust = FollowTrust()
        let v1 = trust.trusts(read(unclaimed: 3))
        #expect(v1)
    }

    @Test func aReadWithMoreUnclaimedSlotsThanTheFewestSeenIsPartial() {
        var trust = FollowTrust()
        let v2 = trust.trusts(read(unclaimed: 0))
        #expect(v2)
        let v3 = trust.trusts(read(unclaimed: 2))
        #expect(!v3, "an app didn't answer: its icons have no place in this read")
        let v4 = trust.trusts(read(unclaimed: 0))
        #expect(v4)
    }

    @Test func twoReadsInARowThatAgreeAreTheBarAsItIs() {
        var trust = FollowTrust()
        let v5 = trust.trusts(read(unclaimed: 0))
        #expect(v5)
        let v6 = trust.trusts(read(unclaimed: 1))
        #expect(!v6)
        let v7 = trust.trusts(read(unclaimed: 1))
        #expect(v7, "an icon whose owner can't be told is there to stay")
        let v8 = trust.trusts(read(unclaimed: 1))
        #expect(v8)
    }

    @Test func aReadWithNoBarHasNoUnclaimedSlots() {
        let empty = Inventory(capturedAt: Date(timeIntervalSince1970: 0), bars: [], items: [], chevrons: [:], reach: [], problems: [])
        #expect(FollowTrust.unclaimedSlots(in: empty) == 0)
    }

    // MARK: An app that doesn't answer

    private func item(_ bundleID: String, frameX: CGFloat) -> MenuBarItem {
        MenuBarItem(id: ItemID(bundleID: bundleID, key: .identifier("main")), ownerBundleID: bundleID, appName: nil, label: nil,
                    frames: ["main": CGRect(x: frameX, y: 0, width: 28, height: 24)], overflowedOn: [], isMantel: false)
    }

    private func read(apps: [String], unanswered: Set<String> = [], incomplete: Set<String> = [], unclaimed: Int = 0, cut: Bool = false) -> Inventory {
        let bar = MenuBarGeometry(displayUUID: "main", rect: CGRect(x: 0, y: 0, width: 1000, height: 24), notch: nil)
        let slots = (0..<unclaimed).map { CGRect(x: 900 + CGFloat($0) * 30, y: 0, width: 28, height: 24) }
        let items = apps.enumerated().map { item($1, frameX: CGFloat($0) * 30) }
        let whole = Inventory(capturedAt: Date(timeIntervalSince1970: 0), bars: [bar], items: items, chevrons: [:], reach: [], problems: [],
                              unansweredApps: unanswered, untiedSlots: unclaimed == 0 ? [:] : ["main": slots], incompleteApps: incomplete)
        return cut ? whole.markingAgentReadCut() : whole
    }

    @Test func anAppThatHadAnIconAndIsMissingFromEveryReadIsNotTheBarAsItIs() {
        var trust = FollowTrust()
        let first = trust.trusts(read(apps: ["vpn", "notes"]))
        #expect(first)
        // The VPN app stops answering for good: its icon has a slot and no item, in every read from now on, and the count of slots no one
        // claimed is the same in two reads in a row. That isn't the bar as it is: the app is missing.
        for _ in 0..<3 {
            let partial = trust.trusts(read(apps: ["notes"], unanswered: ["vpn"], unclaimed: 1))
            #expect(!partial)
        }
        let back = trust.trusts(read(apps: ["vpn", "notes"]))
        #expect(back, "and a read that has it is whole")
    }

    @Test func anAppThatWasNotOnTheBarAndIsUnansweredDoesNotStopTheFollowing() {
        var trust = FollowTrust()
        let first = trust.trusts(read(apps: ["notes"]))
        #expect(first)
        let later = trust.trusts(read(apps: ["notes"], unanswered: ["xcode"]))
        #expect(later, "an app with no icon on the bar that doesn't answer (Xcode's helpers) says nothing of the order")
    }

    @Test func aReadOfMenuBarAgentThatWasCutIsPartial() {
        var trust = FollowTrust()
        let first = trust.trusts(read(apps: ["notes"]))
        #expect(first)
        let cut = trust.trusts(read(apps: ["notes"], cut: true))
        #expect(!cut, "a slot may lack its frame, or a window have been passed over")
        let whole = trust.trusts(read(apps: ["notes"]))
        #expect(whole)
    }

    // MARK: An app that answered in part

    @Test func anAppWithAnIconOnTheBarThatAnsweredInPartMakesAReadPartial() {
        var trust = FollowTrust()
        let first = trust.trusts(read(apps: ["vpn", "notes"]))
        #expect(first)
        // The VPN app's list was cut, or an item's name didn't come: its icon is named by its place, and may not be the record the list holds.
        // The count of slots no one claimed is the same as before, so the count rule alone would follow it.
        for _ in 0..<2 {
            let partial = trust.trusts(read(apps: ["vpn", "notes"], incomplete: ["vpn"]))
            #expect(!partial)
        }
        let back = trust.trusts(read(apps: ["vpn", "notes"]))
        #expect(back, "and a read whose apps are whole is trusted again")
    }

    @Test func anAppWithNoIconOnTheBarThatAnsweredInPartDoesNotStopTheFollowing() {
        var trust = FollowTrust()
        let first = trust.trusts(read(apps: ["notes"]))
        #expect(first)
        let later = trust.trusts(read(apps: ["notes"], incomplete: ["xcode"]))
        #expect(later)
    }

    @Test func aReadThatIsNotTrustedSaysWhy() {
        var trust = FollowTrust()
        #expect(trust.doubt(in: read(unclaimed: 0)) == nil)
        #expect(trust.doubt(in: read(unclaimed: 2)) == .unclaimedSlots(2))
        #expect(trust.doubt(in: read(unclaimed: 0)) == nil)
    }
}
