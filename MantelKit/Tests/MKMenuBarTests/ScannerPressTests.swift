import CoreGraphics
import Foundation
import MKCore
import MKTestSupport
import Testing

@testable import MKMenuBar

private let agentPID: pid_t = 50
private let appPID: pid_t = 1001
private let bundle = "com.example.weather"
private let desk = DisplayLayout(displays: [DisplayFixtures.deskMain])

/// The weather app's items, as fake Accessibility lists them, and a scanner that asks it.
private struct Rig {
    let ax = FakeAX()
    let items: [Int]
    let running: [RunningApp]

    init(_ extras: [FakeAX.Extra], appRunning: Bool = true) {
        items = ax.addApp(pid: appPID, extras: extras)
        running = [.fake(agentPID, MenuBarReader.menuBarAgentBundleID, "MenuBarAgent")] + (appRunning ? [.fake(appPID, bundle, "Weather")] : [])
    }

    func scanner(trusted: Bool = true) -> MenuBarScanner {
        let running = running
        return MenuBarScanner(ax: ax, runningApps: { running }, layout: { desk }, ownBundleID: InventoryFixtures.ownBundleID,
                              isTrusted: { trusted }, clock: FakeClock())
    }

    func item(_ key: ItemID.Key) -> ItemID { ItemID(bundleID: bundle, key: key) }
}

/// Pressing an item, and opening its menu: the element is found again in the app's own list, by its name or its place, and never
/// another one is pressed in its stead.
@Suite("Scanner presses", .timeLimit(.minutes(1)))
struct ScannerPressTests {
    @Test func pressFindsByIdentifier() async throws {
        let rig = Rig([.init(title: "Weather", identifier: "weather.temp"), .init(title: "Alerts", identifier: "weather.alerts")])

        try await rig.scanner().press(rig.item(.identifier("weather.alerts")))

        #expect(rig.ax.pressed == [rig.items[1]])
    }

    @Test func aNameWithTheLayoutPrefixIsTheSameName() async throws {
        // An app may give its identifier the way the layout names it: `<bundle ID>::<name>`.
        let rig = Rig([.init(title: "Weather", identifier: "\(bundle)::weather.temp")])
        try await rig.scanner().press(rig.item(.identifier("weather.temp")))
        #expect(rig.ax.pressed == [rig.items[0]])
    }

    @Test func pressFindsByIndex() async throws {
        // Two items that name themselves nothing, told by their place from left to right as the last scan saw them on the bar. The app
        // lists them right to left.
        let rig = Rig([.init(title: "B", frame: CGRect(x: 3106, y: 1, width: 24, height: 28)),
                       .init(title: "A", frame: CGRect(x: 3062, y: 1, width: 24, height: 28))])
        let window = rig.ax.addAgentWindow(agent: agentPID, frame: CGRect(x: 0, y: 0, width: 3360, height: 30))
        rig.ax.addSlot(in: window, frame: CGRect(x: 3100, y: 0, width: 36, height: 30))
        rig.ax.addSlot(in: window, frame: CGRect(x: 3056, y: 0, width: 36, height: 30))
        let scanner = rig.scanner()
        let read = await scanner.scan()
        #expect(read.items(ofApp: bundle).map(\.id) == [rig.item(.index(0)), rig.item(.index(1))], "the scan names them by place")

        try await scanner.press(rig.item(.index(0)))
        try await scanner.press(rig.item(.index(1)))

        #expect(rig.ax.pressed == [rig.items[1], rig.items[0]], "index 0 is the left-most: the app's second")
    }

    @Test func withoutAScanTheIndexIsThePlaceInTheAppsList() async throws {
        let rig = Rig([.init(title: "B"), .init(title: "A")])
        let scanner = rig.scanner()

        try await scanner.press(rig.item(.index(1)))

        #expect(rig.ax.pressed == [rig.items[1]])
    }

    @Test func aNamedItemDoesNotTakeAnIndex() async throws {
        // Index 0 is the first item that has no name of its own, not the first item.
        let rig = Rig([.init(title: "Named", identifier: "weather.temp"), .init(title: "Plain")])
        try await rig.scanner().press(rig.item(.index(0)))
        #expect(rig.ax.pressed == [rig.items[1]])
    }

