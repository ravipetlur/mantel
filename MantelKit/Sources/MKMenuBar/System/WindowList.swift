import AppKit
import CoreGraphics
import Foundation

/// One window that is on screen, as the window list gives it: who owns it, at what level, where and how opaque. Never its title,
/// which can hold a document's name or a network's.
public struct WindowInfo: Sendable, Equatable {
    public let number: Int
    public let ownerPID: pid_t
    /// The owner's bundle ID, when the owner is a running app that has one.
    public let ownerBundleID: String?
    public let layer: Int
    /// CoreGraphics global points.
    public let bounds: CGRect
    public let alpha: Double

    public init(number: Int, ownerPID: pid_t, ownerBundleID: String?, layer: Int, bounds: CGRect, alpha: Double) {
        self.number = number
        self.ownerPID = ownerPID
        self.ownerBundleID = ownerBundleID
        self.layer = layer
        self.bounds = bounds
        self.alpha = alpha
    }
}

/// The windows on screen. The live one is `LiveWindowList`; a test gives its own, so that no test reads the real window list.
public protocol WindowListReading: Sendable {
    /// Every window that is on screen now, with what is above. Never titles.
    func onScreenWindows() -> [WindowInfo]
}

/// The window levels the menu bar and what opens from it are at (`CGWindowLevelForKey`): the main menu is at 24, status items at
/// 25, and the pop-up level, where an app's menu sits, is 101. (Notification Center's panel is at 21: see `OpenedSystemUI`.)
public enum WindowLevels {
    public static let mainMenu = 24
    public static let statusBar = 25
    public static let popUpMenu = 101
}

/// The real window list, which gives owners, levels and bounds without Screen Recording.
public struct LiveWindowList: WindowListReading {
    public init() {}

    public func onScreenWindows() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [] }
        // An owner's bundle ID is looked up once for each process, not for each of its windows.
        var owners: [pid_t: String?] = [:]
        var windows: [WindowInfo] = []
        for window in list {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, let number = window[kCGWindowNumber as String] as? Int,
                  let layer = window[kCGWindowLayer as String] as? Int else { continue }
            let owner: String?
            if let known = owners[pid] {
                owner = known
            } else {
                owner = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                owners[pid] = .some(owner)
            }
            let bounds = (window[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
            let alpha = window[kCGWindowAlpha as String] as? Double ?? 1
            windows.append(WindowInfo(number: number, ownerPID: pid, ownerBundleID: owner, layer: layer, bounds: bounds, alpha: alpha))
        }
        return windows
    }
}
