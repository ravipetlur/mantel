import Foundation
import MKCore

/// An app that draws menu bar icons and can be relaunched, for the list Settings shows after the icon spacing changes.
public struct RelaunchCandidate: Sendable, Equatable, Identifiable {
    /// The app's bundle ID.
    public let id: String
    public let name: String
    public let pid: pid_t
    public let bundleURL: URL
    /// Passed when the app is opened again.
    public var arguments: [String]

    public init(id: String, name: String, pid: pid_t, bundleURL: URL, arguments: [String] = []) {
        self.id = id
        self.name = name
        self.pid = pid
        self.bundleURL = bundleURL
        self.arguments = arguments
    }
}

/// Which apps are offered for a relaunch.
public enum RelaunchPlan {
    /// The apps that draw icons in the menu bar and can be relaunched: running, with a bundle on disk to open again, and neither Mantel
    /// nor one of Apple's (`com.apple.*`: macOS looks after those). Each app once, in the order Settings lists apps (`NameOrdering`).
    public static func candidates(inventory: Inventory, running: [RunningApp], ownBundleID: String) -> [RelaunchCandidate] {
        var candidates: [RelaunchCandidate] = []
        for bundleID in inventory.appsWithItems {
            guard bundleID != ownBundleID, !bundleID.lowercased().hasPrefix("com.apple.") else { continue }
            guard let app = running.first(where: { $0.bundleID == bundleID && $0.bundleURL != nil }), let url = app.bundleURL else { continue }
            let name = AppNames.resolve(bundleID: bundleID, runningName: app.name,
                                        bundleName: url.deletingPathExtension().lastPathComponent)
            candidates.append(RelaunchCandidate(id: bundleID, name: name, pid: app.pid, bundleURL: url))
        }
        return NameOrdering.sorted(candidates, name: \.name, tiebreak: \.id)
    }
}
