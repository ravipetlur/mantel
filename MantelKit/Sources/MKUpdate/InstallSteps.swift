import Foundation

/// How an install ended.
public enum InstallOutcome: Equatable, Sendable {
    /// The new app is in place and the app was asked to relaunch. `backupNotRemoved`: the old copy couldn't be deleted
    /// and stays beside the app under its backup name.
    case installed(backupNotRemoved: Bool)
    /// The app's folder isn't writable: the disk image was opened and is left mounted, at `volume`, for the person to
    /// drag the app to Applications.
    case handedOff(volume: URL)
    /// The person cancelled, or the attempt was replaced by a newer one. The flow already says so (or no longer cares),
    /// and everything was cleaned up.
    case cancelled
    /// Something failed. The flow was told, and everything was cleaned up.
    case failed(UpdateFailure)
}

/// The order of an install, with the work of each step injected: download, checksum, Gatekeeper on the image, mount,
/// the app's identity, its signature, Gatekeeper on the app, then (when the app's folder is writable) stage and replace,
/// delete the old copy, detach, clean up, wait until nothing is in the relaunch's way, and relaunch. Pure: it holds no Security, disk or network call of its own, so
/// the order and the endings are tested with fakes.
///
/// - **Each step must pass before the next.** A step that throws stops the run: the later steps are never called, the
///   image is detached (if it was mounted) and the temporary files removed, and only then is the failure reported.
/// - **It drives the flow.** Every step is reported with `report`, which says whether the flow took the event. A report
///   the flow turns down means this attempt is over (it was cancelled, or a newer one replaced it), and the run stops
///   and cleans up, saying nothing more. A late failure from an old attempt therefore can't reach a new one.
/// - **Cancelling** is noticed between steps, and by a step that throws `CancellationError` or `URLError.cancelled`
///   (which count as cancellation, not failure). Once `installStarted` is accepted the point of no return is passed: the
///   flow can't be cancelled and the run no longer listens for it.
/// - **Cleanup** (detach, then `cleanup`) runs in a task of its own, so that a cancelled install still ejects its image.
///   Only a hand-off skips it: the image is left mounted, with its files in place, for the person.
/// - **The relaunch is last**, after the cleanup and the wait for a quiet moment (`waitUntilQuiet`): it ends the process. A run
///   that was cancelled by then (the app's quit began) doesn't start it.
public struct InstallSteps: Sendable {
    /// What the log says when the old copy stays beside the app: the install carries on, and the person is told nothing.
    public static let backupNotRemovedNote = "The old copy of Mantel couldn't be deleted, so it was left beside the app"
    /// What the log says when the app began to quit before the relaunch: the new version is in place for the next launch.
    public static let relaunchSkippedNote = "The app is quitting: the relaunch was skipped"

    /// Reports an event to the flow; true when the flow took it.
    public typealias Report = @Sendable (InstallFlow.Event) async -> Bool
    /// The share of the download that has arrived, 0 to 1.
    public typealias Progress = @Sendable (Double) -> Void

    /// What the download leaves in the temporary folder.
    public struct Files: Equatable, Sendable {
        public let image: URL
        public let checksum: URL

        public init(image: URL, checksum: URL) {
            self.image = image
            self.checksum = checksum
        }
    }

    /// Downloads both files into a fresh private folder, reporting the disk image's progress, and checks the image is the
    /// size the release lists.
    public let download: @Sendable (_ progress: @escaping Progress) async throws -> Files
    /// The image's SHA-256 equals the one the checksum file gives for it.
    public let checksum: @Sendable (_ files: Files) async throws -> Void
    /// macOS accepts the disk image as a notarized download.
    public let gatekeeperImage: @Sendable (_ image: URL) async throws -> Void
    /// Mounts the image read-only and returns where.
    public let mount: @Sendable (_ image: URL) async throws -> URL
    /// Finds the app on the volume and checks it is this app, at the offered version. Returns the app.
    public let appIdentity: @Sendable (_ volume: URL) async throws -> URL
    /// The app's signature is valid and satisfies this app's own designated requirement.
    public let appSignature: @Sendable (_ app: URL) async throws -> Void
    /// macOS accepts the app to run.
    public let gatekeeperApp: @Sendable (_ app: URL) async throws -> Void
    /// Whether the running app's folder can be written to.
    public let destinationIsWritable: @Sendable () -> Bool
    /// Shows the mounted volume in Finder.
    public let openImage: @Sendable (_ volume: URL) async -> Void
    /// Copies the verified app beside the running one, replaces the running one with the copy, and returns the old copy,
    /// which is now a backup beside it.
    public let stageAndReplace: @Sendable (_ app: URL) async throws -> URL
    /// Deletes the backup: an update replaces the old version, and nothing goes to the Trash.
    public let removeBackup: @Sendable (_ backup: URL) async throws -> Void
    /// Ejects the image.
    public let detach: @Sendable (_ volume: URL) async -> Void
    /// Removes what the install left in the temporary folder, and anything of it still mounted.
    public let cleanup: @Sendable () async -> Void
    /// Returns once nothing is in the relaunch's way (`RelaunchWait`): no dialog is open and no change of the menu bar's order
    /// is being written. One that began after Install was clicked is finished first. Returns at once when nothing is.
    public let waitUntilQuiet: @Sendable () async -> Void
    /// Starts a relaunch, which waits for this process to exit. False when it couldn't be started.
    public let relaunch: @Sendable () async -> Bool
    /// A line for the log: no secrets, URLs and statuses are fine.
    public let note: @Sendable (_ text: String) -> Void

