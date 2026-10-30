import CoreGraphics
import Foundation
import MKCommands
import MKCore

/// What the probes know of the test item: what its items are called, how it is started, and what it writes when one of them is clicked.
///
/// The test item has two items, `one` and `two`; started with `--extra N` it has N more, `extra.1` to `extra.N`; started with `--single`
/// it has `one` alone. Each is kept in the menu bar's order table under its autosave name, `mantel.fixture.` and the short name.
enum TestItemNames {
    /// What each item's autosave name starts with.
    static let autosavePrefix = "mantel.fixture."
    /// The most extra items the test item can be started with.
    static let maximumExtras = 20

    /// Whether `name` is one of the test item's items: `one`, `two`, or `extra.<n>` for n from 1 to `maximumExtras`.
    static func isValid(_ name: String) -> Bool {
        name == "one" || name == "two" || extraNumber(of: name) != nil
    }

    /// The name the system keeps the item's place under.
    static func autosaveName(_ name: String) -> String {
        autosavePrefix + name
    }

    /// n for `extra.<n>`; nil for any other name, and for an n outside 1 to `maximumExtras`.
    static func extraNumber(of name: String) -> Int? {
        guard name.hasPrefix("extra."), let number = Int(name.dropFirst("extra.".count)), (1...maximumExtras).contains(number) else {
            return nil
        }
        return number
    }

    /// The names of the items of a test item that has this many: `one`; `one` and `two`; and then `extra.1` and on.
    static func names(itemCount: Int) -> [String] {
        guard itemCount > 0 else { return [] }
        var names = ["one"]
        if itemCount >= 2 { names.append("two") }
        if itemCount > 2 { names += (1...(itemCount - 2)).map { "extra.\($0)" } }
        return names
    }

    /// What opens a test item that has this many items again with as many: nothing for the plain two, `--single` for one, and
    /// `--extra N` for the ones that have N more.
    static func launchArguments(itemCount: Int) -> [String] {
        switch itemCount {
        case ..<2: ["--single"]
        case 2: []
        default: launchArguments(extras: itemCount - 2)
        }
    }

    /// What opens a test item with this many extra items.
    static func launchArguments(extras: Int) -> [String] {
        extras > 0 ? ["--extra", String(min(extras, maximumExtras))] : []
    }
}

/// What the test item writes to `clicks.json` in its own folder when `one` or `two` receives a click: which item, what kind of click it
/// was and when, in seconds since 1970. The file holds the last one only.
struct TestItemClick: Decodable, Equatable {
    let item: String
    let kind: String
    let at: Double
}

/// The probes' reading of that file. Nothing here writes it: the test item does.
enum TestItemClickLog {
    static let fileName = "clicks.json"

    /// The record in the folder; nil when there is no file or it holds no record.
    static func latest(in folder: URL) -> TestItemClick? {
        guard let data = try? Data(contentsOf: folder.appending(path: fileName, directoryHint: .notDirectory)) else { return nil }
        return try? JSONDecoder().decode(TestItemClick.self, from: data)
    }

    /// The kind of click `item` (`one` or `two`) received, if it received one at `sent` or after. Nil when there is no file, when what is in
    /// it is no record, when it is another item's, and when it is older than the click: the file keeps the last record, and a click that
    /// nothing answered would otherwise be given the answer to one before it.
    static func kindReceived(by item: String, since sent: Date, in folder: URL) -> String? {
        guard let record = latest(in: folder), record.item == item, record.at >= sent.timeIntervalSince1970 else { return nil }
        return record.kind
    }
}

extension ProbeContext {
    /// An item of the test item, by the name its place in the order table is kept under.
    func fixtureItemID(_ name: String) -> ItemID {
        ItemID(bundleID: fixtureBundleID, key: .identifier(TestItemNames.autosaveName(name)))
    }

    /// The running test item as an app that can be relaunched, with `arguments`; nil when it isn't running or has no bundle to open again.
    /// It is the test item and nothing else, whatever the options say: no probe relaunches another app.
    func fixtureRelaunchCandidate(arguments: [String]) -> RelaunchCandidate? {
        guard let app = platform.runningApps().first(where: { $0.bundleID == fixtureBundleID }), let url = app.bundleURL else { return nil }
        return RelaunchCandidate(id: fixtureBundleID, name: app.name ?? "MantelTestItem", pid: app.pid, bundleURL: url, arguments: arguments)
    }

    /// The same app as `old`, with the process it is now: after it has been relaunched it is another process, and a request to quit the old one
    /// would find nothing, and opening the app would only bring the new one forward. (An app that isn't running keeps the old one's.)
    func fixtureRelaunchCandidate(refreshing old: RelaunchCandidate) -> RelaunchCandidate {
        let pid = platform.runningApps().first(where: { $0.bundleID == fixtureBundleID })?.pid ?? old.pid
        return RelaunchCandidate(id: old.id, name: old.name, pid: pid, bundleURL: old.bundleURL, arguments: old.arguments)
    }

    /// How many items the running test item lists in its own menu bar; nil when it isn't running or lists none.
    func fixtureItemCount() -> Int? {
        guard let pid = platform.runningApps().first(where: { $0.bundleID == fixtureBundleID })?.pid,
              let frames = reader.extrasFrames(ofPID: pid), !frames.isEmpty else { return nil }
        return frames.count
    }

    /// Where each of these items of the test item is on the main display now (`locate`, with no snapshot): the ones that are located.
    func locateFixtureItems(_ names: [String]) async -> [String: ItemLocation] {
        var found: [String: ItemLocation] = [:]
        for name in names {
            if let location = await platform.locator.locate(fixtureItemID(name), on: nil, since: nil) { found[name] = location }
        }
        return found
    }

    /// Waits until every one of these items is located (every 100 ms, for `timeoutMs` at most). The locations of the ones that were found
    /// when it ended, and the milliseconds from the call until all were (nil when some never were).
    func waitForFixtureItems(_ names: [String], upTo timeoutMs: Double = 5000) async throws -> (found: [String: ItemLocation], allFoundMs: Double?) {
        let started = clock.now()
        var found: [String: ItemLocation] = [:]
        while true {
            try Task.checkCancellation()
            found = await locateFixtureItems(names)
            if found.count == names.count { return (found, milliseconds(since: started)) }
            if milliseconds(since: started) >= timeoutMs { return (found, nil) }
            try await clock.sleep(for: .milliseconds(100))
        }
    }
}

/// How the probes put numbers and rectangles into a report.
enum ProbeJSON {
    static func number(_ value: Double?) -> JSONValue {
        value.map(JSONValue.number) ?? .null
    }

    static func number(_ value: CGFloat?) -> JSONValue {
        value.map { JSONValue.number(Double($0)) } ?? .null
    }

    static func rect(_ rect: CGRect?) -> JSONValue {
        rect.map(NotchCoordinatesProbe.rect) ?? .null
    }

    static func flag(_ value: Bool?) -> JSONValue {
        value.map(JSONValue.bool) ?? .null
    }

    static func text(_ value: String?) -> JSONValue {
        value.map(JSONValue.string) ?? .null
    }
}
