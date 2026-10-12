import AppKit
import MKCore
import Synchronization

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Made at launch, unless another Mantel is running and this copy only hands off to it and quits.
    private var coordinator: AppCoordinator?
    /// Set once the person's quit has been answered, by whichever of the cleanup and the quit timer came first.
    private var hasAnsweredQuit = false
    private var isQuitting = false
    /// What a SIGTERM does (`TerminationSignal`), and the dispatch source that hears it.
    private var terminationSignal = TerminationSignal()
    private var sigtermSource: DispatchSourceSignal?
    /// The one owner of Mantel's activation policy: a menu bar app with no Dock icon, except while a window of its own is open (or the
    /// menu bar is taken over). The coordinator, the windows and the takeover share it.
    private let activation = ActivationPolicyOwner()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // A menu bar app with no Dock icon, so that none flashes at launch unless onboarding opens. (LSUIElement in Info.plist says the
        // same from the first moment of launch.)
        activation.launch()
        // macOS 27 can quit an accessory app that has no windows open. Mantel has to stay running until the person
        // quits it, so neither automatic nor sudden termination is allowed.
        ProcessInfo.processInfo.disableAutomaticTermination("Mantel manages the menu bar")
        ProcessInfo.processInfo.disableSuddenTermination()
        quitOnSIGTERM()
    }

    /// `make install`, `killall` and `pkill` end an app with SIGTERM, which would end Mantel at once, with what it changed in the system
    /// still changed and the control socket left behind. The signal is ignored by the system's default action and heard by a dispatch
    /// source instead, which quits as the Quit command does (`applicationShouldTerminate`, bounded by the quit timer).
    ///
    /// The source is heard on a queue of its own, not the main one: a Mantel whose main thread is stuck would otherwise never hear a
    /// SIGTERM at all. If the quit it asks for hasn't ended Mantel well after the quit timer's bound, Mantel ends at once, as the
    /// system's default action would have.
    private func quitOnSIGTERM() {
        signal(SIGTERM, SIG_IGN)
        let fallback = SIGTERMFallback()
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: SIGTERMFallback.queue)
        source.setEventHandler { @Sendable [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receivedSIGTERM() }
            }
            fallback.armOnce()
        }
        source.resume()
        sigtermSource = source
    }

    private func receivedSIGTERM() {
        switch terminationSignal.received() {
        case .quit(let line):
            Log.info("quit", line)
            NSApp.terminate(nil)
        case .alreadyQuitting:
            break
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let paths = MantelPaths.live()
        // Before anything of Mantel's is made or read: a second copy must leave the first one's files alone. Its log lines go to
        // the unified log only: the log file is the running copy's, and is pointed at only once the control socket is held.
        if let other = SingleInstance.otherInstance() {
            Log.warning("launch", "another Mantel is running (pid \(other.processIdentifier)); handing off")
            Task {
                let facts = await SingleInstance.handOff(socket: paths.controlSocket, to: other)
                switch HandOff.decide(facts) {
                case .quit:
                    NSApp.terminate(nil)
                case .start:
                    // Never quit with nobody to take over: the other one wasn't reached (it may have exited, or be starting
                    // at the same moment as this one), so this one starts, and the control socket's lock decides which stays.
                    // The hand-off has been made: the coordinator is told, so that it doesn't make it again.
                    start(with: paths, earlierHandOff: facts)
                }
            }
            return
        }
        start(with: paths)
    }

    private func start(with paths: MantelPaths, earlierHandOff: HandOffFacts? = nil) {
        let coordinator = AppCoordinator(paths: paths, activation: activation, earlierHandOff: earlierHandOff)
        self.coordinator = coordinator
        coordinator.start()
    }

    /// Opening Mantel again (a click on its Dock icon, or opening it from Finder) shows Settings, or brings onboarding forward when that
    /// is what is open.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        coordinator?.reopen()
        return false
    }

    /// Quitting waits for the cleanup (the store written, what Mantel changed put back, the socket closed) for as long as the quit
    /// timer says: a second, or three while the journal is being replayed.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator else { return .terminateNow }
        guard !isQuitting else { return .terminateLater }
        isQuitting = true
        terminationSignal.quitBegan()
        Task {
            await coordinator.prepareToQuit()
            answerQuit()
        }
        Task {
            await coordinator.quitTimer.wait()
            answerQuit()
        }
        return .terminateLater
    }

    private func answerQuit() {
        guard !hasAnsweredQuit else { return }
        hasAnsweredQuit = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }
}

/// What ends Mantel when the quit a SIGTERM asked for never ends it (a main thread that is stuck can't run the quit): armed by the first
/// SIGTERM, it waits well past the quit timer's bound of three seconds, then ends the process at once, as the system's default action
/// for SIGTERM would have. A quit that works ends the process long before it fires.
private nonisolated final class SIGTERMFallback: Sendable {
    /// The queue the SIGTERM source is heard on, and the wait is made on.
    static let queue = DispatchQueue(label: "mantel.sigterm")
    /// How long after the first SIGTERM the process ends regardless.
    static let wait: DispatchTimeInterval = .seconds(8)

    private let armed = Mutex(false)

    func armOnce() {
        let first = armed.withLock { wasArmed in
            defer { wasArmed = true }
            return !wasArmed
        }
        guard first else { return }
        Self.queue.asyncAfter(deadline: .now() + Self.wait) {
            Log.warning("quit", "the quit asked for by SIGTERM didn't end Mantel within 8 seconds; ending now")
            _exit(0)
        }
    }
}
