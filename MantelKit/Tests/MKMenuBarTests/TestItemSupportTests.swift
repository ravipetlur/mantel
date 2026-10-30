import CoreGraphics
import Foundation
import MKCore
import MKTestSupport
import Testing

@testable import MKMenuBar

@Suite("Test item support")
struct TestItemSupportTests {
    // MARK: Names

    @Test func theItemsAreOneTwoAndUpToTwentyExtras() {
        #expect(["one", "two", "extra.1", "extra.20"].allSatisfy(TestItemNames.isValid))
        #expect(!["three", "extra.0", "extra.21", "extra.", "extra.x", "extra", "One", ""].contains(where: TestItemNames.isValid))
        #expect(TestItemNames.extraNumber(of: "extra.7") == 7)
        #expect(TestItemNames.extraNumber(of: "one") == nil)
        #expect(TestItemNames.autosaveName("extra.1") == "mantel.fixture.extra.1")
        #expect(TestItemNames.autosaveName("one") == "mantel.fixture.one", "the names the order table keeps the places under")
    }

    @Test func aTestItemWithSomeItemsHasTheseNames() {
        #expect(TestItemNames.names(itemCount: 0).isEmpty)
        #expect(TestItemNames.names(itemCount: 1) == ["one"])
        #expect(TestItemNames.names(itemCount: 2) == ["one", "two"])
        #expect(TestItemNames.names(itemCount: 5) == ["one", "two", "extra.1", "extra.2", "extra.3"])
    }

    @Test func itIsOpenedAgainWithAsManyItems() {
        #expect(TestItemNames.launchArguments(itemCount: 1) == ["--single"])
        #expect(TestItemNames.launchArguments(itemCount: 2).isEmpty)
        #expect(TestItemNames.launchArguments(itemCount: 3) == ["--extra", "1"])
        #expect(TestItemNames.launchArguments(itemCount: 22) == ["--extra", "20"])
        #expect(TestItemNames.launchArguments(extras: 0).isEmpty)
        #expect(TestItemNames.launchArguments(extras: 4) == ["--extra", "4"])
        #expect(TestItemNames.launchArguments(extras: 99) == ["--extra", "20"], "no more than it can have")
    }

    // MARK: Its click log

    private func write(_ text: String, in folder: TemporaryFolder) throws {
        try Data(text.utf8).write(to: folder.url.appending(path: TestItemClickLog.fileName))
    }

