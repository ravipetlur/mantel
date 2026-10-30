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

    @Test func deniedByTheUserPointsToLoginItems() {
        let message = LoginItemFeedback.message(for: error(kSMErrorLaunchDeniedByUser))
        #expect(message?.contains("Login Items") == true)
    }

    @Test func aRejectedSignatureSaysSo() {
        let message = LoginItemFeedback.message(for: error(kSMErrorInvalidSignature))
        #expect(message?.contains("signature") == true)
    }

    @Test func anyOtherErrorStillSaysWhatToDo() {
        let message = LoginItemFeedback.message(for: error(kSMErrorInternalFailure))
        #expect(message?.contains("Login Items") == true)
        #expect(message?.contains("\(kSMErrorInternalFailure)") == true)
    }

    @Test func everyMessageNamesMantel() {
        let codes = [kSMErrorLaunchDeniedByUser, kSMErrorInvalidSignature, kSMErrorInternalFailure]
        let messages = codes.compactMap { LoginItemFeedback.message(for: error($0)) } + [LoginItemFeedback.approvalMessage]
        #expect(messages.count == 4)
        for message in messages {
            #expect(message.contains("Mantel"))
        }
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
