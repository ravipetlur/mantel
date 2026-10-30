import Foundation
import MKTestSupport
import MKUpdate
import Testing

/// The order of an install: every check passes before the next, nothing is replaced until all of them have, the current app is
/// kept on any failure before the swap, the image is always put away, and the relaunch is last.
@Suite("The order of an install", .timeLimit(.minutes(2)))
struct InstallStepsTests {
    let release = Releases.current

    struct Run {
        let world: World
        let box: FlowBox
        let outcome: InstallOutcome
    }

    func run(_ script: World.Script = World.Script()) async -> Run {
        let world = World(script)
        let box = FlowBox()
        let attempt = box.begin(release)
        let outcome = await world.steps().run(report: box.sink(attempt))
        return Run(world: world, box: box, outcome: outcome)
    }

    /// The calls a run makes when `call` is the last step it gets to: the image detached if it had mounted, then cleaned up.
    func callsWhenStoppedAt(_ call: Call, finished: Bool = false) -> [Call] {
        let index = Call.verification.firstIndex(of: call)!
        let mountIndex = Call.verification.firstIndex(of: .mount)!
        let mounted = finished ? index >= mountIndex : index > mountIndex
        return Array(Call.verification[...index]) + (mounted ? [.detach] : []) + [.cleanup]
    }

    func isFailure(_ event: InstallFlow.Event) -> Bool {
        if case .failure = event { true } else { false }
    }

    // MARK: A clean run

