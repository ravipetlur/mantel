import CoreGraphics
import Foundation
import MKCore
import MKTestSupport
import Testing

@testable import MKMenuBar

@Suite("Names that slots carry", .timeLimit(.minutes(1)))
struct AgentWindowReaderNamesTests {
    @Test func aChildsIdentifierIsNotASlotNameUnlessItIsASystemModule() async throws {
        // A slot that has no identifier of its own may carry the one of a view inside it: an updater's window, a panel. That is the app's
        // view and not the item's name. The clock's slot, whose identifier is on a child, is still the clock's.
        let ax = FakeAX()
        let window = ax.addAgentWindow(agent: 50, frame: CGRect(x: 0, y: 0, width: 3360, height: 30))
        ax.addSlot(in: window, childIdentifier: "x.update-alert", frame: CGRect(x: 3000, y: 0, width: 40, height: 30))
        ax.addSlot(in: window, identifier: "x.own", childIdentifier: "x.other", frame: CGRect(x: 3050, y: 0, width: 40, height: 30))
        ax.addSlot(in: window, childIdentifier: "com.apple.menuextra.clock", frame: CGRect(x: 3300, y: 0, width: 50, height: 30))

        let reader = AgentWindowReader(ax: ax)
        let agent = RunningApp.fake(50, MenuBarReader.menuBarAgentBundleID)
        let read = try #require(await reader.readBar(agent: agent, layout: .desk, display: DisplayFixtures.deskMain.uuid, preferring: nil))
        let names = Dictionary(uniqueKeysWithValues: read.bar.slots.compactMap { slot in slot.frame.map { ($0.minX, slot.identifier) } })
        #expect(names[3000] == .some(nil), "a view's name is no name")
        #expect(names[3050] == "x.own", "the slot's own is kept")
        #expect(names[3300] == "com.apple.menuextra.clock", "a system module's, from a child")
    }

    @Test func aWindowWhoseOnlyNamesAreChildrensDoesNotWinTheChoice() async throws {
        // D2 changed what the chooser counts: the names a window's slots carry, and not its slots' views' names (an updater's window, a
        // panel). Two windows of one display: the first has three slots with a view's name each, and the second has one slot with a name of its
        // own. Counted by the names the slots carry, the second has more, and it is the one that is read.
        let ax = FakeAX()
        let frame = CGRect(x: 0, y: 0, width: 3360, height: 30)
        let views = ax.addAgentWindow(agent: 50, frame: frame)
        for (place, name) in ["x.view-one", "x.view-two", "x.view-three"].enumerated() {
            ax.addSlot(in: views, childIdentifier: name, frame: CGRect(x: 3000 + 50 * CGFloat(place), y: 0, width: 40, height: 30))
        }
        let named = ax.addAgentWindow(agent: 50, frame: frame)
        ax.addSlot(in: named, identifier: "x.own", frame: CGRect(x: 3000, y: 0, width: 40, height: 30))

        let reader = AgentWindowReader(ax: ax)
        let agent = RunningApp.fake(50, MenuBarReader.menuBarAgentBundleID)
        let read = await reader.read(agent: agent, layout: .desk, plan: .allWindows)
        let slots = try #require(read.bars.first).slots
        #expect(slots.map(\.identifier) == ["x.own"], "the window whose slots are named")
        #expect(AgentWindowReader.identifierCount(slots) == 1)
    }
}
