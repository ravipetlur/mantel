import CoreGraphics
import Foundation
import MKCommands
import MKCore
import MKTestSupport
import Synchronization
import Testing

@testable import MKMenuBar

// The fakes a probe test is made of. Nothing here reaches the real system: the menu bar is a `FakeAX` tree, the allowlist,
// the capture, the window list and the click tap are fakes that note what they were asked, and the plist files are in a
// temporary folder that goes away with the test.

/// A yes or no a test can turn over while a probe runs.
final class Switch: Sendable {
    private let flag: Mutex<Bool>

    init(_ isOn: Bool) { flag = Mutex(isOn) }

    var isOn: Bool { flag.withLock { $0 } }
    func set(_ isOn: Bool) { flag.withLock { $0 = isOn } }
}

/// Which apps the fake allowlist is hiding at the moment. A slot of a hidden app has no frame.
final class HiddenApps: Sendable {
    private let hidden = Mutex<Set<String>>([])

    var all: Set<String> { hidden.withLock { $0 } }
    func set(_ apps: Set<String>) { hidden.withLock { $0 = apps } }
    func contains(_ app: String) -> Bool { hidden.withLock { $0.contains(app) } }
}

/// An allowlist that hides what it is not told to allow, in the fake menu bar, and notes every call.
final class FakeAllowlist: AllowlistControlling {
    struct Call: Equatable {
        let systemItems: [Int]
        let bundleIDs: [String]
    }

    private struct State {
        var calls: [Call] = []
        var invalidations = 0
        var live = 0
        var failure: AllowlistError?
        var inspection = FakeAllowlist.healthy
        /// The menu bar doesn't come back when an assertion is let go.
        var sticky = false
    }

    static let healthy = AllowlistInspection(
        frameworkLoaded: true, configurationClassFound: true, assertionClassFound: true,
        encodings: ["initWithAllowedSystemItems:allowedBundleIdentifiers:": "@32@0:8@16@24",
                    "activateWithConfiguration:completionHandler:": "v32@0:8@16@?24", "invalidate": "v16@0:8"],
        problem: nil)

    private let state = Mutex(State())
    private let hidden: HiddenApps
    private let everyApp: @Sendable () -> [String]
    /// Opened when an activation is asked for, so that a test knows a probe has got that far.
    let entered = Gate()
    /// If set, an activation waits for it.
    private let hold = Mutex<Gate?>(nil)
    /// Runs when an assertion has been made live: for a test where something else changes while it is held.
    private let afterActivation = Mutex<(@Sendable () -> Void)?>(nil)

    init(hidden: HiddenApps, everyApp: @escaping @Sendable () -> [String]) {
        self.hidden = hidden
        self.everyApp = everyApp
    }

    var calls: [Call] { state.withLock { $0.calls } }
    var invalidations: Int { state.withLock { $0.invalidations } }
    /// How many assertions are live now.
    var live: Int { state.withLock { $0.live } }

    func fail(with error: AllowlistError?) { state.withLock { $0.failure = error } }
    func makeReleaseNotRestore() { state.withLock { $0.sticky = true } }
    func setInspection(_ inspection: AllowlistInspection) { state.withLock { $0.inspection = inspection } }
    func holdActivations(until gate: Gate?) { hold.withLock { $0 = gate } }
    func onActivated(_ body: (@Sendable () -> Void)?) { afterActivation.withLock { $0 = body } }

    func inspect() -> AllowlistInspection { state.withLock { $0.inspection } }

    func activate(systemItems: [Int], bundleIDs: [String]) async throws -> any AllowlistAssertionHandle {
        state.withLock { $0.calls.append(Call(systemItems: systemItems, bundleIDs: bundleIDs)) }
        entered.open()
        if let gate = hold.withLock({ $0 }) { await gate.wait() }
        if let failure = state.withLock({ $0.failure }) { throw failure }
        // What isn't allowed is hidden: the union with what an earlier assertion hid is not modelled (an assertion that is
        // replaced is invalidated by its caller).
        hidden.set(Set(everyApp()).subtracting(bundleIDs))
        state.withLock { $0.live += 1 }
        afterActivation.withLock { $0 }?()
        return Handle(owner: self)
    }

