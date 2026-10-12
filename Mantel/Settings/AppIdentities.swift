import AppKit
import MKCore
import MKMenuBar
import UniformTypeIdentifiers

/// How Settings knows an app by its bundle ID: its name and its icon. One of these lives as long as the pane that uses it, so that the
/// icons and names are looked up once, not each time the pane is drawn.
///
/// The name is what the running app calls itself, else the name of its bundle where it is installed, else its bundle ID
/// (`AppNames.resolve`), and it is the same name wherever Settings lists the app.
@MainActor
final class AppIdentities {
    private let runningApps: RunningAppsSource
    private var names: [String: String] = [:]
    private var icons: [String: NSImage] = [:]

    init(runningApps: RunningAppsSource) {
        self.runningApps = runningApps
    }

    /// The names of these apps, for `LayoutRows`.
    func names(for bundleIDs: some Sequence<String>) -> [String: String] {
        var result: [String: String] = [:]
        for bundleID in bundleIDs { result[bundleID] = name(for: bundleID) }
        return result
    }

    func name(for bundleID: String) -> String {
        if let known = names[bundleID] { return known }
        let running = runningApps.all.first { $0.bundleID == bundleID }?.name
        // The bundle on disk is read only when the running app has no name to give: nothing on the main actor opens an Info.plist it
        // doesn't need.
        let hasRunningName = running.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
        let installed = hasRunningName ? nil
            : NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).flatMap(Self.bundleName(at:))
        let name = AppNames.resolve(bundleID: bundleID, runningName: running, bundleName: installed)
        names[bundleID] = name
        return name
    }

    /// The app's icon, 16 points, from its bundle. An app that isn't installed has the generic one.
    func icon(for bundleID: String) -> NSImage {
        if let known = icons[bundleID] { return known }
        let url = runningApps.all.first { $0.bundleID == bundleID }?.bundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        // `icon(forFile:)` hands back a copy to size as wanted.
        let icon = url.map { NSWorkspace.shared.icon(forFile: $0.path(percentEncoded: false)) } ?? NSWorkspace.shared.icon(for: .application)
        icon.size = NSSize(width: 16, height: 16)
        icons[bundleID] = icon
        return icon
    }

    /// The name in the app's Info.plist: the one it shows people, else the short one.
    private static func bundleName(at url: URL) -> String? {
        guard let info = Bundle(url: url)?.infoDictionary else { return nil }
        return (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
    }
}