    public init(
        download: @escaping @Sendable (_ progress: @escaping Progress) async throws -> Files,
        checksum: @escaping @Sendable (_ files: Files) async throws -> Void,
        gatekeeperImage: @escaping @Sendable (_ image: URL) async throws -> Void,
        mount: @escaping @Sendable (_ image: URL) async throws -> URL,
        appIdentity: @escaping @Sendable (_ volume: URL) async throws -> URL,
        appSignature: @escaping @Sendable (_ app: URL) async throws -> Void,
        gatekeeperApp: @escaping @Sendable (_ app: URL) async throws -> Void,
        destinationIsWritable: @escaping @Sendable () -> Bool,
        openImage: @escaping @Sendable (_ volume: URL) async -> Void,
        stageAndReplace: @escaping @Sendable (_ app: URL) async throws -> URL,
        removeBackup: @escaping @Sendable (_ backup: URL) async throws -> Void,
        detach: @escaping @Sendable (_ volume: URL) async -> Void,
        cleanup: @escaping @Sendable () async -> Void,
        waitUntilQuiet: @escaping @Sendable () async -> Void,
        relaunch: @escaping @Sendable () async -> Bool,
        note: @escaping @Sendable (_ text: String) -> Void
    ) {
        self.download = download
        self.checksum = checksum
        self.gatekeeperImage = gatekeeperImage
        self.mount = mount
        self.appIdentity = appIdentity
        self.appSignature = appSignature
        self.gatekeeperApp = gatekeeperApp
        self.destinationIsWritable = destinationIsWritable
        self.openImage = openImage
        self.stageAndReplace = stageAndReplace
        self.removeBackup = removeBackup
        self.detach = detach
        self.cleanup = cleanup
        self.waitUntilQuiet = waitUntilQuiet
        self.relaunch = relaunch
        self.note = note
    }

    // MARK: Running

    /// Runs the install for one attempt, reporting each step to its flow with `report`.
    public func run(report: @escaping Report) async -> InstallOutcome {
        var volume: URL?
        do {
            let files = try await perform(.downloadFailed) { try await downloadReporting(to: report) }
            try await advance(.downloadFinished, report)

            try await perform(.checksumMismatch) { try await checksum(files) }
            try await advance(.stepPassed(.checksum), report)

            try await perform(.imageRejected) { try await gatekeeperImage(files.image) }
            try await advance(.stepPassed(.gatekeeperImage), report)

            let mounted = try await perform(.mountFailed) { try await mount(files.image) }
            volume = mounted
            try await advance(.stepPassed(.mount), report)

            let app = try await perform(.appMissing) { try await appIdentity(mounted) }
            try await advance(.stepPassed(.appIdentity), report)

            try await perform(.signatureInvalid) { try await appSignature(app) }
            try await advance(.stepPassed(.appSignature), report)

            try await perform(.appRejected) { try await gatekeeperApp(app) }

            // Every check passed. The last step is ended by the install, or by the hand-off.
            try Task.checkCancellation()
            guard destinationIsWritable() else {
                try await advance(.handOff, report)
                await openImage(mounted)
                note("The app's folder isn't writable: the disk image is open, and left mounted, for the person to finish")
                return .handedOff(volume: mounted)
            }
            // The flow's answer is the gate: a Cancel that reached it first turns this down, and nothing is replaced.
            try await advance(.installStarted, report)
            return await install(app: app, volume: mounted, report: report)
        } catch let stop as Stop {
            await tearDown(volume: volume)
            switch stop {
            case .cancelled: return .cancelled
            case .failed(let failure, let cause): return await fail(failure, cause: cause, report)
            }
        } catch {
            // A `CancellationError` from between the steps.
            await tearDown(volume: volume)
            return .cancelled
        }
    }

