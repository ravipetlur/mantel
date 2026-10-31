import Foundation
import MKCore
import Testing

@testable import MKMenuBar

/// What Settings › Advanced shows for "Keep the mic and camera indicator visible while they're in use".
@Suite("Mic indicator row", .timeLimit(.minutes(1)))
struct MicIndicatorRowTests {
    private func status(availability: [HidingEngineKind: String] = [:], unavailable: [HidingEngineKind: String] = [:]) -> EngineStatus {
        EngineStatus(kind: .allowlist, reason: "Chosen automatically: macOS's allowlist works.", degraded: false, availability: availability,
                     lastError: nil, unavailableReasons: unavailable)
    }

    @Test func theSwitchIsOnOfferWhileTheSwitchesCanBeUsedOrNothingIsKnown() {
        let usable = status(availability: [.approvals: EngineAvailability.available.statusText])
        for engine in [usable, nil] {
            let row = AdvancedCopy.micIndicator(engine: engine)
            #expect(row.isEnabled)
            #expect(!row.offersGrant)
            #expect(row.caption == AdvancedCopy.micIndicatorCaption)
        }
        #expect(AdvancedCopy.micIndicatorTitle == "Keep the mic and camera indicator visible while they're in use")
    }

    @Test func withoutTheFileTheSwitchIsOffTheCaptionSaysSoAndTheGrantIsOffered() {
        let reason = ApprovalsEngine.permissionText
        let engine = status(availability: [.approvals: EngineAvailability.needsPermission(reason).statusText], unavailable: [.approvals: reason])
        let row = AdvancedCopy.micIndicator(engine: engine)
        #expect(!row.isEnabled)
        #expect(row.offersGrant)
        #expect(row.caption == "\(AdvancedCopy.micIndicatorCaption) \(AdvancedCopy.micIndicatorNeedsGrant)")
        #expect(AdvancedCopy.grantButton == "Grant Access…")
    }

    @Test func forAnotherReasonTheSwitchIsOffTheCaptionEndsWithItAndNothingIsToBeGranted() {
        let reason = ApprovalsEngine.changedText
        let engine = status(availability: [.approvals: EngineAvailability.broken(reason).statusText], unavailable: [.approvals: reason])
        let row = AdvancedCopy.micIndicator(engine: engine)
        #expect(!row.isEnabled)
        #expect(!row.offersGrant)
        #expect(row.caption == "\(AdvancedCopy.micIndicatorCaption) \(HidingMethodRows.sentence(reason))")
    }
}
