import Foundation

/// Keeps the grants of the two protected files, one bookmark of each in `grants.json`, and opens a file for as long as its
/// caller needs it.
///
/// - **Granting** is the person choosing the file in an open panel (which the app shows; this type only checks the
///   choice and keeps it). The choice is accepted only if it is the file Mantel needs, see `ExpectedFile`.
/// - **Opening** resolves the bookmark and hands the URL to a closure, with access to it started and stopped around the
///   closure. The system may replace a preferences file when it writes it, which leaves a bookmark stale but still
///   pointing at the file; such a bookmark is made anew. A file that is gone or has moved is no longer the one that was
///   granted: the grant is removed and the caller is told, with `.stale`.
/// - **Security scope.** Whether a security-scoped bookmark of these containers works for an app that isn't sandboxed,
///   and survives a relaunch, is measured on the real machine, which is why the options are given
///   to `init`. If the system won't make a security-scoped bookmark, a plain one is made (and logged).
///
/// `grants.json` is read once, at first use. As with every settings document, it is saved a moment after the change
/// (`SettingsStore.flush` writes it at once). Each change is handed to the store after the one before it, so that the store
/// always ends up with the last change, which has all the others in it.
public actor FileGrantStore {
    typealias BookmarkMaker = @Sendable (URL, URL.BookmarkCreationOptions) throws -> Data
    typealias DocumentLoader = @Sendable (SettingsStore) async -> GrantsDocument
    typealias DocumentSaver = @Sendable (SettingsStore, GrantsDocument) async -> Void

    /// How a bookmark is made, and how the document is read, unless a test gives its own.
    static let systemBookmark: BookmarkMaker = { url, options in
        try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    static let systemLoader: DocumentLoader = { store in
        await store.load(GrantsDocument.self)
    }
    static let systemSaver: DocumentSaver = { store, document in
        await store.save(document)
    }

    private let store: SettingsStore
    private let bookmarkOptions: URL.BookmarkCreationOptions
    private let clock: any Clock
    private let makeBookmark: BookmarkMaker
    private let loadDocument: DocumentLoader
    private let saveDocument: DocumentSaver
    /// Nil until the first use has read it.
    private var document: GrantsDocument?
    /// The read of the document that is under way, for every call that finds the document not yet read to wait for.
    private var loading: Task<GrantsDocument, Never>?
    /// The last save handed to the store. Each save waits for the one before it, so that they reach the store in the order of
    /// the changes, however long one of them takes.
    private var lastSave: Task<Void, Never>?
    /// How many calls are waiting for that read. For tests.
    private(set) var loadWaiters = 0
    /// Which renewals of a stale bookmark have been said in the log (`GrantRenewalLogging`).
    private var renewalLogging = GrantRenewalLogging()

    /// `bookmarkOptions` are the options for the bookmarks it makes. The tests give `[]`, a plain bookmark, which doesn't
    /// depend on what the system lets an unsandboxed app scope.
    public init(store: SettingsStore,
                bookmarkOptions: URL.BookmarkCreationOptions = [.withSecurityScope],
                clock: any Clock = SystemClock()) {
        self.init(store: store, bookmarkOptions: bookmarkOptions, clock: clock, makeBookmark: Self.systemBookmark)
    }

    /// As the public one, with the way a bookmark is made, the way the document is read and the way it is saved given: a test
    /// makes a bookmark fail, counts the reads, or holds a save.
    init(store: SettingsStore,
         bookmarkOptions: URL.BookmarkCreationOptions = [.withSecurityScope],
         clock: any Clock = SystemClock(),
         makeBookmark: @escaping BookmarkMaker,
         loadDocument: @escaping DocumentLoader = FileGrantStore.systemLoader,
         saveDocument: @escaping DocumentSaver = FileGrantStore.systemSaver) {
        self.store = store
        self.bookmarkOptions = bookmarkOptions
        self.clock = clock
        self.makeBookmark = makeBookmark
        self.loadDocument = loadDocument
        self.saveDocument = saveDocument
    }

    // MARK: Granting

    /// Keeps `url`, which the person chose for `kind`, if it is the file Mantel needs, and replaces the grant it had.
    /// - Throws: `.wrongFile` for any other file, `.bookmarkFailed` if the system can't bookmark it.
    public func grant(_ kind: FileGrantKind, chosen url: URL, home: URL) async throws -> FileGrant {
        let expected = ExpectedFile.expected(kind, home: home)
        guard expected.matches(url) else {
            throw FileGrantError.wrongFile(expected: expected.fileName, got: url.lastPathComponent)
        }

        let bookmark: Data
        let resolved: URL
        do {
            // The choice carries the open panel's access to the file; the bookmark is made while it is on.
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            bookmark = try bookmarkData(of: url)
            // Resolving it straight away shows that it can be used, and where it leads.
            resolved = try resolve(bookmark).url
        } catch {
            Log.error("grants", "\(kind.rawValue) couldn't be bookmarked: \(Self.describe(error))")
            throw FileGrantError.bookmarkFailed(error.localizedDescription)
        }

        let grant = FileGrant(kind: kind, bookmark: bookmark, path: resolved.path(percentEncoded: false),
                              grantedAt: clock.now())
        await update { document in
            document.grants.removeAll { $0.kind == kind }
            document.grants.append(grant)
        }
        renewalLogging.startOver(kind)
        Log.info("grants", "\(kind.rawValue) granted")
        return grant
    }

    // MARK: Using

    /// Runs `body` with the URL of the granted file, for as long as `body` runs. `body` runs on this store, which serves no
    /// other call meanwhile: it is for reading or writing the file, not for anything long.
    ///
    /// - Throws: `.stale` if there is no grant, or the file is gone or has moved (the grant is then removed, and `body`
    ///   doesn't run); otherwise whatever `body` throws.
    public func withAccess<T: Sendable>(_ kind: FileGrantKind, _ body: (URL) throws -> T) async throws -> T {
        guard let grant = await grant(for: kind) else { throw FileGrantError.stale(fileName: kind.fileName) }

        let resolved: (url: URL, isStale: Bool)
        do {
            resolved = try resolve(grant.bookmark)
        } catch {
            Log.warning("grants", "\(kind.rawValue) can't be opened any more (\(Self.describe(error))); the grant is removed")
            await revoke(kind)
            throw FileGrantError.stale(fileName: kind.fileName)
        }
        // A bookmark follows a file that moves. The grant is for the file where it was granted.
        guard CanonicalPath.of(resolved.url) == CanonicalPath.of(URL(filePath: grant.path)) else {
            Log.warning("grants", "\(kind.rawValue) has moved; the grant is removed")
            await revoke(kind)
            throw FileGrantError.stale(fileName: kind.fileName)
        }

        let url = resolved.url
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        if resolved.isStale {
            await refresh(grant, from: url)
        }
        return try body(url)
    }

    /// Makes the bookmark of a file again, which the system calls stale when the file was replaced under the same name.
    /// If that fails, the old bookmark stays: it still resolves, which is why this was reached.
    private func refresh(_ old: FileGrant, from url: URL) async {
        let fresh: Data
        do {
            fresh = try bookmarkData(of: url)
        } catch {
            // Every failure is said: it is not the routine one.
            if renewalLogging.shouldLog(.couldNotRenew, for: old.kind) {
                Log.warning("grants", "\(old.kind.rawValue) has a stale bookmark that couldn't be renewed (\(Self.describe(error)))")
            }
            return
        }
        await update { document in
            // Only if nobody has granted or revoked it in the meantime.
            guard let index = document.grants.firstIndex(where: { $0.kind == old.kind && $0.bookmark == old.bookmark }) else { return }
            document.grants[index] = FileGrant(kind: old.kind, bookmark: fresh, path: old.path, grantedAt: old.grantedAt)
        }
        // macOS rewrites its files again and again: once for each grant, for as long as Mantel runs.
        if renewalLogging.shouldLog(.renewed, for: old.kind) {
            Log.info("grants", "\(old.kind.rawValue) had a stale bookmark; it was renewed")
        }
    }

    // MARK: Keeping

    /// Forgets the grant of `kind`, if there is one. The file itself is left alone.
    public func revoke(_ kind: FileGrantKind) async {
        guard await grant(for: kind) != nil else { return }
        await update { $0.grants.removeAll { $0.kind == kind } }
        renewalLogging.startOver(kind)
        Log.info("grants", "\(kind.rawValue) revoked")
    }

    /// The grant of `kind`, or nil. It says nothing of whether the file is still there; `withAccess` finds that out.
    public func grant(for kind: FileGrantKind) async -> FileGrant? {
        await loadedDocument().grants.first { $0.kind == kind }
    }

    /// The document, read once: by the first call that finds it not read, which every call that comes while the read is
    /// under way waits for, instead of reading it again. The first of them to go on makes what was read the document;
    /// the others find that document, which may have been changed already, and take it.
    private func loadedDocument() async -> GrantsDocument {
        if let document { return document }
        let reading: Task<GrantsDocument, Never>
        if let loading {
            reading = loading
        } else {
            reading = Task { [store, loadDocument] in await loadDocument(store) }
            loading = reading
        }
        loadWaiters += 1
        let loaded = await reading.value
        loadWaiters -= 1
        if let document { return document }
        document = loaded
        loading = nil
        return loaded
    }

    /// Changes the document and hands it to the store to save. The change and the new state happen without a wait in
    /// between, so a call that overlaps this one sees the document before or after the change, not a half of it; and the save
    /// is chained after the one before in the same step, so the store is given the documents in the order they were made. (A
    /// save that overtook the one before it would leave the store with the older document, and the newer grant lost at the next
    /// launch.) Returns when the store has been given this document.
    private func update(_ change: (inout GrantsDocument) -> Void) async {
        var changed = await loadedDocument()
        change(&changed)
        document = changed
        let saved = changed
        let previous = lastSave
        let save = Task { [store, saveDocument] in
            await previous?.value
            await saveDocument(store, saved)
        }
        lastSave = save
        await save.value
    }

    // MARK: Bookmarks

    /// A bookmark of `url` with the options asked for, or, if the system won't make a security-scoped one, a plain one.
    private func bookmarkData(of url: URL) throws -> Data {
        do {
            return try makeBookmark(url, bookmarkOptions)
        } catch where bookmarkOptions.contains(.withSecurityScope) {
            Log.warning("grants", "security scope unavailable (\(Self.describe(error))); making a plain bookmark")
            return try makeBookmark(url, bookmarkOptions.subtracting(.withSecurityScope))
        }
    }

    /// The URL a bookmark leads to, with whether the system calls the bookmark stale. If a security scope is preferred it
    /// is tried first; a plain bookmark, which can't be resolved as a scoped one, is resolved without (the failure of the
    /// scoped resolve is logged, by its domain and code: it tells whether a security-scoped bookmark of these files works). Never shows a dialog or mounts a volume.
    private func resolve(_ bookmark: Data) throws -> (url: URL, isStale: Bool) {
        if bookmarkOptions.contains(.withSecurityScope) {
            do {
                return try Self.resolve(bookmark, with: [.withSecurityScope, .withoutUI, .withoutMounting])
            } catch {
                Log.warning("grants", "security-scoped resolve failed (\(Self.describe(error))); trying a plain resolve")
            }
        }
        return try Self.resolve(bookmark, with: [.withoutUI, .withoutMounting])
    }

    private static func resolve(_ bookmark: Data, with options: URL.BookmarkResolutionOptions) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: options, relativeTo: nil, bookmarkDataIsStale: &isStale)
        return (url, isStale)
    }

    /// An error for the log: its domain and code, never its text, which can hold a path.
    private static func describe(_ error: any Error) -> String {
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }
}
