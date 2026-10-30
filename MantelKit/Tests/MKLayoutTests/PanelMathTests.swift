import CoreGraphics
import Foundation
import MKCore
import Testing

@testable import MKLayout

/// The arithmetic of Mantel's floating panels.
@Suite("Panel math", .timeLimit(.minutes(1)))
struct PanelMathTests {
    private func near(_ one: CGPoint, _ other: CGPoint) -> Bool {
        abs(one.x - other.x) < 1e-9 && abs(one.y - other.y) < 1e-9
    }

    // MARK: The command bar

    @Test func commandBarCentredTwentyTwoPercentDown() {
        let screen = CGRect(x: 100, y: 50, width: 1500, height: 1000)
        let frame = PanelMath.commandBarFrame(screen: screen)
        #expect(frame.width == 560)
        #expect(abs(frame.midX - screen.midX) < 1e-9)
        // 22 % of 1000 down from the screen's top edge, which is its smallest y in CoreGraphics' coordinates.
        #expect(abs(frame.minY - 270) < 1e-9)
        // With eight rows showing: the field, the divider, the rows and the footer.
        #expect(frame.height == PanelMath.commandBarFieldHeight + PanelMath.commandBarDividerHeight + 8 * 36 + PanelMath.commandBarFooterHeight)
        #expect(frame.maxY < screen.maxY)

        // A screen whose origin is left of the main one's (a display placed to the left) is centred in its own place.
        let left = PanelMath.commandBarFrame(screen: CGRect(x: -1920, y: 0, width: 1920, height: 1080))
        #expect(abs(left.minX - (-1240)) < 1e-9)
        #expect(abs(left.minY - 237.6) < 1e-9)
    }

