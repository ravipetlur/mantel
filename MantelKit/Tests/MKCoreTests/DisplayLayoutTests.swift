import CoreGraphics
import Foundation
import MKCore
import MKTestSupport
import Testing

@testable import MKCore

@Suite("DisplayLayout")
struct DisplayLayoutTests {
    private let deskMain = DisplayFixtures.deskMain
    private let portrait = DisplayFixtures.deskPortrait

    // MARK: AppKit ⇄ CoreGraphics

    @Test func lgPortraitConvertsBothWays() {
        let layout = DisplayLayout.desk
        // The main display is 1890 points high, so the portrait display, whose AppKit frame tops out at y = 2381,
        // starts 491 points above the top of the main display in CoreGraphics (y down): -491.
        let cg = layout.cgRect(fromAppKit: portrait.frame)
        #expect(cg == CGRect(x: -1800, y: -491, width: 1800, height: 3200))
        #expect(layout.appKitRect(fromCG: cg) == portrait.frame)
    }

    @Test func pointsConvertAboutTheMainDisplaysHeight() {
        let layout = DisplayLayout.desk
        #expect(layout.cgPoint(fromAppKit: CGPoint(x: 100, y: 1890)) == CGPoint(x: 100, y: 0))
        #expect(layout.cgPoint(fromAppKit: CGPoint(x: -900, y: -819)) == CGPoint(x: -900, y: 2709))
        #expect(layout.appKitPoint(fromCG: CGPoint(x: -900, y: 2709)) == CGPoint(x: -900, y: -819))
        let point = CGPoint(x: 1234.5, y: 678.25)
        #expect(layout.appKitPoint(fromCG: layout.cgPoint(fromAppKit: point)) == point)
    }

    @Test func rectsOnTheMainDisplayFlipWithinIt() {
        let layout = DisplayLayout.desk
        // The menu bar strip is at the top in AppKit and at y = 0 in CoreGraphics.
        let strip = layout.menuBarStrip(of: deskMain)
        #expect(layout.cgRect(fromAppKit: strip) == CGRect(x: 0, y: 0, width: 3360, height: 31))
        #expect(layout.cgRect(fromAppKit: deskMain.frame) == CGRect(x: 0, y: 0, width: 3360, height: 1890))
    }

    @Test func conversionAxisIsTheMainDisplaysHeightWhateverTheOrder() {
        // The laptop (982 high) is listed first and is not at the origin; the axis is still the 1890-point main one.
        let shuffled = DisplayLayout(displays: [DisplayFixtures.laptopRightOfDesk, portrait, deskMain])
        #expect(shuffled.cgRect(fromAppKit: portrait.frame) == CGRect(x: -1800, y: -491, width: 1800, height: 3200))
        #expect(shuffled.cgPoint(fromAppKit: CGPoint(x: 10, y: 10)) == CGPoint(x: 10, y: 1880))
    }

