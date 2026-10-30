import CoreGraphics
import Foundation
import MKCommands
import MKCore
import MKTestSupport
import Testing

@testable import MKMenuBar

private let fixtureID = ProbeHarness.fixtureID
private let ownID = ProbeHarness.ownBundleID
private let otherID = ProbeHarness.otherID
private let main = DisplayFixtures.deskMain.uuid
private let trailing = LayoutKeys.trailingPositions

@Suite("Layout-map probe", .timeLimit(.minutes(1)))
struct LayoutMapProbeTests {
    /// The bar is 3360 wide. Its items are at: Mantel's dot 3000 to 3030, the test item's two 3100 to 3140 and 3150 to 3190, and the other
    /// app's 3200 to 3240. Their distances from the right edge are the room between the item's right edge and 3360 (220, 170 and 120).
    private func table(_ extra: [String: Any] = [:]) -> [String: Any] {
        var positions: [String: Any] = [
            "status:\(fixtureID)::one": 220, "status:\(fixtureID)::two": 170, "status:\(otherID)::\(otherID).item": 120,
            "status:\(ownID)::\(ownID).dot": 330, "module:Clock": 10, "module:ControlCenter": 30,
        ]
        for (key, value) in extra { positions[key] = value }
        return [trailing: positions, "keep": "this"]
    }

    private func text(_ report: ProbeReport) throws -> String {
        String(decoding: try JSONCoding.encoder().encode(report), as: UTF8.self)
    }

