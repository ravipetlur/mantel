import CoreGraphics
import Foundation
import MKCore
import MKLayout
import MKTestSupport
import Testing

@testable import MKMenuBar

/// A write of the order from one real Mac's table, bar and sections (`OwnersTable`, made-up bundle IDs), through the applier: the person
/// has reordered, and the write has to place the apps that can be placed.
@Suite("Reordering on one Mac's table", .timeLimit(.minutes(1)))
struct ReorderingOnTheOwnersTableTests {
    struct Outcome {
        let report: LayoutWriteReport
        let writes: [(arrangement: LayoutArrangement, keys: [LayoutToken: String])]
    }

    /// One person's write, worked out and written, with a read of the bar that can't be taken (the check ends as `cantTell`).
    static func write(table: LayoutTableSnapshot = OwnersTable.table, inventory: Inventory = OwnersTable.inventory(),
                      concealed: Set<String> = [], rules: LayoutRules = LayoutFixtures.rules(.byRank)) async throws -> Outcome {
        let clock = FakeClock()
        let writer = FakeLayoutWriter()
        writer.table = table
        let applier = LayoutApplier(writer: writer, rules: rules, clock: clock, read: { nil },
                                    shownBars: { Set($0.bars.map(\.displayUUID)) }, phase: { _, _, _ in }, held: { nil })
        let sections = try OwnersTable.sections()
        await applier.request(OwnersTable.inputs(sections, inventory: inventory), ownBundleID: OwnersTable.own, inventory: inventory,
                              memory: [:], concealedApps: concealed, cause: .person)
        let settled = await withinTimeLimit(.seconds(10)) {
            while await applier.status().isPending {
                if await clock.waitForSleepers(1, within: .milliseconds(20)) { clock.advance(by: .milliseconds(250)) }
            }
            return true
        }
        #expect(settled == true)
        let report = try #require(await applier.status().lastReport)
        return Outcome(report: report, writes: writer.writes)
    }

    private static let ownTokens: Set<LayoutToken> = [.dot(.hidden), .dot(.always), .divider]

    @Test func theAppsThatCanBePlacedAreWrittenOnTheOwnersTable() async throws {
        let result = try await Self.write()
        let write = try #require(result.writes.first)

        // Before: 0 places, 45 can't be reordered, 12 not placed (every write placed nothing). Now the nine apps that have a key and
        // whose neighbours let them be placed are written, and Mantel's own three are left where macOS has them: apps it can't reorder
        // sit on both sides of where they would go.
        #expect(write.keys.count == 9)
        #expect(result.report.placed == 5, "nine places, four of them apps that aren't running")
        #expect(result.report.unresolved.count == 45)
        #expect(Set(result.report.notPlaced) == [OwnItems.hiddenDotName, OwnItems.alwaysDotName, OwnItems.dividerName])
        #expect(write.keys.keys.allSatisfy { !Self.ownTokens.contains($0) })
    }

    @Test func whatIsWrittenKeepsTheArrangementsOrderAboveTheSystemItems() async throws {
        let result = try await Self.write()
        let write = try #require(result.writes.first)
        // The system items end at the left-most drawn module's distance and width: 321 and 16 on this bar.
        let placed = write.arrangement.tokens.compactMap { token in write.keys[token] == nil ? nil : write.arrangement.distances[token] }
        #expect(placed.count == 9)
        #expect(zip(placed, placed.dropFirst()).allSatisfy { $0 > $1 }, "left to right, so the distances fall")
        #expect(try #require(placed.last) > 337)
    }

    @Test func theSectionsHoldAppsThatAreNotRunningAndHaveNoKeyAndTheyStopNothing() async throws {
        // The sections hold many apps that aren't running, and some of them have no key in the table: the nine places are written all the same.
        let result = try await Self.write()
        let table = OwnersTable.table
        let running = Set(OwnersTable.inventory().items.map(\.ownerBundleID))
        let notRunning = try OwnersTable.sections().apps.keys.filter { !running.contains($0) }
        #expect(notRunning.count >= 10)
        let withoutKeys = notRunning.filter { app in table.statusKeys(ofApp: app).isEmpty }
        #expect(withoutKeys.count >= 5)
        #expect(result.report.placed == 5, "nine places, four of them apps that aren't running")
    }

    @Test func theSameWriteWhenTheHiddenAppsAreConcealed() async throws {
        let sections = try OwnersTable.sections()
        let concealed = Set(sections.apps.filter { $0.value.section != .shown }.keys)
        let result = try await Self.write(concealed: concealed)
        #expect((result.report.placed ?? 0) >= 5)
    }

    @Test func ownItemsAreWrittenWhenNoRunningAppStandsInTheirWay() async throws {
        // The apps that can't be reordered and that sit across the dots (the system UI server's three icons, the app with a stale second
        // key, the test item with one key among the system modules) are taken away: the dots and the divider are placed too.
        let stuck: Set<String> = ["com.apple.systemuiserver", "com.example.app20", "com.example.app28", OwnersTable.testItem, "com.example.app18"]
        let result = try await Self.write(inventory: OwnersTable.inventory(without: stuck))
        let write = try #require(result.writes.first)
        #expect(Self.ownTokens.isSubset(of: Set(write.keys.keys)))
        #expect(!result.report.notPlaced.contains(OwnItems.hiddenDotName))
    }

    @Test func aReadWithNoBarsWritesNothingAndTheNextOneWritesWhatThisTableWrites() async throws {
        // MenuBarAgent is down (or restarting, or the grant is missing) when the person reorders: the request carries a read with no bar and
        // no item. Planned from it, every app would count as not running and the system items would end at 0: 33 keys were written, the
        // dots far left, and four Shown apps among the system modules.
        let clock = FakeClock()
        let writer = FakeLayoutWriter()
        writer.table = OwnersTable.table
        let applier = LayoutApplier(writer: writer, rules: LayoutFixtures.rules(.byRank), clock: clock, read: { nil },
                                    shownBars: { Set($0.bars.map(\.displayUUID)) }, phase: { _, _, _ in }, held: { nil })
        let sections = try OwnersTable.sections()
        let good = OwnersTable.inventory()
        let down = Inventory(capturedAt: good.capturedAt, bars: [], items: [], chevrons: [:], reach: [], problems: [.agentNotRunning])
        func settle() async {
            let settled = await withinTimeLimit(.seconds(10)) {
                while await applier.status().isPending {
                    if await clock.waitForSleepers(1, within: .milliseconds(20)) { clock.advance(by: .milliseconds(250)) }
                }
                return true
            }
            #expect(settled == true)
        }

        await applier.request(OwnersTable.inputs(sections, inventory: good), ownBundleID: OwnersTable.own, inventory: down, memory: [:],
                              concealedApps: [], cause: .person)
        await settle()
        #expect(writer.writeCount == 0, "nothing is written from a read with no bars")
        #expect(await applier.status().lastReport == nil)

        await applier.request(OwnersTable.inputs(sections, inventory: good), ownBundleID: OwnersTable.own, inventory: good, memory: [:],
                              concealedApps: [], cause: .person)
        await settle()
        let write = try #require(writer.writes.first)
        #expect(writer.writeCount == 1)
        #expect(write.keys.count == 9, "what the owner's table writes from a read that has the bars")
        #expect(try #require(await applier.status().lastReport).placed == 5, "four of the nine are apps that aren't running")
    }
}
