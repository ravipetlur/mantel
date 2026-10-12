import Foundation
import MKCommands
import Testing

@Suite("Command-line output")
struct CLIOutputTests {
    // MARK: Answers

    @Test func pingPrintsPong() {
        #expect(CLIOutput.outcome(for: .ok(.string("pong")), json: false)
                == CLIOutcome(stdout: "pong", stderr: "", exitCode: 0))
    }

    @Test func nothingToSayPrintsNothing() {
        #expect(CLIOutput.outcome(for: .ok(.null), json: false) == CLIOutcome(stdout: "", stderr: "", exitCode: 0))
    }

    @Test func otherValuesArePrintedAsPrettyJSONInOrder() {
        let result = CommandResult.ok(.object(["version": .string("0.1.0"), "build": .string("1"),
                                               "paths": .array([.string("/a/b")])]))
        let outcome = CLIOutput.outcome(for: result, json: false)
        #expect(outcome.exitCode == 0)
        #expect(outcome.stderr.isEmpty)
        #expect(outcome.stdout == """
        {
          "build" : "1",
          "paths" : [
            "/a/b"
          ],
          "version" : "0.1.0"
        }
        """)
    }

    @Test func aFailurePrintsItsMessageOnStderr() {
        let outcome = CLIOutput.outcome(for: .failure(code: .unavailable, message: "Probes aren't built yet"), json: false)
        #expect(outcome == CLIOutcome(stdout: "", stderr: "mantel: Probes aren't built yet", exitCode: 1))
    }

    @Test(arguments: [CommandErrorCode.badRequest, .unavailable, .failed, .unknownCommand])
    func everyFailureButARefusalExitsWith1(code: CommandErrorCode) {
        #expect(CLIOutput.outcome(for: .failure(code: code, message: "x"), json: false).exitCode == 1)
    }

    @Test func aRefusalExitsWith4() {
        let outcome = CLIOutput.outcome(for: .failure(code: .rejected, message: "Not a Mantel tool: com.apple.Terminal"),
                                        json: false)
        #expect(outcome == CLIOutcome(stdout: "", stderr: "mantel: Not a Mantel tool: com.apple.Terminal", exitCode: 4))
    }

    // MARK: --json

    @Test func jsonPrintsTheResultAsItIsOnTheWire() throws {
        let ok = CLIOutput.outcome(for: .ok(.string("pong")), json: true)
        #expect(ok == CLIOutcome(stdout: #"{"status":"ok","value":"pong"}"#, stderr: "", exitCode: 0))

        let nothing = CLIOutput.outcome(for: .ok(.null), json: true)
        #expect(nothing.stdout == #"{"status":"ok","value":null}"#)

        let failure = CLIOutput.outcome(for: .failure(code: .rejected, message: "No."), json: true)
        #expect(failure == CLIOutcome(stdout: #"{"code":"rejected","message":"No.","status":"failure"}"#,
                                      stderr: "", exitCode: 4))
        let failed = CLIOutput.outcome(for: .failure(code: .failed, message: "No."), json: true)
        #expect(failed.exitCode == 1)

        // What it prints reads back as the result.
        let printed = try JSONDecoder().decode(CommandResult.self, from: Data(failure.stdout.utf8))
        #expect(printed == .failure(code: .rejected, message: "No."))
    }

    // MARK: No answer

    @Test func whenMantelIsNotRunningTheExitCodeIs3() {
        #expect(CLIOutput.outcome(for: ClientError.notRunning)
                == CLIOutcome(stdout: "", stderr: "mantel: Mantel isn't running. Open it, then try again.", exitCode: 3))
    }

    @Test func whenMantelDoesNotAnswerTheExitCodeIs1() {
        let timedOut = CLIOutput.outcome(for: ClientError.timedOut)
        #expect(timedOut.exitCode == 1)
        #expect(timedOut.stderr == "mantel: Mantel didn't answer in time. Try again.")
        let protocolError = CLIOutput.outcome(for: ClientError.protocolError("Mantel's answer couldn't be read."))
        #expect(protocolError == CLIOutcome(stdout: "", stderr: "mantel: Mantel's answer couldn't be read.", exitCode: 1))
    }

    // MARK: Confirming

    @Test(arguments: ["y", "Y", "yes", "YES", "Yes", " y ", "\tyes\n", "  Yes  "])
    func confirmationAcceptsYAndYes(answer: String) {
        #expect(CLIConfirmation.accepts(answer))
    }

    @Test(arguments: ["", " ", "\n", "n", "N", "no", "No", "yep", "yess", "ye", "y es", "ok", "sure", "1", "true", "yes please", "yn"])
    func confirmationRejectsEmpty(answer: String) {
        // An empty line is a no (the question says [y/N]), and so is anything that isn't one of the two words.
        #expect(!CLIConfirmation.accepts(answer))
    }

    @Test func confirmationRejectsTheEndOfTheInput() {
        #expect(!CLIConfirmation.accepts(nil))
    }

    @Test func notAgreeingToAResetPrintsThatItWasNotDone() {
        #expect(CLIOutput.declined == CLIOutcome(stdout: "", stderr: "mantel: Not reset.", exitCode: 1))
    }

    @Test func aResetWithNobodyToAskIsWrongArguments() {
        #expect(CLIOutput.needsAnswerBeforehand
                == CLIOutcome(stdout: "", stderr: "mantel: Add --yes to reset without being asked.", exitCode: 2))
    }

    // MARK: Usage

    @Test func wrongArgumentsExitWith2AndSayWhatToTypeInstead() {
        guard case .failure(let error) = CLIParser.parse(["settings", "bogus"]) else {
            Issue.record("expected a usage error")
            return
        }
        let outcome = CLIOutput.outcome(for: error)
        #expect(outcome.exitCode == 2)
        #expect(outcome.stdout.isEmpty)
        #expect(outcome.stderr == "mantel: \(error.message)")
    }

    @Test func noArgumentsPrintsTheUsageItselfOnStderr() {
        guard case .failure(let error) = CLIParser.parse([]) else {
            Issue.record("expected a usage error")
            return
        }
        #expect(CLIOutput.outcome(for: error) == CLIOutcome(stdout: "", stderr: CLIParser.usage, exitCode: 2))
    }

    @Test func helpPrintsTheUsageAndSucceeds() {
        #expect(CLIOutput.help == CLIOutcome(stdout: CLIParser.usage, stderr: "", exitCode: 0))
    }
}