    /// The part past the point of no return: it can't be cancelled, and what goes wrong in it is reported as the failure
    /// it is.
    private func install(app: URL, volume: URL, report: @escaping Report) async -> InstallOutcome {
        let backup: URL
        do {
            backup = try await stageAndReplace(app)
        } catch {
            // Before the swap: the current version is still installed.
            await tearDown(volume: volume)
            return await fail((error as? UpdateFailure) ?? .installFailed, cause: error, report)
        }
        // The new app is in place. A backup that can't be deleted stays beside it, and the log says so.
        var backupNotRemoved = false
        do {
            try await removeBackup(backup)
        } catch {
            backupNotRemoved = true
            note("\(Self.backupNotRemovedNote) (\(Self.describe(error)))")
        }
        await tearDown(volume: volume)
        // The relaunch ends the process, and a dialog opened, or an order change begun, since Install was clicked would go
        // with it. The image is already ejected, so a long wait leaves nothing mounted.
        await waitUntilQuiet()
        // Only a quit cancels an install this far on (the person can't), and the relauncher would open the app again after the
        // quit the person asked for. The new version is in place for the next launch, so this is an install that is done.
        guard !Task.isCancelled else {
            note(Self.relaunchSkippedNote)
            return .installed(backupNotRemoved: backupNotRemoved)
        }
        guard await relaunch() else { return await fail(.relaunchFailed, cause: nil, report) }
        return .installed(backupNotRemoved: backupNotRemoved)
    }

    // MARK: Steps

    /// Why a run stopped, inside `run`.
    private enum Stop: Error {
        case cancelled
        case failed(UpdateFailure, cause: (any Error)?)
    }

    /// Runs one step: cancelled before it starts means it doesn't; whatever it throws becomes a `Stop`.
    private func perform<T>(_ fallback: UpdateFailure, _ work: () async throws -> T) async throws -> T {
        do {
            try Task.checkCancellation()
            return try await work()
        } catch {
            throw Self.stop(for: error, fallback: fallback)
        }
    }

    /// Reports an event, and stops when the flow turns it down: the attempt is over.
    private func advance(_ event: InstallFlow.Event, _ report: Report) async throws {
        guard await report(event) else { throw Stop.cancelled }
    }

    /// A cancellation (the task's, `CancellationError`, or what URLSession says when a download is cancelled) is a
    /// cancel, even when the step reports it as some other error. Anything else is the step's own failure, or the
    /// fallback for an error that isn't one.
    private static func stop(for error: any Error, fallback: UpdateFailure) -> Stop {
        if Task.isCancelled || error is CancellationError || isURLCancellation(error) { return .cancelled }
        if let failure = error as? UpdateFailure { return .failed(failure, cause: nil) }
        return .failed(fallback, cause: error)
    }

    private static func isURLCancellation(_ error: any Error) -> Bool {
        if (error as? URLError)?.code == .cancelled { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    /// The download, with its progress sent on as it comes. Every report has been sent before this returns, so none
    /// arrives after `downloadFinished`.
    private func downloadReporting(to report: @escaping Report) async throws -> Files {
        let (stream, feed) = AsyncStream.makeStream(of: Double.self)
        async let forwarded: Void = Self.forward(stream, to: report)
        do {
            let files = try await download { _ = feed.yield($0) }
            feed.finish()
            await forwarded
            return files
        } catch {
            feed.finish()
            await forwarded
            throw error
        }
    }

    private static func forward(_ progress: AsyncStream<Double>, to report: Report) async {
        // A report the flow turns down (a late one) is of no matter: the next step's report finds the attempt over.
        for await value in progress { _ = await report(.downloadProgress(value)) }
    }

    // MARK: Endings

    /// Records a failure, and reports it. When the flow turns it down (the attempt was cancelled or replaced) it is
    /// ignored, as a cancel.
    private func fail(_ failure: UpdateFailure, cause: (any Error)?, _ report: Report) async -> InstallOutcome {
        note("The install stopped: \(failure)" + (cause.map { " (\(Self.describe($0)))" } ?? ""))
        return await report(.failure(failure)) ? .failed(failure) : .cancelled
    }

    private static func describe(_ error: any Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code)"
    }

    /// Detaches the image (when it was mounted) and removes the temporary files, in a task that a cancel of the install
    /// doesn't reach: a cancelled task would end the very process that ejects the image.
    private func tearDown(volume: URL?) async {
        let steps = self
        await Task.detached(priority: .utility) {
            if let volume { await steps.detach(volume) }
            await steps.cleanup()
        }.value
    }
}
