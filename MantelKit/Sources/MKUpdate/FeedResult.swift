import Foundation

/// What GitHub's answer to a check comes to.
public enum FeedResult: Equatable, Sendable {
    /// A release to install, which may or may not be newer than the running version: `UpdateDecision` says.
    case release(ReleaseInfo)
    /// The answer was fine and holds nothing to install: no release yet, or one that isn't a release to install (a
    /// pre-release, a tag that isn't `vX.Y.Z`, assets missing).
    case noRelease
    /// The check didn't work.
    case failed(UpdateFailure)
}

extension ReleaseFeed {
    /// What the answer with HTTP status `status` and body `body` comes to.
    ///
    /// - 200: the release in the body (`latest(from:)`), or no release when it's valid JSON of another shape or holds
    ///   nothing installable. A body that isn't a JSON object at all (a page a network puts in front of the request, an
    ///   empty body) is a server error, since no real answer looks like that.
    /// - 404: the endpoint's answer when the repository has no release to call the latest, so no release.
    /// - 403 and 429: rate limiting. (GitHub also answers 403 to a request without a User-Agent, which the app sends.)
    /// - Any other status, 5xx included: a server error.
    ///
    /// The status decides first: the body of an error is never read for a release.
    public static func result(status: Int, body: Data) -> FeedResult {
        switch status {
        case 200:
            if let release = latest(from: body) { return .release(release) }
            guard (try? JSONSerialization.jsonObject(with: body)) is [String: Any] else { return .failed(.serverError) }
            return .noRelease
        case 404:
            return .noRelease
        case 403, 429:
            return .failed(.rateLimited)
        default:
            return .failed(.serverError)
        }
    }

    /// The address of the repository's latest release, `https://api.github.com/repos/<owner>/<repo>/releases/latest`,
    /// or nil when `repository` isn't `owner/repo`: exactly one slash, and on each side letters, digits, `-`, `_` and
    /// `.` only (and not just dots). The name comes from a build setting, so this keeps a stray value (a space, a `?`, a
    /// `..`, an unexpanded `$(…)`) from ever becoming part of a request.
    public static func endpoint(repository: String) -> URL? {
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy(isRepositoryName) else { return nil }
        return URL(string: "https://api.github.com/repos/\(parts[0])/\(parts[1])/releases/latest")
    }

    private static func isRepositoryName(_ part: Substring) -> Bool {
        guard !part.isEmpty, part.contains(where: { $0 != "." }) else { return false }
        return part.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."): true
            default: false
            }
        }
    }
}