    @Test func theTestItemsAndMantelsEntriesAreRecordedWithTheirSlots() async throws {
        let harness = try ProbeHarness.make()
        try await harness.installFile(.menuBarLayout, table())

        let report = await harness.run(.layoutMap)

        #expect(report.errors.isEmpty)
        let entries = try #require(report.object("fixtureEntries"))
        #expect(Set(entries.keys) == ["status:\(fixtureID)::one", "status:\(fixtureID)::two", "status:\(ownID)::\(ownID).dot"],
                "the test item's and Mantel's, and nobody else's")
        guard case .object(let one)? = entries["status:\(fixtureID)::one"] else {
            Issue.record("one")
            return
        }
        #expect(one["distance"] == .number(220))
        #expect(one["slots"] == .object([main: NotchCoordinatesProbe.rect(CGRect(x: 3100, y: 0, width: 40, height: 31))]))
        #expect(report.number("tableEntries") == 6)
    }

    @Test func theResidualsSayHowFarEachDistanceIsFromWhereTheIconIs() async throws {
        let harness = try ProbeHarness.make()
        try await harness.installFile(.menuBarLayout, table())

        let report = await harness.run(.layoutMap)

        let residuals = try #require(report.object("residuals"))
        guard case .object(let onMain)? = residuals[main] else {
            Issue.record("the main display")
            return
        }
        #expect(onMain["count"] == .number(4), "Mantel's, the test item's two and the other app's: every icon that has a name")
        #expect(onMain["barMaxX"] == .number(3360))
        // The distance is the room to the icon's right edge, so that is no residual; to its left edge it is the icon's width less.
        #expect(onMain["right"] == .object(["min": .number(0), "median": .number(0), "max": .number(0)]))
        guard case .object(let left)? = onMain["left"], case .number(let smallest)? = left["min"], case .number(let largest)? = left["max"] else {
            Issue.record("left")
            return
        }
        #expect(smallest == -40 && largest == -30, "the icons are 40 wide, and Mantel's 30")
    }

    @Test func theResidualsHaveNoKeysAndNoNames() async throws {
        let harness = try ProbeHarness.make()
        try await harness.installFile(.menuBarLayout, table())
        let report = await harness.run(.layoutMap)
        let residuals = try #require(report.object("residuals"))
        let json = String(decoding: try JSONCoding.encoder().encode(JSONValue.object(residuals)), as: UTF8.self)
        #expect(!json.contains("status:") && !json.contains(otherID) && !json.contains("mantel.fixture"), "\(json)")
        // Nor does anything else in the report say another app's name.
        #expect(try !text(report).contains(otherID), "the other app is not named")
    }

    @Test func moduleKeysAreRecordedByTheirNames() async throws {
        let harness = try ProbeHarness.make()
        try await harness.installFile(.menuBarLayout, table())
        let report = await harness.run(.layoutMap)
        #expect(report.object("moduleKeys") == ["Clock": .number(10), "ControlCenter": .number(30)])
    }

    @Test func itemDashKeysAreCountedAndAppsWithMoreKeysThanItemsToo() async throws {
        let harness = try ProbeHarness.make()
        // The other app has one item and, in the table, three entries.
        try await harness.installFile(.menuBarLayout, table(["status:\(otherID)::Item-0": 100, "status:\(otherID)::Item-1": 90,
                                                              "status:\(otherID)::Item-x": 80]))
        let report = await harness.run(.layoutMap)
        #expect(report.number("itemDashNKeys") == 2, "Item-0 and Item-1; Item-x isn't one")
        #expect(report.number("appsWithMoreKeysThanItems") == 1)
        #expect(report.number("indexItemsMatchedByOrder") == 0)
        #expect(report.number("indexItemsMatchedByRank") == 0, "the other app's item has a name here")
    }

    @Test func anAppsUnnamedItemsAreMatchedByOrderWhenItHasAsManyItemDashKeysAsItems() async throws {
        let harness = try ProbeHarness.make()
        // The other app's item has no name on the bar: it is told by its place.
        let slot = try #require(harness.slotOwners.first { $0.value == otherID }?.key)
        harness.ax.setAttribute(AXName.identifier, .string(""), on: slot)
        harness.ax.setAttribute(AXName.identifier, .string(""), on: harness.otherExtra)
        try await harness.installFile(.menuBarLayout, [trailing: ["status:\(otherID)::Item-0": 120]])

        let report = await harness.run(.layoutMap)

        #expect(report.number("itemDashNKeys") == 1)
        #expect(report.number("indexItemsMatchedByOrder") == 1)
        #expect(report.number("indexItemsMatchedByRank") == 1)
        #expect(report.number("appsWithMoreKeysThanItems") == 0)
        let residuals = try #require(report.object("residuals"))
        #expect(residuals[main] == nil, "an item with no name of its own isn't looked at")
    }

    @Test func anAppsUnnamedItemsAreMatchedByRankWhenItHasAsManyKeysAsItems() async throws {
        let harness = try ProbeHarness.make()
        let slot = try #require(harness.slotOwners.first { $0.value == otherID }?.key)
        harness.ax.setAttribute(AXName.identifier, .string(""), on: slot)
        harness.ax.setAttribute(AXName.identifier, .string(""), on: harness.otherExtra)

        // One nameless item and one entry for it, under any name: a match (the entry is a name the app gave it, not `Item-<n>`).
        try await harness.installFile(.menuBarLayout, [trailing: ["status:\(otherID)::NSStatusItem Item 7": 120]])
        let matched = await harness.run(.layoutMap)
        #expect(matched.number("indexItemsMatchedByRank") == 1)
        #expect(matched.number("indexItemsMatchedByOrder") == 0, "the other count is of `Item-<n>` entries only")

        // Two entries for the one item: a stale one, and none is guessed.
        try await harness.installFile(.menuBarLayout, [trailing: ["status:\(otherID)::Item-0": 120, "status:\(otherID)::Item-1": 100]])
        let stale = await harness.run(.layoutMap)
        #expect(stale.number("indexItemsMatchedByRank") == 0)
        #expect(stale.number("itemDashNKeys") == 2)
    }

    @Test func mantelsOwnPreferredPositionKeysAreCounted() async throws {
        let harness = try ProbeHarness.make { platform in platform.ownPreferredPositionKeyCount = { 3 } }
        try await harness.installFile(.menuBarLayout, table())
        let report = await harness.run(.layoutMap)
        #expect(report.number("ownPreferredPositionKeyCount") == 3)
    }

    @Test func nothingIsWritten() async throws {
        let harness = try ProbeHarness.make()
        let url = try await harness.installFile(.menuBarLayout, table())
        let before = try Data(contentsOf: url)
        _ = await harness.run(.layoutMap)
        #expect(try Data(contentsOf: url) == before)
        #expect(await harness.journal.records().isEmpty)
        #expect(harness.preferences.writes.isEmpty && harness.poster.clicks.isEmpty && harness.relauncher.asked.isEmpty)
    }

    @Test func withoutAGrantItSaysWhatToDo() async throws {
        let harness = try ProbeHarness.make()
        let report = await harness.run(.layoutMap)
        #expect(report.errors == [GrantedFile.missing(.menuBarLayout)])
    }

    @Test func aTableThatIsNotOneIsAnError() async throws {
        let harness = try ProbeHarness.make()
        try await harness.installFile(.menuBarLayout, [trailing: "not a table"])
        let report = await harness.run(.layoutMap)
        #expect(report.errors.count == 1 && report.errors[0].contains("couldn't be read"))
    }

    @Test func aFileWithNoTableHasAnEmptyOne() async throws {
        let harness = try ProbeHarness.make()
        try await harness.installFile(.menuBarLayout, ["keep": "this"])
        let report = await harness.run(.layoutMap)
        #expect(report.errors.isEmpty)
        #expect(report.number("tableEntries") == 0)
        #expect(report.object("fixtureEntries") == [:])
    }

    @Test func theSummaryIsTheSmallestMiddleAndLargest() {
        #expect(LayoutMapProbe.summary([3, 1, 2]) == .object(["min": .number(1), "median": .number(2), "max": .number(3)]))
        #expect(LayoutMapProbe.summary([4, 1, 2, 3]) == .object(["min": .number(1), "median": .number(2.5), "max": .number(4)]), "the mean of the two in the middle")
        #expect(LayoutMapProbe.summary([]) == .object(["min": .null, "median": .null, "max": .null]))
        #expect(LayoutMapProbe.dashNumber(ofKey: "status:com.example.a::Item-12") == 12)
        #expect(LayoutMapProbe.dashNumber(ofKey: "status:com.example.a::Item-") == nil)
        #expect(LayoutMapProbe.dashNumber(ofKey: "module:Item-1") == nil)
    }
}