    @Test func conversionOnTheLaptopAloneUsesTheLaptopsHeight() {
        let layout = DisplayLayout.laptop
        #expect(layout.cgPoint(fromAppKit: CGPoint(x: 5, y: 982)) == CGPoint(x: 5, y: 0))
        #expect(layout.cgRect(fromAppKit: DisplayFixtures.laptopAlone.notch!)
            == CGRect(x: 663, y: 0, width: 186, height: 32))
    }

    // MARK: The main display

    @Test func mainIsOriginDisplayNotKeyScreen() throws {
        // `NSScreen.main` follows the key window, so the layout never asks for it: the main display is the one whose
        // frame starts at (0, 0), wherever it is in the list.
        let shuffled = DisplayLayout(displays: [DisplayFixtures.laptopRightOfDesk, portrait, deskMain])
        let main = try #require(shuffled.main)
        #expect(main.uuid == deskMain.uuid)
        #expect(main.frame.origin == .zero)
        #expect(shuffled.displays.filter(\.isMain).map(\.uuid) == [deskMain.uuid])

        // The laptop is a built-in display but only the main one when it sits at the origin.
        #expect(DisplayLayout.laptop.main?.uuid == DisplayFixtures.laptopAlone.uuid)
        #expect(DisplayLayout.deskWithLaptopOpen.main?.uuid == deskMain.uuid)
    }

    @Test func noDisplaysMeansNoMain() {
        let layout = DisplayLayout(displays: [])
        #expect(layout.main == nil)
        #expect(layout.display(containing: .zero) == nil)
        #expect(layout.fingerprint.uuids.isEmpty)
    }

    // MARK: Fingerprints

    @Test func fingerprintIgnoresOrder() {
        let forward = DisplayLayout.desk.fingerprint
        let backward = DisplayLayout(displays: [portrait, deskMain]).fingerprint
        #expect(forward == backward)
        #expect(forward.hashValue == backward.hashValue)
        #expect(forward.uuids == [portrait.uuid, deskMain.uuid].sorted())
        #expect(forward.uuids == forward.uuids.sorted())
    }

    @Test func fingerprintChangesWithTheSetOfDisplays() {
        #expect(DisplayLayout.desk.fingerprint != DisplayLayout.deskWithLaptopOpen.fingerprint)
        #expect(DisplayLayout.desk.fingerprint != DisplayLayout.laptop.fingerprint)
        #expect(Set([DisplayLayout.desk.fingerprint, DisplayLayout(displays: [portrait, deskMain]).fingerprint]).count == 1)
    }

    @Test func fingerprintIgnoresWhereDisplaysAre() {
        // The same displays arranged differently are the same fingerprint: a layout of items belongs to the set of
        // screens, not to their arrangement.
        let moved = DisplayInfo(uuid: DisplayFixtures.laptopAlone.uuid, name: "Built-in Retina Display",
                                frame: CGRect(x: -1512, y: 0, width: 1512, height: 982),
                                visibleFrame: CGRect(x: -1512, y: 0, width: 1512, height: 950),
                                scale: 2, notch: nil, isBuiltIn: true, isMain: false)
        let left = DisplayLayout(displays: [deskMain, moved])
        let right = DisplayLayout(displays: [deskMain, DisplayFixtures.laptopRightOfDesk])
        #expect(left.fingerprint == right.fingerprint)
    }

    @Test func fingerprintDecodesSorted() throws {
        let json = Data(#"{"uuids":["B","A","C"]}"#.utf8)
        let decoded = try JSONDecoder().decode(DisplayFingerprint.self, from: json)
        #expect(decoded.uuids == ["A", "B", "C"])
        #expect(decoded == DisplayFingerprint(uuids: ["C", "A", "B"]))
    }

    // MARK: Finding a display

    @Test func displayContainingPointOnEachScreenAndInGaps() {
        let layout = DisplayLayout.deskWithLaptopOpen
        // On each screen.
        #expect(layout.display(containing: CGPoint(x: 1680, y: 945))?.uuid == deskMain.uuid)
        #expect(layout.display(containing: CGPoint(x: -900, y: 781))?.uuid == portrait.uuid)
        #expect(layout.display(containing: CGPoint(x: 4116, y: 491))?.uuid == DisplayFixtures.laptopRightOfDesk.uuid)
        // The portrait display reaches above and below the main one; the strip beside the laptop does not.
        #expect(layout.display(containing: CGPoint(x: -100, y: 2300))?.uuid == portrait.uuid)
        #expect(layout.display(containing: CGPoint(x: -100, y: -800))?.uuid == portrait.uuid)
        // In the gaps: above the main display and the laptop, below the main one, left of the portrait one, right of
        // the laptop, and above the laptop, right of the main display.
        #expect(layout.display(containing: CGPoint(x: 1000, y: 2000)) == nil)
        #expect(layout.display(containing: CGPoint(x: 1000, y: -100)) == nil)
        #expect(layout.display(containing: CGPoint(x: -2000, y: 0)) == nil)
        #expect(layout.display(containing: CGPoint(x: 5000, y: 500)) == nil)
        #expect(layout.display(containing: CGPoint(x: 3400, y: 1500)) == nil)
        // Without the laptop, the same point beside the main display is a gap too.
        #expect(DisplayLayout.desk.display(containing: CGPoint(x: 3500, y: 500)) == nil)
    }

    @Test func sharedEdgesBelongToOneDisplayWhicheverOrderTheyAreListed() {
        // x = 0 is where the portrait display ends and the main one begins; x = 3360 where the main one ends and the
        // laptop begins. Each point belongs to the display on its right whatever the order of the list.
        let forward = DisplayLayout.deskWithLaptopOpen
        let backward = DisplayLayout(displays: forward.displays.reversed())
        for layout in [forward, backward] {
            #expect(layout.display(containing: CGPoint(x: 0, y: 500))?.uuid == deskMain.uuid)
            #expect(layout.display(containing: CGPoint(x: -0.5, y: 500))?.uuid == portrait.uuid)
            #expect(layout.display(containing: CGPoint(x: 3360, y: 500))?.uuid == DisplayFixtures.laptopRightOfDesk.uuid)
            #expect(layout.display(containing: CGPoint(x: 3359.5, y: 500))?.uuid == deskMain.uuid)
        }
    }

    @Test func theTopRowOfADisplayIsItsOwn() {
        // With the pointer at the very top of the screen, `NSEvent.mouseLocation` is y = frame.maxY: the menu bar's
        // top row is on the display, not above it.
        let layout = DisplayLayout.deskWithLaptopOpen
        #expect(layout.display(containing: CGPoint(x: 1000, y: 1890))?.uuid == deskMain.uuid)
        #expect(layout.display(containing: CGPoint(x: 4000, y: 982))?.uuid == DisplayFixtures.laptopRightOfDesk.uuid)
        #expect(layout.display(containing: CGPoint(x: -900, y: 2381))?.uuid == portrait.uuid)
    }

    @Test func theEdgeBetweenStackedDisplaysIsTheLowerOnesTopRow() {
        // One display above another: the shared line y = 800 is, in CoreGraphics, the first row of the lower display
        // (the upper one ends just above it), so a pointer there is on the lower display.
        func display(_ uuid: String, _ frame: CGRect, isMain: Bool) -> DisplayInfo {
            DisplayInfo(uuid: uuid, name: uuid, frame: frame, visibleFrame: frame, scale: 2, notch: nil,
                        isBuiltIn: false, isMain: isMain)
        }
        let lower = display("LOWER", CGRect(x: 0, y: 0, width: 1000, height: 800), isMain: true)
        let upper = display("UPPER", CGRect(x: 0, y: 800, width: 1000, height: 600), isMain: false)
        for layout in [DisplayLayout(displays: [lower, upper]), DisplayLayout(displays: [upper, lower])] {
            #expect(layout.display(containing: CGPoint(x: 500, y: 800))?.uuid == "LOWER")
            #expect(layout.display(containing: CGPoint(x: 500, y: 800.5))?.uuid == "UPPER")
            #expect(layout.display(containing: CGPoint(x: 500, y: 1400))?.uuid == "UPPER")
            #expect(layout.cgPoint(fromAppKit: CGPoint(x: 500, y: 800)) == CGPoint(x: 500, y: 0))
        }
    }

    @Test func pointsOnTheOuterEdgeOfTheLayoutStillFindTheirDisplay() {
        let layout = DisplayLayout.desk
        // The right and bottom edges of a frame are outside its half-open area, but where no other display takes over
        // they still resolve to the display they are the edge of.
        #expect(layout.display(containing: CGPoint(x: 3360, y: 1000))?.uuid == deskMain.uuid)
        #expect(layout.display(containing: CGPoint(x: 1000, y: 0))?.uuid == deskMain.uuid)
        #expect(layout.display(containing: CGPoint(x: 3360, y: 0))?.uuid == deskMain.uuid)
        #expect(layout.display(containing: CGPoint(x: -1800, y: -819))?.uuid == portrait.uuid)
    }

    @Test func displayByUUID() {
        let layout = DisplayLayout.deskWithLaptopOpen
        #expect(layout.display(uuid: portrait.uuid) == portrait)
        #expect(layout.display(uuid: DisplayFixtures.laptopAlone.uuid) == DisplayFixtures.laptopRightOfDesk)
        #expect(layout.display(uuid: "00000000-0000-0000-0000-000000000000") == nil)
    }

    // MARK: Menu bar

    @Test func menuBarHeightOfMainIs31() throws {
        let layout = DisplayLayout.desk
        let main = try #require(layout.main)
        #expect(layout.menuBarHeight(of: main) == 31)
        #expect(layout.menuBarStrip(of: main) == CGRect(x: 0, y: 1859, width: 3360, height: 31))
    }

    @Test func menuBarOfTheNotchedLaptopIsAsTallAsItsNotch() throws {
        let layout = DisplayLayout.deskWithLaptopOpen
        let laptop = DisplayFixtures.laptopRightOfDesk
        #expect(layout.menuBarHeight(of: laptop) == 32)
        let strip = layout.menuBarStrip(of: laptop)
        #expect(strip == CGRect(x: 3360, y: 950, width: 1512, height: 32))
        let notch = try #require(laptop.notch)
        #expect(strip.contains(notch))
    }

    @Test func noMenuBarStripWhenVisibleFrameIsFull() {
        // The portrait display reports no menu bar: nothing is drawn on it, or it is hidden, and there is nothing to
        // hide items on.
        let layout = DisplayLayout.desk
        #expect(portrait.visibleFrame == portrait.frame)
        #expect(layout.menuBarHeight(of: portrait) == 0)
        #expect(layout.menuBarStrip(of: portrait) == .zero)
    }

    @Test func aVisibleFrameAboveTheFrameIsNoMenuBarEither() {
        let odd = DisplayInfo(uuid: "ODD", name: "Odd", frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                              visibleFrame: CGRect(x: 0, y: 0, width: 100, height: 120), scale: 1, notch: nil,
                              isBuiltIn: false, isMain: true)
        let layout = DisplayLayout(displays: [odd])
        #expect(layout.menuBarHeight(of: odd) == 0)
        #expect(layout.menuBarStrip(of: odd) == .zero)
    }

    // MARK: The notch

    @Test func notchRectComesFromAuxiliaryAreas() {
        // The 14-inch laptop: the menu bar is 32 points high; 663 points are free on the left of the camera housing
        // and 663 on the right, so the notch is the 186 points between them.
        let notch = DisplayInfo.notchRect(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982), safeAreaTop: 32,
            auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 663, height: 32),
            auxiliaryTopRight: CGRect(x: 849, y: 950, width: 663, height: 32))
        #expect(notch == CGRect(x: 663, y: 950, width: 186, height: 32))
        #expect(notch == DisplayLayout.laptop.displays.first?.notch)
    }

    @Test func notchRectFollowsTheDisplayWhereverItIs() {
        // The laptop right of the desk: the same notch, 3360 points over.
        let notch = DisplayInfo.notchRect(
            frame: CGRect(x: 3360, y: 0, width: 1512, height: 982), safeAreaTop: 32,
            auxiliaryTopLeft: CGRect(x: 3360, y: 950, width: 663, height: 32),
            auxiliaryTopRight: CGRect(x: 4209, y: 950, width: 663, height: 32))
        #expect(notch == DisplayFixtures.laptopRightOfDesk.notch)
    }

    @Test func noNotchWithoutASafeAreaOrBothAuxiliaryAreas() {
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let left = CGRect(x: 0, y: 950, width: 663, height: 32)
        let right = CGRect(x: 849, y: 950, width: 663, height: 32)
        #expect(DisplayInfo.notchRect(frame: frame, safeAreaTop: 0, auxiliaryTopLeft: left, auxiliaryTopRight: right) == nil)
        #expect(DisplayInfo.notchRect(frame: frame, safeAreaTop: 32, auxiliaryTopLeft: nil, auxiliaryTopRight: right) == nil)
        #expect(DisplayInfo.notchRect(frame: frame, safeAreaTop: 32, auxiliaryTopLeft: left, auxiliaryTopRight: nil) == nil)
        #expect(DisplayInfo.notchRect(frame: frame, safeAreaTop: 32, auxiliaryTopLeft: nil, auxiliaryTopRight: nil) == nil)
        // An empty area counts as none.
        #expect(DisplayInfo.notchRect(frame: frame, safeAreaTop: 32, auxiliaryTopLeft: .zero, auxiliaryTopRight: right) == nil)
        // Areas that leave no gap between them are no notch.
        let overlapping = CGRect(x: 600, y: 950, width: 663, height: 32)
        #expect(DisplayInfo.notchRect(frame: frame, safeAreaTop: 32, auxiliaryTopLeft: left, auxiliaryTopRight: overlapping) == nil)
    }

    // MARK: Fixtures and Codable

    @Test func fixturesAreTheRecordedLayouts() {
        #expect(DisplayLayout.desk.displays.map(\.name) == ["U32J59x", "LG HDR 4K"])
        #expect(DisplayLayout.desk.displays.allSatisfy { $0.notch == nil && !$0.isBuiltIn })
        #expect(DisplayLayout.laptop.displays.map(\.isBuiltIn) == [true])
        let open = DisplayLayout.deskWithLaptopOpen
        #expect(open.displays.count == 3)
        let laptop = DisplayFixtures.laptopRightOfDesk
        #expect(laptop.frame == CGRect(x: 3360, y: 0, width: 1512, height: 982))
        #expect(laptop.visibleFrame == CGRect(x: 3360, y: 0, width: 1512, height: 950))
        #expect(laptop.notch == CGRect(x: 4023, y: 950, width: 186, height: 32))
        #expect(!laptop.isMain)
    }

    @Test func codableRoundTrip() throws {
        for layout in [DisplayLayout.desk, .laptop, .deskWithLaptopOpen, DisplayLayout(displays: [])] {
            let data = try JSONEncoder().encode(layout)
            let decoded = try JSONDecoder().decode(DisplayLayout.self, from: data)
            #expect(decoded == layout)
            #expect(decoded.fingerprint == layout.fingerprint)
        }
        // A display without a notch has no notch key, and one with a notch keeps its rectangle.
        let withNotch = try JSONDecoder().decode(DisplayInfo.self, from: JSONEncoder().encode(DisplayFixtures.laptopAlone))
        #expect(withNotch.notch == CGRect(x: 663, y: 950, width: 186, height: 32))
        let withoutNotch = try JSONDecoder().decode(DisplayInfo.self, from: JSONEncoder().encode(deskMain))
        #expect(withoutNotch.notch == nil)
    }
}
