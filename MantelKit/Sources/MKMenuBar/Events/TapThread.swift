import CoreFoundation
import CoreGraphics
import Foundation

/// The thread an event tap lives on, which the click-replay tap and the system-click tap share.
///
/// A tap that is on holds every click in the system, so it never runs on the main thread: a busy app would stall the event stream. The
/// owner keeps the tap's life as a `ClickReplayLifecycle` under its own lock, and this runs what the thread does, asking the owner at the
/// two moments that matter (switching the tap on, and going round again) so that every decision stays the owner's, under its lock.
enum TapThread {
    /// How long the thread runs its loop before it asks whether the tap is still wanted. `stop()` also stops the loop, but a stop that
    /// comes before the loop is running has nothing to stop, and this is how long such a stop can go unseen.
    static let runLoopSlice: CFTimeInterval = 0.25

    /// Starts the thread, with the body that runs on it.
    static func start(named name: String, _ body: @escaping @Sendable () -> Void) {
        let thread = Thread(block: body)
        thread.name = name
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Runs the tap's port in this thread's run loop until the owner says to stop, then takes it out of the loop and invalidates it. It
    /// is the body of the thread: it returns when the tap's life is over.
    ///
    /// - Parameters:
    ///   - port: the tap's mach port.
    ///   - publishAndEnable: called once, with this thread's run loop, under the owner's lock: it keeps the run loop where `stop()` can
    ///     reach it and switches the tap on, in one step, and only while the tap runs. It says whether it switched it on: a `stop()` that
    ///     came before this has marked the phase, and finds nothing to switch off, and the tap is never switched on after it.
    ///   - keepsGoing: asked, under the owner's lock, after each slice of the loop with how the slice ended (the first slice is run
    ///     because the tap runs, so it is first asked after one): whether to run another. Not when the loop has nothing to wait for (it
    ///     would return at once, for ever) and not once the tap is stopped (`ClickReplayLifecycle.keepsRunLoopGoing(after:)`).
    static func run(port: CFMachPort, publishAndEnable: (CFRunLoop) -> Bool, keepsGoing: (CFRunLoopRunResult) -> Bool) {
        guard let source = CFMachPortCreateRunLoopSource(nil, port, 0) else { return }
        let runLoop = CFRunLoopGetCurrent()!
        CFRunLoopAddSource(runLoop, source, .commonModes)
        if publishAndEnable(runLoop) {
            // In slices, asking each time whether the tap is still wanted: `CFRunLoopStop` from `stop()` ends a slice, and a stop it
            // couldn't deliver (the loop wasn't running yet) is seen at the end of the slice it fell in.
            var result = CFRunLoopRunResult.timedOut
            while keepsGoing(result) {
                result = CFRunLoopRunInMode(.defaultMode, runLoopSlice, true)
            }
        }
        CFRunLoopRemoveSource(runLoop, source, .commonModes)
        CFMachPortInvalidate(port)
    }
}
