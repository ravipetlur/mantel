import Foundation
import MKCore
import MKTestSupport
import Synchronization
import Testing

@testable import MKCore

/// Where the two files are, relative to the home folder. The tests build fake files under a temporary "home" at these
/// paths; the real ones are never touched.
private let menuBarLayoutPath = "Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar.plist"
private let approvalsPath =
    "Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist"

/// The canonical path of a file that exists (every symlink resolved, `/private` included), from the system's own
/// `realpath`: an answer that doesn't come from the code under test.
private func realPath(_ url: URL) -> String? {
    guard let resolved = realpath(url.path(percentEncoded: false), nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// A door a test holds shut: whoever `wait()`s is suspended until `open()`, and anyone who comes after it is open passes.
private final class Gate: Sendable {
    private struct State {
        var isOpen = false
        var waiting: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func wait() async {
        await withCheckedContinuation { continuation in
            let passes = state.withLock { state -> Bool in
                if state.isOpen { return true }
                state.waiting.append(continuation)
                return false
            }
            if passes { continuation.resume() }
        }
    }

    func open() {
        let waiting = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isOpen = true
            defer { state.waiting = [] }
            return state.waiting
        }
        for continuation in waiting { continuation.resume() }
    }
}

@Suite("ExpectedFile", .timeLimit(.minutes(2)))
struct ExpectedFileTests {
    private let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
    /// Held by the suite, and so for the whole test.
    private let folder = TemporaryFolder(prefix: "mantel-expected")

    @Test func theMenuBarLayoutIsInItsGroupContainer() {
        let expected = ExpectedFile.expected(.menuBarLayout, home: home)
        #expect(expected.kind == .menuBarLayout)
        #expect(expected.candidates == ["/Users/someone/\(menuBarLayoutPath)"])
        #expect(expected.fileName == "com.apple.MenuBar.plist")
    }

    @Test func theApprovalsAreInControlCentersGroupContainer() {
        let expected = ExpectedFile.expected(.controlCenterApprovals, home: home)
        #expect(expected.kind == .controlCenterApprovals)
        #expect(expected.candidates == ["/Users/someone/\(approvalsPath)"])
        #expect(expected.fileName == "group.com.apple.controlcenter.plist")
    }

    @Test func theHomeFolderIsTheOneGiven() {
        let other = URL(filePath: "/Volumes/Data/Users/else/", directoryHint: .isDirectory)
        let candidates = ExpectedFile.expected(.menuBarLayout, home: other).candidates
        #expect(candidates == ["/Volumes/Data/Users/else/\(menuBarLayoutPath)"], "a trailing slash doesn't double up")
    }

    @Test func aChoiceMatchesAnyOfTheCandidates() throws {
        let first = folder.url.appending(path: "first.plist")
        let second = folder.url.appending(path: "second.plist")
        let third = folder.url.appending(path: "third.plist")
        for file in [first, second, third] { try Data("x".utf8).write(to: file) }
        let expected = ExpectedFile(kind: .menuBarLayout, candidates: [first.path, second.path])

        #expect(expected.matches(first))
        #expect(expected.matches(second))
        #expect(!expected.matches(third))
    }

    @Test func aRelativeSpellingOfTheSamePathMatches() throws {
        let file = folder.url.appending(path: "a.plist")
        try Data("x".utf8).write(to: file)
        let roundabout = folder.url.appending(path: "sub/../a.plist")
        #expect(ExpectedFile(kind: .menuBarLayout, candidates: [file.path]).matches(roundabout))
    }
}

@Suite("FileGrantError", .timeLimit(.minutes(2)))
struct FileGrantErrorTests {
    @Test func theWrongFileMessageNamesTheFileToChoose() {
        let error = FileGrantError.wrongFile(expected: "com.apple.MenuBar.plist", got: "other.plist")
        #expect(error.errorDescription == "That's not the file Mantel needs. Choose com.apple.MenuBar.plist in the folder that opened.")
    }

    @Test func theStaleMessageNamesTheFileAndWhereToChooseItAgain() {
        #expect(FileGrantError.stale(fileName: "com.apple.MenuBar.plist").errorDescription
                == "Mantel lost access to com.apple.MenuBar.plist. Choose it again in Settings › Permissions.")
        #expect(FileGrantError.stale(fileName: "group.com.apple.controlcenter.plist").errorDescription
                == "Mantel lost access to group.com.apple.controlcenter.plist. Choose it again in Settings › Permissions.")
    }

    @Test func theFileNamesAreTheOnesThePanelAsksFor() {
        #expect(FileGrantKind.menuBarLayout.fileName == "com.apple.MenuBar.plist")
        #expect(FileGrantKind.controlCenterApprovals.fileName == "group.com.apple.controlcenter.plist")
        for kind in FileGrantKind.allCases {
            #expect(ExpectedFile.expected(kind, home: URL(filePath: "/Users/x")).fileName == kind.fileName)
        }
    }

    @Test func theOtherMessagesSayWhatToDo() {
        let failed = FileGrantError.bookmarkFailed("The file doesn't exist.").errorDescription
        #expect(failed?.contains("The file doesn't exist.") == true)
        #expect(failed?.hasSuffix("Choose it again.") == true)
    }
}

