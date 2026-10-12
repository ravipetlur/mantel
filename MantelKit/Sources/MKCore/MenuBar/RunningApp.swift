import Foundation

/// A running app, as the menu bar code needs it: who it is and whether it can show anything of its own.
public struct RunningApp: Sendable, Hashable {
    public let pid: pid_t
    public let bundleID: String?
    public let name: String?
    public let bundleURL: URL?
    /// The app's activation policy is `.prohibited`: it has no windows and no Dock icon, and can't be brought forward. It may
    /// still have status items, which is why an allowlist has to name it. (MenuBarAgent is not one: it is an accessory app, which
    /// `lsappinfo` lists as a UIElement, with windows of its own that make up the menu bar.)
    public let isBackgroundOnly: Bool

    public init(pid: pid_t, bundleID: String?, name: String?, bundleURL: URL?, isBackgroundOnly: Bool) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.bundleURL = bundleURL
        self.isBackgroundOnly = isBackgroundOnly
    }
}

/// What changed between two lists of running apps: who has started and who has gone.
public struct RunningAppsChange: Sendable, Equatable {
    public let launched: [RunningApp]
    public let quit: [RunningApp]

    public init(launched: [RunningApp], quit: [RunningApp]) {
        self.launched = launched
        self.quit = quit
    }

    /// What `new` has that `old` hadn't (`launched`, in the order of `new`) and what `old` had that `new` hasn't (`quit`, in the
    /// order of `old`).
    ///
    /// An app is told by its process ID. One that has the same process ID but another bundle ID is another app (the system gave
    /// the number to a new process, or the process became another program), so it counts as having quit and having launched.
    public static func between(_ old: [RunningApp], _ new: [RunningApp]) -> RunningAppsChange {
        let before = Set(old.map(Identity.init))
        let after = Set(new.map(Identity.init))
        return RunningAppsChange(launched: new.filter { !before.contains(Identity($0)) },
                                 quit: old.filter { !after.contains(Identity($0)) })
    }

    /// Nothing started and nothing quit.
    public var isEmpty: Bool {
        launched.isEmpty && quit.isEmpty
    }

    private struct Identity: Hashable {
        let pid: pid_t
        let bundleID: String?

        init(_ app: RunningApp) {
            pid = app.pid
            bundleID = app.bundleID
        }
    }
}
