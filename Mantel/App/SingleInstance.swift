import AppKit
import MKCommands
import MKCore

/// One Mantel at a time. A second copy that starts asks the first to open Settings and quits: this is also how
/// relaunching Mantel opens Settings.
///
/// Two things say that another Mantel is running, and whichever comes first is used:
/// - **LaunchServices**: another process with this bundle identifier (`otherInstance`). It is asked before anything of
///   Mantel's is made or read.
/// - **The control socket's lock**: the first Mantel holds it for as long as it runs (`ControlSocketServer.start()` throws
///   `.inUse`), which finds a copy LaunchServices doesn't list, such as one started from another place under another
///   identifier. The socket is the first thing `AppCoordinator` starts after the folders and the log, before the journal
///   replay, so a second copy never replays the journal under the running one.
///
/// A copy quits only when `HandOff.decide` says so: after a hand-off has reached the running Mantel, or when the lock shows
/// that one is alive. If a copy LaunchServices lists can't be reached, this one starts anyway and the socket's lock decides
/// which of them stays.
enum SingleInstance {
    /// The Mantel that is already running, which this copy hands off to rather than starting: another live process with
    /// this app's bundle identifier (a Debug build and the one in Applications share it). Nil when this is the only one,
    /// and for a copy that the move to Applications started, which the copy that moved is still running beside.
    ///
    /// Only a copy that started before this one counts. Of two started together, only the later hands off, so they never
    /// both quit (copies that started at the same instant both start, and the control socket's lock decides).
    static func otherInstance() -> NSRunningApplication? {
        guard !SingleInstancePolicy.suppressesHandOff(environment: ProcessInfo.processInfo.environment),
              let bundleID = Bundle.main.bundleIdentifier
        else { return nil }
        let ownLaunch = NSRunningApplication.current.launchDate
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { app in
            guard let ownLaunch, let launch = app.launchDate else { return true }
            return launch < ownLaunch
        }
        let running = apps.map { RunningInstance(pid: $0.processIdentifier, isTerminated: $0.isTerminated) }
        guard let target = SingleInstancePolicy.instanceToHandOffTo(running: running, currentPID: getpid()) else {
            return nil
        }
        return apps.first { $0.processIdentifier == target.pid }
    }

    /// Asks the running Mantel to open Settings, and says what happened: `HandOff.decide` says from that whether this copy
    /// may quit. Nothing here quits or starts anything. `HandOff.attempt` does the asking (over the control socket, then by
    /// opening `running`'s app again through LaunchServices); this supplies the real socket, process list and LaunchServices.
    ///
    /// The control socket only takes Mantel's own tools (`PeerPolicy`), which this copy isn't, so it may answer "rejected";
    /// the reopen is then what reaches the running copy, and is taken as a reopen that shows Settings.
    static func handOff(socket: URL, to running: NSRunningApplication?) async -> HandOffFacts {
        let client = ControlSocketClient(path: socket)
        // Only what is Sendable is kept: the app is looked up by its process each time it is asked about.
        let pid = running?.processIdentifier
        let url = running?.bundleURL
        return await HandOff.attempt(HandOffPorts(
            sendOpenSettings: { await openSettings(over: client) },
            observeTarget: { pid.map(observe) },
            reopenTarget: {
                guard let url else { return nil }
                return await reopen(url)
            },
            pause: { try? await Task.sleep(for: $0) }))
    }

    private static func openSettings(over client: ControlSocketClient) async -> HandOffSocketReply {
        do throws(ClientError) {
            switch try await client.send(.openSettings(nil), timeout: .seconds(2)) {
            case .ok:
                Log.info("launch", "the running Mantel was asked to open Settings")
                return .answered
            case .failure(let code, _):
                Log.warning("launch", "the running Mantel refused the hand-off (\(code.rawValue))")
                return .refused
            }
        } catch {
            if error == .notRunning { return .notRunning }
            Log.warning("launch", "the hand-off over the control socket failed: \(error)")
            return .failed
        }
    }

    /// The process with this identifier as it is now: exited if the system no longer has it.
    private nonisolated static func observe(pid: Int32) -> RunningInstance {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            return RunningInstance(pid: pid, isTerminated: true)
        }
        return RunningInstance(pid: pid, isTerminated: app.isTerminated)
    }

    /// Opens the app at `url` again, which a running app takes as a reopen. The process LaunchServices answered with.
    private static func reopen(_ url: URL) async -> Int32? {
        do {
            let app = try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            Log.info("launch", "the running Mantel was reopened to show Settings")
            return app.processIdentifier
        } catch {
            Log.error("launch", "the running Mantel couldn't be reopened: \(error.localizedDescription)")
            return nil
        }
    }
}
