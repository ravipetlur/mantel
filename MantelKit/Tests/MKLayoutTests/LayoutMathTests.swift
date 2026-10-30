import CoreGraphics
import MKCore
import Testing

@testable import MKLayout

@Suite("Layout math", .timeLimit(.minutes(1)))
struct LayoutMathTests {
    private typealias F = ArrangementFixtures
    private let a = F.app("a"), b = F.app("b"), c = F.app("c"), d = F.app("d"), e = F.app("e")

    private func tokens(_ inputs: LayoutInputs) -> [LayoutToken] {
        LayoutMath.arrange(inputs, rules: F.rules(), systemStart: 0).tokens
    }

    @Test func betweenSectionsOrder() {
        let sections = F.sections(always: [a], hidden: [b, c], shown: [d, e])
        #expect(tokens(F.inputs(sections)) == [.item(a), .dot(.always), .item(b), .item(c), .dot(.hidden), .divider, .item(d), .item(e)])
    }

    @Test func besideClockOrder() {
        let sections = F.sections(always: [a], hidden: [b], shown: [c, d])
        #expect(tokens(F.inputs(sections, placement: .besideClock))
            == [.item(a), .item(b), .divider, .item(c), .item(d), .dot(.always), .dot(.hidden)])
    }

    @Test func systemTokensNeverArranged() {
        let sections = F.sections(hidden: [.system("battery"), a], shown: [.system("wifi"), b])
        let arranged = LayoutMath.arrange(F.inputs(sections), rules: F.rules(), systemStart: 0)
        #expect(arranged.tokens == [.dot(.always), .item(a), .dot(.hidden), .divider, .item(b)])
        #expect(!arranged.tokens.contains(.item(.system("battery"))))
        #expect(!arranged.tokens.contains(.item(.system("wifi"))))
        #expect(arranged.distances.keys.allSatisfy { if case .item(let id) = $0 { !id.isSystem } else { true } })
    }

    @Test func arrangeUsesGroupItems() {
        var sections = F.sections(always: [a], shown: [d])
        let group = IconGroup(id: GroupID(rawValue: "0000beef"))
        sections.groups[group.id] = group
        sections.groupOrder = [group.id]
        sections.groupItems[group.id] = [b, c]
        #expect(tokens(F.inputs(sections, dots: false, divider: false)) == [.item(b), .item(c), .item(a), .item(d)])
    }

    @Test func alwaysDotOmittedWhenHidden() {
        let sections = F.sections(hidden: [a], shown: [b])
        #expect(tokens(F.inputs(sections, alwaysDot: false)) == [.item(a), .dot(.hidden), .divider, .item(b)])
        #expect(tokens(F.inputs(sections, placement: .besideClock, alwaysDot: false)) == [.item(a), .divider, .item(b), .dot(.hidden)])
    }

    @Test func dotsOmittedWhenBothHidden() {
        let sections = F.sections(hidden: [a], shown: [b])
        // Neither dot is there, whatever the second one says.
        #expect(tokens(F.inputs(sections, alwaysDot: true, dots: false)) == [.item(a), .divider, .item(b)])
        #expect(tokens(F.inputs(sections, alwaysDot: false, dots: false, divider: false)) == [.item(a), .item(b)])
    }

    @Test func dividerAtLeftOfShownInBoth() {
        let sections = F.sections(hidden: [a], shown: [b, c])
        for placement in [DotsPlacement.betweenSections, .besideClock] {
            let order = tokens(F.inputs(sections, placement: placement))
            #expect(order.firstIndex(of: .divider)! + 1 == order.firstIndex(of: .item(b))!, "\(placement)")
        }
        #expect(!tokens(F.inputs(sections, divider: false)).contains(.divider))
    }

    @Test func groupsLeftOfAlwaysHidden() {
        var sections = F.sections(always: [a])
        let group = IconGroup(id: GroupID(rawValue: "0000beef"))
        sections.groups[group.id] = group
        sections.groupOrder = [group.id]
        sections.groupItems[group.id] = [b]
        for placement in [DotsPlacement.betweenSections, .besideClock] {
            let order = tokens(F.inputs(sections, placement: placement))
            #expect(order.prefix(2) == [.item(b), .item(a)], "\(placement)")
        }
    }

    @Test func rightEdgeDistancesAccumulate() {
        let sections = F.sections(hidden: [a], shown: [b, c])
        let widths: [ItemID: CGFloat] = [a: 40, b: 30, c: 20]
        let arranged = LayoutMath.arrange(F.inputs(sections, widths: widths), rules: F.rules(.rightEdge), systemStart: 100)
        // Right to left: c 100; b 100 + 20; the divider 120 + 30; • 150 + 9; a 159 + 38; •• 197 + 40.
        #expect(arranged.tokens == [.dot(.always), .item(a), .dot(.hidden), .divider, .item(b), .item(c)])
        #expect(arranged.distances == [.item(c): 100, .item(b): 120, .divider: 150, .dot(.hidden): 159, .item(a): 197, .dot(.always): 237])
        #expect(arranged.skipped.isEmpty)
    }

    @Test func leftEdgeAddsOwnWidth() {
        let sections = F.sections(shown: [a, b])
        let widths: [ItemID: CGFloat] = [a: 40, b: 30]
        let arranged = LayoutMath.arrange(F.inputs(sections, dots: false, divider: false, widths: widths),
                                          rules: F.rules(.leftEdge), systemStart: 100)
        #expect(arranged.distances == [.item(b): 130, .item(a): 170])
    }

    @Test func orderOnlyUsesKnownOrAssumedWidths() {
        let sections = F.sections(shown: [a, b])
        let arranged = LayoutMath.arrange(F.inputs(sections, dots: false, divider: false, widths: [b: 30]),
                                          rules: F.rules(.orderOnly), systemStart: 10)
        #expect(arranged.distances == [.item(b): 10, .item(a): 40])
        let assumed = LayoutMath.arrange(F.inputs(sections, dots: false, divider: false), rules: F.rules(.orderOnly), systemStart: 10)
        #expect(assumed.distances == [.item(b): 10, .item(a): 48])
    }

    @Test func unknownWidthSkippedUnderKnownWidths() {
        let sections = F.sections(shown: [a, b, c])
        // b's width is unknown: it is skipped, and a is placed after the assumed 38 for it.
        let arranged = LayoutMath.arrange(F.inputs(sections, dots: false, divider: false, widths: [a: 20, c: 25]),
                                          rules: F.rules(.rightEdge, needsKnownWidths: true), systemStart: 0)
        #expect(arranged.skipped == [b])
        #expect(arranged.distances == [.item(c): 0, .item(a): 63])
        #expect(arranged.tokens == [.item(a), .item(b), .item(c)])
        // Without the need it is placed like any other.
        let placed = LayoutMath.arrange(F.inputs(sections, dots: false, divider: false, widths: [a: 20, c: 25]),
                                        rules: F.rules(.rightEdge), systemStart: 0)
        #expect(placed.skipped.isEmpty)
        #expect(placed.distances[.item(b)] == 25)
    }

    @Test func systemStartFromPresentModules() {
        let table = F.table(["module:Clock": 0, "module:BentoBox-0": 129, "module:WiFi": 155, "module:Battery": 177, "module:AirDrop": 895])
        let present = ["clock": "Clock", "controlcenter": "BentoBox-0", "wifi": "WiFi", "battery": "Battery"]
        let widths: [ItemID: CGFloat] = [.system("battery"): 40, .system("wifi"): 30]
        // Battery is the furthest: 177 + 40. AirDrop isn't drawn, so its 895 never counts.
        #expect(LayoutMath.systemStart(table: table, presentModules: present, widths: widths) == 217)
        // A module with no known width counts the assumed one.
        #expect(LayoutMath.systemStart(table: table, presentModules: ["wifi": "WiFi"], widths: [:]) == 155 + 38)
        #expect(LayoutMath.systemStart(table: table, presentModules: [:], widths: widths) == 0)
        // A drawn module the table doesn't have sets nothing.
        #expect(LayoutMath.systemStart(table: table, presentModules: ["sound": "Sound"], widths: [:]) == 0)
    }

    @Test func theStayingModulesStartIsTheLeftMostOnesOwnDistance() {
        let table = F.table(["module:Clock": 0, "module:WiFi": 155, "module:Battery": 177, "module:Bluetooth": 321, "module:NowPlaying": 662.5,
                             "module:AirDrop": 895])
        let present = ["clock": "Clock", "wifi": "WiFi", "battery": "Battery", "bluetooth": "Bluetooth", "now-playing": "NowPlaying",
                       "airdrop": "AirDrop"]
        // The modules that come and go (Now Playing, AirDrop) never count: Bluetooth's own distance, with no width added.
        #expect(LayoutMath.stayingModulesStart(table: table, presentModules: present) == 321)
        #expect(LayoutMath.stayingModulesStart(table: table, presentModules: ["wifi": "WiFi", "now-playing": "NowPlaying"]) == 155)
        // Only modules that come and go, none drawn, or none the table has: 0, so no app is among them.
        #expect(LayoutMath.stayingModulesStart(table: table, presentModules: ["airdrop": "AirDrop"]) == 0)
        #expect(LayoutMath.stayingModulesStart(table: table, presentModules: [:]) == 0)
        #expect(LayoutMath.stayingModulesStart(table: table, presentModules: ["sound": "Sound"]) == 0)
        // A module that comes and goes under a name the inventory hasn't been seen to give it is still known by its name in the table.
        #expect(LayoutMath.stayingModulesStart(table: F.table(["module:WiFi": 155, "module:ScreenMirroring": 628.5]),
                                               presentModules: ["wifi": "WiFi", "screen-mirroring": "ScreenMirroring"]) == 155)
        // All six that come and go are left out, wherever the table puts them (Screen Mirroring can sit left of the apps).
        let six = ["display": "Display", "focusmodes": "FocusModes", "screenmirroring": "ScreenMirroring", "now-playing": "NowPlaying",
                   "audiovideo": "AudioVideoModule", "airdrop": "AirDrop"]
        let sixTable = F.table(["module:Wifi": 100, "module:Display": 145, "module:FocusModes": 153, "module:ScreenMirroring": 628.5,
                                "module:NowPlaying": 662.5, "module:AudioVideoModule": 829, "module:AirDrop": 895])
        #expect(LayoutMath.stayingModulesStart(table: sixTable, presentModules: six.merging(["wifi": "Wifi"]) { $1 }) == 100)
        #expect(LayoutMath.stayingModulesStart(table: sixTable, presentModules: six) == 0)
        // The start of the apps (where a write may begin) still counts the ones that come and go.
        #expect(LayoutMath.systemStart(table: table, presentModules: present, widths: [.system("airdrop"): 28]) == 895 + 28)
    }

    @Test func distancesRoundToHalf() {
        let sections = F.sections(shown: [a, b])
        let arranged = LayoutMath.arrange(F.inputs(sections, dots: false, divider: false, widths: [a: 20.3, b: 30.2]),
                                          rules: F.rules(.rightEdge), systemStart: 10.1)
        #expect(arranged.distances == [.item(b): 10, .item(a): 40.5])
    }
}
