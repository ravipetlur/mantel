import ApplicationServices
import Foundation

/// Where a call to Accessibility is made from, for the calls that are about **this app's own process**: the main thread.
///
/// Asking Accessibility about your own process doesn't go to another one: the call is answered in place, on the thread that made it,
/// by AppKit's own accessibility code. AppKit's menus and status items are for the main thread (an `NSMenu` asserts that it is on it), so
/// a call made from the scan's thread fails: AppKit logs an assertion failure from `NSMenu.m` for each element it is asked about, and the
/// read comes back with an error.
///
/// Two reads of the scan are about Mantel's own process:
/// - **The status items of every app that has them, Mantel's own dots included.** This is the one that failed every two seconds while
///   Settings was open (the scan's interval then). It began to fail once Mantel had a main menu: the first scan at launch, with none,
///   read the dots without a complaint.
/// - **The menus of the app in front** (its `AXMenuBar`), which is Mantel's own only while Mantel has taken the menu bar over
///   (`MenuBarTakeoverPolicy.reportsFrontApp`). A window of Mantel's having the focus is not that.
///
/// `AXClient` makes each of its calls through this, so that every client the app makes routes them, and a client made later does too.
/// Calls about other processes are made where they are asked from. Making an element, which asks nothing of anyone, is left alone.
public struct OwnProcessAccess: Sendable {
    /// Runs `work` on the main thread and returns when it is done: at once if this is the main thread.
    public typealias MainThreadRunner = @Sendable (_ work: () -> Void) -> Void

    private let belongsToThisApp: @Sendable (AXElementRef) -> Bool
    private let moveToMainThread: MainThreadRunner

    /// - Parameters:
    ///   - belongsToThisApp: whether an element is one of this process's. The element's process ID is Mantel's own by default.
    ///   - runOnMainThread: how a call is moved to the main thread.
    public init(belongsToThisApp: @escaping @Sendable (AXElementRef) -> Bool = OwnProcessAccess.isThisProcess,
                runOnMainThread: @escaping MainThreadRunner = OwnProcessAccess.runOnMainThread) {
        self.belongsToThisApp = belongsToThisApp
        moveToMainThread = runOnMainThread
    }

    /// Whether the element is of this process, by its process ID (which the element knows without asking anyone).
    public static let isThisProcess: @Sendable (AXElementRef) -> Bool = { element in
        var pid: pid_t = 0
        return AXUIElementGetPid(element.element, &pid) == .success && pid == getpid()
    }

    /// Runs `work` on the main thread, waiting for it. The caller is never the main thread's own work: the scan runs off it, and the main
    /// thread doesn't wait for the scan.
    public static let runOnMainThread: MainThreadRunner = { work in
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
    }

    /// Makes `work` on the main thread when `element` is this app's, and where it is when it isn't. The result keeps its typed error. A
    /// call that was never made (the runner didn't run it) is a failure, not a value.
    func call<Value>(about element: AXElementRef, _ work: () throws(AXReadError) -> Value) throws(AXReadError) -> Value {
        guard belongsToThisApp(element) else { return try work() }
        var outcome: Result<Value, AXReadError>?
        moveToMainThread { outcome = Result(catching: work) }
        guard let outcome else { throw .failure(AXError.cannotComplete.rawValue) }
        return try outcome.get()
    }
}
