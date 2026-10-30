import Foundation
import MKUpdate
import Testing

/// What the updater makes of GitHub's `releases/latest`: only a published release with exactly one disk image and one checksum
/// file for its own version, over https, is one to install. The values are synthetic.
@Suite("The release feed", .timeLimit(.minutes(2)))
struct ReleaseFeedTests {
    static let downloads = "https://example.com/app/releases/download"

    /// One asset as the API lists it: the fields used plus extras.
    static func asset(_ name: String, size: Int = 3_763_969, url: String? = nil, extra: String = "") -> String {
        """
        { "id": 4242, "name": "\(name)", "state": "uploaded", "size": \(size), "uploader": { "login": "release-bot" },
          "browser_download_url": "\(url ?? "\(downloads)/v1.2.0/\(name)")"\(extra) }
        """
    }

    static let notesJSON = ###""## What's new\n\n- Updates arrive in the app.\n""###
    static let goodDMG = asset("Mantel-1.2.0.dmg")
    static let goodChecksum = asset("Mantel-1.2.0.dmg.sha256", size: 86)

    /// A release as `releases/latest` returns it. `assets` are JSON snippets; the default is the two a good release has.
    static func release(
        tag: String? = "v1.2.0", draft: String? = "false", prerelease: String? = "false", body: String? = notesJSON,
        pageURL: String? = "https://example.com/app/releases/tag/v1.2.0", assets: [String]? = [goodDMG, goodChecksum]
    ) -> Data {
        var fields = [#""id": 1001"#, #""published_at": "2026-10-09T08:00:00Z""#]
        if let tag { fields.append(#""tag_name": "\#(tag)""#) }
        if let draft { fields.append(#""draft": \#(draft)"#) }
        if let prerelease { fields.append(#""prerelease": \#(prerelease)"#) }
        if let body { fields.append(#""body": \#(body)"#) }
        if let pageURL { fields.append(#""html_url": "\#(pageURL)""#) }
        if let assets { fields.append(#""assets": [\#(assets.joined(separator: ","))]"#) }
        return Data("{\(fields.joined(separator: ",\n"))}".utf8)
    }

    @Test func decodesAGoodReleaseAndIgnoresWhatItDoesNotRead() throws {
        let noisy = Self.asset("Mantel-1.2.0.dmg", extra: #", "future_field": { "a": [1, {"b": null}] }"#)
        let junk = ["null", "7", #""text""#, "[]", #"{"name": 5, "size": "x"}"#, "{}", Self.asset("Mantel-1.2.0.zip"), Self.asset("notes.txt", size: 12)]
        for assets in [[Self.goodDMG, Self.goodChecksum], [Self.goodChecksum, noisy], junk + [Self.goodDMG, Self.goodChecksum]] {
            let info = try #require(ReleaseFeed.latest(from: Self.release(assets: assets)))
            #expect(info.version == VersionNumber("1.2.0"))
            #expect(info.notes == "## What's new\n\n- Updates arrive in the app.\n")
            #expect(info.pageURL == URL(string: "https://example.com/app/releases/tag/v1.2.0"))
            #expect(info.dmg.name == "Mantel-1.2.0.dmg")
            #expect(info.dmg.size == 3_763_969)
            #expect(info.dmg.url == URL(string: "https://example.com/app/releases/download/v1.2.0/Mantel-1.2.0.dmg"))
            #expect(info.checksum.name == "Mantel-1.2.0.dmg.sha256")
        }
        #expect(ReleaseFeed.latest(from: Self.release(tag: "1.2.0")) != nil)
        #expect(ReleaseFeed.latest(from: Self.release(body: nil))?.notes == "")
        #expect(ReleaseFeed.latest(from: Self.release(body: "null"))?.notes == "")
    }

    // MARK: Drafts, pre-releases and tags

    @Test(arguments: [("true", "false"), ("false", "true"), ("true", "true"), (#""false""#, "false"), ("false", "0")])
    func aDraftOrPreReleaseGivesNothing(draft: String, prerelease: String) {
        #expect(ReleaseFeed.latest(from: Self.release(draft: draft, prerelease: prerelease)) == nil)
    }

    @Test(arguments: [
        "latest", "v1.2", "1.2", "v1.2.0.1", "1.2.0-beta.1", "v1.2.0-rc1", "v01.2.0", "V1.2.0", "", " v1.2.0", "release-1.2.0",
    ])
    func aTagThatIsNotAVersionGivesNothing(tag: String) {
        #expect(ReleaseFeed.latest(from: Self.release(tag: tag)) == nil)
        #expect(ReleaseFeed.latest(from: Self.release(tag: nil)) == nil)
    }

    // MARK: The assets

    /// Names are matched exactly (case, spacing, suffix, version): the wrong image for the tag is never taken.
    @Test(arguments: [
        "mantel-1.2.0.dmg", "Mantel-1.2.0.DMG", "Mantel-1.2.0.dmg ", " Mantel-1.2.0.dmg", "Mantel-v1.2.0.dmg", "Mantel-1.2.dmg",
        "Mantel-1.2.0.dmg.zip", "Mantel-1.2.0-arm64.dmg", "Other-1.2.0.dmg", "Mantel-1.1.0.dmg",
    ])
    func aDiskImageNamedAnyOtherWayDoesNotCount(name: String) {
        #expect(ReleaseFeed.latest(from: Self.release(assets: [Self.asset(name), Self.goodChecksum])) == nil)
    }

    @Test(arguments: [
        "mantel-1.2.0.dmg.sha256", "Mantel-1.2.0.dmg.SHA256", "Mantel-1.2.0.dmg.sha256.txt", "Mantel-1.2.0.sha256",
        "Mantel-1.2.0.dmg.sha512", "Mantel-1.1.0.dmg.sha256",
    ])
    func aChecksumNamedAnyOtherWayDoesNotCount(name: String) {
        #expect(ReleaseFeed.latest(from: Self.release(assets: [Self.goodDMG, Self.asset(name, size: 86)])) == nil)
    }

    @Test func bothFilesAreNeededAndEachOnlyOnce() {
        #expect(ReleaseFeed.latest(from: Self.release(assets: [Self.goodDMG])) == nil)
        #expect(ReleaseFeed.latest(from: Self.release(assets: [Self.goodChecksum])) == nil)
        #expect(ReleaseFeed.latest(from: Self.release(assets: [])) == nil)
        #expect(ReleaseFeed.latest(from: Self.release(assets: nil)) == nil)
        let mirror = Self.asset("Mantel-1.2.0.dmg", size: 999, url: "https://example.com/mirror/Mantel-1.2.0.dmg")
        #expect(ReleaseFeed.latest(from: Self.release(assets: [Self.goodDMG, mirror, Self.goodChecksum])) == nil)
        // A malformed twin counts too: it isn't dropped in favour of the well-formed one.
        let twin = #"{"name": "Mantel-1.2.0.dmg", "size": "big", "browser_download_url": "https://example.com/x"}"#
        #expect(ReleaseFeed.latest(from: Self.release(assets: [Self.goodDMG, twin, Self.goodChecksum])) == nil)
    }

    @Test(arguments: ["0", "-5", "null", #""3763969""#, "1.5"])
    func aFileWithoutAUsableSizeGivesNothing(size: String) {
        let dmg = #"{"name": "Mantel-1.2.0.dmg", "size": \#(size), "browser_download_url": "https://example.com/a/Mantel-1.2.0.dmg"}"#
        #expect(ReleaseFeed.latest(from: Self.release(assets: [dmg, Self.goodChecksum])) == nil)
    }

    @Test(arguments: [
        "http://example.com/a/Mantel-1.2.0.dmg", "file:///tmp/Mantel-1.2.0.dmg", "ftp://example.com/Mantel-1.2.0.dmg",
        "/relative/Mantel-1.2.0.dmg", "https:///Mantel-1.2.0.dmg", "",
    ])
    func onlyHTTPSLinksCount(link: String) {
        let dmg = Self.asset("Mantel-1.2.0.dmg", url: link)
        #expect(ReleaseFeed.latest(from: Self.release(assets: [dmg, Self.goodChecksum])) == nil)
        let sum = Self.asset("Mantel-1.2.0.dmg.sha256", size: 86, url: link)
        #expect(ReleaseFeed.latest(from: Self.release(assets: [Self.goodDMG, sum])) == nil)
        #expect(ReleaseFeed.latest(from: Self.release(pageURL: link)) == nil)
    }

    @Test(arguments: ["", "not json", "{", "[]", "null", "7", "{}", #"{"tag_name": 5}"#, #"{"tag_name": null}"#])
    func garbageGivesNothing(text: String) {
        #expect(ReleaseFeed.latest(from: Data(text.utf8)) == nil)
        let whole = Self.release()
        #expect(ReleaseFeed.latest(from: whole.prefix(whole.count / 2)) == nil)
    }

    // MARK: The answer

    @Test func aGoodReleaseWith200IsARelease() throws {
        let body = Self.release()
        #expect(ReleaseFeed.result(status: 200, body: body) == .release(try #require(ReleaseFeed.latest(from: body))))
    }

    /// Valid JSON with no release to install is no release; a 200 that isn't a JSON object (a network's sign-in page, an empty
    /// body) is the server's fault.
    @Test func a200WithNothingToInstallIsNoReleaseAndOneThatIsNotJSONIsAnError() {
        for body in [Self.release(prerelease: "true"), Self.release(draft: "true"), Self.release(assets: []), Data("{}".utf8)] {
            #expect(ReleaseFeed.result(status: 200, body: body) == .noRelease)
        }
        for text in ["", "<html>Sign in</html>", "[]", "42", "null", "{"] {
            #expect(ReleaseFeed.result(status: 200, body: Data(text.utf8)) == .failed(.serverError))
        }
    }

    /// The status decides first: a good-looking body under an error status is never read for a release.
    @Test(arguments: [
        (404, FeedResult.noRelease), (403, .failed(.rateLimited)), (429, .failed(.rateLimited)), (500, .failed(.serverError)),
        (503, .failed(.serverError)), (301, .failed(.serverError)), (304, .failed(.serverError)), (0, .failed(.serverError)),
    ])
    func theStatusWinsOverTheBody(status: Int, expected: FeedResult) {
        #expect(ReleaseFeed.result(status: status, body: Self.release()) == expected)
    }

    // MARK: The endpoint

    @Test func theEndpointIsTheLatestReleaseOfTheRepositoryAndNothingElseBecomesOne() {
        #expect(ReleaseFeed.endpoint(repository: "owner/repo") == URL(string: "https://api.github.com/repos/owner/repo/releases/latest"))
        #expect(ReleaseFeed.endpoint(repository: "My-Org_2/some.app-v2")
                == URL(string: "https://api.github.com/repos/My-Org_2/some.app-v2/releases/latest"))
        let bad = [
            "", " ", "owner", "owner/", "/repo", "a/b/c", " owner/repo", "owner/repo ", "owner/re po", "owner//repo", "../x", "owner/..",
            "owner/.", "owner/repo?x=1", "owner/repo#frag", "ow%6Eer/repo", "own@er/repo", "$(MANTEL_UPDATE_REPO)",
            "https://github.com/owner/repo", "ow\u{f1}er/repo", "owner\\repo", "owner/repo\n",
        ]
        for repository in bad {
            #expect(ReleaseFeed.endpoint(repository: repository) == nil, "\(repository.debugDescription)")
        }
    }
}
