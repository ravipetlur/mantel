import CoreGraphics
import Foundation
import Testing

@testable import MKMenuBar

@Suite("Overflow analysis", .timeLimit(.minutes(1)))
struct OverflowAnalysisTests {
    private let chevron = CGRect(x: 1000, y: 0, width: 30, height: 31)

    private func snapshot(slots: [AgentSlot] = [], apps: [AppExtras]) -> MenuBarSnapshot {
        MenuBarSnapshot(capturedAt: Date(timeIntervalSince1970: 0), layout: .laptop,
                        agentWindows: [AgentWindow(frame: CGRect(x: 0, y: 0, width: 1512, height: 32), slots: slots)],
                        apps: apps, rawAgentTree: nil)
    }

    private func chevronSlot() -> AgentSlot {
        AgentSlot(frame: chevron, identifier: nil, role: "AXGroup", subrole: "AXMenuExtra", description: "»",
                  ownerPID: nil, isOverflowChevron: true)
    }

    private func app(_ bundleID: String, pid: pid_t = 1, items: [ExtraItem]) -> AppExtras {
        AppExtras(pid: pid, bundleID: bundleID, name: nil, items: items, timedOut: false)
    }

    private func item(_ index: Int, frame: CGRect?) -> ExtraItem {
        ExtraItem(index: index, frame: frame, identifier: nil, title: nil, description: nil)
    }

    @Test func aFramelessExtraIsOverflowed() {
        let snapshot = snapshot(slots: [chevronSlot()], apps: [
            app("com.example.a", items: [item(0, frame: CGRect(x: 100, y: 0, width: 30, height: 31)), item(1, frame: nil)]),
        ])
        #expect(OverflowAnalysis.overflowed(in: snapshot) == [ExtraItemRef(bundleID: "com.example.a", index: 1)])
    }

    @Test func aFrameInsideTheChevronIsOverflowed() {
        let inside = CGRect(x: 1005, y: 2, width: 20, height: 27)
        let snapshot = snapshot(slots: [chevronSlot()], apps: [
            app("com.example.a", items: [item(0, frame: inside), item(1, frame: CGRect(x: 100, y: 0, width: 30, height: 31))]),
        ])
        #expect(OverflowAnalysis.overflowed(in: snapshot) == [ExtraItemRef(bundleID: "com.example.a", index: 0)])
    }

    @Test func normalItemsAreNotOverflowed() {
        let snapshot = snapshot(slots: [chevronSlot()], apps: [
            app("com.example.a", items: [item(0, frame: CGRect(x: 100, y: 0, width: 30, height: 31))]),
            app("com.example.b", pid: 2, items: [item(0, frame: CGRect(x: 200, y: 0, width: 30, height: 31))]),
        ])
        #expect(OverflowAnalysis.overflowed(in: snapshot).isEmpty)
    }

    @Test func withoutAChevronOnlyTheFramelessAreOverflowed() {
        let snapshot = snapshot(apps: [
            app("com.example.a", items: [item(0, frame: CGRect(x: 1005, y: 2, width: 20, height: 27)), item(1, frame: nil)]),
        ])
        #expect(OverflowAnalysis.overflowed(in: snapshot) == [ExtraItemRef(bundleID: "com.example.a", index: 1)])
    }

    @Test func aFrameWithNoAreaCountsAsNone() {
        let snapshot = snapshot(apps: [app("com.example.a", items: [item(0, frame: CGRect(x: 5, y: 5, width: 0, height: 0))])])
        #expect(OverflowAnalysis.overflowed(in: snapshot) == [ExtraItemRef(bundleID: "com.example.a", index: 0)])
    }

    @Test func aFramelessSlotWithAnOwnerIsOverflowedByItsOwnersIndex() {
        // The app lists no items of its own, but a slot of it has no frame: it is the app's first.
        let slot = AgentSlot(frame: nil, identifier: "com.example.a.item", role: nil, subrole: nil, description: nil,
                             ownerPID: 7, isOverflowChevron: false)
        let snapshot = snapshot(slots: [chevronSlot(), slot], apps: [app("com.example.a", pid: 7, items: [])])
        #expect(OverflowAnalysis.overflowed(in: snapshot) == [ExtraItemRef(bundleID: "com.example.a", index: 0)])
    }

    @Test func aSlotThatItsAppAlreadyAccountsForIsNotCountedTwice() {
        let slot = AgentSlot(frame: nil, identifier: "com.example.a.item", role: nil, subrole: nil, description: nil,
                             ownerPID: 7, isOverflowChevron: false)
        let snapshot = snapshot(slots: [slot], apps: [app("com.example.a", pid: 7, items: [item(0, frame: nil)])])
        #expect(OverflowAnalysis.overflowed(in: snapshot) == [ExtraItemRef(bundleID: "com.example.a", index: 0)])
    }

    @Test func theChevronItselfIsNeverOverflowed() {
        let snapshot = snapshot(slots: [chevronSlot()], apps: [])
        #expect(OverflowAnalysis.overflowed(in: snapshot).isEmpty)
    }

    @Test func anExtraRefIsCodable() throws {
        let ref = ExtraItemRef(bundleID: "com.example.a", index: 3)
        #expect(try JSONDecoder().decode(ExtraItemRef.self, from: JSONEncoder().encode(ref)) == ref)
    }
}
