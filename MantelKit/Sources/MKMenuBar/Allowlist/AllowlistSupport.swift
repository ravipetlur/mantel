import Foundation
import MKCore

/// What the allowlist probes share: which apps an allowlist names so that some others are the ones concealed, which system items it
/// keeps, and when there is nothing for a probe to hide.
enum AllowlistSupport {
    /// The bundle IDs to allow so that `hidden` are the only apps concealed: every running app's, but theirs, each once, in
    /// the order the apps came, and `own` (Mantel's) whether it is running or not and whatever `hidden` says. (An allowlist
    /// names the apps that stay; whatever isn't on it is concealed.)
    static func allowedBundleIDs(hiding hidden: Set<String>, running: [RunningApp], own: String) -> [String] {
        let hidden = hidden.subtracting([own])
        var seen: Set<String> = []
        var allowed: [String] = []
        for app in running {
            guard let bundleID = app.bundleID, !hidden.contains(bundleID), seen.insert(bundleID).inserted else { continue }
            allowed.append(bundleID)
        }
        if seen.insert(own).inserted { allowed.append(own) }
        return allowed
    }

    /// Every system item (0 to 255) unless the options name which.
    static func systemItems(_ options: ProbeOptions) -> [Int] {
        options.numbers("system-items") ?? Array(0...255)
    }

    /// Why a probe that hides `hidden` mustn't activate an allowlist, or nil: none of them is running. Such an allowlist hides
    /// nothing of theirs, and for the whole hold every system item that isn't on it (the microphone and camera indicators, Now
    /// Playing, Focus), which is a change to the person's menu bar for no measurement at all.
    static func nothingToHide(_ hidden: [String], running: [RunningApp], fixture: String) -> String? {
        let runningIDs = Set(running.compactMap(\.bundleID))
        guard !hidden.contains(where: runningIDs.contains) else { return nil }
        let names = hidden.joined(separator: ", ")
        let only = hidden.allSatisfy { $0 == fixture }
        return "Nothing to hide: \(names) \(hidden.count == 1 ? "isn't" : "aren't") running. "
            + (only ? "Open MantelTestItem first." : hidden.count == 1 ? "Open it first." : "Open them first.")
    }
}
