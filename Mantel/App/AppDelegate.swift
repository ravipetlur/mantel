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
    /// What the log says of the quit: each step with its time, who answered, and what the fallback found (`QuitTrace`).
    private let quitTrace = QuitTrace(write: { Log.info("quit", $0) })
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
        let fallback = SIGTERMFallback(trace: quitTrace)
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
            // An alert or panel that is up holds the run loop in its own mode, where the quit's request isn't served: it is ended, with the
            // answer every alert takes as Cancel, so that the quit goes on with its cleanup.
            if NSApp.modalWindow != nil { NSApp.abortModal() }
            // Not `terminate` itself: this runs inside a main-queue block, where AppKit's wait for the reply would hold the cleanup and
            // the quit timer that answer it (`QuitRequest`).
            AppQuit.request()
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
                    AppQuit.request()
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
        coordinator.registerQuitDiagnostics(on: quitTrace)
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
        // First of all, before anything is awaited: reads stop waiting for apps (they hold the threads the cleanup and the timer need), and
        // the log's account of the quit begins, with a heartbeat of the main thread and of the pool.
        coordinator.beginQuit(quitTrace, because: "quitting")
        startQuitHeartbeats()
        Task {
            await coordinator.prepareToQuit()
            answerQuit(by: "the cleanup")
        }
        Task {
            await coordinator.quitTimer.wait()
            answerQuit(by: "the timer")
        }
        return .terminateLater
    }

    private func answerQuit(by who: String) {
        guard !hasAnsweredQuit else { return }
        hasAnsweredQuit = true
        quitTrace.answered(by: who)
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    /// How long the beats go on: until the process ends, and no longer than the SIGTERM fallback waits.
    private static let heartbeatLimitMilliseconds = 8_000

    /// Every half second, a line from the main queue and one from a task of the pool: a beat that doesn't come says that thread was held (the
    /// SIGTERM fallback's line says the last step reached, and what the readers were waiting for). They go on after the quit is answered,
    /// so that a hang after the reply says which thread is held.
    private func startQuitHeartbeats() {
        let trace = quitTrace
        let limit = Self.heartbeatLimitMilliseconds
        func mainBeat() {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500)) {
                guard trace.elapsedMilliseconds <= limit else { return }
                trace.beat("the main thread")
                mainBeat()
            }
        }
        mainBeat()
        Task.detached {
            while trace.elapsedMilliseconds <= limit {
                try? await Task.sleep(for: .milliseconds(500))
                guard trace.elapsedMilliseconds <= limit else { return }
                trace.beat("the task pool")
            }
        }
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
    private let trace: QuitTrace

    init(trace: QuitTrace) {
        self.trace = trace
    }

    func armOnce() {
        let first = armed.withLock { wasArmed in
            defer { wasArmed = true }
            return !wasArmed
        }
        guard first else { return }
        let trace = trace
        Self.queue.asyncAfter(deadline: .now() + Self.wait) {
            Log.warning("quit", "the quit asked for by SIGTERM didn't end Mantel within 8 seconds; ending now")
            Log.warning("quit", trace.fallbackLine())
            _exit(0)
        }
    }
}
