import AppKit
import MKCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Made at launch, unless another Mantel is running and this copy only hands off to it and quits.
    private var coordinator: AppCoordinator?
    /// Set once the person's quit has been answered, by whichever of the cleanup and its one-second limit came first.
    private var hasAnsweredQuit = false
    private var isQuitting = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // A menu bar app with no Dock icon. (LSUIElement in Info.plist says the same from the first moment of launch.)
        NSApp.setActivationPolicy(.accessory)
        // macOS 27 can quit an accessory app that has no windows open. Mantel has to stay running until the person
        // quits it, so neither automatic nor sudden termination is allowed.
        ProcessInfo.processInfo.disableAutomaticTermination("Mantel manages the menu bar")
        ProcessInfo.processInfo.disableSuddenTermination()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let paths = MantelPaths.live()
        // Before anything of Mantel's is made or read: a second copy must leave the first one's files alone.
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
                    start(with: paths)
                }
            }
            return
        }
        start(with: paths)
    }

    private func start(with paths: MantelPaths) {
        let coordinator = AppCoordinator(paths: paths)
        self.coordinator = coordinator
        coordinator.start()
    }

    /// Opening Mantel again (from Finder, or by the second copy's hand-off) shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        coordinator?.openSettings(nil)
        return false
    }

    /// Quitting waits for the cleanup (the store written, the socket closed) for one second at most.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator else { return .terminateNow }
        guard !isQuitting else { return .terminateLater }
        isQuitting = true
        Task {
            await coordinator.prepareToQuit()
            answerQuit()
        }
        Task {
            try? await Task.sleep(for: .seconds(1))
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