    fileprivate func release() {
        let last = state.withLock { state -> Bool in
            state.invalidations += 1
            state.live = max(0, state.live - 1)
            return state.live == 0 && !state.sticky
        }
        if last { hidden.set([]) }
    }

    private final class Handle: AllowlistAssertionHandle {
        private let owner: FakeAllowlist
        private let released = Mutex(false)

        init(owner: FakeAllowlist) { self.owner = owner }

        func invalidate() {
            let first = released.withLock { released -> Bool in
                defer { released = true }
                return !released
            }
            if first { owner.release() }
        }
    }
}

/// A window list: Notification Center has a window on screen when `opens` says so.
final class FakeWindows: WindowWatching {
    private let opens: Mutex<@Sendable () -> Bool>
    private let reads = Mutex(0)

    /// By default nothing opens.
    init(opens: @escaping @Sendable () -> Bool = { false }) {
        self.opens = Mutex(opens)
    }

    func setOpens(_ opens: @escaping @Sendable () -> Bool) { self.opens.withLock { $0 = opens } }
    var readCount: Int { reads.withLock { $0 } }

    func onScreenWindows(ownedBy bundleID: String) -> Set<Int> {
        reads.withLock { $0 += 1 }
        guard bundleID == "com.apple.notificationcenterui" else { return [] }
        // One window that is always there (the desktop widgets), and a second when the click works.
        return opens.withLock { $0 }() ? [10, 11] : [10]
    }
}

/// A click tap that is told which clicks to see. It sees one when `deliverNext` says so, as the real tap does: the callback is
/// called on the spot and has returned before the replay is reported, `delay` later.
final class FakeTapFactory: Sendable {
    struct Made: Equatable {
        let rects: [CGRect]
        let delay: Duration
        let lifetime: Duration
    }

    /// A click as the tap saw it: how many times the allowlist had been lifted before it, and right after the click callback
    /// returned (so that a callback that lifts shows one more).
    struct Delivery: Equatable {
        let delay: Duration
        let liftsBefore: Int
        let liftsAfterTheClickCallback: Int
    }

    private struct State {
        var made: [Made] = []
        var started = 0
        var stopped = 0
        var startFailure = false
        var onClick: (@Sendable (CGPoint) -> Void)?
        var onReplay: (@Sendable (CGPoint) -> Void)?
        var delay: Duration = .zero
        var pending: [CGPoint]
        var deliveries: [Delivery] = []
    }

    private let state: Mutex<State>
    private let liftCount: @Sendable () -> Int

    /// - Parameters:
    ///   - clicks: the clicks the tap will see, one at a time.
    ///   - liftCount: how many times the allowlist has been lifted so far.
    init(clicks: [CGPoint] = [], liftCount: @escaping @Sendable () -> Int = { 0 }) {
        state = Mutex(State(pending: clicks))
        self.liftCount = liftCount
    }

    var made: [Made] { state.withLock { $0.made } }
    var started: Int { state.withLock { $0.started } }
    var stopped: Int { state.withLock { $0.stopped } }
    var deliveries: [Delivery] { state.withLock { $0.deliveries } }
    /// Whether the tap is on and a click is still to come.
    var hasAClickToDeliver: Bool { state.withLock { $0.started > $0.stopped && !$0.pending.isEmpty } }
    func failToStart() { state.withLock { $0.startFailure = true } }

    func make(rects: [CGRect], delay: Duration, lifetime: Duration, onClick: @escaping @Sendable (CGPoint) -> Void,
              onReplay: @escaping @Sendable (CGPoint) -> Void) -> any ClickReplaying {
        state.withLock {
            $0.made.append(Made(rects: rects, delay: delay, lifetime: lifetime))
            $0.onClick = onClick
            $0.onReplay = onReplay
            $0.delay = delay
        }
        return Tap(factory: self)
    }

