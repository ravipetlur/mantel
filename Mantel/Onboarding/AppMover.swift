import AppKit
import Darwin
import MKCore

/// Moves the running Mantel into `/Applications`, starts it there and quits this copy.
enum AppMover {
    /// True when Mantel was moved, so that it must not be moved again (the bundle this copy was run from is gone): it was
    /// started in Applications and this copy is quitting, or it couldn't be started there and an alert says to open it from
    /// Applications. False when nothing was moved (an alert says why, unless the person cancelled).
    static func moveToApplicationsAndRelaunch() async -> Bool {
        let source = Bundle.main.bundleURL
        let destination = InstallLocation.destination
        let fileManager = FileManager.default

        // Not when the copy in Applications is this very app, or one that is running: replacing it would put a running Mantel
        // in the Trash. This process's own idea of where it is (`Bundle.main`) doesn't follow a move, so where its executable
        // is now comes from the system, and a bundle that isn't there any more says it has been moved.
        if let refusal = InstallLocation.moveRefusal(source: source, sourceExists: fileManager.fileExists(atPath: source.path),
                                                     currentExecutable: currentExecutableURL(),
                                                     runningBundles: NSWorkspace.shared.runningApplications.compactMap(\.bundleURL)) {
            let alert = NSAlert()
            switch refusal {
            case .alreadyMoved:
                alert.messageText = "Mantel has already been moved to Applications"
                alert.informativeText = "Quit this copy, then open Mantel from Applications."
            case .destinationIsRunning:
                alert.messageText = "Mantel in Applications is already running"
                alert.informativeText = "Quit it first, then move this copy."
            case .cannotConfirmRunningCopy:
                alert.messageText = "Mantel couldn't check which copy is running, so it didn't replace anything"
                alert.informativeText = "Quit Mantel and move it to Applications in Finder."
            }
            await ModalLoop.run(alert)
            return false
        }

        if fileManager.fileExists(atPath: destination.path) {
            let alert = NSAlert()
            alert.messageText = "Replace the Mantel in Applications?"
            alert.informativeText = "Another copy of Mantel is already there. Replacing it moves that copy to the Trash."
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            guard await ModalLoop.run(alert) == .alertFirstButtonReturn else { return false }
            do {
                try fileManager.trashItem(at: destination, resultingItemURL: nil)
            } catch {
                await show("Couldn't replace the copy in Applications", error)
                return false
            }
        }

        do {
            try fileManager.moveItem(at: source, to: destination)
        } catch {
            await show("Couldn't move Mantel to Applications", error)
            return false
        }
        Log.info("onboarding", "moved Mantel to Applications")

        // A second copy, started while this one is still running: it must not hand off to this one (see `SingleInstance`).
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.environment = [SingleInstancePolicy.relaunchedFromMoveKey: "1"]
        do {
            _ = try await NSWorkspace.shared.openApplication(at: destination, configuration: configuration)
        } catch {
            // Moved, though: the bundle this copy was run from is gone, so it must not be moved again.
            await show("Mantel is in Applications, but it didn't start there. Open it from Applications", error)
            return true
        }
        AppQuit.request()
        return true
    }

    /// Where this process's executable is now. The system answers with the file's current path, which follows the bundle
    /// if it is moved while the app runs. Nil if it can't say, and the move is then refused (`InstallLocation.moveRefusal`).
    private static func currentExecutableURL() -> URL? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(getpid(), &buffer, UInt32(buffer.count))
        guard length > 0 else {
            Log.error("onboarding", "couldn't find where Mantel's executable is (error \(errno)); the move to Applications is refused")
            return nil
        }
        return URL(filePath: String(decoding: buffer.prefix(Int(length)), as: UTF8.self))
    }

    /// A failure, as an alert: what happened, and why as the system words it.
    private static func show(_ message: String, _ error: any Error) async {
        Log.error("onboarding", "\(message): \(error.localizedDescription)")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        await ModalLoop.run(alert)
    }
}
