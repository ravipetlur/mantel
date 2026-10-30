import Foundation
import MKTestSupport
import MKUpdate
import Synchronization

/// What the fake steps are called, in the order a clean install calls them.
enum Call: String, CaseIterable, Hashable, Sendable {
    case download, checksum, gatekeeperImage, mount, appIdentity, appSignature, gatekeeperApp
    case writable, openImage, stageAndReplace, removeBackup, detach, cleanup, waitUntilQuiet, relaunch

    /// The steps that check the release, in order: a failure at one stops the ones after it.
    static let verification: [Call] = [.download, .checksum, .gatekeeperImage, .mount, .appIdentity, .appSignature, .gatekeeperApp]
}

struct SomeError: Error, Equatable {}

/// The steps of an install, faked: each records that it was called (and with what), may run a behaviour of the test's (suspend,
/// cancel the task, change the flow), and may then fail as the test says. Nothing touches the network, a disk image, the
/// signature checks or a file.
final class World: Sendable {
    struct Script: Sendable {
        var failures: [Call: any Error] = [:]
        var behaviors: [Call: @Sendable () async throws -> Void] = [:]
        var writable = true
        var relaunches = true
    }

    private struct Recorded {
        var calls: [Call] = []
        var arguments: [Call: URL] = [:]
        var notes: [String] = []
        /// `Task.isCancelled`, as the detach and cleanup steps saw it.
        var cleanupSawCancellation: [Bool] = []
        /// The flow's state at each cleanup, when the world watches a flow.
        var flowAtCleanup: [InstallFlow.State] = []
    }

    let script: Script
    private let watching: FlowBox?
    let image = URL(filePath: "/work/Mantel-1.2.0.dmg")
    let checksumFile = URL(filePath: "/work/Mantel-1.2.0.dmg.sha256")
    let volume = URL(filePath: "/work/Mantel")
    let app = URL(filePath: "/work/Mantel/Mantel.app")
    let backup = URL(filePath: "/Applications/Mantel-1.1.0.app")
    private let recorded = Mutex(Recorded())

    init(_ script: Script = Script(), watching: FlowBox? = nil) {
        self.script = script
        self.watching = watching
    }

    var calls: [Call] { recorded.withLock { $0.calls } }
    var notes: [String] { recorded.withLock { $0.notes } }
    var cleanupSawCancellation: [Bool] { recorded.withLock { $0.cleanupSawCancellation } }
    var flowAtCleanup: [InstallFlow.State] { recorded.withLock { $0.flowAtCleanup } }
    func argument(of call: Call) -> URL? { recorded.withLock { $0.arguments[call] } }

    private func enter(_ call: Call, _ url: URL? = nil) async throws {
        recorded.withLock {
            $0.calls.append(call)
            if let url { $0.arguments[call] = url }
        }
        if let behavior = script.behaviors[call] { try await behavior() }
        if let failure = script.failures[call] { throw failure }
    }

    func steps() -> InstallSteps {
        InstallSteps(
            download: { [self] progress in
                try await enter(.download)
                progress(0.5)
                progress(1)
                return InstallSteps.Files(image: image, checksum: checksumFile)
            },
            checksum: { [self] files in try await enter(.checksum, files.image) },
            gatekeeperImage: { [self] image in try await enter(.gatekeeperImage, image) },
            mount: { [self] image in
                try await enter(.mount, image)
                return volume
            },
            appIdentity: { [self] volume in
                try await enter(.appIdentity, volume)
                return app
            },
            appSignature: { [self] app in try await enter(.appSignature, app) },
            gatekeeperApp: { [self] app in try await enter(.gatekeeperApp, app) },
            destinationIsWritable: { [self] in
                recorded.withLock { $0.calls.append(.writable) }
                return script.writable
            },
            openImage: { [self] volume in try? await enter(.openImage, volume) },
            stageAndReplace: { [self] app in
                try await enter(.stageAndReplace, app)
                return backup
            },
            removeBackup: { [self] backup in try await enter(.removeBackup, backup) },
            detach: { [self] volume in
                recorded.withLock { $0.cleanupSawCancellation.append(Task.isCancelled) }
                try? await enter(.detach, volume)
            },
            cleanup: { [self] in
                let state = watching?.state
                recorded.withLock {
                    $0.cleanupSawCancellation.append(Task.isCancelled)
                    if let state { $0.flowAtCleanup.append(state) }
                }
                try? await enter(.cleanup)
            },
            waitUntilQuiet: { [self] in try? await enter(.waitUntilQuiet) },
            relaunch: { [self] in
                recorded.withLock { $0.calls.append(.relaunch) }
                return script.relaunches
            },
            note: { [self] text in recorded.withLock { $0.notes.append(text) } })
    }
}

/// An `InstallFlow` as the update center holds it: the sequencer's events go in tagged with their attempt, and the person's
/// choices (Cancel, Try Again, a new check) go in untagged.
final class FlowBox: Sendable {
    private struct Inner {
        var flow = InstallFlow()
        var attempted: [InstallFlow.Event] = []
        var accepted: [InstallFlow.Event] = []
    }

    private let inner = Mutex(Inner())

    var flow: InstallFlow { inner.withLock { $0.flow } }
    var state: InstallFlow.State { inner.withLock { $0.flow.state } }
    /// Every event the sequencer sent, taken or not.
    var attempted: [InstallFlow.Event] { inner.withLock { $0.attempted } }
    /// The events the flow took.
    var accepted: [InstallFlow.Event] { inner.withLock { $0.accepted } }

    /// A check that found the release, then the person's choice to install it: the first attempt.
    func begin(_ release: ReleaseInfo) -> InstallAttempt {
        inner.withLock { inner in
            _ = inner.flow.handle(.checkStarted)
            _ = inner.flow.handle(.updateFound(release))
            _ = inner.flow.handle(.downloadStarted)
            return inner.flow.attempt!
        }
    }

    @discardableResult
    func choose(_ event: InstallFlow.Event) -> Bool {
        inner.withLock { $0.flow.handle(event) }
    }

    /// The new attempt after the person cancelled, tried again and chose to install.
    func beginAgain() -> InstallAttempt {
        inner.withLock { inner in
            _ = inner.flow.handle(.retry)
            _ = inner.flow.handle(.downloadStarted)
            return inner.flow.attempt!
        }
    }

    func sink(_ attempt: InstallAttempt) -> InstallSteps.Report {
        { [self] event in
            inner.withLock { inner in
                inner.attempted.append(event)
                let taken = inner.flow.handle(event, from: attempt)
                if taken { inner.accepted.append(event) }
                return taken
            }
        }
    }
}