    @Test func missingIndexIsNotFound() async throws {
        let rig = Rig([.init(title: "Weather"), .init(title: "Alerts")])
        let scanner = rig.scanner()

        await #expect(throws: ItemPressError.notFound) { try await scanner.press(rig.item(.index(2))) }
        await #expect(throws: ItemPressError.notFound) { try await scanner.press(rig.item(.index(9))) }
        await #expect(throws: ItemPressError.notFound) { try await scanner.showMenu(rig.item(.index(2))) }
        #expect(rig.ax.pressed.isEmpty, "nothing else is pressed in its place")
        #expect(rig.ax.performedActions.isEmpty)
    }

    @Test func aNameThatIsNotThereIsNotFound() async throws {
        let rig = Rig([.init(title: "Weather", identifier: "weather.temp"), .init(title: "Alerts")])
        let scanner = rig.scanner()

        await #expect(throws: ItemPressError.notFound) { try await scanner.press(rig.item(.identifier("weather.gone"))) }
        #expect(rig.ax.pressed.isEmpty)
    }

    @Test func anAppThatIsNotRunningIsNotFound() async throws {
        let rig = Rig([.init(title: "Weather", identifier: "weather.temp")], appRunning: false)
        let scanner = rig.scanner()

        await #expect(throws: ItemPressError.notFound) { try await scanner.press(rig.item(.identifier("weather.temp"))) }
    }

    @Test func withoutAccessibilityNothingIsPressed() async throws {
        let rig = Rig([.init(title: "Weather", identifier: "weather.temp")])
        let scanner = rig.scanner(trusted: false)

        await #expect(throws: ItemPressError.notTrusted) { try await scanner.press(rig.item(.identifier("weather.temp"))) }
        await #expect(throws: ItemPressError.notTrusted) { try await scanner.showMenu(rig.item(.identifier("weather.temp"))) }
        #expect(rig.ax.pressed.isEmpty)
    }

