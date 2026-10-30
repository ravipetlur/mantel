import Foundation
import MKUpdate
import Testing

/// The places an update can be, and the moves between them. A move the state doesn't allow is rejected and changes nothing,
/// which is how a late result (a failure arriving after a cancel, say) is dropped, and how the install's last step is gated.
@Suite("The install flow", .timeLimit(.minutes(2)))
struct InstallFlowTests {
    typealias Event = InstallFlow.Event
    typealias State = InstallFlow.State

    let release = Releases.current

    func after(_ events: Event...) -> InstallFlow {
        var flow = InstallFlow()
        for event in events {
            let accepted = flow.handle(event)
            #expect(accepted, "\(event) should be accepted")
        }
        return flow
    }

    func eventsToVerify(_ step: VerifyStep) -> [Event] {
        var events: [Event] = [.checkStarted, .updateFound(release), .downloadStarted, .downloadFinished]
        var at = VerifyStep.checksum
        while at != step {
            events.append(.stepPassed(at))
            at = at.next!
        }
        return events
    }

    func flow(at state: State) -> InstallFlow {
        switch state {
        case .idle: return InstallFlow()
        case .checking: return after(.checkStarted)
        case .available: return after(.checkStarted, .updateFound(release))
        case .downloading: return after(.checkStarted, .updateFound(release), .downloadStarted)
        case .verifying(let step):
            var flow = InstallFlow()
            for event in eventsToVerify(step) { _ = flow.handle(event) }
            return flow
        case .installing: return after(.checkStarted, .updateFound(release), .downloadStarted, .downloadFinished) + .toInstalling
        case .handedOff: return flow(at: .verifying(step: .gatekeeperApp)) + .handOff
        case .failed: return after(.checkStarted, .updateFound(release), .downloadStarted, .failure(.downloadFailed))
        case .cancelled: return after(.checkStarted, .updateFound(release), .downloadStarted, .cancel)
        case .upToDate: return after(.checkStarted, .noUpdateFound)
        }
    }

    static var everyState: [State] {
        let release = Releases.current
        return [.idle, .checking, .available(release), .downloading(progress: 0.3), .installing, .handedOff(release),
                .failed(.downloadFailed), .cancelled, .upToDate] + VerifyStep.allCases.map { .verifying(step: $0) }
    }

    // MARK: The whole table

    /// What each event is allowed from, written out on its own so the flow is held to it: everything outside it is rejected,
    /// leaving the flow as it was.
    func allowed(_ event: Event, in state: State) -> Bool {
        switch (event, state) {
        case (.checkStarted, .idle), (.checkStarted, .upToDate), (.checkStarted, .available), (.checkStarted, .failed),
             (.checkStarted, .cancelled): true
        case (.updateFound, .checking), (.noUpdateFound, .checking): true
        case (.downloadStarted, .available): true
        case (.downloadProgress, .downloading), (.downloadFinished, .downloading): true
        case (.stepPassed(let passed), .verifying(let step)): passed == step && step != .gatekeeperApp
        case (.installStarted, .verifying(.gatekeeperApp)), (.handOff, .verifying(.gatekeeperApp)): true
        case (.failure, .checking), (.failure, .downloading), (.failure, .verifying), (.failure, .installing): true
        case (.cancel, .downloading), (.cancel, .verifying): true
        case (.retry, .failed), (.retry, .cancelled): true
        case (.dismiss, .available), (.dismiss, .upToDate), (.dismiss, .failed), (.dismiss, .cancelled), (.dismiss, .handedOff): true
        default: false
        }
    }

