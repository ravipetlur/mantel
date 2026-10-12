import Foundation
import MKCore

extension RunningApp {
    /// An app for a test: only the process ID, the bundle ID and the name matter to most of them.
    public static func fake(_ pid: pid_t, _ bundleID: String?, _ name: String? = nil, backgroundOnly: Bool = false) -> RunningApp {
        RunningApp(pid: pid, bundleID: bundleID, name: name, bundleURL: nil, isBackgroundOnly: backgroundOnly)
    }
}
