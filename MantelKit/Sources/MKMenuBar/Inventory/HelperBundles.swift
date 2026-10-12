import Foundation

/// The apps that run beside others and never have a status item of their own: asking one for its items costs a full wait
/// for an answer that never comes, so the scanner never asks.
enum HelperBundles {
    private static let prefixes = ["com.apple.WebKit.", "com.apple.Virtualization."]
    private static let exact: Set<String> = ["com.apple.universalcontrol"]

    static func isHelper(_ bundleID: String) -> Bool {
        exact.contains(bundleID) || prefixes.contains { bundleID.hasPrefix($0) }
    }
}
