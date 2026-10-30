import AppKit
import Foundation
import MKCore

/// How relaunching one app came out.
public enum RelaunchOutcome: Sendable, Equatable {
    /// The app quit and was opened again.
    case relaunched
    /// The app was asked to quit and was still running 5 seconds later (it may be waiting for the person: unsaved work). It is left alone.
    case didNotQuit
    /// The app quit, and opening it again failed; the text says why.
    case couldNotOpen(String)
}

public protocol AppRelaunching: Sendable {
    func relaunch(_ app: RelaunchCandidate) async -> RelaunchOutcome
}

/// What opening an app again asks for.
struct RelaunchOpening: Sendable, Equatable {
    let url: URL
    let arguments: [String]
    /// Whether the app comes forward. A relaunch never takes the person away from what they are doing.
    let activates: Bool
}

/// The decision of a relaunch, over what it does to the system, so that a test gives it fakes and nothing is quit.
enum AppRelauncher {
    /// How long an app has to quit once it is asked to.
    static let quitWait: Duration = .seconds(5)
    /// How often it is looked at while it does.
    static let pollInterval: Duration = .milliseconds(100)

    /// Asks the app to quit, waits for it to be gone, and opens it again without bringing it forward.
    ///
    /// - The request is polite (`terminate`) and never forced: an app that is still there after `quitWait` is `.didNotQuit`, and nothing
    ///   more is done to it.
    /// - Every wait is on `clock`, 100 ms at a time.
    /// - A task that is cancelled while it waits ends as `.didNotQuit`: the app isn't opened while it may still be quitting.
    static func relaunch(_ app: RelaunchCandidate, terminate: @Sendable (RelaunchCandidate) -> Void,
                         isRunning: @Sendable (RelaunchCandidate) -> Bool,
                         open: @Sendable (RelaunchOpening) async throws -> Void, clock: any Clock) async -> RelaunchOutcome {
        terminate(app)
        var waited = Duration.zero
        while isRunning(app) {
            guard waited < quitWait else {
                Log.info("relaunch", "\(app.id) was still running \(quitWait.components.seconds) seconds after it was asked to quit; left alone")
                return .didNotQuit
            }
            do {
                try await clock.sleep(for: pollInterval)
            } catch {
                return .didNotQuit
            }
            waited += pollInterval
        }
        do {
            try await open(RelaunchOpening(url: app.bundleURL, arguments: app.arguments, activates: false))
        } catch {
            Log.warning("relaunch", "\(app.id) quit, and couldn't be opened again: \(error.localizedDescription)")
            return .couldNotOpen(error.localizedDescription)
        }
        Log.info("relaunch", "\(app.id) was relaunched")
        return .relaunched
    }
}

/// Relaunches apps through the system: an app is asked to quit (`NSRunningApplication.terminate`), watched until it has gone, and
/// opened again with `NSWorkspace` without being brought forward. A test never makes one: it quits real apps.
public struct LiveAppRelauncher: AppRelaunching {
    private let runningApps: @Sendable () -> [RunningApp]
    private let clock: any Clock

    /// - Parameter runningApps: the apps that are running now, asked at every look.
    public init(runningApps: @escaping @Sendable () -> [RunningApp], clock: any Clock = SystemClock()) {
        self.runningApps = runningApps
        self.clock = clock
    }

    public func relaunch(_ app: RelaunchCandidate) async -> RelaunchOutcome {
        let runningApps = runningApps
        return await AppRelauncher.relaunch(
            app,
            terminate: { candidate in
                // The list the person chose from may be old: a process ID that now belongs to another app is not asked to quit.
                guard let running = NSRunningApplication(processIdentifier: candidate.pid),
                      running.bundleIdentifier == candidate.id else { return }
                running.terminate()
            },
            isRunning: { candidate in runningApps().contains { $0.pid == candidate.pid && $0.bundleID == candidate.id } },
            open: { opening in
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = opening.activates
                configuration.arguments = opening.arguments
                _ = try await NSWorkspace.shared.openApplication(at: opening.url, configuration: configuration)
            },
            clock: clock)
    }
}
