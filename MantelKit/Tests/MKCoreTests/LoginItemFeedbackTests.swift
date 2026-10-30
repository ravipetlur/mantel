import Foundation
import ServiceManagement
import Testing

@testable import MKCore

@Suite("LoginItemFeedback", .timeLimit(.minutes(2)))
struct LoginItemFeedbackTests {
    private func error(_ code: Int) -> NSError {
        NSError(domain: "SMAppServiceErrorDomain", code: code)
    }

    @Test func alreadyInTheRequestedStateIsNotAnError() {
        // Turning off an item that isn't registered used to show "The operation couldn't be completed".
        #expect(LoginItemFeedback.message(for: error(kSMErrorAlreadyRegistered)) == nil)
        #expect(LoginItemFeedback.message(for: error(kSMErrorJobNotFound)) == nil)
    }

    @Test func pendingApprovalCountsAsOnButNeedsAction() {
        #expect(LoginItemState(.requiresApproval) == .requiresApproval)
        #expect(LoginItemState(.requiresApproval).isOn)
        #expect(LoginItemState(.enabled) == .enabled)
        #expect(LoginItemState(.enabled).isOn)
        #expect(LoginItemState(.notRegistered) == .disabled)
        #expect(LoginItemState(.notFound) == .disabled)
        #expect(!LoginItemState(.notRegistered).isOn)
    }
}
