import AppKit
import Foundation
import MKCore
import Synchronization

/// The one list of the apps that are running, for the menu bar reader, the probes and whatever reacts to a launch or a quit.
///
/// - **Updated from `NSWorkspace.runningApplications`**, which is observed with KVO. (The workspace's launch and quit
///   notifications are not sent for every agent app's quit; the property changes for all of them.) KVO calls back on the main
///   thread, and the callback first writes the new list and only then calls `onChange`, so that a handler that reads the list
///   finds the change in it.
/// - **Read from any thread.** The list is kept behind a lock, so `all` and `regular` never wait for the main thread. (A read that
///   waited for it would deadlock with anything on the main thread that waits for a read.)
@MainActor
public final class RunningAppsSource {
    /// What is kept: the list as of the last change.
    private struct State: Sendable {
        var apps: [RunningApp] = []
    }

    private let state = Mutex(State())
    private let read: @MainActor () -> [RunningApp]
    private let observeChanges: @MainActor (_ changed: @escaping @MainActor () -> Void) -> NSKeyValueObservation?
    private var observation: NSKeyValueObservation?
    private var onChange: (@MainActor (RunningAppsChange) -> Void)?

    public convenience init(workspace: NSWorkspace = .shared) {
        self.init(read: { Self.apps(of: workspace) },
                  observeChanges: { changed in
                      workspace.observe(\.runningApplications, options: []) { _, _ in
                          // On the main thread, but a closure that isn't known to be: this makes sure.
                          if Thread.isMainThread {
                              MainActor.assumeIsolated { changed() }
                          } else {
                              DispatchQueue.main.async { MainActor.assumeIsolated { changed() } }
                          }
                      }
                  })
    }

    /// With the way the list is read and the way a change is heard given, so that a test needs no workspace.
    init(read: @escaping @MainActor () -> [RunningApp],
         observeChanges: @escaping @MainActor (_ changed: @escaping @MainActor () -> Void) -> NSKeyValueObservation? = { _ in nil }) {
        self.read = read
        self.observeChanges = observeChanges
        state.withLock { $0.apps = read() }
    }

    /// Starts keeping the list up to date, and calls `onChange` for each launch or quit after that (not for the apps that are
    /// running now). Calling it again replaces the handler.
    public func start(onChange: @escaping @MainActor (RunningAppsChange) -> Void) {
        self.onChange = onChange
        state.withLock { $0.apps = read() }
        observation = observeChanges { [weak self] in self?.reload() }
    }

    /// Every running app that has a bundle ID, background-only ones included: what an allowlist has to name, since one that left
    /// an app out would conceal its status items. Readable from any thread.
    public nonisolated var all: [RunningApp] {
        state.withLock { $0.apps.filter { $0.bundleID != nil } }
    }

    /// Every running app that can show something of its own (not a background-only one): what the menu bar reader asks about.
    /// Readable from any thread.
    public nonisolated var regular: [RunningApp] {
        state.withLock { $0.apps.filter { !$0.isBackgroundOnly } }
    }

    /// Reads the list again; calls `onChange` when something started or quit.
    func reload() {
        let fresh = read()
        let change = state.withLock { state -> RunningAppsChange in
            let change = RunningAppsChange.between(state.apps, fresh)
            state.apps = fresh
            return change
        }
        guard !change.isEmpty else { return }
        onChange?(change)
    }

    private static func apps(of workspace: NSWorkspace) -> [RunningApp] {
        workspace.runningApplications.map { app in
            RunningApp(pid: app.processIdentifier, bundleID: app.bundleIdentifier, name: app.localizedName,
                       bundleURL: app.bundleURL, isBackgroundOnly: app.activationPolicy == .prohibited)
        }
    }
}
