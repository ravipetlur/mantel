import CoreGraphics
import Foundation
import MKCore
import Testing

@testable import MKMenuBar

/// What posting a click comes to, decided on its own: nothing is posted, and no poster is made.
@Suite("Click post plan", .timeLimit(.minutes(1)))
struct ClickPostPlanTests {
    private let point = CGPoint(x: 1234.5, y: 12)
    private let before = CGPoint(x: 400, y: 600)
    private let mark = ClickReplayTap.eventMark

    /// The mouse events of the plan, in order.
    private func mouseEvents(_ plan: ClickPostPlan) -> [(type: CGEventType, button: CGMouseButton, location: CGPoint, flags: CGEventFlags)] {
        plan.steps.compactMap { step in
            if case .mouse(let type, let button, let location, let flags, _, _) = step { return (type, button, location, flags) }
            return nil
        }
    }

    @Test func leftIsDownUpLeftButton() {
        let plan = ClickPostPlan.click(.left, at: point, pointerWas: before)

        #expect(plan.steps == [
            .mouse(type: .leftMouseDown, button: .left, location: point, flags: [], mark: mark, clickState: 1),
            .wait(.milliseconds(30)),
            .mouse(type: .leftMouseUp, button: .left, location: point, flags: [], mark: mark, clickState: 1),
            .putPointerBack(before),
        ])
    }

    @Test func rightUsesRightButton() {
        let events = mouseEvents(ClickPostPlan.click(.right, at: point, pointerWas: before))

        #expect(events.map(\.type) == [.rightMouseDown, .rightMouseUp])
        #expect(events.allSatisfy { $0.button == .right })
        #expect(events.allSatisfy { $0.location == point })
        #expect(events.allSatisfy { $0.flags.isEmpty })
    }

    @Test func optionCarriesAlternateFlag() {
        let events = mouseEvents(ClickPostPlan.click(.option, at: point, pointerWas: before))

        #expect(events.map(\.type) == [.leftMouseDown, .leftMouseUp], "an option click is a left click with the key held")
        #expect(events.allSatisfy { $0.button == .left })
        #expect(events.allSatisfy { $0.flags == .maskAlternate }, "and nothing else held")
    }

    @Test func everyEventIsMarked() {
        for kind in ClickKind.allCases {
            let plan = ClickPostPlan.click(kind, at: point, pointerWas: before)
            var marked = 0
            for step in plan.steps {
                if case .mouse(_, _, _, _, let eventMark, _) = step {
                    #expect(eventMark == ClickReplayTap.eventMark, "\(kind)")
                    marked += 1
                }
            }
            #expect(marked == 2, "a down and an up")
        }
        for step in ClickPostPlan.key(53, flags: []).steps {
            if case .key(_, _, _, let eventMark) = step { #expect(eventMark == ClickReplayTap.eventMark) }
        }
    }

    @Test func everyMouseEventIsASingleClick() {
        // The click count is part of what is posted, so it is the plan's: a down and an up that say they are one click, of every kind.
        for kind in ClickKind.allCases {
            let plan = ClickPostPlan.click(kind, at: point, pointerWas: before)
            var states: [Int64] = []
            for step in plan.steps {
                if case .mouse(_, _, _, _, _, let clickState) = step { states.append(clickState) }
            }
            #expect(states == [1, 1], "\(kind)")
        }
        #expect(ClickPostPlan.singleClick == 1)
    }

    @Test func pointerIsPutBackLast() {
        for kind in ClickKind.allCases {
            let plan = ClickPostPlan.click(kind, at: point, pointerWas: before)
            #expect(plan.steps.last == .putPointerBack(before), "\(kind)")
            #expect(plan.steps.filter { if case .putPointerBack = $0 { true } else { false } }.count == 1)
        }
    }

    @Test func noPointerToPutBackLeavesItAlone() {
        let plan = ClickPostPlan.click(.left, at: point, pointerWas: nil)
        #expect(plan.steps.count == 3)
        #expect(!plan.steps.contains { if case .putPointerBack = $0 { true } else { false } })
    }

    @Test func theUpFollowsTheDownByThirtyMilliseconds() {
        let plan = ClickPostPlan.click(.left, at: point, pointerWas: before)
        #expect(ClickPostPlan.pressDuration == .milliseconds(30))
        guard case .mouse(let first, _, _, _, _, _) = plan.steps[0], case .wait(let gap) = plan.steps[1],
              case .mouse(let second, _, _, _, _, _) = plan.steps[2] else {
            Issue.record("down, wait, up")
            return
        }
        #expect(first == .leftMouseDown)
        #expect(gap == .milliseconds(30))
        #expect(second == .leftMouseUp)
    }

    @Test func aKeyIsDownThenUpWithItsFlagsAndNoPointerMoved() {
        let plan = ClickPostPlan.key(53, flags: .maskCommand)

        #expect(plan.steps == [
            .key(code: 53, isDown: true, flags: .maskCommand, mark: mark),
            .key(code: 53, isDown: false, flags: .maskCommand, mark: mark),
        ])
    }
}