    @Test func aRefusedPressIsSaidSo() async throws {
        let rig = Rig([.init(title: "Weather", identifier: "weather.temp")])
        rig.ax.failPress(on: rig.items[0], with: .timeout)
        let scanner = rig.scanner()

        await #expect(throws: ItemPressError.noAnswer) {
            try await scanner.press(rig.item(.identifier("weather.temp")))
        }
        // Mantel is trusted here, so an app that says "not trusted" refuses Accessibility itself: Mantel's grant isn't to blame.
        rig.ax.failPress(on: rig.items[0], with: .notTrusted)
        await #expect(throws: ItemPressError.refused("the app refuses to be controlled by other apps")) {
            try await scanner.press(rig.item(.identifier("weather.temp")))
        }
        rig.ax.failPress(on: rig.items[0], with: .failure(-25205))
        await #expect(throws: ItemPressError.refused("macOS said -25205")) { try await scanner.press(rig.item(.identifier("weather.temp"))) }
    }

    @Test func anAppThatDoesNotAnswerIsNotNotFound() async throws {
        let rig = Rig([.init(title: "Weather", identifier: "weather.temp")])
        rig.ax.failReads(on: rig.ax.root(ofApp: appPID), with: .timeout)
        let scanner = rig.scanner()

        await #expect(throws: ItemPressError.refused("the app didn't answer in time")) {
            try await scanner.press(rig.item(.identifier("weather.temp")))
        }
    }

    // MARK: Menus

    @Test func showMenuPerformsTheAction() async throws {
        let rig = Rig([.init(title: "Weather", identifier: "weather.temp"), .init(title: "Alerts", identifier: "weather.alerts")])
        rig.ax.setActions(["AXPress", "AXShowMenu"], on: rig.items[1])

        try await rig.scanner().showMenu(rig.item(.identifier("weather.alerts")))

        #expect(rig.ax.performedActions == [FakeAX.Performed(id: rig.items[1], action: "AXShowMenu")])
        #expect(rig.ax.pressed.isEmpty, "a menu is opened by its own action, not by a press")
    }

    @Test func showMenuWithoutActionIsNoShowMenu() async throws {
        let rig = Rig([.init(title: "Weather", identifier: "weather.temp")])
        rig.ax.setActions(["AXPress"], on: rig.items[0])
        let scanner = rig.scanner()

        await #expect(throws: ItemPressError.noShowMenu) { try await scanner.showMenu(rig.item(.identifier("weather.temp"))) }
        #expect(rig.ax.performedActions.isEmpty, "nothing was asked of an element that doesn't offer it")
    }

    @Test func aRefusedShowMenuIsSaidSo() async throws {
        let rig = Rig([.init(title: "Weather", identifier: "weather.temp")])
        rig.ax.setActions(["AXShowMenu"], on: rig.items[0])
        rig.ax.failPerform(on: rig.items[0], with: .failure(-25204))
        let scanner = rig.scanner()

        await #expect(throws: ItemPressError.refused("macOS said -25204")) { try await scanner.showMenu(rig.item(.identifier("weather.temp"))) }
    }

    @Test func aTimeoutReadingTheActionsIsNotAnActionThatWasSent() async throws {
        // Reading the actions sends nothing: an app that doesn't answer that was never asked to open its menu.
        let rig = Rig([.init(title: "Weather", identifier: "weather.temp")])
        rig.ax.setActions(["AXShowMenu"], on: rig.items[0])
        rig.ax.failActions(on: rig.items[0], with: .timeout)
        let scanner = rig.scanner()

        await #expect(throws: ItemPressError.refused("the app didn't answer in time")) {
            try await scanner.showMenu(rig.item(.identifier("weather.temp")))
        }
        #expect(rig.ax.performedActions.isEmpty, "AXShowMenu was never performed")

        // The action itself timing out is the one that may have been sent.
        rig.ax.failActions(on: rig.items[0], with: nil)
        rig.ax.failPerform(on: rig.items[0], with: .timeout)
        await #expect(throws: ItemPressError.noAnswer) { try await scanner.showMenu(rig.item(.identifier("weather.temp"))) }
        #expect(rig.ax.performedActions == [FakeAX.Performed(id: rig.items[0], action: "AXShowMenu")])
    }

    // MARK: The system's items

    @Test func aSystemItemIsPressedInTheAppThatListsIt() async throws {
        let ax = FakeAX()
        let controlCenter = ax.addApp(pid: 1500, extras: [.init(title: "Wi-Fi", identifier: "com.apple.menuextra.wifi"),
                                                          .init(title: "Sound", identifier: "com.apple.menuextra.sound")])
        let running: [RunningApp] = [.fake(agentPID, MenuBarReader.menuBarAgentBundleID), .fake(1500, "com.apple.controlcenter", "Control Center"),
                                     .fake(appPID, bundle, "Weather")]
        let scanner = MenuBarScanner(ax: ax, runningApps: { running }, layout: { desk }, ownBundleID: InventoryFixtures.ownBundleID,
                                     isTrusted: { true }, clock: FakeClock())

        try await scanner.press(.system("sound"))

        #expect(ax.pressed == [controlCenter[1]])
        await #expect(throws: ItemPressError.notFound) { try await scanner.press(.system("bluetooth")) }
    }

    // MARK: What the scanner is

    @Test func scannerIsALocatorAndAPresser() {
        let rig = Rig([.init(title: "Weather")])
        let scanner = rig.scanner()
        // Compiles as both, so that the probes and the click driver can be given the scanner.
        let locator: any ItemLocating = scanner
        let presser: any ItemPressing = scanner
        #expect(locator is MenuBarScanner)
        #expect(presser is MenuBarScanner)
        let both: any ItemLocating & ItemPressing = scanner
        #expect(both is MenuBarScanner)
    }

    @Test func pressErrorsSayWhatHappened() {
        #expect(ItemPressError.notFound.errorDescription == "That icon isn't in the menu bar right now.")
        #expect(ItemPressError.noShowMenu.errorDescription == "That icon doesn't open a menu that way.")
        #expect(ItemPressError.refused("the app didn't answer in time").errorDescription == "The icon didn't respond: the app didn't answer in time")
        #expect(ItemPressError.noAnswer.errorDescription == "The icon didn't answer in time.")
        #expect(ItemPressError.notTrusted.errorDescription?.contains("Device control and data access") == true)
    }
}
