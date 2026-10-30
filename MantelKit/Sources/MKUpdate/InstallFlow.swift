/// The checks the downloaded release goes through, in order. Each must pass before the next, and none of them changes
/// anything on disk outside the temporary folder.
public enum VerifyStep: Equatable, Hashable, Sendable, CaseIterable {
    /// The disk image's SHA-256 equals the one the release publishes.
    case checksum
    /// macOS accepts the disk image as a notarized Developer ID download.
    case gatekeeperImage
    /// The disk image mounts, read-only.
    case mount
    /// The app inside has this app's bundle identifier and the offered version.
    case appIdentity
    /// The app's code signature is valid and satisfies this app's own designated requirement.
    case appSignature
    /// macOS accepts the app to run.
    case gatekeeperApp

    /// The step after this one, or nil after the last.
    public var next: VerifyStep? {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self), index + 1 < all.count else { return nil }
        return all[index + 1]
    }
}

/// Why an update stopped, with the words to show. It is an `Error`, so an installer can throw it.
public enum UpdateFailure: Error, Equatable, Hashable, Sendable, CaseIterable {
    // Checking.
    case network
    case rateLimited
    case serverError
    // Downloading.
    case downloadFailed
    case sizeMismatch
    // Verifying, in `VerifyStep` order.
    case checksumFileInvalid
    case checksumMismatch
    case imageRejected
    case mountFailed
    case appMissing
    case appIdentifierMismatch
    case appVersionMismatch
    case signatureInvalid
    case signerMismatch
    case appRejected
    // Installing.
    /// The new version couldn't be put in place. Only for what goes wrong before the swap, when the current version is
    /// still installed.
    case installFailed
    /// The swap stopped partway and the old copy couldn't be put back: the app is missing from its folder.
    case appNotRestored
    // After the swap, when the new version is in place.
    /// The app was updated, but couldn't be started again. The old process is still running, so it has to be quit first.
    case relaunchFailed
    /// The app was updated and asked to relaunch, but hasn't quit (a quit something held up, an editor with unsaved
    /// changes): quitting finishes it, and the relaunch helper opens the app again on its own.
    case quitPending

    /// Whether the new version is in place when this happens, so the current one isn't what's installed any more (and
    /// installing again would only install what is already there).
    public var newVersionIsInstalled: Bool {
        switch self {
        case .relaunchFailed, .quitPending: true
        default: false
        }
    }

    /// Whether Try Again makes sense: not when the new version is already installed, and not when the app is missing from
    /// its folder, where a new install has nothing to replace.
    public var canTryAgain: Bool {
        !newVersionIsInstalled && self != .appNotRestored
    }

    /// A plain sentence for the person using the app. Failures before the install say nothing was changed, because
    /// nothing has been; failures after it say the app was updated.
    public var message: String {
        switch self {
        case .network:
            "Couldn't reach the update server. Check your internet connection and try again."
        case .rateLimited:
            "The update server is limiting requests right now. Try again in a little while."
        case .serverError:
            "The update server had a problem. Try again later."
        case .downloadFailed:
            "The download didn't finish, so nothing was changed. Check your internet connection and try again."
        case .sizeMismatch:
            "The downloaded file isn't the size the release lists, so nothing was changed."
        case .checksumFileInvalid:
            "The release's checksum file couldn't be read, so nothing was changed."
        case .checksumMismatch:
            "The download didn't match its published checksum, so nothing was changed."
        case .imageRejected:
            "The download didn't pass the macOS check for notarized apps, so nothing was changed."
        case .mountFailed:
            "The downloaded disk image couldn't be opened, so nothing was changed."
        case .appMissing:
            "The downloaded disk image doesn't contain the app, so nothing was changed."
        case .appIdentifierMismatch:
            "The app in the download isn't this app, so nothing was changed."
        case .appVersionMismatch:
            "The app in the download isn't the version that was offered, so nothing was changed."
        case .signatureInvalid:
            "The app in the download has an invalid code signature, so nothing was changed."
        case .signerMismatch:
            "The app in the download wasn't signed by the same developer as this one, so nothing was changed."
        case .appRejected:
            "The app in the download didn't pass the macOS security check, so nothing was changed."
        case .installFailed:
            "The new version couldn't be put in place. The current version is still installed."
        case .appNotRestored:
            "The update stopped partway, and Mantel's own copy is missing from its folder. Install Mantel again from its release page."
        case .relaunchFailed:
            "Mantel was updated. Quit Mantel and open it again to use the new version."
        case .quitPending:
            "Mantel was updated. Quit Mantel to finish; it opens again on its own."
        }
    }
}