    /// The next click comes: the click callback is called and returns, `delay` goes by (`advance` moves the test's clock), and
    /// the replay is reported. False when the tap isn't on or no click is left.
    @discardableResult
    func deliverNext(advance: (Duration) -> Void) -> Bool {
        let next = state.withLock { state -> (point: CGPoint, onClick: @Sendable (CGPoint) -> Void, onReplay: @Sendable (CGPoint) -> Void, delay: Duration)? in
            guard state.started > state.stopped, !state.pending.isEmpty, let onClick = state.onClick, let onReplay = state.onReplay else {
                return nil
            }
            return (state.pending.removeFirst(), onClick, onReplay, state.delay)
        }
        guard let next else { return false }
        let before = liftCount()
        next.onClick(next.point)
        let after = liftCount()
        state.withLock { $0.deliveries.append(Delivery(delay: next.delay, liftsBefore: before, liftsAfterTheClickCallback: after)) }
        advance(next.delay)
        next.onReplay(next.point)
        return true
    }

    private final class Tap: ClickReplaying {
        let factory: FakeTapFactory

        init(factory: FakeTapFactory) {
            self.factory = factory
        }

        func start() throws {
            if factory.state.withLock({ $0.startFailure }) { throw ClickReplayError.tapUnavailable }
            factory.state.withLock { $0.started += 1 }
        }

        func stop() { factory.state.withLock { $0.stopped += 1 } }
    }
}

/// A clock that, when something sleeps on it, first lets a hook run. A click-replay test uses it to have the next click come
/// while the probe is waiting for one with the allowlist live: the only time a person's click can come.
final class ClickDeliveryClock: Clock {
    private let base: any Clock
    private let hook = Mutex<(@Sendable () -> Void)?>(nil)

    init(base: any Clock) {
        self.base = base
    }

    func onSleep(_ hook: (@Sendable () -> Void)?) { self.hook.withLock { $0 = hook } }

    /// Moves the base clock on, which is what `delay` going by is.
    func advance(_ duration: Duration) {
        (base as? SteppingClock)?.advance(by: duration)
        (base as? FakeClock)?.advance(by: duration)
    }

    func now() -> Date { base.now() }

    func sleep(for duration: Duration) async throws {
        hook.withLock { $0 }?()
        try await base.sleep(for: duration)
    }
}

/// A capture that makes a flat image of the strip's size, and notes which displays it was asked for.
final class FakeCapture: StripCapturing {
    private let asked = Mutex<[String]>([])
    private let failure = Mutex<StripCaptureError?>(nil)

    var displays: [String] { asked.withLock { $0 } }
    func fail(with error: StripCaptureError?) { failure.withLock { $0 = error } }

    func capture(display: DisplayInfo, layout: DisplayLayout) async throws -> CGImage {
        asked.withLock { $0.append(display.uuid) }
        if let error = failure.withLock({ $0 }) { throw error }
        let geometry = try StripGeometry.of(display, in: layout)
        let context = CGContext(data: nil, width: Int(geometry.pixelSize.width), height: Int(geometry.pixelSize.height),
                                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [0.2, 0.4, 0.6, 1])!)
        context.fill(CGRect(origin: .zero, size: geometry.pixelSize))
        return context.makeImage()!
    }
}

extension PlistIO {
    /// Both strategies done on the file itself. The probe tests use it, and never the real `cfprefsd`: it is the system's
    /// preferences service, shared with every app, and a domain in a folder that looks like a group container isn't one a
    /// test can be sure stays in its temporary folder. (`PlistFileAccessTests` tries the real one on a plain temporary file.)
    static let filesOnly = PlistIO(
        read: { url, key, _ in try readFile(url, key: key) },
        write: { value, key, url, _ in try writeFile(value, key: key, to: url) })
}

/// A small desk: Mantel's own •, the test item with two items, another app, and the system's clock and Control Center; the
/// plist files, with grants, in a fake home folder; and a runner over all of it.
struct ProbeHarness: Sendable {
    static let ownBundleID = "com.example.mantel"
    static let fixtureID = "com.example.mantel.testitem"
    static let otherID = "com.example.other"
    static let agentPID: pid_t = 50

    let folder: TemporaryFolder
    let paths: MantelPaths
    let home: URL
    let journal: Journal
    let settings: SettingsStore
    let grants: FileGrantStore
    let plist: PlistFileAccess
    let ax: FakeAX
    let clock: any Clock
    let hidden: HiddenApps
    let allowlist: FakeAllowlist
    let windows: FakeWindows
    let taps: FakeTapFactory
    let capture: FakeCapture
    let runner: ProbeRunner
    /// The slot nodes of each app, by bundle ID.
    let slotOwners: [Int: String]
    /// MenuBarAgent's window on the main display, and the clock's slot in it.
    let window: Int
    let clockSlot: Int
    /// The test item's first slot, `::one`.
    let fixtureOneSlot: Int
    let screenRecording: Switch
    /// While on, the other app has quit: it isn't running and its slot is gone.
    let otherQuit: Switch

