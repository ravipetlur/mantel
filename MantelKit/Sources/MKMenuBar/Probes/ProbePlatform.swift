import AppKit
import CoreGraphics
import Foundation
import MKCore

/// Which windows an app has on screen. `click-replay` watches Notification Center's: a click on the clock that works opens one.
public protocol WindowWatching: Sendable {
    /// The numbers of the windows on screen that belong to a running app with this bundle ID.
    func onScreenWindows(ownedBy bundleID: String) -> Set<Int>
}

/// A tap that holds clicks and replays them (`ClickReplayTap`, or a stand-in in a test).
public protocol ClickReplaying: Sendable {
    func start() throws
    func stop()
}

extension ClickReplayTap: ClickReplaying {}

/// Everything a probe reaches the system through, other than the reader, the plist files and the grants, which the runner is
/// given. The live one is `.live`; tests give a fake of each piece, so that no probe in a test touches the real system.
public struct ProbePlatform: Sendable {
    public typealias RunningApp = (pid: pid_t, bundleID: String?, name: String?)
    /// `onClick` is called inside the tap's event callback for each click it holds, before the replay is scheduled; `onReplay`
    /// right after the replayed mouse-down is posted.
    public typealias MakeClickTap = @Sendable (_ rects: [CGRect], _ delay: Duration, _ lifetime: Duration,
                                               _ onClick: @escaping @Sendable (CGPoint) -> Void,
                                               _ onReplay: @escaping @Sendable (CGPoint) -> Void) -> any ClickReplaying

    public var allowlist: any AllowlistControlling
    public var capture: any StripCapturing
    public var windows: any WindowWatching
    public var makeClickTap: MakeClickTap
    /// Every running app that has a bundle ID, background-only ones included: what an allowlist has to name, since one that
    /// left an app out would conceal its status items. (The reader is given the narrower `RunningApps.current()`.)
    public var runningApps: @Sendable () -> [RunningApp]
    /// What the numbers were measured on: macOS build, model and Mantel version.
    public var environment: @Sendable () async -> [String: String]
    /// `NSStatusBar.system.thickness`, which can only be read on the main actor.
    public var statusBarThickness: @Sendable () async -> Double
    public var screenRecordingGranted: @Sendable () -> Bool
    /// Mantel's own bundle ID; the test item's is this with `.testitem` after it.
    public var ownBundleID: String
    /// Whether this process is the copy in `/Applications`. macOS honours the allowlist for that copy only, and a probe that
    /// changes the person's menu bar runs only from it (the runner refuses the others).
    public var isInstalledCopy: Bool
    /// Where this copy is, for the refusal's text.
    public var copyPath: String

    public init(allowlist: any AllowlistControlling, capture: any StripCapturing, windows: any WindowWatching,
                makeClickTap: @escaping MakeClickTap, runningApps: @escaping @Sendable () -> [RunningApp],
                environment: @escaping @Sendable () async -> [String: String],
                statusBarThickness: @escaping @Sendable () async -> Double,
                screenRecordingGranted: @escaping @Sendable () -> Bool, ownBundleID: String, isInstalledCopy: Bool,
                copyPath: String) {
        self.allowlist = allowlist
        self.capture = capture
        self.windows = windows
        self.makeClickTap = makeClickTap
        self.runningApps = runningApps
        self.environment = environment
        self.statusBarThickness = statusBarThickness
        self.screenRecordingGranted = screenRecordingGranted
        self.ownBundleID = ownBundleID
        self.isInstalledCopy = isInstalledCopy
        self.copyPath = copyPath
    }

    /// Whether the app at `bundleURL` is the copy macOS honours the allowlist for: directly in `/Applications`, not in the
    /// person's own `~/Applications`, not a translocated one, not one in a build folder.
    public static func isInstalledCopy(at bundleURL: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        InstallLocation.verdict(for: bundleURL, home: home) == .applications
    }

    /// The real system.
    public static var live: ProbePlatform {
        ProbePlatform(
            allowlist: LiveAllowlist(),
            capture: StripCapture(),
            windows: LiveWindowWatcher(),
            makeClickTap: { rects, delay, lifetime, onClick, onReplay in
                ClickReplayTap(rects: rects, delay: delay, lifetime: lifetime, onClick: onClick, onReplay: onReplay)
            },
            runningApps: { RunningApps.all() },
            environment: { ProbeEnvironment.current() },
            statusBarThickness: { await MainActor.run { NSStatusBar.system.thickness } },
            screenRecordingGranted: { CGPreflightScreenCaptureAccess() },
            ownBundleID: Bundle.main.bundleIdentifier ?? "com.example.mantel",
            isInstalledCopy: isInstalledCopy(at: Bundle.main.bundleURL),
            copyPath: Bundle.main.bundleURL.path(percentEncoded: false))
    }
}

/// The apps that are running, as the menu bar reader wants them.
public enum RunningApps {
    /// Every running app that can show something (not a background-only process), by process ID, bundle ID and name: what the
    /// menu bar reader asks about.
    public static func current() -> [(pid: pid_t, bundleID: String?, name: String?)] {
        read(includingBackgroundOnly: false)
    }

    /// Every running app that has a bundle ID, background-only ones too: what an allowlist has to name.
    public static func all() -> [(pid: pid_t, bundleID: String?, name: String?)] {
        read(includingBackgroundOnly: true).filter { $0.bundleID != nil }
    }

    /// `NSWorkspace` updates the list on the main thread, so it is read there: from another thread this waits for the main
    /// thread, which nothing here makes wait for it.
    private static func read(includingBackgroundOnly: Bool) -> [(pid: pid_t, bundleID: String?, name: String?)] {
        if Thread.isMainThread { return list(includingBackgroundOnly) }
        return DispatchQueue.main.sync { list(includingBackgroundOnly) }
    }

    private static func list(_ includingBackgroundOnly: Bool) -> [(pid: pid_t, bundleID: String?, name: String?)] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard includingBackgroundOnly || app.activationPolicy != .prohibited else { return nil }
            return (app.processIdentifier, app.bundleIdentifier, app.localizedName)
        }
    }
}

/// What a report says it was measured on.
public enum ProbeEnvironment {
    public static func current() -> [String: String] {
        var environment: [String: String] = [
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "mantelVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
        ]
        if let build = sysctlString("kern.osversion") { environment["macOSBuild"] = build }
        if let model = sysctlString("hw.model") { environment["model"] = model }
        return environment
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// The windows on screen, from the window list (which gives owners and numbers without needing Screen Recording).
struct LiveWindowWatcher: WindowWatching {
    func onScreenWindows(ownedBy bundleID: String) -> Set<Int> {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [] }
        var numbers: Set<Int> = []
        var owners: [pid_t: String?] = [:]
        for window in list {
            guard let pid = window["kCGWindowOwnerPID"] as? pid_t, let number = window["kCGWindowNumber"] as? Int else { continue }
            let owner: String?
            if let known = owners[pid] {
                owner = known
            } else {
                owner = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                owners[pid] = .some(owner)
            }
            if owner == bundleID { numbers.insert(number) }
        }
        return numbers
    }
}