/// Which try at installing a release this is. Every install the person starts is a new one, and what it reports comes
/// back tagged with it (`InstallFlow.handle(_:from:)`), so a late report from an old one can be told from a new one's.
public struct InstallAttempt: Hashable, Sendable {
    fileprivate let number: Int

    fileprivate init(number: Int) {
        self.number = number
    }
}

/// Where an update is, from the check to the install, and which moves between those places are allowed. Pure: the
/// work happens elsewhere, and reports what happened as events. An event the current state doesn't allow is rejected
/// and changes nothing, which is how a late result (a failure arriving after a cancel, say) is dropped.
///
/// ```
/// idle / upToDate / available / failed / cancelled
///      --checkStarted--> checking --updateFound--> available --downloadStarted--> downloading
///                                 --noUpdateFound-> upToDate
/// downloading --downloadFinished--> verifying(checksum) --stepPassed--> ... --> verifying(gatekeeperApp)
/// verifying(gatekeeperApp) --installStarted--> installing
/// verifying(gatekeeperApp) --handOff--> handedOff        (the app's folder isn't writable)
/// checking / downloading / verifying / installing --failure--> failed
/// downloading / verifying --cancel--> cancelled
/// failed / cancelled --retry--> available
/// available / upToDate / failed / cancelled / handedOff --dismiss--> idle
/// ```
///
/// An install is an attempt: `downloadStarted` begins one, and it ends when the flow leaves downloading, verifying and
/// installing. What the attempt reports goes through `handle(_:from:)`, which takes it only while that attempt is the
/// one running.
public struct InstallFlow: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case checking
        /// A release is on offer.
        case available(ReleaseInfo)
        /// 0 to 1.
        case downloading(progress: Double)
        /// The step being checked now.
        case verifying(step: VerifyStep)
        /// The point of no return: from here on, there's no cancelling.
        case installing
        /// Every check passed, but the app's folder isn't writable, so the install can't be done here: the disk image
        /// is left mounted and the person drags the app to Applications. Not an error, not cancellable, and left only
        /// by dismissing.
        case handedOff(ReleaseInfo)
        case failed(UpdateFailure)
        case cancelled
        case upToDate
    }

    public enum Event: Equatable, Sendable {
        /// A check began: a manual one, or the daily one.
        case checkStarted
        /// The check found a release to offer.
        case updateFound(ReleaseInfo)
        /// The check found nothing newer.
        case noUpdateFound
        /// The person chose to install the offered release, and the download began.
        case downloadStarted
        /// The share of the download that has arrived, 0 to 1. A value outside that is clamped, and one that goes
        /// backwards is ignored, so the bar only moves forward.
        case downloadProgress(Double)
        /// The whole download arrived at the right size: verification begins with the checksum.
        case downloadFinished
        /// A verify step passed, so the next one begins. The last step, `gatekeeperApp`, isn't ended with this but
        /// with `installStarted` or `handOff`, once the caller has decided what to do.
        case stepPassed(VerifyStep)
        /// Every check passed and the install began.
        case installStarted
        /// Every check passed, but the app can't be replaced where it is: the person finishes by hand.
        case handOff
        /// The check, the download, a verify step or the install failed.
        case failure(UpdateFailure)
        /// The person cancelled the download or the verification.
        case cancel
        /// Back to the offered release, after a failure or a cancel.
        case retry
        /// The person is done with an offer, a result, a failure, a cancel or a hand-off: back to idle.
        case dismiss
    }

    /// What the window says while the new app is installed and the relaunch holds off for an open dialog (the flow is
    /// `installing` all the while; Cancel stays off).
    public static let restartWaitingText = "Restarts when the open dialog is closed."

    public private(set) var state: State = .idle

    /// The release in play, kept through the download, the verification, a failure, a cancel and a hand-off, so a retry
    /// can offer it again. Nil when a check found nothing, failed with nothing on offer, or was dismissed.
    public private(set) var release: ReleaseInfo?

    /// The install attempt that is running (downloading, verifying or installing), nil when none is.
    public private(set) var attempt: InstallAttempt?

    /// How many attempts have begun, which numbers the next.
    private var attemptsBegun = 0

    public init() {}

    /// Cancel is for the download and the verification. Once the install starts the old copy is being replaced, and
    /// nothing is cancellable from there on. (Nor is a hand-off: there is nothing left to cancel.)
    public var canCancel: Bool {
        switch state {
        case .downloading, .verifying: true
        default: false
        }
    }

    /// Applies an event that an install attempt reported. It is taken only while that attempt is the one running: a
    /// failure, a progress report or a result from an attempt that was cancelled, failed or replaced by a new one is
    /// rejected, changing nothing, however the state looks. So a late report can't touch the new attempt, or a check
    /// the person started in between.
    public mutating func handle(_ event: Event, from reporter: InstallAttempt) -> Bool {
        guard attempt == reporter else { return false }
        return handle(event)
    }

    /// Applies the event if the current state allows it, and says whether it did. A rejected event changes nothing.
    ///
    /// Not `@discardableResult`: the caller has to branch on the answer, so that a rejected event is never followed by
    /// the work it would have started.
    public mutating func handle(_ event: Event) -> Bool {
        switch (state, event) {
        case (.idle, .checkStarted), (.upToDate, .checkStarted), (.available, .checkStarted),
             (.failed, .checkStarted), (.cancelled, .checkStarted):
            // A check from an offer keeps the offer, so a check that fails can still be retried back to it.
            state = .checking

        case (.checking, .updateFound(let found)):
            state = .available(found)
            release = found
        case (.checking, .noUpdateFound):
            state = .upToDate
            release = nil

        case (.available(let offered), .downloadStarted):
            state = .downloading(progress: 0)
            release = offered
            attemptsBegun += 1
            attempt = InstallAttempt(number: attemptsBegun)
        case (.downloading(let current), .downloadProgress(let progress)):
            guard !progress.isNaN else { return false }
            state = .downloading(progress: max(current, min(max(progress, 0), 1)))
        case (.downloading, .downloadFinished):
            state = .verifying(step: .checksum)

        case (.verifying(let current), .stepPassed(let passed)):
            guard passed == current, let next = current.next else { return false }
            state = .verifying(step: next)
        case (.verifying(.gatekeeperApp), .installStarted):
            state = .installing
        case (.verifying(.gatekeeperApp), .handOff):
            guard let release else { return false }
            state = .handedOff(release)

        case (.checking, .failure(let failure)), (.downloading, .failure(let failure)),
             (.verifying, .failure(let failure)), (.installing, .failure(let failure)):
            state = .failed(failure)

        case (.downloading, .cancel), (.verifying, .cancel):
            state = .cancelled

        case (.failed, .retry), (.cancelled, .retry):
            guard let release else { return false }
            state = .available(release)

        case (.available, .dismiss), (.upToDate, .dismiss), (.failed, .dismiss), (.cancelled, .dismiss),
             (.handedOff, .dismiss):
            state = .idle
            release = nil

        default:
            return false
        }
        // An attempt lasts while the flow is downloading, verifying or installing.
        switch state {
        case .downloading, .verifying, .installing: break
        default: attempt = nil
        }
        return true
    }
}
