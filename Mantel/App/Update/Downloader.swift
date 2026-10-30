import Foundation
import MKCore
import MKUpdate
import Synchronization

/// Downloads a release's files with a `URLSessionDownloadTask`, into a folder the installer made for the purpose. Like the
/// release check, it sends nothing but the GET and a `User-Agent`: an ephemeral session, no cookies, no cache, no
/// credentials. A redirect (GitHub sends assets on to its storage) is followed only to another `https` address.
///
/// A task that is cancelled ends the download and throws `URLError(.cancelled)`; the installer counts that as a cancel.
nonisolated struct Downloader: Sendable {
    let userAgent: String

    /// Downloads `asset` into `folder` as `asset.name`, and returns the file. `progress` is told the share that has
    /// arrived (0 to 1), at most about a hundred times. Throws `UpdateFailure.downloadFailed` when the server answers with
    /// anything but 200 or the transfer breaks, and `UpdateFailure.sizeMismatch` when the file isn't the size the
    /// release lists for it.
    func download(
        _ asset: ReleaseInfo.Asset, into folder: URL, progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let destination = folder.appending(path: asset.name, directoryHint: .notDirectory)
        var request = URLRequest(url: asset.url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        Log.update.info("Downloading \(asset.name) (\(asset.size) bytes)")
        let job = Job(destination: destination, expectedSize: asset.size, progress: progress)
        try await job.run(request)

        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path(percentEncoded: false))[.size] as? Int) ?? -1
        guard size == asset.size else {
            Log.update.warning("\(asset.name) is \(size) bytes, and the release lists \(asset.size)")
            throw UpdateFailure.sizeMismatch
        }
        progress?(1)
        return destination
    }

    /// One download. The session calls back on its own queue, so what the callbacks and the waiting task share is kept
    /// behind a lock.
    private final class Job: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private struct State {
            var continuation: CheckedContinuation<Void, any Error>?
            var task: URLSessionDownloadTask?
            var cancelled = false
            var status: Int?
            var failure: UpdateFailure?
            var reported = 0.0
        }

        private let destination: URL
        private let expectedSize: Int
        private let progress: (@Sendable (Double) -> Void)?
        private let state = Mutex(State())

        init(destination: URL, expectedSize: Int, progress: (@Sendable (Double) -> Void)?) {
            self.destination = destination
            self.expectedSize = expectedSize
            self.progress = progress
        }

        private static var configuration: URLSessionConfiguration {
            let configuration = URLSessionConfiguration.ephemeral
            // A stalled connection gives up after 30 s, and a download that keeps going has a quarter of an hour.
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 15 * 60
            configuration.httpCookieAcceptPolicy = .never
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            return configuration
        }

        func run(_ request: URLRequest) async throws {
            let session = URLSession(configuration: Self.configuration, delegate: self, delegateQueue: nil)
            // The session holds its delegate until it is invalidated.
            defer { session.finishTasksAndInvalidate() }
            let task = session.downloadTask(with: request)
            state.withLock { $0.task = task }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    let alreadyCancelled = state.withLock { state in
                        state.continuation = continuation
                        return state.cancelled
                    }
                    // A cancel that came first still ends the task, which then reports `cancelled` once it runs.
                    if alreadyCancelled { task.cancel() }
                    task.resume()
                }
            } onCancel: {
                let task = state.withLock { state in
                    state.cancelled = true
                    return state.task
                }
                task?.cancel()
            }
        }

        // MARK: URLSessionDownloadDelegate

        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
        ) {
            // More than the release lists, or announced as more: the download is stopped here, as a size mismatch, and not
            // read to the end of a file that can't pass.
            if DownloadSize.exceeds(listed: expectedSize, received: totalBytesWritten)
                || DownloadSize.exceeds(listed: expectedSize, announced: totalBytesExpectedToWrite) {
                Log.update.warning("The download is past the \(expectedSize) bytes the release lists, and was stopped")
                state.withLock { $0.failure = .sizeMismatch }
                downloadTask.cancel()
                return
            }
            guard let progress, expectedSize > 0 else { return }
            // The release's own size is the measure: it is what the file is checked against.
            let share = min(1, Double(totalBytesWritten) / Double(expectedSize))
            let report = state.withLock { state in
                guard share - state.reported >= 0.01 else { return false }
                state.reported = share
                return true
            }
            if report { progress(share) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            // The file is deleted when this returns, so it is moved now.
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode
            state.withLock { $0.status = status }
            guard status == 200 else { return }
            do {
                let fileManager = FileManager.default
                if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.moveItem(at: location, to: destination)
            } catch {
                Log.update.warning("The downloaded file couldn't be moved into place: \(error.localizedDescription)")
                state.withLock { $0.failure = .downloadFailed }
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            let (continuation, status, failure) = state.withLock { state in
                let continuation = state.continuation
                state.continuation = nil
                return (continuation, state.status, state.failure)
            }
            guard let continuation else { return }
            if let failure, failure == .sizeMismatch {
                // Stopped by `didWriteData` for being too large: that is the answer, not the cancel that carried it out.
                continuation.resume(throwing: failure)
            } else if let error {
                // A cancelled task says `URLError.cancelled`, which the installer counts as a cancel.
                Log.update.info("The download ended with an error (\((error as NSError).domain) \((error as NSError).code))")
                continuation.resume(throwing: error)
            } else if status != 200 {
                Log.update.warning("The download answered HTTP \(status.map(String.init) ?? "none")")
                continuation.resume(throwing: UpdateFailure.downloadFailed)
            } else if let failure {
                continuation.resume(throwing: failure)
            } else {
                continuation.resume()
            }
        }

        /// A redirect is followed only to `https`: anything else ends the download as a failure.
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard request.url?.scheme?.lowercased() == "https" else {
                Log.update.warning("The download was redirected to an address that isn't https")
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
    }
}
