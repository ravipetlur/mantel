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

    @Test func windowsThatWereNotReadForTheirSlotsAreNotCompared() {
        // A read that didn't look at the slots of every window has nothing to compare: it is no doubt.
        let chosen = AgentWindowChooser.choose([window(0, mainBar, slots: []), window(1, mainBar, slots: []), window(2, mainBar, slots: [])],
                                               layout: .desk)
        #expect(chosen.first?.index == 0)
        #expect(chosen.first?.isAmbiguous == false)
        #expect(chosen.first?.candidates == [0, 1, 2])
    }

    @Test func portraitDisplayHasABar() {
        // The portrait display reports no menu bar in its visible frame (it is its frame), but MenuBarAgent has a window on it.
        #expect(DisplayFixtures.deskPortrait.visibleFrame == DisplayFixtures.deskPortrait.frame)
        let chosen = AgentWindowChooser.choose([window(0, portraitBar, slots: slots)], layout: .desk)
        #expect(chosen.map(\.displayUUID) == [DisplayFixtures.deskPortrait.uuid])
        #expect(chosen.first?.frame == portraitBar)
    }

    @Test func aDisplayWithNoWindowHasNoBar() {
        let chosen = AgentWindowChooser.choose([window(0, mainBar, slots: slots)], layout: .desk)
        #expect(chosen.map(\.displayUUID) == [DisplayFixtures.deskMain.uuid])
    }

    @Test func windowOffEveryDisplayIsIgnored() {
        let nowhere = CGRect(x: 9000, y: 9000, width: 100, height: 30)
        let chosen = AgentWindowChooser.choose([window(0, nowhere, slots: slots), window(1, nil, slots: slots), window(2, .zero, slots: [])],
                                               layout: .desk)
        #expect(chosen.isEmpty)
        // And one that is on a display is still found among them.
        let found = AgentWindowChooser.choose([window(0, nowhere, slots: slots), window(1, mainBar, slots: slots)], layout: .desk)
        #expect(found.map(\.index) == [1])
    }

    @Test func aWindowBelongsToTheDisplayItsTopLeftCornerIsOn() {
        // On the laptop with the lid open, its bar is at CoreGraphics (3360, 773).
        let layout = DisplayLayout.deskWithLaptopOpen
        let laptopBar = CGRect(x: 3360, y: 773, width: 1728, height: 33)
        let chosen = AgentWindowChooser.choose([window(0, laptopBar, slots: slots), window(1, mainBar, slots: slots)], layout: layout)
        #expect(chosen.map(\.displayUUID) == [DisplayFixtures.deskMain.uuid, DisplayFixtures.laptopRightOfDesk.uuid])
    }
}
