import Foundation
import MKCore
import MKPrivateShims
import Synchronization

/// What `MKAssessmentShim.inspect` found in macOS's private MenuBarClientCore framework, as a value.
public struct AllowlistInspection: Codable, Sendable, Equatable {
    public let frameworkLoaded: Bool
    public let configurationClassFound: Bool
    public let assertionClassFound: Bool
    /// Selector → the type encoding found for it; "" for a method that isn't there.
    public let encodings: [String: String]
    /// nil when everything matches what Mantel was written against.
    public let problem: String?

    public init(frameworkLoaded: Bool, configurationClassFound: Bool, assertionClassFound: Bool,
                encodings: [String: String], problem: String?) {
        self.frameworkLoaded = frameworkLoaded
        self.configurationClassFound = configurationClassFound
        self.assertionClassFound = assertionClassFound
        self.encodings = encodings
        self.problem = problem
    }

    /// The two classes, by name, and whether each is there.
    public var classes: [String: Bool] {
        ["MBAssessmentModeConfiguration": configurationClassFound, "MBAssessmentModeAssertion": assertionClassFound]
    }
}

/// Why an allowlist wasn't activated.
public enum AllowlistError: Error, Equatable, LocalizedError {
    /// The shim refused before calling anything (a method's encoding isn't the one Mantel was written against), or macOS
    /// couldn't make its objects.
    case refused(String)
    /// macOS answered the activation with an error.
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .refused(let reason), .failed(let reason): reason
        }
    }
}

/// A live allowlist. It is released by `invalidate()`, which may be called more than once.
public protocol AllowlistAssertionHandle: Sendable {
    func invalidate()
}

/// macOS's allowlist ("assessment mode"): every app that isn't on it has its status items concealed for as long as the
/// assertion lives. The live one is `LiveAllowlist`; tests and the probes' tests give their own.
public protocol AllowlistControlling: Sendable {
    /// Loads the framework and checks it. Only reads; never activates anything.
    func inspect() -> AllowlistInspection

    /// Activates an allowlist of `systemItems` and `bundleIDs`, and returns once macOS has finished activating it.
    /// - Throws: `AllowlistError`.
    func activate(systemItems: [Int], bundleIDs: [String]) async throws -> any AllowlistAssertionHandle
}

/// The real one, through the shim.
///
/// - The assertion object is held strongly until `invalidate()`. Whether macOS releases the assertion when the object is
///   released without `invalidate` is for the platform test to find out; `deinit` here invalidates, so that a handle that
///   is dropped never leaves one live.
/// - macOS calls the completion handler on a thread of its own, so nothing here assumes which.
/// - **An activation that doesn't finish is given up on.** If macOS never calls the completion handler, or the task is
///   cancelled first, the assertion the shim returned is invalidated here, explicitly, and the call throws: the caller never
///   has a handle to release, so nobody else could. Until then the assertion would sit live, hiding every app's items.
public struct LiveAllowlist: AllowlistControlling {
    /// How long macOS gets to finish an activation. Not measured yet: the working estimate for the stall MenuBarAgent
    /// has per apply is 100 to 150 ms, so 3 seconds is more than twenty times that. The platform test measures the real
    /// figure (`activateToCompletionMs`); change this only if that says an activation can take longer.
    public static let activationTimeout: Duration = .seconds(3)

    /// What starts an activation: it is given the items, the apps and the completion handler (which macOS calls, once, on any
    /// thread), and returns the assertion at once. The real one is the shim; a test gives its own.
    typealias Activator = @Sendable (_ systemItems: [Int], _ bundleIDs: [String],
                                     _ completion: @escaping @Sendable (AllowlistError?) -> Void) throws -> any AllowlistAssertionHandle

    private let timeout: Duration
    private let clock: any Clock
    private let activator: Activator

    public init() {
        self.init(timeout: Self.activationTimeout, clock: SystemClock(), activator: Self.shimActivator)
    }

    init(timeout: Duration, clock: any Clock, activator: @escaping Activator) {
        self.timeout = timeout
        self.clock = clock
        self.activator = activator
    }

    public func inspect() -> AllowlistInspection {
        let report = MKAssessmentShim.inspect()
        return AllowlistInspection(frameworkLoaded: report.frameworkLoaded,
                                   configurationClassFound: report.configurationClassFound,
                                   assertionClassFound: report.assertionClassFound,
                                   encodings: report.encodings,
                                   problem: report.problem)
    }

    public func activate(systemItems: [Int], bundleIDs: [String]) async throws -> any AllowlistAssertionHandle {
        let join = ActivationJoin()
        let timeout = timeout
        let clock = clock
        let activator = activator
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<any AllowlistAssertionHandle, any Error>) in
                // A task that was cancelled before it got here has nothing asked of macOS.
                guard join.install(continuation) else { return }
                do {
                    join.provide(try activator(systemItems, bundleIDs) { join.complete($0) })
                } catch {
                    // Nothing was activated, and the completion handler will not be called.
                    join.fail(error as? AllowlistError ?? .refused(error.localizedDescription))
                    return
                }
                join.startTimer(Task {
                    do { try await clock.sleep(for: timeout) } catch { return }
                    join.timeOut(after: timeout)
                })
            }
        } onCancel: {
            join.cancel()
        }
    }

    /// The shim: makes the objects, activates, and wraps the assertion object in a handle.
    private static let shimActivator: Activator = { systemItems, bundleIDs, completion in
        do {
            let object = try MKAssessmentShim.activateAllowingSystemItems(
                systemItems.map { NSNumber(value: $0) }, bundleIDs: bundleIDs
            ) { error in
                completion(error.map { .failed($0.localizedDescription) })
            }
            return LiveAssertion(object: object)
        } catch {
            throw AllowlistError.refused(error.localizedDescription)
        }
    }
}