    @Test func aRecordIsReadAsTheTestItemWritesIt() throws {
        let folder = TemporaryFolder()
        try write(#"{"item":"one","kind":"option","at":1700000100.5}"#, in: folder)

        let click = try #require(TestItemClickLog.latest(in: folder.url))

        #expect(click == TestItemClick(item: "one", kind: "option", at: 1_700_000_100.5))
        #expect(TestItemClickLog.kindReceived(by: "one", since: Date(timeIntervalSince1970: 1_700_000_100), in: folder.url) == "option")
    }

    @Test func aMissingFileIsNoRecord() {
        let folder = TemporaryFolder()
        #expect(TestItemClickLog.latest(in: folder.url) == nil)
        #expect(TestItemClickLog.kindReceived(by: "one", since: .distantPast, in: folder.url) == nil)
        #expect(TestItemClickLog.latest(in: folder.url.appending(path: "nowhere")) == nil)
    }

    @Test func aRecordOlderThanTheClickIsNotItsAnswer() throws {
        let folder = TemporaryFolder()
        try write(#"{"item":"one","kind":"left","at":1700000000}"#, in: folder)
        #expect(TestItemClickLog.kindReceived(by: "one", since: Date(timeIntervalSince1970: 1_700_000_001), in: folder.url) == nil)
        #expect(TestItemClickLog.kindReceived(by: "one", since: Date(timeIntervalSince1970: 1_700_000_000), in: folder.url) == "left",
                "a record at the very moment of the click is its")
    }

    @Test func anotherItemsRecordIsNotTheAnswer() throws {
        let folder = TemporaryFolder()
        try write(#"{"item":"two","kind":"right","at":1700000005}"#, in: folder)
        #expect(TestItemClickLog.kindReceived(by: "one", since: Date(timeIntervalSince1970: 1_700_000_000), in: folder.url) == nil)
        #expect(TestItemClickLog.kindReceived(by: "two", since: Date(timeIntervalSince1970: 1_700_000_000), in: folder.url) == "right")
    }

    @Test(arguments: ["", "not json", "[]", #"{"item":"one"}"#, #"{"item":"one","kind":"left","at":"yesterday"}"#, #"{"item":1,"kind":2,"at":3}"#])
    func whatIsNotARecordIsNoRecord(text: String) throws {
        let folder = TemporaryFolder()
        try write(text, in: folder)
        #expect(TestItemClickLog.latest(in: folder.url) == nil)
        #expect(TestItemClickLog.kindReceived(by: "one", since: .distantPast, in: folder.url) == nil)
    }

    @Test func anExtraKeyInTheRecordIsIgnored() throws {
        // The test item may write more one day; what the probes read stays readable.
        let folder = TemporaryFolder()
        try write(#"{"item":"one","kind":"left","at":1700000000,"count":3}"#, in: folder)
        #expect(TestItemClickLog.latest(in: folder.url)?.kind == "left")
    }

    // MARK: What it is told by

    @Test func theTestItemListensForANotificationThatCarriesItsOwnBundleID() {
        #expect(TestItemCommands.notificationName(TestItemCommands.toggleExtraOne, fixtureBundleID: "com.example.mantel.testitem").rawValue
                == "com.example.mantel.testitem.toggle-extra-1")
        #expect(TestItemCommands.toggleExtraOne == "toggle-extra-1")
    }

    // MARK: Preferences keys

    @Test func preferredPositionKeysAreCounted() {
        let keys = ["NSStatusItem Preferred Position mantel.fixture.one", "NSStatusItem Preferred Position mantel.fixture.two",
                    "NSStatusItem Visible mantel.fixture.one", "NSStatusItem Preferred Position", "other", "AppleLanguages"]
        #expect(PreferredPositionKeys.count(in: keys) == 3)
        #expect(PreferredPositionKeys.count(in: []) == 0)
        #expect(PreferredPositionKeys.prefix == "NSStatusItem Preferred Position")
    }

    // MARK: The fakes the click path is tested with

    @Test func theFakeLocatorAnswersByTheNumberOfTheCall() async throws {
        let locator = FakeItemLocator()
        let item = ItemID(bundleID: "com.example.a", key: .identifier("x"))
        let slot = CGRect(x: 100, y: 0, width: 30, height: 31)
        locator.appear(FakeItemLocator.location(of: item, slot: slot), afterCalls: 2)

        #expect(await locator.locate(item, on: nil, since: nil) == nil)
        #expect(await locator.locate(item, on: nil, since: nil) == nil)
        #expect(await locator.locate(item, on: nil, since: nil)?.slotFrame == slot)
        #expect(locator.calls(of: item).map(\.number) == [1, 2, 3])
        // An item that nobody gave an answer is nowhere, and one is on the display its slot is on and no other.
        let stranger = ItemID(bundleID: "com.example.b", key: .identifier("y"))
        #expect(await locator.locate(stranger, on: nil, since: nil) == nil)
        #expect(await locator.locate(item, on: DisplayFixtures.deskMain.uuid, since: nil) != nil)
        #expect(await locator.locate(item, on: "another", since: nil) == nil)
        #expect(await locator.slotSnapshot(on: nil) == nil)
        locator.setSnapshot(SlotSnapshot(displayUUID: "d", slots: [slot]))
        #expect(await locator.slotSnapshot(on: "d")?.slots == [slot])
        #expect(locator.snapshotCallCount == 2)
    }
}
