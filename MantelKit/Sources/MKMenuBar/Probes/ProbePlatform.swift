import AppKit
import CoreGraphics
import Foundation
import MKCore
import Synchronization

/// A tap that holds clicks and replays them (`ClickReplayTap`, or a stand-in in a test).
public protocol ClickReplaying: Sendable {
    func start() throws
    func stop()
}

extension ClickReplayTap: ClickReplaying {}

/// Everything a probe reaches the system through, other than the reader, the plist files and the grants, which the runner is
/// given. The live one is `.live(runningApps:)`; tests give a fake of each piece, so that no probe in a test touches the real system.
public struct ProbePlatform: Sendable {
    /// `onClick` is called inside the tap's event callback for each click it holds, before the replay is scheduled; `onReplay`
    /// right after the replayed mouse-down is posted.
    public typealias MakeClickTap = @Sendable (_ rects: [CGRect], _ delay: Duration, _ lifetime: Duration,
                                               _ onClick: @escaping @Sendable (CGPoint) -> Void,
                                               _ onReplay: @escaping @Sendable (CGPoint) -> Void) -> any ClickReplaying

    public var allowlist: any AllowlistControlling
    public var capture: any StripCapturing
    /// The windows on screen: `click-replay` watches for the panel a click on the clock opens (`OpenedSystemUI`), and the inventory
    /// lists the menu bar's own windows.
    public var windowList: any WindowListReading
    public var makeClickTap: MakeClickTap
    /// Every running app that has a bundle ID, background-only ones included: what an allowlist has to name, since one that
    /// left an app out would conceal its status items (`RunningAppsSource.all`; the reader is given the narrower `regular`).
    public var runningApps: @Sendable () -> [RunningApp]
    /// What the numbers were measured on: macOS build, model and Mantel version.
    public var environment: @Sendable () async -> [String: String]
    /// `NSStatusBar.system.thickness`, which can only be read on the main actor.
    public var statusBarThickness: @Sendable () async -> Double
    /// What AppKit says of each screen, which can only be read on the main actor.
    public var screens: @Sendable () async -> [ScreenFacts]
    public var screenRecordingGranted: @Sendable () -> Bool
    /// Mantel's own bundle ID; the test item's is this with `.testitem` after it.
    public var ownBundleID: String
    /// Whether this process is the copy in `/Applications`. macOS honours the allowlist for that copy only, and a probe that
    /// changes the person's menu bar runs only from it (the runner refuses the others).
    public var isInstalledCopy: Bool
    /// Where this copy is, for the refusal's text.
    public var copyPath: String
    /// The process ID of the app that is in front, if there is one: the inventory records where its menus are.
    public var frontAppPID: @Sendable () -> pid_t? = { nil }

    public init(allowlist: any AllowlistControlling, capture: any StripCapturing, windowList: any WindowListReading,
                makeClickTap: @escaping MakeClickTap, runningApps: @escaping @Sendable () -> [RunningApp],
                environment: @escaping @Sendable () async -> [String: String],
                statusBarThickness: @escaping @Sendable () async -> Double,
                screens: @escaping @Sendable () async -> [ScreenFacts],
                screenRecordingGranted: @escaping @Sendable () -> Bool, ownBundleID: String, isInstalledCopy: Bool,
                copyPath: String, frontAppPID: @escaping @Sendable () -> pid_t? = { nil }) {
        self.allowlist = allowlist
        self.capture = capture
        self.windowList = windowList
        self.makeClickTap = makeClickTap
        self.runningApps = runningApps
        self.environment = environment
        self.statusBarThickness = statusBarThickness
        self.screens = screens
        self.screenRecordingGranted = screenRecordingGranted
        self.ownBundleID = ownBundleID
        self.isInstalledCopy = isInstalledCopy
        self.copyPath = copyPath
        self.frontAppPID = frontAppPID
    }

    /// Whether the app at `bundleURL` is the copy macOS honours the allowlist for: directly in `/Applications`, not in the
    /// person's own `~/Applications`, not a translocated one, not one in a build folder.
    ///
    /// Both sides are compared as canonical paths (`CanonicalPath.of`: every link resolved), so a folder that is a link to
    /// `/Applications` holds the installed copy, and an entry in `/Applications` that is a link to a build folder doesn't.
    public static func isInstalledCopy(at bundleURL: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        InstallLocation.verdict(for: bundleURL, home: home) == .applications
    }

    /// The real system, with the running apps from the one source the app keeps.
    public static func live(runningApps: RunningAppsSource) -> ProbePlatform {
        ProbePlatform(
            allowlist: LiveAllowlist(),
            capture: StripCapture(),
            windowList: LiveWindowList(),
            makeClickTap: { rects, delay, lifetime, onClick, onReplay in
                ClickReplayTap(rects: rects, delay: delay, lifetime: lifetime, onClick: onClick, onReplay: onReplay)
            },
            runningApps: { runningApps.all },
            environment: { ProbeEnvironment.current() },
            statusBarThickness: { await MainActor.run { NSStatusBar.system.thickness } },
            screens: { await MainActor.run { NSScreen.screens.compactMap(ScreenFacts.init(screen:)) } },
            screenRecordingGranted: { CGPreflightScreenCaptureAccess() },
            ownBundleID: Bundle.main.bundleIdentifier ?? "com.example.mantel",
            isInstalledCopy: isInstalledCopy(at: Bundle.main.bundleURL),
            copyPath: Bundle.main.bundleURL.path(percentEncoded: false),
            frontAppPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier })
    }
}

/// "Enable platform test": whether the probes that change the person's menu bar may run. It is read by the probe runner from any
/// thread, and set by the Settings pane, so it is a value of its own. It is never saved: a new one is off, and the app makes one at
/// every launch.
public final class PlatformTestSwitch: Sendable {
    private let flag = Mutex(false)

    public init() {}

    public var isOn: Bool {
        get { flag.withLock { $0 } }
        set { flag.withLock { $0 = newValue } }
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

extension ScreenFacts {
    /// What `NSScreen` says, for the notch probe. A screen without a display number can't be told apart from the others.
    @MainActor
    init?(screen: NSScreen) {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let id = CGDirectDisplayID(number.uint32Value)
        let uuid: String
        if let reference = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() {
            uuid = CFUUIDCreateString(nil, reference) as String
        } else {
            uuid = "display-\(id)"
        }
        self.init(uuid: uuid, frame: screen.frame, safeAreaTop: screen.safeAreaInsets.top,
                  auxiliaryTopLeft: screen.auxiliaryTopLeftArea, auxiliaryTopRight: screen.auxiliaryTopRightArea,
                  isBuiltIn: CGDisplayIsBuiltin(id) != 0)
    }
}
