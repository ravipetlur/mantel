import AppKit
import MKCore

/// The one way the app asks AppKit to quit from code: from the run loop, not from inside the main-queue block or the task that is
/// running (`QuitRequest` says why). The Quit command and the menu's Quit item go to AppKit from an event and need none of this.
enum AppQuit {
    static func request() {
        QuitRequest.ask { delay, modes in
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: delay, inModes: modes)
        }
    }
}