    @Test func aCleanRunVerifiesEverythingThenReplacesThenRelaunchesLast() async {
        let run = await run()
        let world = run.world
        #expect(run.outcome == .installed(backupNotRemoved: false))
        #expect(world.calls == [
            .download, .checksum, .gatekeeperImage, .mount, .appIdentity, .appSignature, .gatekeeperApp,
            .writable, .stageAndReplace, .removeBackup, .detach, .cleanup, .waitUntilQuiet, .relaunch,
        ])
        // What one step makes, the next gets: the checks are of the very app that is then installed.
        #expect(world.argument(of: .checksum) == world.image)
        #expect(world.argument(of: .mount) == world.image)
        #expect(world.argument(of: .appIdentity) == world.volume)
        #expect(world.argument(of: .appSignature) == world.app)
        #expect(world.argument(of: .gatekeeperApp) == world.app)
        #expect(world.argument(of: .stageAndReplace) == world.app)
        #expect(world.argument(of: .removeBackup) == world.backup)
        #expect(run.box.accepted == [
            .downloadProgress(0.5), .downloadProgress(1), .downloadFinished,
            .stepPassed(.checksum), .stepPassed(.gatekeeperImage), .stepPassed(.mount),
            .stepPassed(.appIdentity), .stepPassed(.appSignature), .installStarted,
        ])
        #expect(run.box.state == .installing)
    }

    // MARK: A failure stops everything after it

    static let failures: [(Call, UpdateFailure)] = [
        (.download, .sizeMismatch), (.checksum, .checksumMismatch), (.gatekeeperImage, .imageRejected), (.mount, .mountFailed),
        (.appIdentity, .appIdentifierMismatch), (.appSignature, .signerMismatch), (.gatekeeperApp, .appRejected),
    ]

    /// Nothing after the failed step is called (so nothing is replaced), the image is put away, and the failure is reported only
    /// after the cleanup, so a Try Again can't meet a half-cleaned attempt.
    @Test(arguments: failures)
    func aFailureStopsTheLaterStepsAndCleansUp(call: Call, failure: UpdateFailure) async {
        var script = World.Script()
        script.failures[call] = failure
        let box = FlowBox()
        let world = World(script, watching: box)
        let attempt = box.begin(release)
        let outcome = await world.steps().run(report: box.sink(attempt))
        #expect(outcome == .failed(failure))
        #expect(world.calls == callsWhenStoppedAt(call))
        #expect(box.state == .failed(failure))
        #expect(world.notes.contains { $0.contains(String(describing: failure)) })
        #expect(world.flowAtCleanup.count == 1)
        for state in world.flowAtCleanup {
            if case .failed = state { Issue.record("the flow was already failed at the cleanup: \(state)") }
        }
    }

    /// An error that isn't an `UpdateFailure` stops the run with its step's own failure.
    @Test(arguments: [
        (Call.download, UpdateFailure.downloadFailed), (.checksum, .checksumMismatch), (.gatekeeperImage, .imageRejected),
        (.mount, .mountFailed), (.appIdentity, .appMissing), (.appSignature, .signatureInvalid), (.gatekeeperApp, .appRejected),
    ])
    func anUnknownErrorIsTheStepsOwnFailure(call: Call, failure: UpdateFailure) async {
        var script = World.Script()
        script.failures[call] = SomeError()
        let run = await run(script)
        #expect(run.outcome == .failed(failure))
        #expect(run.world.calls == callsWhenStoppedAt(call))
    }

    // MARK: Cancelling

    /// The person cancels while a step runs: everything is cleaned up, no failure is reported, nothing runs after, and the
    /// cleanup isn't cancelled with the task (it would end the very process that ejects the image).
    @Test(arguments: Call.verification)
    func cancellingWhileAStepRunsCleansUp(call: Call) async {
        let entered = Gate()
        var script = World.Script()
        script.behaviors[call] = {
            entered.open()
            try await Task.sleep(for: .seconds(60))
        }
        let world = World(script)
        let box = FlowBox()
        let attempt = box.begin(release)
        let task = Task { await world.steps().run(report: box.sink(attempt)) }
        await entered.wait()
        task.cancel()
        box.choose(.cancel)
        let outcome = await task.value
        #expect(outcome == .cancelled)
        #expect(world.calls == callsWhenStoppedAt(call))
        #expect(world.cleanupSawCancellation.allSatisfy { !$0 })
        #expect(box.state == .cancelled)
        #expect(!box.attempted.contains(where: isFailure))
    }

    /// A cancel the step doesn't notice is noticed before the next one.
    @Test(arguments: Call.verification)
    func aCancelIsNoticedBetweenSteps(call: Call) async {
        var script = World.Script()
        script.behaviors[call] = { withUnsafeCurrentTask { $0?.cancel() } }
        let world = World(script)
        let box = FlowBox()
        let attempt = box.begin(release)
        let outcome = await Task { await world.steps().run(report: box.sink(attempt)) }.value
        #expect(outcome == .cancelled)
        #expect(world.calls == callsWhenStoppedAt(call, finished: true))
    }

    /// What URLSession and Swift say for a cancelled task are cancels, not failures, however the step reports them.
    @Test(arguments: [
        URLError(.cancelled) as any Error, NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled), CancellationError(),
    ])
    func aCancellationIsACancelNotAFailure(error: any Error) async {
        var script = World.Script()
        script.failures[.download] = error
        let run = await run(script)
        #expect(run.outcome == .cancelled)
        #expect(run.world.calls == [.download, .cleanup])
        #expect(!run.box.attempted.contains(where: isFailure))
        var other = World.Script()
        other.failures[.download] = URLError(.notConnectedToInternet)
        #expect(await self.run(other).outcome == .failed(.downloadFailed))
    }

    // MARK: Late results from an old attempt

    /// Attempt one is cancelled and the person starts attempt two. Attempt one's download then fails, late: the failure reaches
    /// neither attempt two nor a check the person started meanwhile, and attempt one cleans up and stops.
    @Test(arguments: [false, true])
    func aLateFailureFromAnOldAttemptIsIgnored(startsACheck: Bool) async {
        let gate = Gate()
        let entered = Gate()
        var script = World.Script()
        script.behaviors[.download] = {
            entered.open()
            await gate.wait()
        }
        script.failures[.download] = UpdateFailure.downloadFailed
        let world = World(script)
        let box = FlowBox()
        let first = box.begin(release)
        let task = Task { await world.steps().run(report: box.sink(first)) }
        await entered.wait()
        box.choose(.cancel)
        var second: InstallAttempt?
        if startsACheck {
            box.choose(.retry)
            box.choose(.checkStarted)
        } else {
            second = box.beginAgain()
        }
        let expected = box.state
        gate.open()
        let outcome = await task.value
        #expect(outcome == .cancelled)
        #expect(world.calls == [.download, .cleanup])
        #expect(box.attempted.contains(.failure(.downloadFailed)))
        #expect(!box.accepted.contains(.failure(.downloadFailed)))
        #expect(box.state == expected)
        #expect(box.flow.attempt == second)
    }

    // MARK: The gate on installing

    /// A Cancel that reached the flow first turns `installStarted` (and a hand-off) down: nothing is replaced, the image isn't
    /// opened for a cancelled attempt, and it is put away.
    @Test(arguments: [true, false])
    func aCancelledFlowNeverLetsTheInstallOrTheHandOffStart(writable: Bool) async {
        let box = FlowBox()
        var script = World.Script()
        script.writable = writable
        script.behaviors[.gatekeeperApp] = { [box] in box.choose(.cancel) }
        let world = World(script)
        let attempt = box.begin(release)
        let outcome = await world.steps().run(report: box.sink(attempt))
        #expect(outcome == .cancelled)
        for call in [Call.stageAndReplace, .removeBackup, .relaunch, .openImage, .waitUntilQuiet] {
            #expect(!world.calls.contains(call), "\(call)")
        }
        #expect(world.calls.suffix(2) == [.detach, .cleanup])
        #expect(!box.accepted.contains(.installStarted))
    }

    // MARK: Not writable: the hand-off

    /// Every check passed but the app's folder can't be written: nothing is replaced, and the image is left mounted, with its
    /// files in place, for the person to finish by hand.
    @Test func aFolderThatIsNotWritableHandsTheImageOver() async {
        var script = World.Script()
        script.writable = false
        let run = await run(script)
        let world = run.world
        #expect(run.outcome == .handedOff(volume: world.volume))
        #expect(world.calls == [
            .download, .checksum, .gatekeeperImage, .mount, .appIdentity, .appSignature, .gatekeeperApp, .writable, .openImage,
        ])
        #expect(run.box.state == .handedOff(release))
    }

    // MARK: After the point of no return

    /// The old copy couldn't be deleted: the new app is in place, so the install completes, says so in the log only, and the
    /// flow never sees a failure.
    @Test func aRemovalFailureAfterTheReplaceStillCompletes() async {
        var script = World.Script()
        script.failures[.removeBackup] = SomeError()
        let run = await run(script)
        #expect(run.outcome == .installed(backupNotRemoved: true))
        #expect(run.world.calls.suffix(5) == [.removeBackup, .detach, .cleanup, .waitUntilQuiet, .relaunch])
        #expect(run.world.notes.contains { $0.contains(InstallSteps.backupNotRemovedNote) })
        #expect(run.box.state == .installing)
        #expect(!run.box.attempted.contains(where: isFailure))
    }

    /// The swap failed: the current version is still installed, everything is cleaned, nothing is deleted or relaunched, and the
    /// failure is reported from `installing`.
    @Test(arguments: [UpdateFailure.installFailed, .appNotRestored])
    func aFailedSwapIsReportedAndNeverRelaunches(failure: UpdateFailure) async {
        var script = World.Script()
        script.failures[.stageAndReplace] = failure
        let run = await run(script)
        #expect(run.outcome == .failed(failure))
        #expect(run.world.calls.suffix(3) == [.stageAndReplace, .detach, .cleanup])
        for call in [Call.removeBackup, .waitUntilQuiet, .relaunch] { #expect(!run.world.calls.contains(call)) }
        #expect(run.box.state == .failed(failure))
        var unknown = World.Script()
        unknown.failures[.stageAndReplace] = SomeError()
        #expect(await self.run(unknown).outcome == .failed(.installFailed))
    }

    /// The app is replaced but couldn't be started again: that says the app was updated, not that nothing changed.
    @Test func aRelaunchThatFailsSaysTheAppWasUpdated() async {
        var script = World.Script()
        script.relaunches = false
        let run = await run(script)
        #expect(run.outcome == .failed(.relaunchFailed))
        #expect(run.box.state == .failed(.relaunchFailed))
        #expect(run.world.calls.suffix(4) == [.detach, .cleanup, .waitUntilQuiet, .relaunch])
    }

    /// Past `installStarted` a cancelled task doesn't stop the install halfway: the swap is finished and the image put away. Only
    /// the relaunch, which would open the app again after a quit, is left out (below).
    @Test func theInstallIsNotCancelledOncePastThePointOfNoReturn() async {
        var script = World.Script()
        script.behaviors[.stageAndReplace] = { withUnsafeCurrentTask { $0?.cancel() } }
        let run = await Task { await run(script) }.value
        #expect(run.outcome == .installed(backupNotRemoved: false))
        #expect(run.world.calls.suffix(4) == [.removeBackup, .detach, .cleanup, .waitUntilQuiet])
    }

    /// The app's quit began while the install was still going (it cancels the task), after every check had passed: the new version
    /// is in place, and the relauncher is never started, since it would open the app again after the quit.
    @Test func anInstallCancelledBeforeTheRelaunchNeverRelaunches() async {
        var script = World.Script()
        script.behaviors[.waitUntilQuiet] = { withUnsafeCurrentTask { $0?.cancel() } }
        let run = await Task { await run(script) }.value
        #expect(run.outcome == .installed(backupNotRemoved: false))
        #expect(run.world.calls.suffix(3) == [.detach, .cleanup, .waitUntilQuiet])
        #expect(!run.world.calls.contains(.relaunch))
        #expect(run.world.notes.contains(InstallSteps.relaunchSkippedNote))
    }

    // MARK: The relaunch waits

    /// A dialog opened, or an order change begun, since Install was clicked is waited for: the wait is the step before the relaunch
    /// and comes after the image is put away, and the relaunch isn't started while it goes on. A run that doesn't relaunch never
    /// waits.
    @Test func theRelaunchWaitsUntilNothingIsInItsWay() async {
        let waiting = Gate()
        let quiet = Gate()
        var script = World.Script()
        script.behaviors[.waitUntilQuiet] = {
            waiting.open()
            await quiet.wait()
        }
        let world = World(script)
        let box = FlowBox()
        let attempt = box.begin(release)
        let task = Task { await world.steps().run(report: box.sink(attempt)) }
        await waiting.wait()
        #expect(world.calls.last == .waitUntilQuiet)
        #expect(!world.calls.contains(.relaunch))
        quiet.open()
        #expect(await task.value == .installed(backupNotRemoved: false))
        #expect(world.calls.suffix(4) == [.detach, .cleanup, .waitUntilQuiet, .relaunch])
    }

    @Test(arguments: Call.verification)
    func aRunThatStopsEarlyOrHandsOffNeverWaits(call: Call) async {
        var script = World.Script()
        script.failures[call] = UpdateFailure.imageRejected
        #expect(!(await run(script)).world.calls.contains(.waitUntilQuiet))
        var handOff = World.Script()
        handOff.writable = false
        #expect(!(await run(handOff)).world.calls.contains(.waitUntilQuiet))
    }
}
