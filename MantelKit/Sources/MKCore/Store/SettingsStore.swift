import Foundation

/// Loads and saves the settings documents, each in a file of its own in `MantelPaths.settings`.
///
/// - A file that can't be trusted is never thrown away or overwritten in silence. A corrupt or empty one is moved to
///   `Backups/corrupt-<name>-<timestamp>.json` and the defaults load; one written by a newer Mantel loads read-only and
///   is left as it is; an older one is copied to `Backups` and migrated (read-only if the copy can't be made).
/// - Those copies are kept in small numbers: of the copies of one old version of a file, the oldest and the four newest; of
///   the files set aside as corrupt, the five newest.
/// - A document can only be saved once it has been `load`ed by this store: saving defaults over a file nobody has read would
///   lose what is in it.
/// - A file migrated by a load is migrated once: until a save replaces the old file, later loads answer with the migrated
///   document, and the copy in `Backups` is made once.
/// - `save` is debounced, per document: a burst of saves (a slider being dragged) is one write, `debounce` after the last.
/// - `flush` writes what is still waiting, for `applicationWillTerminate`.
public actor SettingsStore {
    private struct PendingWrite {
        let data: Data
        /// Which save this is, so that a wait that was overtaken by a newer save does nothing when it ends.
        let generation: Int
    }

    private let paths: MantelPaths
    private let clock: any Clock
    private let debounce: Duration
    private let decoder = JSONCoding.decoder()
    private let encoder = JSONCoding.encoder()

    /// By file name: documents saved and not yet written.
    private var pending: [String: PendingWrite] = [:]
    /// By file name: the task that waits out the debounce of the pending write.
    private var timers: [String: Task<Void, Never>] = [:]
    private var generation = 0
    /// By file name: the documents that must not be written, each with why, ending the log line "<name> <reason>". One was
    /// written by a newer Mantel; for the others the file on disk is the only copy of what it holds.
    private var readOnlyFiles: [String: String] = [:]
    private var warnedAboutReadOnly: Set<String> = []
    /// By file name: a file that has been migrated and not saved yet, as the old file's bytes and the migrated document (as the
    /// file of the current version would hold it). The file on disk still says the old version until a save, so a second load
    /// of the same bytes answers from here instead of migrating, and backing up, the old file again.
    private var migrated: [String: (source: Data, envelope: Data)] = [:]
    /// The names of the documents this store has loaded: only those can be saved.
    private var loadedFiles: Set<String> = []

    /// How many files have been written. For tests.
    private(set) var writeCount = 0

    public init(paths: MantelPaths, clock: any Clock = SystemClock(), debounce: Duration = .milliseconds(500)) {
        self.paths = paths
        self.clock = clock
        self.debounce = debounce
    }

    // MARK: Loading

    /// The document in its file, or the defaults. Never throws: whatever is wrong with the file is logged and handled as
    /// described on the type, and the caller always gets a document it can use.
    public func load<D: SettingsDocument>(_ type: D.Type) -> D {
        let name = D.fileName
        loadedFiles.insert(name)

        // Saved a moment ago and not written yet: that is the document, not what the file still says.
        if let waiting = pending[name], let envelope = try? decoder.decode(Envelope<D>.self, from: waiting.data) {
            return envelope.document
        }

        let url = paths.settings.appending(path: name, directoryHint: .notDirectory)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return D() }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return setAside(url, because: "couldn't be read (\(error.localizedDescription))")
        }

        // Migrated a moment ago and not saved yet: that is the document, as long as the file is still the one it came from.
        if let kept = migrated[name], kept.source == data, let envelope = try? decoder.decode(Envelope<D>.self, from: kept.envelope) {
            return envelope.document
        }

        let version: Int
        do {
            version = try decoder.decode(EnvelopeHeader.self, from: data).version
        } catch {
            return setAside(url, because: data.isEmpty ? "was empty" : "isn't a settings file (\(describe(error)))")
        }

        if version == D.currentVersion {
            do {
                return try decoder.decode(Envelope<D>.self, from: data).document
            } catch {
                return setAside(url, because: "couldn't be decoded (\(describe(error)))")
            }
        }
        if version > D.currentVersion {
            return loadNewer(D.self, from: data, version: version)
        }
        return migrate(D.self, from: data, version: version, url: url)
    }

    /// A file written by a newer Mantel: read as far as this version can, and never written, so that going back to the
    /// newer Mantel finds everything it saved.
    private func loadNewer<D: SettingsDocument>(_ type: D.Type, from data: Data, version: Int) -> D {
        let name = D.fileName
        readOnlyFiles[name] = "was written by a newer Mantel; changes aren't saved"
        let envelope = try? decoder.decode(Envelope<D>.self, from: data)
        if envelope != nil {
            Log.warning("settings", "\(name) was written by a newer Mantel (version \(version), this one reads \(D.currentVersion)); it is read but changes aren't saved")
        } else {
            Log.error("settings", "\(name) was written by a newer Mantel (version \(version), this one reads \(D.currentVersion)) in a shape this one can't read; the defaults are used and the file is left alone")
        }
        return envelope?.document ?? D()
    }

    /// A file written by an older Mantel: brought up to date by `D.migrate` and kept in `Backups` as it was. The file
    /// itself is rewritten by the next `save`, which is why the document turns read-only if the copy can't be made: the
    /// old file must not be replaced without a copy of it somewhere.
    private func migrate<D: SettingsDocument>(_ type: D.Type, from data: Data, version: Int, url: URL) -> D {
        let name = D.fileName
        let document: D
        do throws(SettingsMigrationError) {
            document = try migratedDocument(D.self, from: data, version: version)
        } catch {
            return setAside(url, because: "couldn't be migrated from version \(version)", migrationFailure: error)
        }

        do {
            try keep(url, as: "\(name)-v\(version)-\(BackupPruner.stamp(for: clock.now()))", moving: false)
            prune(stem: "\(name)-v\(version)", keepOldest: 1, keepNewest: 4)
            Log.info("settings", "\(name) was migrated from version \(version) to \(D.currentVersion); the old file is in Backups")
        } catch {
            // The old file is the only copy of what it holds, and a save would replace it with the new shape.
            readOnlyFiles[name] = "couldn't be backed up before its migration; changes aren't saved"
            Log.error("settings", "\(name) was migrated from version \(version) but a copy of the old file couldn't be made (\(error.localizedDescription)); the file is left alone and changes aren't saved")
        }
        if let envelope = try? encoder.encode(Envelope(version: D.currentVersion, document: document)) {
            migrated[name] = (source: data, envelope: envelope)
        }
        return document
    }

    /// The document of a file written as an older `version`, brought up to date by `D.migrate` and decoded.
    private func migratedDocument<D: SettingsDocument>(_ type: D.Type, from data: Data, version: Int) throws(SettingsMigrationError) -> D {
        let name = D.fileName
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tree = root["document"] as? JSONValueTree
        else {
            throw .failed(file: name, reason: "there is no document in it")
        }
        let migrated: JSONValueTree
        do {
            migrated = try D.migrate(tree, from: version)
        } catch let error as SettingsMigrationError {
            throw error
        } catch {
            throw .failed(file: name, reason: describe(error))
        }
        guard JSONSerialization.isValidJSONObject(migrated) else {
            throw .failed(file: name, reason: "the result isn't JSON")
        }
        do {
            return try decoder.decode(D.self, from: JSONSerialization.data(withJSONObject: migrated))
        } catch {
            throw .failed(file: name, reason: describe(error))
        }
    }

    /// Moves a file that can't be used to `Backups/corrupt-<name>-<timestamp>.json` and returns the defaults. If it can't
    /// be moved, it stays where it is and the document turns read-only, so that it isn't overwritten. A file that failed to
    /// migrate says why, in the words of `SettingsMigrationError`.
    private func setAside<D: SettingsDocument>(_ url: URL, because reason: String, migrationFailure: SettingsMigrationError? = nil) -> D {
        let name = D.fileName
        let stem = url.deletingPathExtension().lastPathComponent
        do {
            let kept = try keep(url, as: "corrupt-\(stem)-\(BackupPruner.stamp(for: clock.now()))", moving: true)
            prune(stem: "corrupt-\(stem)", keepOldest: 0, keepNewest: 5)
            if let migrationFailure {
                Log.error("settings", "\(migrationFailure.localizedDescription) It is Backups/\(kept.lastPathComponent).")
            } else {
                Log.error("settings", "\(name) \(reason); it was moved to Backups/\(kept.lastPathComponent) and the defaults are used")
            }
        } catch {
            readOnlyFiles[name] = "couldn't be moved aside; changes aren't saved"
            Log.error("settings", "\(name) \(reason), and it couldn't be moved aside (\(error.localizedDescription)); the defaults are used and the file is left alone")
        }
        return D()
    }

    /// Puts a file in `Backups` under `<base>.json` (or the first free name like it), mode 0600, by moving it or copying.
    @discardableResult
    private func keep(_ url: URL, as base: String, moving: Bool) throws -> URL {
        let fileManager = FileManager.default
        try AtomicFile.ensureFolder(paths.backups)
        let destination = AtomicFile.unusedURL(in: paths.backups, base: base, pathExtension: "json")
        if moving {
            try fileManager.moveItem(at: url, to: destination)
        } else {
            try fileManager.copyItem(at: url, to: destination)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path(percentEncoded: false))
        return destination
    }

    /// Clears out the old copies of one kind in `Backups`. A failure to is logged and nothing more: the copies are only a
    /// convenience, and what is being done matters more.
    private func prune(stem: String, keepOldest: Int, keepNewest: Int) {
        do {
            try BackupPruner.prune(in: paths.backups, stem: stem, pathExtension: "json", keepOldest: keepOldest, keepNewest: keepNewest)
        } catch {
            Log.warning("settings", "old copies in Backups couldn't be cleared out: \(error.localizedDescription)")
        }
    }

    // MARK: Saving

    /// Keeps `document` to be written to its file `debounce` after the last save of it. Saving a document that loaded
    /// read-only does nothing, and nor does saving one that this store hasn't loaded: the file may hold what the defaults
    /// would replace.
    public func save<D: SettingsDocument>(_ document: D) {
        let name = D.fileName
        guard loadedFiles.contains(name) else {
            Log.warning("settings", "\(name) wasn't read before this save, so it isn't saved")
            return
        }
        if let reason = readOnlyFiles[name] {
            if warnedAboutReadOnly.insert(name).inserted {
                Log.warning("settings", "\(name) \(reason)")
            }
            return
        }
        let data: Data
        do {
            data = try encoder.encode(Envelope(version: D.currentVersion, document: document))
        } catch {
            Log.error("settings", "\(name) couldn't be encoded and isn't saved: \(describe(error))")
            return
        }

        // From here the saved document is the one that loads, and the file is rewritten by it.
        migrated[name] = nil
        generation += 1
        let thisSave = generation
        pending[name] = PendingWrite(data: data, generation: thisSave)
        // Each save starts the wait over; the wait that this one replaces is cancelled.
        timers[name]?.cancel()
        timers[name] = Task { [clock, debounce] in
            do {
                try await clock.sleep(for: debounce)
            } catch {
                return
            }
            self.debounceEnded(for: name, save: thisSave)
        }
    }

    private func debounceEnded(for name: String, save: Int) {
        // A newer save has its own wait, and a flush has already written this one.
        guard pending[name]?.generation == save else { return }
        timers[name] = nil
        write(name)
    }

    /// Writes everything that is waiting now, without waiting for the debounce. The app calls it from
    /// `applicationWillTerminate`, which can wait for a second at most; writing a few small files takes milliseconds.
    public func flush() async {
        for name in pending.keys.sorted() {
            timers.removeValue(forKey: name)?.cancel()
            write(name)
        }
    }

    /// Writes the pending document `name`. A write that fails stays pending: the next `flush` tries again.
    private func write(_ name: String) {
        guard let waiting = pending[name] else { return }
        do {
            try AtomicFile.ensureFolder(paths.settings)
            try AtomicFile.write(waiting.data, to: paths.settings.appending(path: name, directoryHint: .notDirectory))
            pending[name] = nil
            writeCount += 1
        } catch {
            Log.error("settings", "\(name) couldn't be saved: \(error.localizedDescription)")
        }
    }

    // MARK: State

    /// Whether the document loaded as read-only, so that saving it does nothing.
    public func isReadOnly<D: SettingsDocument>(_ type: D.Type) -> Bool {
        readOnlyFiles[D.fileName] != nil
    }

    /// Returns when every debounce wait that is running has ended, either written or cancelled. For tests, which move
    /// a `FakeClock` past the debounce and then wait for the write it causes.
    func waitForDebounceTimers() async {
        for timer in Array(timers.values) {
            await timer.value
        }
    }

    /// As `waitForDebounceTimers`, for the wait of one document.
    func waitForDebounceTimer<D: SettingsDocument>(for type: D.Type) async {
        await timers[D.fileName]?.value
    }

    /// A short description of an error for the log: what it says about the file's shape, never the file's contents.
    private func describe(_ error: any Error) -> String {
        switch error {
        case let error as DecodingError:
            switch error {
            case .keyNotFound(let key, _): "no value for \"\(key.stringValue)\""
            case .typeMismatch(_, let context), .valueNotFound(_, let context):
                "wrong type at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
            case .dataCorrupted: "not valid JSON, or a value that can't be read"
            @unknown default: "can't be decoded"
            }
        default:
            error.localizedDescription
        }
    }
}
