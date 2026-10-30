import Foundation
import MKCore
import MKTestSupport
import Synchronization
import Testing

@testable import MKMenuBar

/// What the preferences service (`cfprefsd`) is made to say, in place of the real one, which a test must never reach for a
/// domain that isn't its own. The file is read for real, from the test's folder.
final class ScriptedService: Sendable {
    enum Answer: Sendable {
        /// Says what the file says, and writes the file (a service that is in step with it).
        case followsTheFile
        /// Says this about the key, whatever the file holds.
        case says(PlistValue?)
        /// The key holds something that isn't a property list type of Mantel's.
        case unrepresentable
        /// Says this until something is written through the service, and then what the file says: a cache that is ahead of the
        /// file, with the write that follows making them one.
        case saysUntilWritten(PlistValue?)
        /// Says this for the first `reads` reads through the service, and then what the file says: a write that reaches the
        /// file while it is being waited for.
        case saysForReads(Int, PlistValue?)
        /// A service that is ahead of the file: it keeps what is written through it, and says that; the file follows only when the
        /// test calls `flush(to:)`. What a group container's preferences do for a while after a write.
        case aheadOfTheFile
        /// A service that takes a write and doesn't keep it: what it says is what the file says, and a write changes neither. The
        /// next read of the key is the old value.
        case dropsWrites
    }

    private struct State {
        var answer: Answer
        var reads = 0
        var writes = 0
        /// What was written through the service and the file hasn't been given yet (`aheadOfTheFile`); a nil is a removal.
        var held: [String: PlistValue?] = [:]
    }

    private let state: Mutex<State>
    private let beforeWrite = Mutex<(@Sendable () -> Void)?>(nil)

    init(_ answer: Answer) {
        state = Mutex(State(answer: answer))
    }

    /// How many times anything was written through the service.
    var writeCount: Int { state.withLock { $0.writes } }
    /// How many times the service was asked for the key's value.
    var readCount: Int { state.withLock { $0.reads } }

    /// What runs at the start of every write, before anything is written: a test looks at what exists at that moment.
    func onWrite(_ body: (@Sendable () -> Void)?) { beforeWrite.withLock { $0 = body } }

    /// From now on the service says what the file says (a flush that has reached it).
    func follow() { state.withLock { $0.answer = .followsTheFile } }

    /// What the service holds is given to the file: the flush that was pending (`aheadOfTheFile`).
    func flush(to url: URL) throws {
        let held = state.withLock { $0.held }
        for (key, value) in held { try PlistIO.writeFile(value, key: key, to: url) }
    }

    /// Something other than Mantel changes the key through the service (`aheadOfTheFile`): the file doesn't have it yet either.
    func someoneElseWrites(_ value: PlistValue?, key: String) {
        state.withLock { _ = $0.held.updateValue(value, forKey: key) }
    }

    var io: PlistIO {
        var io = PlistIO.system
        io.read = { [self] url, key, strategy in
            guard strategy == .cfPreferences else { return try PlistIO.readFile(url, key: key) }
            let answer = state.withLock { state -> Answer in
                state.reads += 1
                if case .saysForReads(let reads, _) = state.answer, state.reads > reads { state.answer = .followsTheFile }
                return state.answer
            }
            switch answer {
            case .followsTheFile, .dropsWrites: return try PlistIO.readFile(url, key: key)
            case .says(let value), .saysUntilWritten(let value), .saysForReads(_, let value): return value
            case .unrepresentable: throw PlistAccessError.notRepresentable(key: key)
            case .aheadOfTheFile:
                if let held = state.withLock({ $0.held[key] }) { return held }
                return try PlistIO.readFile(url, key: key)
            }
        }
        io.write = { [self] value, key, url, _ in
            beforeWrite.withLock { $0 }?()
            // Where a write goes: to the file, into what the service holds until it is flushed, or nowhere.
            enum Landing { case file, held, nowhere }
            let landing = state.withLock { state -> Landing in
                state.writes += 1
                if case .saysUntilWritten = state.answer { state.answer = .followsTheFile }
                switch state.answer {
                case .dropsWrites:
                    return .nowhere
                case .aheadOfTheFile:
                    _ = state.held.updateValue(value, forKey: key)
                    return .held
                default:
                    return .file
                }
            }
            if landing == .file { try PlistIO.writeFile(value, key: key, to: url) }
        }
        return io
    }
}

