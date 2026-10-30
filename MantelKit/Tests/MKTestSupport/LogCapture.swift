import Foundation
import MKCore

/// What `Log` writes while a test body runs, for a test that checks a line was logged.
///
/// `Log` is one for the whole process, and tests run side by side, so a capture installs a file sink in a folder of its own for the
/// time of the body and takes it away again, one capture at a time. Lines other tests log meanwhile are in the result too: look
/// for the line, and don't count on there being nothing else. A test never writes the live log, because nothing but the app
/// installs a sink on the live folder.
public enum LogCapture {
    private static let queue = AsyncSerialQueue()

    /// The lines `Log` wrote while `body` ran, as the file sink writes them (`<time> [LEVEL] [category] message`).
    public static func lines(during body: @escaping @Sendable () async -> Void) async -> [String] {
        await queue.run {
            let folder = TemporaryFolder(prefix: "mantel-log-capture")
            defer { withExtendedLifetime(folder) {} }
            let sink = FileLogSink(directory: folder.url)
            Log.configure(sink: sink)
            await body()
            Log.configure(sink: nil)
            let text = (try? String(contentsOf: sink.currentFileURL, encoding: .utf8)) ?? ""
            return text.split(separator: "\n").map(String.init)
        }
    }
}
