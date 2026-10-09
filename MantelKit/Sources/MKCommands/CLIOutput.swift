import Foundation

/// What the `mantel` tool prints and exits with. The tool itself only writes it out.
public struct CLIOutcome: Sendable, Equatable {
    /// For standard output. Written with a newline after it, unless it is empty.
    public let stdout: String
    /// For standard error. The same.
    public let stderr: String
    public let exitCode: Int32

    public init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

/// How an answer, or the lack of one, is shown on the command line.
///
/// Exit codes: 0 done, 1 Mantel said it couldn't (or didn't answer properly), 2 wrong arguments, 3 Mantel isn't
/// running, 4 Mantel refused this tool.
public enum CLIOutput {
    private static let unwritable = #"{"code":"failed","message":"Couldn't write the answer.","status":"failure"}"#

    /// `mantel help`.
    public static let help = CLIOutcome(stdout: CLIParser.usage, stderr: "", exitCode: 0)

    /// An answer from Mantel. With `json`, the result as the app sent it, on one line; otherwise a text is printed as it
    /// is (`mantel ping` says `pong`), nothing is printed for nothing, and any other value as indented JSON.
    public static func outcome(for result: CommandResult, json: Bool) -> CLIOutcome {
        let exitCode = exitCode(of: result)
        if json {
            // A result JSON can't hold (a number that isn't one) is the one thing that can't be written as it is.
            let line = (try? LineCodec.encode(result)).flatMap { String(data: $0, encoding: .utf8) }
            return CLIOutcome(stdout: line.map { String($0.dropLast()) } ?? unwritable, stderr: "", exitCode: exitCode)
        }
        switch result {
        case .ok(.null):
            return CLIOutcome(stdout: "", stderr: "", exitCode: 0)
        case .ok(.string(let text)):
            return CLIOutcome(stdout: text, stderr: "", exitCode: 0)
        case .ok(let value):
            return CLIOutcome(stdout: pretty(value), stderr: "", exitCode: 0)
        case .failure(_, let message):
            return CLIOutcome(stdout: "", stderr: "mantel: \(message)", exitCode: exitCode)
        }
    }

    /// No answer.
    public static func outcome(for error: ClientError) -> CLIOutcome {
        switch error {
        case .notRunning:
            CLIOutcome(stdout: "", stderr: "mantel: Mantel isn't running. Open it, then try again.", exitCode: 3)
        case .timedOut:
            CLIOutcome(stdout: "", stderr: "mantel: Mantel didn't answer in time. Try again.", exitCode: 1)
        case .protocolError(let problem):
            CLIOutcome(stdout: "", stderr: "mantel: \(problem)", exitCode: 1)
        }
    }

    /// Arguments that weren't understood. With none at all, the usage is all there is to say.
    public static func outcome(for error: CLIUsageError) -> CLIOutcome {
        let text = error.message == CLIParser.usage ? error.message : "mantel: \(error.message)"
        return CLIOutcome(stdout: "", stderr: text, exitCode: 2)
    }

    private static func exitCode(of result: CommandResult) -> Int32 {
        switch result {
        case .ok: 0
        case .failure(.rejected, _): 4
        case .failure: 1
        }
    }

    private static func pretty(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }
}