@Suite("FileGrantStore", .timeLimit(.minutes(1)))
struct FileGrantStoreTests {
    /// Held by the suite, and so for the whole test: the folder is deleted when the test is over.
    let folder = TemporaryFolder(prefix: "mantel-grants")
    let clock = FakeClock()
    private let fileManager = FileManager.default

    private var home: URL { folder.url.appending(path: "Home", directoryHint: .isDirectory) }

    private var paths: MantelPaths {
        MantelPaths(root: folder.url.appending(path: "Support", directoryHint: .isDirectory),
                    logs: folder.url.appending(path: "Logs", directoryHint: .isDirectory))
    }

    /// A settings store and the grant store on it, over the same folder as any other pair this test makes, so that a
    /// second pair reads what the first one wrote.
    private struct Stores {
        let settings: SettingsStore
        let grants: FileGrantStore
    }

    /// `[]`, the default: plain bookmarks, which no test environment can refuse.
    private func makeStores(options: URL.BookmarkCreationOptions = []) -> Stores {
        let settings = SettingsStore(paths: paths, clock: clock)
        return Stores(settings: settings, grants: FileGrantStore(store: settings, bookmarkOptions: options, clock: clock))
    }

    /// Makes the file at `relative` in the fake home, and its folders.
    @discardableResult
    private func plant(_ relative: String = menuBarLayoutPath, contents: String = "layout") throws -> URL {
        let url = home.appending(path: relative)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func grantFailure(_ kind: FileGrantKind = .menuBarLayout, choosing url: URL, in grants: FileGrantStore) async -> FileGrantError? {
        do {
            _ = try await grants.grant(kind, chosen: url, home: home)
            return nil
        } catch {
            return error as? FileGrantError
        }
    }

    private func accessFailure(_ kind: FileGrantKind = .menuBarLayout, in grants: FileGrantStore) async -> FileGrantError? {
        do {
            try await grants.withAccess(kind) { _ in }
            return nil
        } catch {
            return error as? FileGrantError
        }
    }

    private func contents(through grants: FileGrantStore, _ kind: FileGrantKind = .menuBarLayout) async throws -> String {
        try await grants.withAccess(kind) { try String(contentsOf: $0, encoding: .utf8) }
    }

    // MARK: Granting

    @Test func rightFileIsGranted() async throws {
        let file = try plant()
        let stores = makeStores()

        let grant = try await stores.grants.grant(.menuBarLayout, chosen: file, home: home)

        #expect(grant.kind == .menuBarLayout)
        #expect(!grant.bookmark.isEmpty)
        #expect(realPath(URL(filePath: grant.path)) == realPath(file), "the path is where the bookmark resolved to")
        #expect(grant.grantedAt == clock.now())
        #expect(await stores.grants.grant(for: .menuBarLayout) == grant)
        #expect(await stores.grants.grant(for: .controlCenterApprovals) == nil, "the other file isn't granted")
    }

    @Test func eachFileIsGrantedForItsOwnKind() async throws {
        let layout = try plant(menuBarLayoutPath, contents: "layout")
        let approvals = try plant(approvalsPath, contents: "approvals")
        let stores = makeStores()

        _ = try await stores.grants.grant(.menuBarLayout, chosen: layout, home: home)
        _ = try await stores.grants.grant(.controlCenterApprovals, chosen: approvals, home: home)

        #expect(try await contents(through: stores.grants, .menuBarLayout) == "layout")
        #expect(try await contents(through: stores.grants, .controlCenterApprovals) == "approvals")
    }

    @Test func wrongFileIsRefusedWithExpectedName() async throws {
        try plant()
        let other = try plant("Library/Other/other.plist")
        let stores = makeStores()

        let failure = await grantFailure(choosing: other, in: stores.grants)

        #expect(failure == .wrongFile(expected: "com.apple.MenuBar.plist", got: "other.plist"))
        #expect(await stores.grants.grant(for: .menuBarLayout) == nil, "nothing was kept")
        await stores.settings.flush()
        #expect(!fileManager.fileExists(atPath: paths.settings.appending(path: "grants.json").path), "nothing was saved")
    }

    @Test func theOtherKindsFileIsRefused() async throws {
        try plant()
        let approvals = try plant(approvalsPath)
        let stores = makeStores()

        let failure = await grantFailure(.menuBarLayout, choosing: approvals, in: stores.grants)
        #expect(failure == .wrongFile(expected: "com.apple.MenuBar.plist", got: "group.com.apple.controlcenter.plist"))

        let reverse = await grantFailure(.controlCenterApprovals, choosing: try plant(), in: stores.grants)
        #expect(reverse == .wrongFile(expected: "group.com.apple.controlcenter.plist", got: "com.apple.MenuBar.plist"))
    }

    @Test func aSameNamedFileInAnotherFolderIsRefused() async throws {
        try plant()
        let lookalike = try plant("Documents/com.apple.MenuBar.plist")
        let stores = makeStores()

        let failure = await grantFailure(choosing: lookalike, in: stores.grants)

        #expect(failure == .wrongFile(expected: "com.apple.MenuBar.plist", got: "com.apple.MenuBar.plist"))
        #expect(await stores.grants.grant(for: .menuBarLayout) == nil)
    }

    @Test func symlinkedChoiceMatches() async throws {
        let real = try plant(contents: "the real file")
        let elsewhere = folder.url.appending(path: "Elsewhere", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let link = elsewhere.appending(path: "link.plist")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: real)
        let stores = makeStores()

        let grant = try await stores.grants.grant(.menuBarLayout, chosen: link, home: home)

        #expect(grant.kind == .menuBarLayout)
        #expect(try await contents(through: stores.grants) == "the real file")
    }

    @Test func aSymlinkedFolderInTheExpectedPathMatches() async throws {
        // ~/Library/Group Containers is a link to another folder, and the open panel hands back either spelling.
        let target = folder.url.appending(path: "Containers", directoryHint: .isDirectory)
        let real = target.appending(path: "com.apple.MenuBar/Library/Preferences/com.apple.MenuBar.plist")
        try fileManager.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("through the link".utf8).write(to: real)
        let library = home.appending(path: "Library", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: library, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: library.appending(path: "Group Containers"), withDestinationURL: target)
        let spelledThroughTheLink = home.appending(path: menuBarLayoutPath)
        let stores = makeStores()

        _ = try await stores.grants.grant(.menuBarLayout, chosen: real, home: home)
        #expect(try await contents(through: stores.grants) == "through the link")

        await stores.grants.revoke(.menuBarLayout)
        _ = try await stores.grants.grant(.menuBarLayout, chosen: spelledThroughTheLink, home: home)
        #expect(try await contents(through: stores.grants) == "through the link")
    }

    @Test func aFileThatIsNotThereCantBeBookmarked() async throws {
        // The right path with nothing at it, tried with a security scope (which falls back to a plain bookmark, which
        // fails too).
        let settings = SettingsStore(paths: paths, clock: clock)
        let grants = FileGrantStore(store: settings, clock: clock)
        let missing = home.appending(path: menuBarLayoutPath)

        let failure = await grantFailure(choosing: missing, in: grants)

        guard case .bookmarkFailed(let reason) = failure else {
            Issue.record("expected .bookmarkFailed, got \(String(describing: failure))")
            return
        }
        #expect(!reason.isEmpty)
        #expect(await grants.grant(for: .menuBarLayout) == nil)
    }

    @Test func grantingAgainReplacesTheGrant() async throws {
        let file = try plant()
        let stores = makeStores()
        let first = try await stores.grants.grant(.menuBarLayout, chosen: file, home: home)

        clock.advance(by: .seconds(60))
        let second = try await stores.grants.grant(.menuBarLayout, chosen: file, home: home)

        #expect(second.grantedAt > first.grantedAt)
        #expect(await stores.grants.grant(for: .menuBarLayout) == second)
        await stores.settings.flush()
        #expect(await makeStores().settings.load(GrantsDocument.self).grants == [second], "one grant per kind")
    }

    // MARK: Keeping

    @Test func grantPersistsThroughStore() async throws {
        let file = try plant(contents: "kept")
        let first = makeStores()
        let granted = try await first.grants.grant(.menuBarLayout, chosen: file, home: home)
        await first.settings.flush()

        #expect(fileManager.fileExists(atPath: paths.settings.appending(path: "grants.json").path))
        // A new store, as after a relaunch.
        let second = makeStores()
        #expect(await second.grants.grant(for: .menuBarLayout) == granted)
        #expect(try await contents(through: second.grants) == "kept")
    }

    @Test func theGrantsAreWrittenAsAVersionOneDocument() async throws {
        let file = try plant()
        let stores = makeStores()
        _ = try await stores.grants.grant(.menuBarLayout, chosen: file, home: home)
        await stores.settings.flush()

        #expect(GrantsDocument.fileName == "grants.json")
        #expect(GrantsDocument.currentVersion == 1)
        let written = try Data(contentsOf: paths.settings.appending(path: "grants.json"))
        let header = try JSONDecoder().decode(EnvelopeHeader.self, from: written)
        #expect(header.version == 1)
        #expect(await stores.settings.isReadOnly(GrantsDocument.self) == false)
    }

    @Test func concurrentFirstUsesKeepEveryGrant() async throws {
        let layout = try plant(menuBarLayoutPath)
        let approvals = try plant(approvalsPath)
        let stores = makeStores()
        let home = home

        // Neither call finds the document loaded; the second to get its turn must not replace what the first made.
        async let one = stores.grants.grant(.menuBarLayout, chosen: layout, home: home)
        async let two = stores.grants.grant(.controlCenterApprovals, chosen: approvals, home: home)
        let granted = try await [one, two]
        await stores.settings.flush()

        let reloaded = await makeStores().settings.load(GrantsDocument.self)
        #expect(Set(reloaded.grants.map(\.kind)) == [.menuBarLayout, .controlCenterApprovals])
        #expect(reloaded.grants.count == 2)
        #expect(Set(reloaded.grants.map(\.bookmark)) == Set(granted.map(\.bookmark)))
    }

    @Test func overlappingGrantsBothSurvive() async throws {
        let layout = try plant(menuBarLayoutPath)
        let approvals = try plant(approvalsPath)
        let home = home

        // The store is handed each document in turn, and the first one is held: the store takes a long time over it.
        let handedOver = Mutex<[[FileGrantKind]]>([])
        let finished = Mutex(0)
        let firstHandedOver = Gate()
        let release = Gate()
        let settings = SettingsStore(paths: paths, clock: clock)
        let grants = FileGrantStore(store: settings, bookmarkOptions: [], clock: clock, makeBookmark: FileGrantStore.systemBookmark,
                                    saveDocument: { store, document in
            let isFirst = handedOver.withLock { handedOver -> Bool in
                handedOver.append(document.grants.map(\.kind))
                return handedOver.count == 1
            }
            if isFirst {
                firstHandedOver.open()
                await release.wait()
            }
            await store.save(document)
            finished.withLock { $0 += 1 }
        })

        let one = Task { try await grants.grant(.menuBarLayout, chosen: layout, home: home) }
        await firstHandedOver.wait()
        let two = Task { try await grants.grant(.controlCenterApprovals, chosen: approvals, home: home) }
        // Time for the second grant to reach the store, if nothing makes it wait for the first. It does wait: it can only be
        // handed over after the first has been, so this runs out its time (a real 0.3 s, for a negative that has to be seen; a
        // store that didn't chain its saves hands the second over within a millisecond or two).
        let deadline = ContinuousClock.now + .milliseconds(300)
        while finished.withLock({ $0 }) == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        release.open()
        _ = try await one.value
        _ = try await two.value
        await settings.flush()

        #expect(handedOver.withLock { $0 } == [[.menuBarLayout], [.menuBarLayout, .controlCenterApprovals]],
                "in the order of the changes: the second document has both grants")
        let reloaded = await makeStores().settings.load(GrantsDocument.self)
        #expect(Set(reloaded.grants.map(\.kind)) == [.menuBarLayout, .controlCenterApprovals], "both are there at the next launch")
        #expect(reloaded.grants.count == 2)
    }

