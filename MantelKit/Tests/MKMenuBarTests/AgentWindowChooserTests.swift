import CoreGraphics
import Foundation
import MKCore
import MKTestSupport
import Testing

@testable import MKMenuBar

@Suite("Agent window chooser", .timeLimit(.minutes(1)))
struct AgentWindowChooserTests {
    private let mainBar = CGRect(x: 0, y: 0, width: 3360, height: 30)
    private let portraitBar = CGRect(x: -1800, y: -491, width: 1800, height: 30)
    private let slots = [CGRect(x: 3000, y: 0, width: 40, height: 30), CGRect(x: 3100, y: 0, width: 50, height: 30),
                         CGRect(x: 3200, y: 0, width: 80, height: 30)]

    private func window(_ index: Int, _ frame: CGRect?, slots: [CGRect?]) -> AgentWindowRead {
        AgentWindowRead(index: index, frame: frame, slotFrames: slots)
    }

    @Test func onePerDisplay() {
        // Five windows for each display, as MenuBarAgent has when five Spaces were visited.
        var windows: [AgentWindowRead] = []
        for index in 0..<10 {
            let isMain = index.isMultiple(of: 2)
            windows.append(window(index, isMain ? mainBar : portraitBar, slots: isMain ? slots : slots.map { $0.offsetBy(dx: -3360, dy: -491) }))
        }
        let chosen = AgentWindowChooser.choose(windows, layout: .desk)
        #expect(chosen.map(\.displayUUID) == [DisplayFixtures.deskMain.uuid, DisplayFixtures.deskPortrait.uuid], "in the order of the layout")
        #expect(chosen.map(\.index) == [0, 1], "the first of each display's windows")
        #expect(chosen.map(\.frame) == [mainBar, portraitBar])
        #expect(chosen.allSatisfy { !$0.isAmbiguous })
    }

    @Test func severalWindowsWithTheSameSlotsTakeTheFirstAndAreNotAmbiguous() {
        // The recorded case: MenuBarAgent keeps a window for every Space, nothing tells the active one apart, and they all show the same
        // slots at the same places. The first in Accessibility's order is taken, and it is not a doubt.
        let windows = [window(3, mainBar, slots: slots), window(0, mainBar, slots: slots.reversed()),
                       window(7, mainBar, slots: slots.shuffled()), window(2, mainBar, slots: slots)]
        let chosen = AgentWindowChooser.choose(windows, layout: .desk)
        #expect(chosen.count == 1)
        #expect(chosen.first?.index == 3, "the first listed, whatever its number")
        #expect(chosen.first?.isAmbiguous == false)
        #expect(chosen.first?.candidates == [3, 0, 7, 2], "all of them, in the order they are listed: which has the identifiers is another matter")
    }

    @Test func windowsThatShowDifferentSlotsAreAmbiguous() {
        // One of the display's windows has a slot that is somewhere else (or wider): which is on screen isn't told.
        let moved = slots.enumerated().map { $0.offset == 1 ? CGRect(x: 3110, y: 0, width: 50, height: 30) : $0.element }
        let wider = slots.enumerated().map { $0.offset == 2 ? CGRect(x: 3200, y: 0, width: 90, height: 30) : $0.element }
        let fewer = Array(slots.dropLast())
        for other in [moved, wider, fewer] {
            let chosen = AgentWindowChooser.choose([window(0, mainBar, slots: slots), window(1, mainBar, slots: other)], layout: .desk)
            #expect(chosen.first?.index == 0, "the first is taken")
            #expect(chosen.first?.isAmbiguous == true)
        }
        // A difference of under half a point is no difference.
        let jitter = slots.map { $0.offsetBy(dx: 0.25, dy: 0) }
        #expect(AgentWindowChooser.choose([window(0, mainBar, slots: slots), window(1, mainBar, slots: jitter)], layout: .desk).first?.isAmbiguous == false)
        // Slots with no frame are not compared.
        #expect(AgentWindowChooser.choose([window(0, mainBar, slots: slots + [nil]), window(1, mainBar, slots: slots)], layout: .desk)
            .first?.isAmbiguous == false)
    }

    @Test func theWindowWhoseSlotsHaveTheMostNamesOfTheirOwnIsTaken() {
        // Seen after a change of displays: the windows of the Spaces that aren't on screen give every slot of an app its first item's
        // name, and the one on screen names each slot its own. Of windows whose names were read, the one with the most names of its own is
        // used, and the first listed of those that have as many.
        func named(_ index: Int, _ count: Int?) -> AgentWindowRead {
            AgentWindowRead(index: index, frame: mainBar, slotFrames: slots, uniqueNameCount: count)
        }
        let chosen = AgentWindowChooser.choose([named(0, 6), named(1, 12), named(2, 12), named(3, 6)], layout: .desk)
        #expect(chosen.first?.index == 1)
        #expect(chosen.first?.candidates == [1, 0, 2, 3], "the one used first, then the others as they are listed")
        // Where the names weren't read, the first is the one.
        #expect(AgentWindowChooser.choose([named(0, nil), named(1, nil)], layout: .desk).first?.index == 0)
    }

    /// A fake MenuBarAgent with one window on the main display per entry: the clock, and a slot of 40 points for each name, at its x.
    private func agentWithWindows(_ windows: [[(name: String?, x: CGFloat)]]) -> FakeAX {
        let ax = FakeAX()
        for slots in windows {
            let window = ax.addAgentWindow(agent: 50, frame: mainBar)
            ax.addSlot(in: window, identifier: "com.apple.menuextra.clock", frame: CGRect(x: 3268, y: 0, width: 80, height: 30))
            for slot in slots { ax.addSlot(in: window, identifier: slot.name, frame: CGRect(x: slot.x, y: 0, width: 40, height: 30)) }
        }
        return ax
    }

    @Test func theQuickReadPassesOverAWindowThatRepeatsItsNames() async {
        // Seen after a change of displays: the first window listed is a Space's that isn't on screen. It has the app's slots where they
        // were, and gives both its first item's name. The quick read goes on to the window that names each slot its own.
        let reader = AgentWindowReader(ax: agentWithWindows([[("weather.temp", 3000), ("weather.temp", 3040)],
                                                             [("weather.temp", 3100), ("weather.alerts", 3140)]]))
        let agent = RunningApp.fake(50, MenuBarReader.menuBarAgentBundleID)
        let read = await reader.readBar(agent: agent, layout: .desk, display: DisplayFixtures.deskMain.uuid, preferring: nil)
        #expect(read?.index == 1)
        #expect(read?.bar.slots.compactMap(\.frame?.minX).contains(3140) == true, "the slots where they are now")
        // A memory of the window that lags doesn't make it the one.
        let remembered = await reader.readBar(agent: agent, layout: .desk, display: DisplayFixtures.deskMain.uuid, preferring: 0)
        #expect(remembered?.index == 1)
    }

    @Test func aWindowBelongsToTheDisplayItsTopLeftCornerIsOn() {
        // On the laptop with the lid open, its bar is at CoreGraphics (3360, 773).
        let layout = DisplayLayout.deskWithLaptopOpen
        let laptopBar = CGRect(x: 3360, y: 773, width: 1728, height: 33)
        let chosen = AgentWindowChooser.choose([window(0, laptopBar, slots: slots), window(1, mainBar, slots: slots)], layout: layout)
        #expect(chosen.map(\.displayUUID) == [DisplayFixtures.deskMain.uuid, DisplayFixtures.laptopRightOfDesk.uuid])
    }
}
