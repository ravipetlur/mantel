import Foundation
import MKCommands
import MKCore

// The `mantel` command-line tool: it sends one command to the running Mantel app over the control socket and prints the
// answer. What it prints, and how it exits, is decided in MKCommands (`CLIOutput`), where it is tested; this only
// writes it out.
//
// The app lets this tool in because of how it is signed (its identifier is the app's with `.cli` after it), so it only
// works from inside Mantel.app: Contents/Helpers/mantel.

func finish(_ outcome: CLIOutcome) -> Never {
    if !outcome.stdout.isEmpty {
        FileHandle.standardOutput.write(Data((outcome.stdout + "\n").utf8))
    }
    if !outcome.stderr.isEmpty {
        FileHandle.standardError.write(Data((outcome.stderr + "\n").utf8))
    }
    exit(outcome.exitCode)
}

let arguments = Array(CommandLine.arguments.dropFirst())

if CLIParser.isHelpRequest(arguments) {
    finish(CLIOutput.help)
}

switch CLIParser.parse(arguments) {
case .failure(let error):
    finish(CLIOutput.outcome(for: error))
case .success(let invocation):
    // A command that has to be agreed to is asked about first, on a terminal; with nobody to ask it isn't sent. The question goes to
    // standard error, so that what is printed to standard output is only ever the answer.
    if let question = invocation.confirmation {
        guard isatty(STDIN_FILENO) != 0 else {
            finish(CLIOutput.needsAnswerBeforehand)
        }
        FileHandle.standardError.write(Data(question.utf8))
        guard CLIConfirmation.accepts(readLine()) else {
            finish(CLIOutput.declined)
        }
    }
    let client = ControlSocketClient(path: MantelPaths.live().controlSocket)
    // A probe can hold the menu bar for half a minute or more (its own hold, and its checks before and after), so it is given
    // longer than the other commands to answer; a reset restarts the menu bar and waits for it to come back.
    let timeout: Duration
    switch invocation.command {
    case .probe: timeout = .seconds(180)
    case .reset: timeout = .seconds(60)
    default: timeout = .seconds(30)
    }
    do throws(ClientError) {
        let result = try await client.send(invocation.command, timeout: timeout)
        finish(CLIOutput.outcome(for: result, json: invocation.json))
    } catch {
        finish(CLIOutput.outcome(for: error))
    }
}
