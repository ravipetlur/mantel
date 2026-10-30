import Foundation
import MKCore
import Testing

@testable import MKMenuBar

/// Which apps are offered for a relaunch. Apps and bundle IDs are made up (`com.example.*`) or Apple's own.
@Suite("Relaunch plan")
struct RelaunchPlanTests {
    private let own = "com.example.mantel"

    private func item(_ bundleID: String, index: Int = 0, isMantel: Bool = false) -> MenuBarItem {
        MenuBarItem(id: ItemID(bundleID: bundleID, key: .index(index)), ownerBundleID: bundleID, appName: nil, label: nil, frames: [:],
                    overflowedOn: [], isMantel: isMantel)
    }

    private func inventory(_ items: [MenuBarItem]) -> Inventory {
        Inventory(capturedAt: Date(timeIntervalSince1970: 1_700_000_000), bars: [], items: items, chevrons: [:], reach: [], problems: [])
    }

    private func app(_ pid: pid_t, _ bundleID: String, name: String? = nil, url: String? = nil) -> RunningApp {
        RunningApp(pid: pid, bundleID: bundleID, name: name,
                   bundleURL: url.map { URL(filePath: "/Applications/\($0).app") }, isBackgroundOnly: false)
    }

    private func candidates(_ items: [MenuBarItem], _ running: [RunningApp]) -> [RelaunchCandidate] {
        RelaunchPlan.candidates(inventory: inventory(items), running: running, ownBundleID: own)
    }

    @Test func onlyRunningAppsWithIconsAndBundleURLs() {
        let items = [item("com.example.weather"), item("com.example.notes"), item("com.example.vpn")]
        let running = [
            app(10, "com.example.weather", name: "Weather", url: "Weather"),
            app(11, "com.example.notes", name: "Notes", url: nil),        // no bundle on disk to open again
            app(12, "com.example.helper", name: "Helper", url: "Helper"), // running, but draws no icon
            // com.example.vpn isn't running
        ]

        let result = candidates(items, running)

        #expect(result.map(\.id) == ["com.example.weather"])
        #expect(result.first?.pid == 10)
        #expect(result.first?.bundleURL == URL(filePath: "/Applications/Weather.app"))
        #expect(result.first?.name == "Weather")
        #expect(result.first?.arguments == [])
    }

    @Test func neverMantelOrApple() {
        let items = [item(own, isMantel: true), item("com.example.mantel.helper"), item("com.apple.Safari"), item("com.Apple.Notes"),
                     item("com.apple.menuextra.clock"), item("com.example.sync")]
        let running = [
            app(1, own, url: "Mantel"), app(2, "com.example.mantel.helper", url: "Helper"), app(3, "com.apple.Safari", url: "Safari"),
            app(4, "com.Apple.Notes", url: "Notes"), app(5, "com.example.sync", name: "Sync", url: "Sync"),
        ]

        let result = candidates(items, running)

        // Mantel's own bundle ID is left out whatever its items say; one that only starts like it is another app.
        #expect(result.map(\.id) == ["com.example.mantel.helper", "com.example.sync"])
    }

    @Test func sortedByName() {
        let items = [item("com.example.c"), item("com.example.a"), item("com.example.b"), item("com.example.d")]
        let running = [
            app(1, "com.example.c", name: "App 10", url: "C"),
            app(2, "com.example.a", name: "zebra", url: "A"),
            app(3, "com.example.b", name: "App 2", url: "B"),
            app(4, "com.example.d", name: "Éclair", url: "D"),
        ]

        let result = candidates(items, running)

        // The order Settings lists apps in: without regard to case or accents, and numbers by their value.
        #expect(result.map(\.name) == ["App 2", "App 10", "Éclair", "zebra"])
    }

    @Test func eachAppOnce() {
        // Three icons of one app, and two copies of it running (a helper with the same bundle ID).
        let items = [item("com.example.sync", index: 0), item("com.example.sync", index: 1), item("com.example.sync", index: 2)]
        let running = [app(20, "com.example.sync", name: "Sync", url: nil), app(21, "com.example.sync", name: "Sync", url: "Sync"),
                       app(22, "com.example.sync", name: "Sync", url: "Sync")]

        let result = candidates(items, running)

        #expect(result.map(\.id) == ["com.example.sync"])
        #expect(result.first?.pid == 21, "the first that can be opened again")
    }

    @Test func anAppWithoutANameIsNamedAfterItsBundle() {
        let items = [item("com.example.weather")]
        let result = candidates(items, [app(10, "com.example.weather", name: " ", url: "Weather Station")])

        #expect(result.first?.name == "Weather Station")
    }

    @Test func nothingWhenNothingIsRunning() {
        #expect(candidates([item("com.example.weather")], []).isEmpty)
        #expect(candidates([], [app(10, "com.example.weather", url: "Weather")]).isEmpty)
    }
}
