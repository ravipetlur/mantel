import AppKit
import MKCore
import MKUpdate

/// Restarts Mantel once an update is in place. A shell that waits for this process to exit starts first, so that the copy it opens
/// doesn't find this one running and hand off to it (`SingleInstance`), and then Mantel quits the way every quit from code does
/// (`AppQuit.request()`): the hidden icons come back and an order change that is still held is written, as on Quit.
enum Relauncher {
    /// False, with Mantel still running, when the shell couldn't start; the caller says so.
    static func relaunch() -> Bool {
        // Looked at again here, on the main actor, where the quit that cancels the install also begins: a quit that came after the
        // install's own look (`InstallSteps`) can't come between this one and the shell, which would open the app after that quit.
        guard !Task.isCancelled else {
            Log.update.info(InstallSteps.relaunchSkippedNote)
            return true
        }
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = RelaunchCommand.arguments(pid: ProcessInfo.processInfo.processIdentifier,
                                                      appPath: Bundle.main.bundleURL.path(percentEncoded: false))
        do {
            try process.run()
        } catch {
            Log.error("relaunch", "couldn't start the restart after the update: \(error.localizedDescription)")
            return false
        }
        AppQuit.request()
        return true
    }
}