/// A write is refused, with nothing journaled and nothing changed, when what Mantel would keep as the original may be wrong;
/// and the first write to a file is preceded by a byte-for-byte copy of it.
@Suite("Plist file access: doubtful originals and backups", .timeLimit(.minutes(1)))
struct PlistFileAccessSafetyTests {
    /// Held by the suite, and so for the whole test.
    let folder = TemporaryFolder(prefix: "mantel-plist-safety")
    let clock = FakeClock()

    private var paths: MantelPaths {
        MantelPaths(root: folder.url.appending(path: "Mantel", directoryHint: .isDirectory),
                    logs: folder.url.appending(path: "Logs", directoryHint: .isDirectory))
    }

    private var journalFile: URL { folder.url.appending(path: "journal.json") }
    private var plist: URL { folder.url.appending(path: "sample.plist") }

    private func makeJournal() -> Journal { Journal(file: journalFile, clock: clock) }

    private func makeAccess(_ journal: Journal, service: ScriptedService = ScriptedService(.followsTheFile)) -> PlistFileAccess {
        PlistFileAccess(journal: journal, paths: paths, grants: nil, io: service.io, clock: clock)
    }

    @discardableResult
    private func writePlist(_ dictionary: [String: Any], to url: URL? = nil) throws -> Data {
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        try data.write(to: url ?? plist)
        return data
    }

