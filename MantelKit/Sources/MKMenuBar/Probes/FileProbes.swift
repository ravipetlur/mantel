import CoreGraphics
import Foundation
import MKCommands
import MKCore

/// What the probes add to the granted files: the same calls with the probe's own parts, the check that a write reached the file,
/// and the spelling of a strategy.
extension GrantedFile {
    static func url(of kind: FileGrantKind, in context: ProbeContext) async -> URL? {
        await url(of: kind, in: context.grants)
    }

    static func readTopLevel(_ kind: FileGrantKind, in context: ProbeContext) async throws -> [String: PlistValue] {
        try await readTopLevel(kind, grants: context.grants, plist: context.plist)
    }

    /// How long after `start` the file on disk holds `value` under `key` (or, with a `path`, at that place inside `key`), polled
    /// every 20 ms for a second; nil when it never does in that time. `cfprefsd`, which a `cfPreferences` write goes through,
    /// keeps what it is told in its cache and writes the file in its own time, and may not write it at all (a domain it won't
    /// write for the caller); so a write that `PlistFileAccess` has checked through the cache is not yet known to be in the file.
    static func fileHolds(_ value: PlistValue, forKey key: String, at path: PlistKeyPath = [], of kind: FileGrantKind, since start: Date,
                          in context: ProbeContext) async throws -> Double? {
        let deadline = start.addingTimeInterval(1)
        while true {
            try Task.checkCancellation()
            if let top = try? await readTopLevel(kind, in: context), top[key]?.value(at: path) == value {
                return context.milliseconds(since: start)
            }
            if context.clock.now() >= deadline { return nil }
            try await context.clock.sleep(for: .milliseconds(20))
        }
    }

    /// Records whether the file holds what was written, and when; says so in the notes when it doesn't.
    static func recordFileCheck(_ elapsed: Double?, _ recorder: inout ProbeRecorder) {
        recorder.measure("persistedToFile", elapsed != nil)
        recorder.measure("writtenToFileMs", elapsed.map(JSONValue.number) ?? .null)
        if elapsed == nil {
            recorder.note("The value was accepted, but the file on disk didn't hold it within 1 s of the write.")
        }
    }

    /// How a strategy is spelled in the options; `cfPreferences` unless it says otherwise.
    static func strategy(_ options: ProbeOptions) -> PlistWriteStrategy? {
        switch options.string("strategy") {
        case nil, "cfPreferences": .cfPreferences
        case "atomicFile": .atomicFile
        default: nil
        }
    }
}

/// `approvals-read`: the shape of the "Allow in the Menu Bar" file: its keys, the kinds of value in `trackedApplications`
/// (never the values), and whether the test item is in it.
enum ApprovalsReadProbe {
    static func run(_ context: ProbeContext, _ recorder: inout ProbeRecorder) async {
        guard await GrantedFile.url(of: .controlCenterApprovals, in: context) != nil else {
            recorder.fail(GrantedFile.missing(.controlCenterApprovals))
            return
        }
        let top: [String: PlistValue]
        do {
            top = try await GrantedFile.readTopLevel(.controlCenterApprovals, in: context)
        } catch {
            recorder.fail("The approvals file couldn't be read: \(error.localizedDescription)")
            return
        }
        recorder.measure("topLevelKeys", strings: top.keys.sorted())
        if let tracked = top["trackedApplications"] {
            recorder.measure("trackedApplications", PlistShape.describe(tracked))
            recorder.measure("fixtureBundleIDPresent", PlistShape.contains(tracked, string: context.fixtureBundleID))
        } else {
            recorder.measure("trackedApplications", .null)
            recorder.measure("fixtureBundleIDPresent", false)
            recorder.note("The file has no trackedApplications key.")
        }
    }
}

/// `approvals-toggle`: flips an app's "Allow in the Menu Bar" flag, sees whether the menu bar follows, and puts it back.
///
/// The change is journaled before it is made, so a crash in the middle leaves the original in the journal and the next
/// launch puts it back. `app` defaults to the test item; `strategy` to `cfPreferences`.
enum ApprovalsToggleProbe {
    private static let key = "trackedApplications"

