import ApplicationServices
import CoreGraphics
import Foundation
import Testing

@testable import MKMenuBar

/// What `AXClient` does with the values and errors the Accessibility API gives, tested on values made here. Nothing in this
/// file asks the Accessibility API anything: no call reaches another process.
@Suite("AX client", .timeLimit(.minutes(1)))
struct AXClientTests {
    private func element(_ pid: pid_t) -> AXElementRef { AXElementRef(AXUIElementCreateApplication(pid)) }

    private func axValue(_ point: CGPoint) -> CFTypeRef {
        var copy = point
        return AXValueCreate(.cgPoint, &copy)!
    }

    private func axValue(_ size: CGSize) -> CFTypeRef {
        var copy = size
        return AXValueCreate(.cgSize, &copy)!
    }

    private func axValue(_ rect: CGRect) -> CFTypeRef {
        var copy = rect
        return AXValueCreate(.cgRect, &copy)!
    }

    // MARK: Values

    @Test func textNumbersAndFlagsAreTheirOwnKinds() {
        #expect(AXClient.box("title" as CFString) == .string("title"))
        #expect(AXClient.box(NSNumber(value: 1.5)) == .number(1.5))
        #expect(AXClient.box(NSNumber(value: 7)) == .number(7))
        #expect(AXClient.box(kCFBooleanTrue) == .bool(true))
        #expect(AXClient.box(kCFBooleanFalse) == .bool(false))
    }

    @Test func aPointAndASizeAreRead() {
        #expect(AXClient.box(axValue(CGPoint(x: 3, y: 4))) == .point(CGPoint(x: 3, y: 4)))
        #expect(AXClient.box(axValue(CGSize(width: 5, height: 6))) == .size(CGSize(width: 5, height: 6)))
    }

    @Test func otherAccessibilityValuesAreNoneBecauseNothingHasUseForThem() {
        #expect(AXClient.box(axValue(CGRect(x: 1, y: 2, width: 3, height: 4))) == .none)
        #expect(AXClient.box(Date() as CFDate) == .none)
    }

    @Test func oneElementComesAsAListOfOne() {
        #expect(AXClient.box(AXUIElementCreateApplication(901)) == .elements([element(901)]))
    }

    @Test func aListOfElementsKeepsItsOrder() {
        let list = [AXUIElementCreateApplication(903), AXUIElementCreateApplication(902)] as CFArray
        #expect(AXClient.box(list) == .elements([element(903), element(902)]))
        #expect(AXClient.box([] as CFArray) == .elements([]))
    }

    @Test func aListThatHoldsAnythingElseIsNone() {
        #expect(AXClient.box([AXUIElementCreateApplication(903), "text" as CFString] as CFArray) == .none)
    }

    // MARK: Errors

    @Test func theSystemsErrorsAreOurs() {
        #expect(AXClient.map(.cannotComplete) == .timeout)
        #expect(AXClient.map(.apiDisabled) == .notTrusted)
        #expect(AXClient.map(.noValue) == .noValue)
        #expect(AXClient.map(.attributeUnsupported) == .noValue)
        #expect(AXClient.map(.invalidUIElement) == .failure(AXError.invalidUIElement.rawValue))
        #expect(AXClient.map(.actionUnsupported) == .failure(AXError.actionUnsupported.rawValue))
    }

    // MARK: Elements

    @Test func anElementIsEqualToAnotherMadeForTheSameProcess() {
        #expect(element(910) == element(910))
        #expect(element(910) != element(911))
        #expect(Set([element(910), element(910), element(911)]).count == 2)
        #expect(element(910).hashValue == element(910).hashValue)
    }

    @Test func anApplicationElementIsForTheProcessAskedFor() {
        // Making it asks nothing of the process.
        let reference = AXClient(timeout: 0.25).application(pid: 912)
        var pid: pid_t = 0
        AXUIElementGetPid(reference.element, &pid)
        #expect(pid == 912)
    }
}