    @Test func commandBarKeepsItsTopAsResultsComeAndGo() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let full = PanelMath.commandBarFrame(screen: screen)
        for count in [0, 1, 5, 8, 12] {
            let frame = PanelMath.commandBarFrame(screen: screen, results: count)
            #expect(frame.minY == full.minY && frame.minX == full.minX && frame.width == full.width, "\(count)")
        }
        // No result: the field alone. Twelve results scroll in the eight rows.
        #expect(PanelMath.commandBarFrame(screen: screen, results: 0).height == PanelMath.commandBarFieldHeight)
        #expect(PanelMath.commandBarFrame(screen: screen, results: 12).height == full.height)
        #expect(PanelMath.commandBarFrame(screen: screen, results: 3).height
            == PanelMath.commandBarFieldHeight + PanelMath.commandBarDividerHeight + 3 * 36 + PanelMath.commandBarFooterHeight)
    }

    @Test func thePointerOpensNoPanelWhileTheCommandBarIsOpen() {
        let group = MantelPanel.group(GroupID(rawValue: "0a1b2c3d"))
        #expect(PanelMath.pointerOpensPanels(open: []))
        #expect(PanelMath.pointerOpensPanels(open: [.secondBar]))
        #expect(PanelMath.pointerOpensPanels(open: [.secondBar, group]))
        #expect(!PanelMath.pointerOpensPanels(open: [.commandBar]))
        #expect(!PanelMath.pointerOpensPanels(open: [.commandBar, group]))
    }

    // MARK: Gradient

    @Test func gradientZeroIsLeftToRight() {
        let line = PanelMath.gradientPoints(angle: 0)
        #expect(near(line.start, CGPoint(x: 0, y: 0.5)))
        #expect(near(line.end, CGPoint(x: 1, y: 0.5)))
    }

    @Test func gradientNinetyIsTopToBottom() {
        let line = PanelMath.gradientPoints(angle: 90)
        #expect(near(line.start, CGPoint(x: 0.5, y: 0)))
        #expect(near(line.end, CGPoint(x: 0.5, y: 1)))
        // Clockwise: 180 runs right to left and 270 bottom to top.
        #expect(near(PanelMath.gradientPoints(angle: 180).start, CGPoint(x: 1, y: 0.5)))
        #expect(near(PanelMath.gradientPoints(angle: 270).start, CGPoint(x: 0.5, y: 1)))
        // A diagonal runs from one corner to the other.
        let diagonal = PanelMath.gradientPoints(angle: 45)
        #expect(near(diagonal.start, CGPoint(x: 0, y: 0)))
        #expect(near(diagonal.end, CGPoint(x: 1, y: 1)))
    }

    @Test func gradientAngleWraps() {
        for (angle, same) in [(360, 0), (450, 90), (-90, 270), (-360, 0), (720 + 45, 45)] {
            let line = PanelMath.gradientPoints(angle: angle)
            let expected = PanelMath.gradientPoints(angle: same)
            #expect(near(line.start, expected.start) && near(line.end, expected.end), "\(angle)")
        }
    }

    // MARK: Toast

    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 600)

    @Test func toastBelowRightOfPointer() {
        let frame = PanelMath.toastFrame(size: CGSize(width: 200, height: 40), pointer: CGPoint(x: 300, y: 200), screen: screen)
        #expect(frame == CGRect(x: 312, y: 212, width: 200, height: 40))
    }

    @Test func toastKeptOnScreen() {
        let size = CGSize(width: 200, height: 40)
        // Near the right and bottom edges it is pulled in, 8 points from them.
        let corner = PanelMath.toastFrame(size: size, pointer: CGPoint(x: 990, y: 590), screen: screen)
        #expect(corner == CGRect(x: 1000 - 8 - 200, y: 600 - 8 - 40, width: 200, height: 40))
        // A pointer at the top left of a display that doesn't start at the origin keeps clear of its edge.
        let second = CGRect(x: 1000, y: -200, width: 800, height: 600)
        let top = PanelMath.toastFrame(size: size, pointer: CGPoint(x: 1000, y: -200), screen: second)
        #expect(top.minX >= 1008 && top.minY >= -192)
        // A toast bigger than the room sits at the corner of it.
        let huge = PanelMath.toastFrame(size: CGSize(width: 2000, height: 40), pointer: CGPoint(x: 5, y: 5), screen: screen)
        #expect(huge.minX == 8)
    }

    // MARK: Cells

    private let layout = SecondBarLayout(
        size: CGSize(width: 114, height: 42), rows: 1,
        cellFrames: [CGRect(x: 8, y: 8, width: 30, height: 26), CGRect(x: 42, y: 8, width: 30, height: 26)])

    @Test func cellHitInsideCell() {
        #expect(PanelMath.cell(at: CGPoint(x: 20, y: 20), in: layout) == 0)
        #expect(PanelMath.cell(at: CGPoint(x: 60, y: 9), in: layout) == 1)
    }

    @Test func cellMissBetweenCells() {
        // The gap between the cells, the padding around them and a point past the panel are no cell's.
        #expect(PanelMath.cell(at: CGPoint(x: 40, y: 20), in: layout) == nil)
        #expect(PanelMath.cell(at: CGPoint(x: 3, y: 20), in: layout) == nil)
        #expect(PanelMath.cell(at: CGPoint(x: 20, y: 38), in: layout) == nil)
        #expect(PanelMath.cell(at: CGPoint(x: 500, y: 20), in: layout) == nil)
    }

    // MARK: Which panels are open

    @Test func openingOnePanelClosesTheOthers() {
        let group = MantelPanel.group(GroupID(rawValue: "0a1b2c3d"))
        let other = MantelPanel.group(GroupID(rawValue: "ffffffff"))
        #expect(PanelMath.closes(when: .secondBar, open: [group, .commandBar]) == [group, .commandBar])
        #expect(PanelMath.closes(when: group, open: [.secondBar]) == [.secondBar])
        #expect(PanelMath.closes(when: group, open: [group, other]) == [other])
        #expect(PanelMath.closes(when: .commandBar, open: []).isEmpty)
        #expect(PanelMath.closes(when: .secondBar, open: [.secondBar]).isEmpty)
    }

    // MARK: Clicks and switches

    @Test func clickOnOwnStatusItemIsNotOutside() {
        let panel = CGRect(x: 100, y: 40, width: 300, height: 42)
        let dots = [CGRect(x: 900, y: 0, width: 24, height: 24), CGRect(x: 930, y: 0, width: 24, height: 24)]
        #expect(!PanelMath.isOutsideClick(CGPoint(x: 910, y: 10), panel: panel, ownItemFrames: dots))
        #expect(!PanelMath.isOutsideClick(CGPoint(x: 940, y: 10), panel: panel, ownItemFrames: dots))
    }

    @Test func clickElsewhereIsOutside() {
        let panel = CGRect(x: 100, y: 40, width: 300, height: 42)
        let dots = [CGRect(x: 900, y: 0, width: 24, height: 24)]
        #expect(PanelMath.isOutsideClick(CGPoint(x: 600, y: 300), panel: panel, ownItemFrames: dots))
        #expect(PanelMath.isOutsideClick(CGPoint(x: 600, y: 300), panel: panel, ownItemFrames: []))
        // Inside the panel is not outside.
        #expect(!PanelMath.isOutsideClick(CGPoint(x: 150, y: 60), panel: panel, ownItemFrames: dots))
    }

    @Test func appSwitchClosesUnlessAClickIsInFlight() {
        #expect(PanelMath.closesOnAppSwitch(clickInFlight: false))
        #expect(!PanelMath.closesOnAppSwitch(clickInFlight: true))
    }

    @Test func theActivationATakeoverEndCausesIsNotThePersonLeaving() {
        let now = Date(timeIntervalSince1970: 1_000)
        let until = now.addingTimeInterval(PanelMath.expectedActivationWait)
        // Handed back to an app: that app's activation, within the wait.
        #expect(PanelMath.isExpectedActivation(.app(42), activated: 42, now: now, until: until))
        #expect(!PanelMath.isExpectedActivation(.app(42), activated: 43, now: now, until: until))
        // Mantel stepped back: the next app in line is any app.
        #expect(PanelMath.isExpectedActivation(.nextApp, activated: 43, now: now, until: until))
        // Past the wait, neither is.
        #expect(!PanelMath.isExpectedActivation(.app(42), activated: 42, now: until, until: until))
        #expect(!PanelMath.isExpectedActivation(.nextApp, activated: 43, now: until.addingTimeInterval(1), until: until))
        // A busy Mac's slow hand-back still arrives inside it.
        #expect(PanelMath.isExpectedActivation(.app(42), activated: 42, now: now.addingTimeInterval(2.5), until: until))
    }

    @Test func theSecondBarHotkeyClosesAnOpenBarAndOtherwiseOpensIt() {
        for state in [RevealState.collapsed, .hiddenShown, .allShown, .focusMode] {
            #expect(PanelMath.secondBarHotkey(isOpen: true, state: state) == .close, Comment(rawValue: "\(state)"))
        }
        #expect(PanelMath.secondBarHotkey(isOpen: false, state: .collapsed) == .showHidden)
        #expect(PanelMath.secondBarHotkey(isOpen: false, state: .focusMode) == .showHidden)
        #expect(PanelMath.secondBarHotkey(isOpen: false, state: .allShown) == .showHidden)
        // Hidden already showing on the menu bar: nothing for the machine to change.
        #expect(PanelMath.secondBarHotkey(isOpen: false, state: .hiddenShown) == .openForTheCurrentState)
    }

    @Test func onlyWhatThePersonDidCollapsesTheReveal() {
        for reason in [PanelCloseReason.escape, .outsideClick, .displayChange, .appSwitch, .otherPanel, .hotkey] {
            #expect(reason.collapsesReveal, "\(reason)")
        }
        // An icon's click is sent first and the reveal collapses after it; the others have moved the reveal on already.
        for reason in [PanelCloseReason.dotClick, .iconClick, .revealEnded, .quitting, .hoverEnded] {
            #expect(!reason.collapsesReveal, "\(reason)")
        }
    }

    @Test func onlyTheSecondBarsCloseCollapsesTheReveal() {
        let group = MantelPanel.group(GroupID(rawValue: "0a1b2c3d"))
        for reason in [PanelCloseReason.escape, .outsideClick, .displayChange, .appSwitch, .otherPanel, .hotkey] {
            #expect(PanelMath.collapsesReveal(closed: .secondBar, reason: reason), "\(reason)")
            #expect(!PanelMath.collapsesReveal(closed: group, reason: reason), "a group panel, \(reason)")
            #expect(!PanelMath.collapsesReveal(closed: .commandBar, reason: reason), "the command bar, \(reason)")
        }
        #expect(!PanelMath.collapsesReveal(closed: .secondBar, reason: .iconClick))
    }
}