    static func run(_ context: ProbeContext, _ recorder: inout ProbeRecorder) async {
        let app = context.options.string("app") ?? context.fixtureBundleID
        if case .failure(let refusal) = ProbeSafety.permitted([app], options: context.options) {
            recorder.fail(refusal.message)
            return
        }
        guard let strategy = GrantedFile.strategy(context.options) else {
            recorder.fail("The strategy is cfPreferences or atomicFile.")
            return
        }
        guard let url = await GrantedFile.url(of: .controlCenterApprovals, in: context) else {
            recorder.fail(GrantedFile.missing(.controlCenterApprovals))
            return
        }
        let top: [String: PlistValue]
        do {
            top = try await GrantedFile.readTopLevel(.controlCenterApprovals, in: context)
        } catch {
            recorder.fail("The approvals file couldn't be read: \(error.localizedDescription)")
            return
        }
        guard let tracked = top[key], let flip = ApprovalsEditor.flipped(tracked, bundleID: app) else {
            recorder.fail("Couldn't find \(app) with an allowed flag in trackedApplications. Run approvals-read to see what the file holds.")
            return
        }
        recorder.measure("strategy", strategy.rawValue)
        recorder.measure("flag", flip.path)
        recorder.measure("wasAllowed", flip.wasAllowed)

        let beforeKeys = ProbeContext.framedKeys(await context.snapshot())
        let started = context.clock.now()
        recorder.changeBegan()
        var cutShort = false
        do {
            try await context.plist.write(flip.value, key: key, in: url, strategy: strategy)
            GrantedFile.recordFileCheck(
                try await GrantedFile.fileHolds(flip.value, forKey: key, of: .controlCenterApprovals, since: started, in: context), &recorder)
            let outcome = try await context.poll(every: 50, upTo: 5000, from: started, until: { ProbeContext.framedKeys($0) != beforeKeys })
            recorder.measure(poll: "writeToVisibleChange", outcome.trace)
            if let seen = outcome.hit {
                recorder.measure("writeToVisibleChangeMs", seen.elapsedMs)
            } else {
                recorder.measure("writeToVisibleChangeMs", .null)
                recorder.note("The menu bar showed no change within 5 s of the write.")
            }
        } catch is CancellationError {
            cutShort = true
            recorder.note("The probe was cut short; the flag was put back.")
        } catch {
            recorder.fail("The flag couldn't be changed: \(error.localizedDescription)")
        }

        // Put back, whatever happened above. A change that didn't get as far as the journal has nothing to put back.
        let undoStarted = context.clock.now()
        do {
            try await context.plist.undo(key: key, in: url)
            recorder.changeUndone()
        } catch {
            recorder.undoFailed("The flag couldn't be put back: \(error.localizedDescription) Mantel puts it back when it next starts.")
            return
        }
        guard !cutShort else { return }
        do {
            let outcome = try await context.poll(every: 50, upTo: 5000, from: undoStarted, until: { ProbeContext.framedKeys($0) == beforeKeys })
            recorder.measure(poll: "restoreToVisible", outcome.trace)
            if let back = outcome.hit {
                recorder.measure("restoreToVisibleMs", back.elapsedMs)
            } else {
                recorder.measure("restoreToVisibleMs", .null)
                recorder.note("The menu bar didn't show the flag put back within 5 s.")
            }
        } catch {
            recorder.note("The probe was cut short after the flag was put back.")
        }
    }
}

/// `layout-read`: the shape of the layout file: its keys, how many items are in the order table and in what formats their
/// keys are (the prefixes only), and the test item's entries.
enum LayoutReadProbe {
    static func run(_ context: ProbeContext, _ recorder: inout ProbeRecorder) async {
        guard await GrantedFile.url(of: .menuBarLayout, in: context) != nil else {
            recorder.fail(GrantedFile.missing(.menuBarLayout))
            return
        }
        let top: [String: PlistValue]
        do {
            top = try await GrantedFile.readTopLevel(.menuBarLayout, in: context)
        } catch {
            recorder.fail("The layout file couldn't be read: \(error.localizedDescription)")
            return
        }
        recorder.measure("topLevelKeys", strings: top.keys.sorted())
        guard case .dictionary(let positions)? = top[LayoutKeys.trailingPositions] else {
            recorder.measure("trailingItemCount", 0)
            recorder.note("The file has no \(LayoutKeys.trailingPositions) table.")
            return
        }
        recorder.measure("trailingItemCount", positions.count)
        var prefixes: [String: Int] = [:]
        for key in positions.keys { prefixes[LayoutKeys.prefix(of: key), default: 0] += 1 }
        recorder.measure("keyPrefixes", .object(prefixes.mapValues { .number(Double($0)) }))
        var fixtureEntries: [String: JSONValue] = [:]
        for (key, value) in positions where key.contains(context.fixtureBundleID) {
            fixtureEntries[key] = switch value {
            case .integer(let number): .number(Double(number))
            case .real(let number): .number(number)
            default: .string(PlistShape.typeName(value))
            }
        }
        recorder.measure("fixtureEntries", .object(fixtureEntries))
    }
}

