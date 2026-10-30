import Foundation

/// Runs one of macOS's own command-line tools and waits for it, without holding a thread: the updater uses it for
/// `/usr/sbin/spctl` (Gatekeeper) and `/usr/sbin/diskutil` (mounting). Nothing goes in through the shell: the arguments
/// are passed as they are.
///
/// Cancelling the task ends the tool, and the call throws `CancellationError`. A tool that runs past the timeout is
/// ended too, and the call throws `ProcessRunner.Failure.timedOut`.
nonisolated enum ProcessRunner {
    struct Result: Sendable {
        /// The exit status: 0 for success.
        let status: Int32
        /// What the tool printed (its output and error together), up to a few kilobytes, trimmed. For the log.
        let output: String
    }

    enum Failure: Error, Equatable {
        case timedOut
    }

    static func run(_ executable: String, arguments: [String], timeout: Duration = .seconds(120)) async throws -> Result {
        let job = Job(executable: executable, arguments: arguments)
        return try await withTaskCancellationHandler {
            try await job.run(timeout: timeout)
        } onCancel: {
            job.stop(timedOut: false)
        }
    }

    /// One run of a tool. `Process` isn't `Sendable`, so what is shared between the task and the tool's own threads (the
    /// output, and whether it was stopped) is kept behind a lock.
    private final class Job: @unchecked Sendable {
        private static let outputLimit = 8 * 1024

        private let process = Process()
        private let pipe = Pipe()
        private let lock = NSLock()
        private var started = false
        private var cancelled = false
        private var timedOut = false
        private var output = Data()

        init(executable: String, arguments: [String]) {
            process.executableURL = URL(filePath: executable)
            process.arguments = arguments
            // The tool never waits for a keypress, and what it prints is for the log only.
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = pipe
            process.standardError = pipe
        }

        func run(timeout: Duration) async throws -> Result {
            pipe.fileHandleForReading.readabilityHandler = { [self] handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                lock.withLock {
                    if output.count < Self.outputLimit { output.append(chunk.prefix(Self.outputLimit - output.count)) }
                }
            }
            let timer = Task { [self] in
                try await Task.sleep(for: timeout)
                stop(timedOut: true)
            }
            defer { timer.cancel() }

            let status: Int32 = try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    continuation.resume(returning: finished.terminationStatus)
                }
                let launchError: (any Error)? = lock.withLock {
                    // Stopped before it started: it never does.
                    if cancelled || timedOut { return CancellationError() }
                    do {
                        try process.run()
                        started = true
                        return nil
                    } catch {
                        return error
                    }
                }
                if let launchError { continuation.resume(throwing: launchError) }
            }

            // What it printed last. The tool has exited, but something it started may still hold the pipe open, so what is
            // there is read and the end of the pipe isn't waited for.
            try? await Task.sleep(for: .milliseconds(50))
            pipe.fileHandleForReading.readabilityHandler = nil
            let rest = Self.readWhatIsThere(pipe.fileHandleForReading.fileDescriptor)
            lock.withLock {
                if output.count < Self.outputLimit { output.append(rest.prefix(Self.outputLimit - output.count)) }
            }
            try? pipe.fileHandleForReading.close()

            let (wasCancelled, didTimeOut, printed) = lock.withLock { (cancelled, timedOut, output) }
            if didTimeOut { throw Failure.timedOut }
            if wasCancelled { throw CancellationError() }
            let text = String(decoding: printed, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return Result(status: status, output: text)
        }

        /// Reads from the descriptor while there is something to read, and returns without waiting for more.
        private static func readWhatIsThere(_ descriptor: Int32) -> Data {
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while data.count < outputLimit {
                var watched = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                guard poll(&watched, 1, 0) > 0, watched.revents & Int16(POLLIN) != 0 else { break }
                let count = read(descriptor, &buffer, buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer[..<count])
            }
            return data
        }

        /// Ends the tool: the task was cancelled, or it ran too long. `run` doesn't come back until the tool has exited, so
        /// whatever it was doing is over (or handed on to the system) when the caller carries on. A tool that ignores the
        /// request to end is killed two seconds later.
        func stop(timedOut stoppedByTimeout: Bool) {
            let running: Bool = lock.withLock {
                if stoppedByTimeout { timedOut = true } else { cancelled = true }
                guard started, process.isRunning else { return false }
                process.terminate()
                return true
            }
            guard running else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
                lock.withLock {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
    }
}