/// The keys a panel answers to, and the size its pictures draw at.
@Suite("Panel keys and pictures", .timeLimit(.minutes(1)))
struct PanelKeyAndPictureTests {
    @Test func theNavigationKeysMapToTheirBarKeys() {
        #expect(BarKey.forKeyCode(123) == .left)
        #expect(BarKey.forKeyCode(124) == .right)
        #expect(BarKey.forKeyCode(125) == .down)
        #expect(BarKey.forKeyCode(126) == .up)
        #expect(BarKey.forKeyCode(115) == .home)
        #expect(BarKey.forKeyCode(119) == .end)
        #expect(BarKey.forKeyCode(53) == .escape)
    }

    @Test func tabGoesBackwardsWithShift() {
        #expect(BarKey.forKeyCode(48) == .tab(backwards: false))
        #expect(BarKey.forKeyCode(48, shift: true) == .tab(backwards: true))
    }

    @Test func returnTakesItsKindFromTheModifiers() {
        #expect(BarKey.forKeyCode(36) == .returnKey(.left))
        #expect(BarKey.forKeyCode(76) == .returnKey(.left))
        #expect(BarKey.forKeyCode(36, option: true) == .returnKey(.option))
        #expect(BarKey.forKeyCode(36, command: true) == .returnKey(.right))
        #expect(BarKey.forKeyCode(36, option: true, command: true) == .returnKey(.right))
    }

    @Test func otherKeysArePassedOn() {
        for code: UInt16 in [0, 49, 51, 117, 116, 121] {
            #expect(BarKey.forKeyCode(code) == nil, Comment(rawValue: "\(code)"))
        }
    }

    @Test func aPictureIsNeverScaledUp() {
        #expect(PanelMath.imageSize(natural: CGSize(width: 18, height: 18), in: CGSize(width: 40, height: 26)) == CGSize(width: 18, height: 18))
    }

    @Test func aPictureThatIsTooBigIsScaledDownToFit() {
        // 22 points of room high (26 less 2 on each side): a picture 44 high is halved.
        let fitted = PanelMath.imageSize(natural: CGSize(width: 60, height: 44), in: CGSize(width: 120, height: 26))
        #expect(fitted == CGSize(width: 30, height: 22))
        // Too wide for the cell: 26 points of room across.
        let narrow = PanelMath.imageSize(natural: CGSize(width: 52, height: 10), in: CGSize(width: 30, height: 26))
        #expect(narrow == CGSize(width: 26, height: 5))
        #expect(PanelMath.imageSize(natural: .zero, in: CGSize(width: 30, height: 26)) == .zero)
    }
}
