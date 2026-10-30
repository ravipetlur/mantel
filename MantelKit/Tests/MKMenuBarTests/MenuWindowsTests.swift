import CoreGraphics
import Foundation
import MKCore
import Testing

@testable import MKMenuBar

/// Which windows of an app are its menu, from two lists of the windows on screen.
@Suite("Menu windows", .timeLimit(.minutes(1)))
struct MenuWindowsTests {
    private let app: pid_t = 4242
    private let other: pid_t = 4343

    private func window(_ number: Int, pid: pid_t, layer: Int = 101, alpha: Double = 1) -> WindowInfo {
        WindowInfo(number: number, ownerPID: pid, ownerBundleID: nil, layer: layer, bounds: CGRect(x: 100, y: 30, width: 200, height: 300),
                   alpha: alpha)
    }

    @Test func newWindowOfPidIsOpened() {
        let before = [window(1, pid: app, layer: 25), window(2, pid: other)]
        let after = before + [window(3, pid: app)]

        #expect(MenuWindows.opened(by: app, before: before, after: after, minimumLayer: 101).map(\.number) == [3])
        #expect(MenuWindows.isOpen(by: app, in: after, minimumLayer: 101))
    }

    @Test func aWindowThatWasThereIsNotOpened() {
        let before = [window(7, pid: app)]
        #expect(MenuWindows.opened(by: app, before: before, after: before, minimumLayer: 101).isEmpty)
    }

    @Test func otherPidIsNot() {
        let after = [window(1, pid: other), window(2, pid: other, layer: 200)]
        #expect(MenuWindows.opened(by: app, before: [], after: after, minimumLayer: 0).isEmpty)
        #expect(!MenuWindows.isOpen(by: app, in: after, minimumLayer: 0))
    }

    @Test func belowLayerIsNot() {
        let after = [window(1, pid: app, layer: 25), window(2, pid: app, layer: 100)]
        #expect(MenuWindows.opened(by: app, before: [], after: after, minimumLayer: 101).isEmpty)
        #expect(!MenuWindows.isOpen(by: app, in: after, minimumLayer: 101))
        #expect(MenuWindows.opened(by: app, before: [], after: after, minimumLayer: 25).map(\.number) == [1, 2], "the layer is the caller's to say")
        #expect(MenuWindows.opened(by: app, before: [], after: [window(3, pid: app, layer: 101)], minimumLayer: 101).map(\.number) == [3],
                "the layer itself counts")
    }

    @Test func transparentIsNot() {
        let after = [window(1, pid: app, alpha: 0), window(2, pid: app, alpha: 0.01)]
        #expect(MenuWindows.opened(by: app, before: [], after: after, minimumLayer: 0).map(\.number) == [2])
        #expect(!MenuWindows.isOpen(by: app, in: [window(1, pid: app, alpha: 0)], minimumLayer: 0))
    }

    @Test func theWindowsComeInTheOrderOfTheNewList() {
        let after = [window(9, pid: app), window(4, pid: app), window(6, pid: app)]
        #expect(MenuWindows.opened(by: app, before: [window(4, pid: app)], after: after, minimumLayer: 0).map(\.number) == [9, 6])
    }
}