    private func backupFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: paths.backups.path)) ?? []).sorted()
    }

    // MARK: A doubtful original

    /// Each way the original may be wrong: what the file holds, what the service says, and the refusal that follows.
    enum DoubtfulOriginal: CaseIterable, CustomTestStringConvertible {
        case aServiceThatDisagreesWithTheFile
        /// The case that made the restore delete the person's key: the service gave nothing for a key the file holds, and "no value" was
        /// kept as the original.
        case aServiceThatSeesNothingWhereTheFileHasAValue
        case aServiceThatHasAValueWhereTheFileHasNone
        case aValueTheServiceCantRepresent
        /// An integer that doesn't fit in 64 bits is a property list value, but not one that can be put back.
        case aValueInTheFileThatCantBeRepresentedThroughTheService
        case aValueInTheFileThatCantBeRepresentedInTheFile

        var testDescription: String { String(describing: self) }

        var file: [String: Any] {
            switch self {
            case .aServiceThatDisagreesWithTheFile: ["alpha": 1, "keep": "me"]
            case .aServiceThatHasAValueWhereTheFileHasNone: ["keep": "me"]
            case .aValueInTheFileThatCantBeRepresentedThroughTheService, .aValueInTheFileThatCantBeRepresentedInTheFile:
                ["alpha": NSNumber(value: UInt64.max)]
            default: ["alpha": 1]
            }
        }

        var service: ScriptedService.Answer {
            switch self {
            case .aServiceThatDisagreesWithTheFile: .says(.integer(2))
            case .aServiceThatSeesNothingWhereTheFileHasAValue: .says(nil)
            case .aServiceThatHasAValueWhereTheFileHasNone: .says(.integer(1))
            case .aValueTheServiceCantRepresent: .unrepresentable
            case .aValueInTheFileThatCantBeRepresentedThroughTheService, .aValueInTheFileThatCantBeRepresentedInTheFile: .says(.integer(1))
            }
        }

        var strategy: PlistWriteStrategy {
            self == .aValueInTheFileThatCantBeRepresentedInTheFile ? .atomicFile : .cfPreferences
        }

        var refusal: PlistAccessError {
            switch self {
            case .aServiceThatDisagreesWithTheFile, .aServiceThatHasAValueWhereTheFileHasNone: .disagree(key: "alpha")
            case .aServiceThatSeesNothingWhereTheFileHasAValue: .serviceSeesNothing(key: "alpha")
            default: .notRepresentable(key: "alpha")
            }
        }
    }

    @Test(arguments: DoubtfulOriginal.allCases)
    func aDoubtfulOriginalRefusesAndNothingIsJournaledOrWritten(_ doubtful: DoubtfulOriginal) async throws {
        let before = try writePlist(doubtful.file)
        let journal = makeJournal()
        let service = ScriptedService(doubtful.service)
        let access = makeAccess(journal, service: service)

        await #expect(throws: doubtful.refusal) {
            try await access.write(.integer(9), key: "alpha", in: plist, strategy: doubtful.strategy)
        }

        #expect(await journal.records().isEmpty, "nothing was journaled")
        #expect(service.writeCount == 0, "nothing was written")
        #expect(try Data(contentsOf: plist) == before, "the file is as it was, byte for byte")
        #expect(backupFiles().isEmpty, "a write that is refused doesn't make a backup either")
    }

    @Test func aKeyAbsentFromBothIsWrittenAndRestoredToAbsent() async throws {
        try writePlist(["keep": "me"])
        let journal = makeJournal()
        let access = makeAccess(journal, service: ScriptedService(.followsTheFile))
        try await access.write(.integer(9), key: "alpha", in: plist, strategy: .cfPreferences)
        #expect(await journal.records().map(\.entry) == [
            .plistKey(filePath: CanonicalPath.of(plist), key: "alpha", original: nil, strategy: .cfPreferences),
        ])
    }

    @Test func theAtomicFileStrategyKeepsTheFilesOwnValueAndNeverAsksTheService() async throws {
        // Its original is the bytes on disk, which can't disagree with themselves; whatever the service says is not its business.
        try writePlist(["alpha": 1])
        let journal = makeJournal()
        let service = ScriptedService(.says(.integer(2)))
        let access = makeAccess(journal, service: service)

        try await access.write(.integer(9), key: "alpha", in: plist, strategy: .atomicFile)

        #expect(await journal.records().map(\.entry) == [
            .plistKey(filePath: CanonicalPath.of(plist), key: "alpha", original: .integer(1), strategy: .atomicFile),
        ])
    }

    @Test func theRefusalSaysWhatHappened() {
        #expect(PlistAccessError.disagree(key: "trackedApplications").errorDescription
                == "macOS's preferences service and the file disagree about this setting, so nothing was changed.")
        #expect(PlistAccessError.serviceSeesNothing(key: "trackedApplications").errorDescription
                == "macOS's preferences service reports no value for this setting, but the file has one, so nothing was changed.")
        // The key's name is for the log, not the person: no sentence that reaches Diagnostics names one.
        for error in [PlistAccessError.disagree(key: "trackedApplications"), .serviceSeesNothing(key: "trackedApplications"),
                      .notPersisted(key: "trackedApplications"), .notRepresentable(key: "trackedApplications")] {
            #expect(error.errorDescription?.contains("trackedApplications") == false)
            #expect(error.errorDescription?.contains("\"") == false)
        }
        #expect(PlistAccessError.backupFailed(file: "com.apple.MenuBar.plist", reason: "no room").errorDescription
                == "Mantel couldn't make a backup copy of com.apple.MenuBar.plist first, so nothing was changed: no room")
    }

    // MARK: The backup

    @Test func theFirstWriteToAFileCopiesItWholeAndLaterWritesDoNot() async throws {
        let original = try writePlist(["alpha": 1, "beta": ["x": 2], "keep": "me"])
        let journal = makeJournal()
        let access = makeAccess(journal)

        try await access.write(.integer(2), key: "alpha", in: plist, strategy: .atomicFile)
        try await access.write(.integer(3), key: "alpha", in: plist, strategy: .cfPreferences)
        try await access.write(.integer(4), key: "beta", in: plist, strategy: .atomicFile)

        let expected = "sample-\(BackupPruner.stamp(for: clock.now())).plist"
        #expect(backupFiles() == [expected], "one copy, in the Backups folder, named for the file and the time")
        #expect(try Data(contentsOf: paths.backups.appending(path: expected)) == original, "byte for byte, as the file was before the first write")
        #expect(try Data(contentsOf: plist) != original, "and the file itself has been changed since")
    }

    @Test func theBackupIsNamedForTheFileAndThePrivateToTheOwner() async throws {
        try writePlist(["alpha": 1])
        let access = makeAccess(makeJournal())
        try await access.write(.integer(2), key: "alpha", in: plist, strategy: .atomicFile)

        let name = try #require(backupFiles().first)
        #expect(name.wholeMatch(of: #/sample-\d{8}-\d{6}Z\.plist/#) != nil)
        let attributes = try FileManager.default.attributesOfItem(atPath: paths.backups.appending(path: name).path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
    }

    @Test func eachFileHasItsOwnBackup() async throws {
        let one = try writePlist(["alpha": 1])
        let otherURL = folder.url.appending(path: "other.plist")
        let two = try writePlist(["beta": 2], to: otherURL)
        let access = makeAccess(makeJournal())

        try await access.write(.integer(5), key: "alpha", in: plist, strategy: .atomicFile)
        try await access.write(.integer(6), key: "beta", in: otherURL, strategy: .atomicFile)
        try await access.write(.integer(7), key: "alpha", in: plist, strategy: .atomicFile)

        let stamp = BackupPruner.stamp(for: clock.now())
        #expect(backupFiles() == ["other-\(stamp).plist", "sample-\(stamp).plist"])
        #expect(try Data(contentsOf: paths.backups.appending(path: "sample-\(stamp).plist")) == one)
        #expect(try Data(contentsOf: paths.backups.appending(path: "other-\(stamp).plist")) == two)
    }

    @Test func theSameFileThroughALinkIsBackedUpOnce() async throws {
        let original = try writePlist(["alpha": 1])
        let link = folder.url.appending(path: "link.plist")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: plist)
        let access = makeAccess(makeJournal())

        try await access.write(.integer(2), key: "alpha", in: plist, strategy: .atomicFile)
        try await access.write(.integer(3), key: "alpha", in: link, strategy: .atomicFile)

        #expect(backupFiles().count == 1)
        #expect(try Data(contentsOf: paths.backups.appending(path: try #require(backupFiles().first))) == original)
    }

    @Test func aBackupThatCantBeMadeRefusesTheWriteAndNothingIsJournaled() async throws {
        let before = try writePlist(["alpha": 1])
        // Where the Backups folder should be, there is a file, so nothing can be kept in it.
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try Data("in the way".utf8).write(to: paths.backups)
        let journal = makeJournal()
        let access = makeAccess(journal)

        do {
            try await access.write(.integer(2), key: "alpha", in: plist, strategy: .atomicFile)
            Issue.record("the write should have been refused")
        } catch let error as PlistAccessError {
            guard case .backupFailed(let file, _) = error else {
                Issue.record("expected the backup to be what failed, got \(error)")
                return
            }
            #expect(file == "sample.plist")
        }

        #expect(await journal.records().isEmpty, "nothing was journaled")
        #expect(try Data(contentsOf: plist) == before, "nothing was changed")
    }

    @Test func aFailedBackupIsTriedAgainAtTheNextWrite() async throws {
        let original = try writePlist(["alpha": 1])
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try Data("in the way".utf8).write(to: paths.backups)
        let access = makeAccess(makeJournal())
        await #expect(throws: (any Error).self) {
            try await access.write(.integer(2), key: "alpha", in: plist, strategy: .atomicFile)
        }

        // The obstacle is gone: the file is still as it was, and now it is backed up and written.
        try FileManager.default.removeItem(at: paths.backups)
        try await access.write(.integer(2), key: "alpha", in: plist, strategy: .atomicFile)

        let name = try #require(backupFiles().first)
        #expect(try Data(contentsOf: paths.backups.appending(path: name)) == original)
        #expect(try PlistIO.readFile(plist, key: "alpha") == .integer(2))
    }

    @Test func aFileThatIsNotThereHasNothingToBackUp() async throws {
        let access = makeAccess(makeJournal())
        try await access.write(.integer(1), key: "alpha", in: plist, strategy: .atomicFile)
        #expect(backupFiles().isEmpty)
        #expect(try PlistIO.readFile(plist, key: "alpha") == .integer(1))
    }

    @Test func undoAndReplayMakeNoBackupOfTheirOwn() async throws {
        try writePlist(["alpha": 1])
        let journal = makeJournal()
        let access = makeAccess(journal)
        try await access.write(.integer(2), key: "alpha", in: plist, strategy: .atomicFile)
        let first = backupFiles()

        try await access.undo(key: "alpha", in: plist)
        #expect(backupFiles() == first)
    }
}