/// `layout-move`: changes an item's distance in the layout table, sees whether the menu bar re-sorts, and puts it back.
/// `key` defaults to the test item's first item; `distance` to 60 more than it has now.
///
/// Only that one entry is written, as a place inside the table (`PlistFileAccess.write(_ edits:…)`), and only that one entry is
/// put back: the other items' distances, which macOS may change while the probe runs, are left as they are.
enum LayoutMoveProbe {
    static func run(_ context: ProbeContext, _ recorder: inout ProbeRecorder) async {
        let options = context.options
        guard let strategy = GrantedFile.strategy(options) else {
            recorder.fail("The strategy is cfPreferences or atomicFile.")
            return
        }
        guard let url = await GrantedFile.url(of: .menuBarLayout, in: context) else {
            recorder.fail(GrantedFile.missing(.menuBarLayout))
            return
        }
        let top: [String: PlistValue]
        do {
            top = try await GrantedFile.readTopLevel(.menuBarLayout, in: context)
        } catch {
            recorder.fail("The layout file couldn't be read: \(error.localizedDescription)")
            return
        }
        guard case .dictionary(let positions)? = top[LayoutKeys.trailingPositions] else {
            recorder.fail("The layout file has no \(LayoutKeys.trailingPositions) table, so there is nothing to move. Run layout-read.")
            return
        }

        let key = options.string("key")
            ?? positions.keys.sorted().first { $0.contains(context.fixtureBundleID) }
            ?? context.fixtureLayoutKeys[0]
        if case .failure(let refusal) = ProbeSafety.permitted([LayoutKeys.bundleID(ofStatusKey: key) ?? key], options: options) {
            recorder.fail(refusal.message)
            return
        }
        let current: Double
        switch positions[key] {
        case .integer(let number)?: current = Double(number)
        case .real(let number)?: current = number
        default: current = 0
        }
        let distance: Double
        if let text = options.string("distance") {
            guard let parsed = Double(text), parsed.isFinite else {
                recorder.fail("The distance is a number.")
                return
            }
            distance = parsed
        } else {
            distance = current + 60
        }
        let moved: PlistValue = distance == distance.rounded() ? .integer(Int(distance)) : .real(distance)
        let place: PlistKeyPath = [.key(key)]
        recorder.measure("strategy", strategy.rawValue)
        recorder.measure("key", key)
        recorder.measure("distance", distance)

        let beforeOrder = ProbeContext.framedOrder(await context.snapshot())
        let started = context.clock.now()
        recorder.changeBegan()
        do {
            try await context.plist.write([PathEdit(path: place, value: moved)], key: LayoutKeys.trailingPositions, in: url,
                                          strategy: strategy)
            GrantedFile.recordFileCheck(
                try await GrantedFile.fileHolds(moved, forKey: LayoutKeys.trailingPositions, at: place, of: .menuBarLayout,
                                                since: started, in: context), &recorder)
            let outcome = try await context.poll(every: 50, upTo: 3000, from: started, until: { ProbeContext.framedOrder($0) != beforeOrder })
            recorder.measure(poll: "writeToResort", outcome.trace)
            if let seen = outcome.hit {
                recorder.measure("writeToResortMs", seen.elapsedMs)
                recorder.measure("resortApplied", true)
            } else {
                recorder.measure("writeToResortMs", .null)
                recorder.measure("resortApplied", false)
                recorder.note("The order of the items didn't change within 3 s of the write.")
            }
        } catch is CancellationError {
            recorder.note("The probe was cut short; the table was put back.")
        } catch {
            recorder.fail("The table couldn't be changed: \(error.localizedDescription)")
        }

        // Put back, whatever happened above. A change that didn't get as far as the journal has nothing to put back.
        do {
            try await context.plist.undo(path: place, key: LayoutKeys.trailingPositions, in: url)
            recorder.changeUndone()
        } catch {
            recorder.undoFailed("The table couldn't be put back: \(error.localizedDescription) Mantel puts it back when it next starts.")
        }
    }
}

/// `grant-persistence`: for each file grant, whether its bookmark still resolves, whether it is stale, whether access can be
/// started and whether the file can be read. Run it before and after a relaunch. Only reads.
enum GrantPersistenceProbe {
    static func run(_ context: ProbeContext, _ recorder: inout ProbeRecorder) async {
        var reports: [String: JSONValue] = [:]
        for kind in FileGrantKind.allCases {
            guard let grant = await context.grants.grant(for: kind) else {
                reports[kind.rawValue] = .object(["granted": .bool(false)])
                continue
            }
            reports[kind.rawValue] = .object(inspect(grant))
        }
        recorder.measure("grants", .object(reports))
        recorder.note("Run this before and after a relaunch; a grant that doesn't survive shows as not resolving.")
    }

    private static func inspect(_ grant: FileGrant) -> [String: JSONValue] {
        var report: [String: JSONValue] = ["granted": .bool(true), "path": .string(grant.path)]

        var stale = false
        var resolved: URL?
        do {
            resolved = try URL(resolvingBookmarkData: grant.bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                               relativeTo: nil, bookmarkDataIsStale: &stale)
            report["resolvesWithSecurityScope"] = .bool(true)
        } catch {
            let nsError = error as NSError
            report["resolvesWithSecurityScope"] = .bool(false)
            report["securityScopeError"] = .string("\(nsError.domain) \(nsError.code)")
        }
        if resolved == nil {
            resolved = try? URL(resolvingBookmarkData: grant.bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil,
                                bookmarkDataIsStale: &stale)
        }
        report["resolves"] = .bool(resolved != nil)
        report["isStale"] = .bool(stale)
        guard let url = resolved else {
            report["startAccessing"] = .bool(false)
            report["readable"] = .bool(false)
            return report
        }

        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        report["startAccessing"] = .bool(accessing)
        report["readable"] = .bool((try? FileHandle(forReadingFrom: url).read(upToCount: 1)) != nil)
        return report
    }
}