    @Test(arguments: InstallFlowTests.everyState)
    func everyEventIsAcceptedOnlyWhereTheTableAllowsIt(state: State) {
        var events: [Event] = [
            .checkStarted, .updateFound(release), .noUpdateFound, .downloadStarted, .downloadProgress(0.5), .downloadFinished,
            .installStarted, .handOff, .failure(.network), .cancel, .retry, .dismiss,
        ]
        events += VerifyStep.allCases.map { .stepPassed($0) }
        for event in events {
            var flow = flow(at: state)
            let before = flow
            let accepted = flow.handle(event)
            #expect(accepted == allowed(event, in: state), "\(event) in \(state)")
            if !accepted { #expect(flow == before, "\(event) in \(state) must change nothing") }
        }
    }

    // MARK: The way through

    @Test func theWayThroughWalksTheSixStepsInOrderAndEndsInInstalling() {
        var flow = InstallFlow()
        for event in eventsToVerify(.gatekeeperApp) {
            let accepted = flow.handle(event)
            #expect(accepted)
        }
        #expect(flow.state == .verifying(step: .gatekeeperApp))
        #expect(VerifyStep.allCases == [.checksum, .gatekeeperImage, .mount, .appIdentity, .appSignature, .gatekeeperApp])
        let started = flow.handle(.installStarted)
        #expect(started)
        #expect(flow.state == .installing)
        #expect(flow.attempt != nil)
    }

    /// Cancel is for the download and the verification; once the install starts the old copy is being replaced.
    @Test(arguments: InstallFlowTests.everyState)
    func cancellingIsPossibleOnlyWhileDownloadingOrVerifying(state: State) {
        let flow = flow(at: state)
        switch state {
        case .downloading, .verifying: #expect(flow.canCancel)
        default: #expect(!flow.canCancel)
        }
    }

    // MARK: Late reports

    /// A report from an attempt that was cancelled or replaced is taken only while that attempt is the one running.
    @Test func aReportFromAnOldAttemptIsRejectedWhateverTheStateLooksLike() throws {
        var flow = after(.checkStarted, .updateFound(release), .downloadStarted)
        let first = try #require(flow.attempt)
        _ = flow.handle(.cancel)
        #expect(flow.attempt == nil)
        let late = flow.handle(.failure(.downloadFailed), from: first)
        #expect(!late)
        _ = flow.handle(.retry)
        _ = flow.handle(.downloadStarted)
        let second = try #require(flow.attempt)
        #expect(second != first)
        let stillLate = flow.handle(.failure(.downloadFailed), from: first)
        #expect(!stillLate)
        #expect(flow.state == .downloading(progress: 0))
        let current = flow.handle(.downloadProgress(0.5), from: second)
        #expect(current)
    }

    // MARK: A check

    /// A check that fails never loses the offer that stood, and never leaves the flow in the failed state, which belongs to an
    /// install; with no offer the flow is idle again. A result arriving when no check is running is turned down.
    @Test func aFailedCheckSettlesBackToTheOfferOrToIdle() {
        var offered = after(.checkStarted, .updateFound(release), .checkStarted)
        let settled = offered.settleAfterFailedCheck(.network)
        #expect(settled)
        #expect(offered.state == .available(release))
        var empty = after(.checkStarted)
        let settledEmpty = empty.settleAfterFailedCheck(.network)
        #expect(settledEmpty)
        #expect(empty.state == .idle)
        var none = InstallFlow()
        let late = none.settleAfterFailedCheck(.network)
        #expect(!late)
    }

    @Test func aNewerReleaseReplacesTheOfferAndANoUpdateClearsIt() {
        var flow = after(.checkStarted, .updateFound(release), .checkStarted, .updateFound(Releases.newer))
        #expect(flow.state == .available(Releases.newer))
        #expect(flow.release == Releases.newer)
        _ = flow.handle(.checkStarted)
        _ = flow.handle(.noUpdateFound)
        #expect(flow.state == .upToDate)
        #expect(flow.release == nil)
    }

    // MARK: Failures

    /// A failure after the swap leaves the new version installed, so installing again would only install what is there; and an
    /// app missing from its folder has nothing for a new install to replace.
    @Test func onlyAFailureBeforeTheSwapCanBeTriedAgain() {
        for failure in UpdateFailure.allCases {
            let after = failure == .relaunchFailed || failure == .quitPending
            #expect(failure.newVersionIsInstalled == after, "\(failure)")
            #expect(failure.canTryAgain == (!after && failure != .appNotRestored), "\(failure)")
        }
    }

    /// The owner's rule for the words on macOS 27: nothing a person reads says "Accessibility".
    @Test func noMessageSaysAccessibility() {
        #expect(UpdateFailure.allCases.allSatisfy { !$0.message.contains("Accessibility") })
    }
}

private extension InstallFlow {
    enum Step { case toInstalling, handOff }

    /// The flow after one more step, which must be allowed.
    static func + (flow: InstallFlow, step: Step) -> InstallFlow {
        var flow = flow
        switch step {
        case .toInstalling:
            for verify in VerifyStep.allCases.dropLast() { _ = flow.handle(.stepPassed(verify)) }
            _ = flow.handle(.installStarted)
        case .handOff:
            _ = flow.handle(.handOff)
        }
        return flow
    }
}
