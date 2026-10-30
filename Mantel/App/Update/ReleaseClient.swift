import Foundation
import MKCore
import MKUpdate

/// Asks GitHub for the repository's latest release. Nothing is sent but the GET and a `User-Agent`, which GitHub refuses
/// a request without: no cookies, no cache, no credentials, no identifiers. The session is ephemeral and every request
/// gives up after 30 s.
nonisolated struct ReleaseClient: Sendable {
    let endpoint: URL
    let userAgent: String
    /// The `owner/repo` the endpoint is for, to name it in the log.
    let repository: String
    private let session: URLSession

    init(endpoint: URL, userAgent: String, repository: String) {
        self.endpoint = endpoint
        self.userAgent = userAgent
        self.repository = repository
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    /// The answer, read (`ReleaseFeed.result`). A request that doesn't get an answer (no network, a timeout, a refused
    /// connection) is a network failure; the status of an answer that came is `ReleaseFeed`'s to judge.
    func fetchLatest() async -> FeedResult {
        var request = URLRequest(url: endpoint)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (body, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed(.serverError) }
            Log.update.info("Release check: HTTP \(http.statusCode)")
            if http.statusCode == 404 {
                // The person is told they're up to date, as a repository with no release says; a 404 is also what a wrong
                // or private repository answers, so the log says which one was asked.
                Log.update.warning("The update feed answered 404 for \(repository): no release yet, or the repository name is wrong or private")
            }
            return ReleaseFeed.result(status: http.statusCode, body: body)
        } catch {
            Log.update.info("Release check: no answer (\((error as? URLError)?.code.rawValue ?? 0))")
            return .failed(.network)
        }
    }
}