    @Test func concurrentFirstUsesReadTheDocumentOnce() async throws {
        // A grant made and saved earlier, for the callers to find.
        let file = try plant()
        let earlier = makeStores()
        let granted = try await earlier.grants.grant(.menuBarLayout, chosen: file, home: home)
        await earlier.settings.flush()

        // A store whose read of the document is counted, and held until every caller is waiting for it.
        let callers = 6
        let reads = Mutex(0)
        let gate = Gate()
        let settings = SettingsStore(paths: paths, clock: clock)
        let grants = FileGrantStore(store: settings, bookmarkOptions: [], clock: clock, makeBookmark: FileGrantStore.systemBookmark) { store in
            reads.withLock { $0 += 1 }
            await gate.wait()
            return await FileGrantStore.systemLoader(store)
        }
        let results = Task {
            await withTaskGroup(of: FileGrant?.self) { group in
                for _ in 0..<callers {
                    group.addTask { await grants.grant(for: .menuBarLayout) }
                }
                return await group.reduce(into: []) { $0.append($1) }
            }
        }

        // Every caller has found the document not read and is waiting for it; the gate is still shut.
        while await grants.loadWaiters < callers {
            if Task.isCancelled { break }
            await Task.yield()
        }
        gate.open()
        let found = await results.value

        #expect(found.count == callers)
        #expect(found.allSatisfy { $0 == granted }, "each one got the document that was read")
        #expect(reads.withLock { $0 } == 1, "one read for \(callers) callers")
        #expect(await grants.loadWaiters == 0)

        // Once read, it isn't read again.
        _ = await grants.grant(for: .controlCenterApprovals)
        #expect(reads.withLock { $0 } == 1)
    }