/// The assertion object macOS made, held until it is invalidated.
private final class LiveAssertion: AllowlistAssertionHandle, Sendable {
    /// An Objective-C object from a private framework, which makes no Sendable promise: it is kept in a box that says it is
    /// safe to move, because it is only ever touched under the lock, and only to be handed to the shim.
    private struct Held: @unchecked Sendable {
        var object: Any?
    }

    private let held: Mutex<Held>

    init(object: Any) {
        held = Mutex(Held(object: object))
    }

    func invalidate() {
        let taken = held.withLock { held -> Held in
            let taken = held
            held.object = nil
            return taken
        }
        if let object = taken.object { MKAssessmentShim.invalidate(object) }
    }

    deinit {
        invalidate()
    }
}

/// Joins what an activation waits for, which comes in any order and on different threads: the assertion object the shim
/// returns, and the completion handler macOS calls; and ends it early when the timer or a cancellation comes first.
///
/// It resolves once, and then holds nothing: the continuation, the assertion and the timer are let go, so that the block the
/// framework may keep on the assertion doesn't make a cycle (assertion → block → join → assertion). An assertion that arrives
/// after the join has resolved without it (given up on, cancelled, or failed) is invalidated at once; one that is there when
/// the join resolves without it is invalidated then.
final class ActivationJoin: Sendable {
    private struct State {
        var continuation: CheckedContinuation<any AllowlistAssertionHandle, any Error>?
        var handle: (any AllowlistAssertionHandle)?
        var completion: Result<Void, AllowlistError>?
        var timer: Task<Void, Never>?
        var cancelled = false
        var resolved = false
    }

    private let state = Mutex(State())

    /// Takes the continuation. False when the task was cancelled before this, which resumes it with `CancellationError` and
    /// means that nothing is to be activated.
    func install(_ continuation: CheckedContinuation<any AllowlistAssertionHandle, any Error>) -> Bool {
        let cancelled = state.withLock { state -> Bool in
            if state.cancelled {
                state.resolved = true
                return true
            }
            state.continuation = continuation
            return false
        }
        if cancelled { continuation.resume(throwing: CancellationError()) }
        return !cancelled
    }

    /// The assertion object came back from the shim.
    func provide(_ handle: any AllowlistAssertionHandle) {
        let abandoned = state.withLock { state -> Bool in
            if state.resolved { return true }
            state.handle = handle
            return false
        }
        if abandoned {
            handle.invalidate()
        } else {
            resumeIfComplete()
        }
    }

    /// macOS called the completion handler; `error` is nil when it went well.
    func complete(_ error: AllowlistError?) {
        if let error {
            resolve(.failure(error))
            return
        }
        state.withLock { state in
            if !state.resolved { state.completion = .success(()) }
        }
        resumeIfComplete()
    }

    /// The activation never started, so neither the object nor the handler will come.
    func fail(_ error: AllowlistError) {
        resolve(.failure(error))
    }

    /// The timer is started once the activation has; if the join resolved meanwhile it is not needed.
    func startTimer(_ timer: Task<Void, Never>) {
        let resolved = state.withLock { state -> Bool in
            if state.resolved { return true }
            state.timer = timer
            return false
        }
        if resolved { timer.cancel() }
    }

    /// The handler didn't come in time.
    func timeOut(after timeout: Duration) {
        resolve(.failure(AllowlistError.failed("macOS didn't finish activating the allowlist within \(timeout.components.seconds) s.")))
    }

    /// The task was cancelled. Before `install` that is remembered; after it, the continuation is resumed.
    func cancel() {
        let early = state.withLock { state -> Bool in
            guard !state.resolved else { return false }
            guard state.continuation != nil else {
                state.cancelled = true
                return true
            }
            return false
        }
        if !early { resolve(.failure(CancellationError())) }
    }

    private func resumeIfComplete() {
        let ready = state.withLock { state -> Bool in
            !state.resolved && state.completion != nil && state.handle != nil && state.continuation != nil
        }
        guard ready else { return }
        let handle = state.withLock { $0.handle }
        if let handle { resolve(.success(handle)) }
    }

    /// Ends it: the first call decides; the continuation is resumed, and an assertion that isn't going to the caller is
    /// invalidated. The timer is cancelled and nothing is kept.
    private func resolve(_ outcome: Result<any AllowlistAssertionHandle, any Error>) {
        let taken = state.withLock { state -> (CheckedContinuation<any AllowlistAssertionHandle, any Error>?, (any AllowlistAssertionHandle)?, Task<Void, Never>?)? in
            guard !state.resolved else { return nil }
            state.resolved = true
            let taken = (state.continuation, state.handle, state.timer)
            state.continuation = nil
            state.handle = nil
            state.timer = nil
            state.completion = nil
            return taken
        }
        guard let (continuation, held, timer) = taken else { return }
        timer?.cancel()
        switch outcome {
        case .success(let handle):
            continuation?.resume(returning: handle)
        case .failure(let error):
            // Not for the caller, who would have no way to release it.
            held?.invalidate()
            continuation?.resume(throwing: error)
        }
    }
}
