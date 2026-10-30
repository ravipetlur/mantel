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
    /// Posts clicks and keys, which moves the real pointer (and puts it back).
    public var poster: any ClickPosting
    /// Says where an item is in the menu bar now. The scanner of the running app, which has learned where each app's items are while they
    /// were all drawn; a test gives its own.
    public var locator: any ItemLocating
    /// Presses an item or opens its menu through Accessibility (the scanner too).
    public var presser: any ItemPressing
    /// The preferences the icon spacing is kept in.
    public var preferences: any PreferencesService
    /// Quits an app and opens it again. The probes use it for the test item and nothing else.
    public var relauncher: any AppRelaunching
    /// Where the test item keeps what it writes (its click log): its folder in Application Support. A probe reads it and nothing more.
    public var testItemSupportFolder: URL
    /// Where Mantel's own items' buttons are, by the name the system keeps their place under (the status item's autosave name), in
    /// CoreGraphics global points. Read in the app, on the main actor.
    public var ownItemFrames: @Sendable () async -> [String: CGRect] = { [:] }
    /// How many keys of the form `NSStatusItem Preferred Position …` Mantel's own preferences hold.
    public var ownPreferredPositionKeyCount: @Sendable () -> Int = { 0 }
    /// The same in the test item's preferences, which are another app's: a read.
    public var testItemPreferredPositionKeyCount: @Sendable () -> Int = { 0 }
    /// Tells the test item to do something, by a notification only it listens for: `toggle-extra-1` hides its first extra item, or shows
    /// it again (`TestItemCommands`).
    public var notifyTestItem: @Sendable (String) -> Void = { _ in }
    /// Where the pointer is now, in CoreGraphics global points: a posted click moves it and puts it back.
    public var pointerLocation: @Sendable () -> CGPoint? = { nil }

    public init(allowlist: any AllowlistControlling, capture: any StripCapturing, windowList: any WindowListReading,
                makeClickTap: @escaping MakeClickTap, runningApps: @escaping @Sendable () -> [RunningApp],
                environment: @escaping @Sendable () async -> [String: String],
                statusBarThickness: @escaping @Sendable () async -> Double,
                screens: @escaping @Sendable () async -> [ScreenFacts],
                screenRecordingGranted: @escaping @Sendable () -> Bool, ownBundleID: String, isInstalledCopy: Bool,
                copyPath: String, poster: any ClickPosting, locator: any ItemLocating, presser: any ItemPressing,
                preferences: any PreferencesService, relauncher: any AppRelaunching, testItemSupportFolder: URL,
                frontAppPID: @escaping @Sendable () -> pid_t? = { nil },
                ownItemFrames: @escaping @Sendable () async -> [String: CGRect] = { [:] },
                ownPreferredPositionKeyCount: @escaping @Sendable () -> Int = { 0 },
                testItemPreferredPositionKeyCount: @escaping @Sendable () -> Int = { 0 },
                notifyTestItem: @escaping @Sendable (String) -> Void = { _ in },
                pointerLocation: @escaping @Sendable () -> CGPoint? = { nil }) {
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
        self.poster = poster
        self.locator = locator
        self.presser = presser
        self.preferences = preferences
        self.relauncher = relauncher
        self.testItemSupportFolder = testItemSupportFolder
        self.frontAppPID = frontAppPID
        self.ownItemFrames = ownItemFrames
        self.ownPreferredPositionKeyCount = ownPreferredPositionKeyCount
        self.testItemPreferredPositionKeyCount = testItemPreferredPositionKeyCount
        self.notifyTestItem = notifyTestItem
        self.pointerLocation = pointerLocation
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
    ///
    /// - Parameters:
    ///   - scanner: the app's own scanner, which finds an item in the menu bar and presses it. It has to be the one that scans: what it
    ///     learned of where each app's items are, while they were all drawn, is what lets it say which slot is an item's once the item
    ///     has been concealed.
    ///   - ownItemFrames: where Mantel's own items' buttons are (it reads them on the main actor).
    public static func live(runningApps: RunningAppsSource, scanner: MenuBarScanner,
                            ownItemFrames: @escaping @Sendable () async -> [String: CGRect]) -> ProbePlatform {
        let ownBundleID = Bundle.main.bundleIdentifier ?? "com.example.mantel"
        let fixtureBundleID = ownBundleID + ProbeSafety.fixtureBundleIDSuffix
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        return ProbePlatform(
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
            ownBundleID: ownBundleID,
            isInstalledCopy: isInstalledCopy(at: Bundle.main.bundleURL),
            copyPath: Bundle.main.bundleURL.path(percentEncoded: false),
            poster: LiveClickPoster(), locator: scanner, presser: scanner, preferences: LivePreferences(),
            relauncher: LiveAppRelauncher(runningApps: { runningApps.all }),
            testItemSupportFolder: support.appending(path: "MantelTestItem", directoryHint: .isDirectory),
            frontAppPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            ownItemFrames: ownItemFrames,
            ownPreferredPositionKeyCount: { PreferredPositionKeys.count(inDomain: ownBundleID) },
            testItemPreferredPositionKeyCount: { PreferredPositionKeys.count(inDomain: fixtureBundleID) },
            notifyTestItem: { command in
                DistributedNotificationCenter.default().postNotificationName(
                    TestItemCommands.notificationName(command, fixtureBundleID: fixtureBundleID), object: nil, userInfo: nil,
                    deliverImmediately: true)
            },
            pointerLocation: { CGEvent(source: nil)?.location })
    }
}

/// What the test item listens for. It is told what to do by a notification of the system's that carries its own bundle ID, so that no
/// other app has the name.
public enum TestItemCommands {
    /// Hides the test item's first extra item, or shows it again.
    public static let toggleExtraOne = "toggle-extra-1"

    /// `<the test item's bundle ID>.<command>`: the name the test item listens for.
    public static func notificationName(_ command: String, fixtureBundleID: String) -> Notification.Name {
        Notification.Name("\(fixtureBundleID).\(command)")
    }
}

/// The keys AppKit keeps an app's status items' places under in the app's own preferences: `NSStatusItem Preferred Position <name>`.
public enum PreferredPositionKeys {
    public static let prefix = "NSStatusItem Preferred Position"

    /// How many of `keys` are such keys.
    public static func count(in keys: [String]) -> Int {
        keys.filter { $0.hasPrefix(prefix) }.count
    }

    /// How many such keys the app with this bundle ID has now, read afresh through the preferences service (a read of another app's
    /// domain). Zero when it has none, or the domain can't be read.
    public static func count(inDomain bundleID: String) -> Int {
        CFPreferencesAppSynchronize(bundleID as CFString)
        let keys = CFPreferencesCopyKeyList(bundleID as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String]
        return count(in: keys ?? [])
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