    // MARK: Access

    @Test func withAccessGivesResolvedURL() async throws {
        let file = try plant(contents: "layout bytes")
        let stores = makeStores()
        _ = try await stores.grants.grant(.menuBarLayout, chosen: file, home: home)

        let seen = try await stores.grants.withAccess(.menuBarLayout) { url in
            (url, try String(contentsOf: url, encoding: .utf8))
        }

        #expect(realPath(seen.0) == realPath(file))
        #expect(seen.1 == "layout bytes")
    }

    @Test func withAccessReturnsWhatTheBodyReturns() async throws {
        let file = try plant(contents: "12345")
        let stores = makeStores()
        _ = try await stores.grants.grant(.menuBarLayout, chosen: file, home: home)

        let size = try await stores.grants.withAccess(.menuBarLayout) { try Data(contentsOf: $0).count }

        #expect(size == 5)
    }

    @Test func aFailureInTheBodyPassesThroughAndKeepsTheGrant() async throws {
        struct Refused: Error, Equatable {}
        let file = try plant()
        let stores = makeStores()
        let granted = try await stores.grants.grant(.menuBarLayout, chosen: file, home: home)

        await #expect(throws: Refused()) {
            try await stores.grants.withAccess(.menuBarLayout) { _ in throw Refused() }
        }
        #expect(await stores.grants.grant(for: .menuBarLayout) == granted, "the body failing isn't the grant failing")
    }

    @Test func withoutAGrantThereIsNothingToOpen() async {
        let stores = makeStores()
        let ran = Mutex(false)

        let failure: FileGrantError?
        do {
            try await stores.grants.withAccess(.menuBarLayout) { _ in ran.withLock { $0 = true } }
            failure = nil
        } catch {
            failure = error as? FileGrantError
        }

        #expect(failure == .stale(fileName: "com.apple.MenuBar.plist"))
        #expect(ran.withLock { $0 } == false)
    }

    @Test func revokeForgets() async throws {
        let layout = try plant(menuBarLayoutPath)
        let approvals = try plant(approvalsPath)
        let stores = makeStores()
        _ = try await stores.grants.grant(.menuBarLayout, chosen: layout, home: home)
        let kept = try await stores.grants.grant(.controlCenterApprovals, chosen: approvals, home: home)

        await stores.grants.revoke(.menuBarLayout)

        #expect(await stores.grants.grant(for: .menuBarLayout) == nil)
        #expect(await accessFailure(.menuBarLayout, in: stores.grants) == .stale(fileName: "com.apple.MenuBar.plist"))
        #expect(await stores.grants.grant(for: .controlCenterApprovals) == kept, "the other grant stays")
        #expect(fileManager.fileExists(atPath: layout.path), "the file itself is left alone")
        await stores.settings.flush()
        let reloaded = makeStores()
        #expect(await reloaded.grants.grant(for: .menuBarLayout) == nil, "forgotten for good")
        #expect(await reloaded.grants.grant(for: .controlCenterApprovals) == kept)
    }

    @Test func revokingWhatWasNeverGrantedDoesNothing() async {
        let stores = makeStores()
        await stores.grants.revoke(.controlCenterApprovals)
        #expect(await stores.grants.grant(for: .controlCenterApprovals) == nil)
    }

    // MARK: A file that changes after it was granted

    @Test func deletedFileMakesGrantStale() async throws {
        let file = try plant()
        let stores = makeStores()
        _ = try await stores.grants.grant(.menuBarLayout, chosen: file, home: home)
        try fileManager.removeItem(at: file)
        let ran = Mutex(false)

        let failure: FileGrantError?
        do {
            try await stores.grants.withAccess(.menuBarLayout) { _ in ran.withLock { $0 = true } }
            failure = nil
        } catch {
            failure = error as? FileGrantError
        }

        #expect(failure == .stale(fileName: "com.apple.MenuBar.plist"))
        #expect(ran.withLock { $0 } == false, "nothing runs on a file that isn't there")
        #expect(await stores.grants.grant(for: .menuBarLayout) == nil, "a stale grant is revoked")
        await stores.settings.flush()
        #expect(await makeStores().grants.grant(for: .menuBarLayout) == nil, "and stays revoked")
    }

    @Test func movedFileMakesGrantStale() async throws {
        // The bookmark follows a file that moves; the grant is for the file at its place, so it isn't followed.
        let file = try plant()
        let stores = makeStores()
        _ = try await stores.grants.grant(.menuBarLayout, chosen: file, home: home)
        let moved = home.appending(path: "Library/moved.plist")
        try fileManager.moveItem(at: file, to: moved)
        let ran = Mutex(false)

        let failure: FileGrantError?
        do {
            try await stores.grants.withAccess(.menuBarLayout) { _ in ran.withLock { $0 = true } }
            failure = nil
        } catch {
            failure = error as? FileGrantError
        }

        #expect(failure == .stale(fileName: "com.apple.MenuBar.plist"))
        #expect(ran.withLock { $0 } == false, "nothing runs on the file it moved to")
        #expect(await stores.grants.grant(for: .menuBarLayout) == nil)
    }

    @Test func aReplacedFileKeepsTheGrantAndRefreshesTheBookmark() async throws {
        // What the system does when it writes a preferences file: a new file takes the old one's place.
        let file = try plant(contents: "before")
        let stores = makeStores()
        let original = try await stores.grants.grant(.menuBarLayout, chosen: file, home: home)
        clock.advance(by: .seconds(60))
        let replacement = file.deletingLastPathComponent().appending(path: "written.tmp")
        try Data("after".utf8).write(to: replacement)
        _ = try fileManager.replaceItemAt(file, withItemAt: replacement)

        #expect(try await contents(through: stores.grants) == "after")

        let refreshed = try #require(await stores.grants.grant(for: .menuBarLayout))
        #expect(refreshed.bookmark != original.bookmark, "the stale bookmark was replaced")
        #expect(refreshed.kind == original.kind)
        #expect(refreshed.path == original.path)
        #expect(refreshed.grantedAt == original.grantedAt, "when it was granted doesn't change")
        var stale = false
        let resolved = try URL(resolvingBookmarkData: refreshed.bookmark, options: [.withoutUI], relativeTo: nil,
                               bookmarkDataIsStale: &stale)
        #expect(realPath(resolved) == realPath(file))
        #expect(!stale, "the new bookmark is current")

        // The refresh is kept for the next launch too.
        await stores.settings.flush()
        #expect(await makeStores().grants.grant(for: .menuBarLayout) == refreshed)
    }

    // MARK: Security scope

    @Test func theDefaultIsASecurityScopedBookmark() async throws {
        // `FileGrantStore(store:)` asks for a security scope. Whether an unsandboxed app gets one is measured on a real Mac;
        // either way (a scope, or the plain fallback) the grant has to work.
        let file = try plant(contents: "scoped")
        let settings = SettingsStore(paths: paths, clock: clock)
        let grants = FileGrantStore(store: settings)

        _ = try await grants.grant(.menuBarLayout, chosen: file, home: home)

        #expect(try await contents(through: grants) == "scoped")
    }

    @Test func aPlainBookmarkIsStillOpenedByAStoreThatPrefersASecurityScope() async throws {
        // A grant made while the scope wasn't available (or by a build that didn't ask for one) is read by a build
        // that does.
        let file = try plant(contents: "plain")
        let plain = makeStores(options: [])
        _ = try await plain.grants.grant(.menuBarLayout, chosen: file, home: home)
        await plain.settings.flush()

        let scoped = makeStores(options: [.withSecurityScope])

        #expect(try await contents(through: scoped.grants) == "plain")
    }

    @Test func aSecurityScopeThatCantBeMadeFallsBackToAPlainBookmark() async throws {
        let file = try plant(contents: "fallback")
        let attempts = Mutex<[URL.BookmarkCreationOptions]>([])
        let settings = SettingsStore(paths: paths, clock: clock)
        let grants = FileGrantStore(store: settings, bookmarkOptions: [.withSecurityScope], clock: clock) { url, options in
            attempts.withLock { $0.append(options) }
            if options.contains(.withSecurityScope) { throw CocoaError(.fileReadUnknown) }
            return try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
        }

        let granted = try await grants.grant(.menuBarLayout, chosen: file, home: home)

        #expect(attempts.withLock { $0 } == [[.withSecurityScope], []], "the scope first, then without it")
        #expect(!granted.bookmark.isEmpty)
        #expect(try await contents(through: grants) == "fallback")
    }

    @Test func aBookmarkThatCantBeMadeAtAllIsReported() async throws {
        let file = try plant()
        let settings = SettingsStore(paths: paths, clock: clock)
        let grants = FileGrantStore(store: settings, bookmarkOptions: [.withSecurityScope], clock: clock) { _, _ in
            throw CocoaError(.fileReadUnknown)
        }

        let failure = await grantFailure(choosing: file, in: grants)

        guard case .bookmarkFailed(let reason) = failure else {
            Issue.record("expected .bookmarkFailed, got \(String(describing: failure))")
            return
        }
        #expect(!reason.isEmpty)
        #expect(await grants.grant(for: .menuBarLayout) == nil)
    }
}