    var approvalsURL: URL {
        home.appending(path: "Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist")
    }

    var layoutURL: URL {
        home.appending(path: "Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar.plist")
    }

    var probesFolder: URL { paths.probes }

    static let runningApps: [(pid: pid_t, bundleID: String?, name: String?)] = [
        (agentPID, "com.apple.MenuBarAgent", "MenuBarAgent"),
        (100, ownBundleID, "Mantel"),
        (300, fixtureID, "MantelTestItem"),
        (301, otherID, "Other"),
    ]

    /// - Parameters:
    ///   - clock: `SteppingClock` unless the test has to say when a sleeper wakes.
    ///   - clicks: the clicks the fake tap sees, one at a time, each while the probe waits for one with the allowlist live. (With
    ///     any, the harness's clock is a `ClickDeliveryClock` over `clock`.)
    ///   - readCost: how much time each read of an Accessibility attribute takes, when the clock is a `SteppingClock`; so
    ///     that a read of the menu bar takes as long as the reads it is made of, and a test can say what a poll cost.
    static func make(clock givenClock: any Clock = SteppingClock(), clicks: [CGPoint] = [], readCost: Duration = .zero,
                     io: PlistIO = .filesOnly, configure: (inout ProbePlatform) -> Void = { _ in }) throws -> ProbeHarness {
        let clock: any Clock = clicks.isEmpty ? givenClock : ClickDeliveryClock(base: givenClock)
        let folder = TemporaryFolder(prefix: "mantel-probe")
        let paths = MantelPaths(root: folder.url.appending(path: "Mantel", directoryHint: .isDirectory),
                                logs: folder.url.appending(path: "Logs", directoryHint: .isDirectory))
        try paths.createDirectories()
        let home = folder.url.appending(path: "home", directoryHint: .isDirectory)
        let journal = Journal(file: paths.journalFile, clock: clock)
        // Settings are written when a test asks (`installFile` flushes) and never on a timer: a grant that a probe refreshes (the
        // file it points at was replaced) is saved a debounce later, and a save that fell due after the test had ended would
        // write into its folder while it is being deleted, and leave it behind.
        let settings = SettingsStore(paths: paths, clock: SystemClock(), debounce: .seconds(3600))
        let grants = FileGrantStore(store: settings, bookmarkOptions: [], clock: clock)
        let plist = PlistFileAccess(journal: journal, paths: paths, grants: grants, io: io, clock: clock)

        // The menu bar: one window on the main display, slots left to right.
        let ax = FakeAX()
        let window = ax.addAgentWindow(agent: agentPID, frame: CGRect(x: 0, y: 0, width: 3360, height: 31))
        var owners: [Int: String] = [:]
        owners[ax.addSlot(in: window, identifier: "\(ownBundleID).dot", frame: CGRect(x: 3000, y: 0, width: 30, height: 31))] = ownBundleID
        let fixtureOneSlot = ax.addSlot(in: window, identifier: "\(fixtureID)::one", frame: CGRect(x: 3100, y: 0, width: 40, height: 31))
        owners[fixtureOneSlot] = fixtureID
        owners[ax.addSlot(in: window, identifier: "\(fixtureID)::two", frame: CGRect(x: 3150, y: 0, width: 40, height: 31))] = fixtureID
        owners[ax.addSlot(in: window, identifier: "\(otherID).item", frame: CGRect(x: 3200, y: 0, width: 40, height: 31))] = otherID
        ax.addSlot(in: window, identifier: "com.apple.menuextra.controlcenter", frame: CGRect(x: 3250, y: 0, width: 40, height: 31))
        let clockSlot = ax.addSlot(in: window, identifier: "com.apple.menuextra.clock", frame: CGRect(x: 3300, y: 0, width: 50, height: 31))
        ax.addApp(pid: 100, extras: [.init(title: "Mantel", frame: CGRect(x: 3000, y: 0, width: 30, height: 31))])
        ax.addApp(pid: 300, extras: [.init(title: "one", frame: CGRect(x: 3100, y: 0, width: 40, height: 31)),
                                     .init(title: "two", frame: CGRect(x: 3150, y: 0, width: 40, height: 31))])
        ax.addApp(pid: 301, extras: [.init(title: "other", frame: CGRect(x: 3200, y: 0, width: 40, height: 31))])

        // A slot of a hidden app has no frame, nor has one of an app that has quit.
        let hidden = HiddenApps()
        let otherQuit = Switch(false)
        let frozenOwners = owners
        let stepping = givenClock as? SteppingClock
        ax.setOverride { id, name in
            if readCost > .zero { stepping?.advance(by: readCost) }
            guard name == AXName.position || name == AXName.size, let app = frozenOwners[id],
                  hidden.contains(app) || (app == otherID && otherQuit.isOn) else { return nil }
            return .failure(.noValue)
        }
        let running: @Sendable () -> [(pid: pid_t, bundleID: String?, name: String?)] = {
            otherQuit.isOn ? runningApps.filter { $0.bundleID != otherID } : runningApps
        }

        let allowlist = FakeAllowlist(hidden: hidden, everyApp: { running().compactMap(\.bundleID) })
        let windows = FakeWindows()
        let taps = FakeTapFactory(clicks: clicks, liftCount: { allowlist.invalidations })
        let capture = FakeCapture()
        let screenRecording = Switch(true)

        var platform = ProbePlatform(
            allowlist: allowlist, capture: capture, windows: windows,
            makeClickTap: { rects, delay, lifetime, onClick, onReplay in
                taps.make(rects: rects, delay: delay, lifetime: lifetime, onClick: onClick, onReplay: onReplay)
            },
            runningApps: running,
            environment: { ["macOS": "27.0.1 (26A434)", "model": "Mac16,1", "mantelVersion": "0.1.0"] },
            statusBarThickness: { 31 },
            screenRecordingGranted: { screenRecording.isOn },
            ownBundleID: ownBundleID, isInstalledCopy: true, copyPath: "/Applications/Mantel.app")
        configure(&platform)

        if let delivering = clock as? ClickDeliveryClock {
            // The probe is idle in its wait for a click, with the allowlist live: the next click comes now.
            delivering.onSleep {
                if allowlist.live == 1 { taps.deliverNext(advance: delivering.advance) }
            }
        }

        let reader = MenuBarReader(ax: ax, runningApps: running, clock: clock)
        let runner = ProbeRunner(paths: paths, reader: reader, plist: plist, grants: grants,
                                 layoutProvider: { .desk }, clock: clock, platform: platform)
        return ProbeHarness(folder: folder, paths: paths, home: home, journal: journal, settings: settings, grants: grants, plist: plist, ax: ax,
                            clock: clock, hidden: hidden, allowlist: allowlist, windows: windows, taps: taps, capture: capture,
                            runner: runner, slotOwners: owners, window: window, clockSlot: clockSlot, fixtureOneSlot: fixtureOneSlot,
                            screenRecording: screenRecording, otherQuit: otherQuit)
    }

    // MARK: Files

    /// Writes a plist at `url` (making its folders) and grants it, as the Permissions pane does.
    @discardableResult
    func installFile(_ kind: FileGrantKind, _ contents: [String: Any]) async throws -> URL {
        let url = kind == .menuBarLayout ? layoutURL : approvalsURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: contents, format: .binary, options: 0).write(to: url)
        _ = try await grants.grant(kind, chosen: url, home: home)
        // The grant is saved a moment after it is made; saved now, it is in the test's folder and not in one already deleted.
        await settings.flush()
        return url
    }

    static func read(_ url: URL) throws -> NSDictionary {
        let data = try Data(contentsOf: url)
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? NSDictionary)
    }

    func run(_ name: ProbeName, _ options: [String: String] = [:]) async -> ProbeReport {
        await runner.run(name, options: ProbeOptions(options))
    }

    /// The names of the files in the Probes folder, sorted.
    func probeFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: probesFolder.path)) ?? []).sorted()
    }
}
