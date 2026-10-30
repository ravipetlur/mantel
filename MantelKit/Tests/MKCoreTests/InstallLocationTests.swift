import Foundation
import MKTestSupport
import Testing

@testable import MKCore

@Suite("InstallLocation", .timeLimit(.minutes(2)))
struct InstallLocationTests {
    private let home = URL(filePath: "/Users/x", directoryHint: .isDirectory)

    private func verdict(_ path: String, directory: Bool = true) -> InstallLocation.Verdict {
        InstallLocation.verdict(for: URL(filePath: path, directoryHint: directory ? .isDirectory : .notDirectory), home: home)
    }

    @Test func applicationsFolder() {
        #expect(verdict("/Applications/Mantel.app") == .applications)
    }

    @Test func aBundleURLWithoutATrailingSlashIsTheSame() {
        // `Bundle.main.bundleURL` ends in a slash; a URL made from a path may not.
        #expect(verdict("/Applications/Mantel.app", directory: false) == .applications)
    }

    @Test func userApplicationsFolder() {
        #expect(verdict("/Users/x/Applications/Mantel.app") == .userApplications)
    }

    @Test func userApplicationsOfTheCurrentUser() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications/Mantel.app")
        #expect(InstallLocation.verdict(for: url) == .userApplications)
    }

    @Test func aTranslocatedCopyIsTranslocated() {
        let path = "/private/var/folders/zz/abc123def456/T/AppTranslocation/6B2F0C1E-1111-2222-3333-444455556666/d/Mantel.app"
        #expect(verdict(path) == .translocated)
    }

    @Test func downloadsIsElsewhere() {
        #expect(verdict("/Users/x/Downloads/Mantel.app") == .elsewhere("/Users/x/Downloads"))
    }

    @Test func aFolderInsideApplicationsIsElsewhere() {
        // The hiding method wants the app in /Applications itself.
        #expect(verdict("/Applications/Utilities/Mantel.app") == .elsewhere("/Applications/Utilities"))
    }

    @Test func anotherUsersApplicationsIsElsewhere() {
        #expect(verdict("/Users/y/Applications/Mantel.app") == .elsewhere("/Users/y/Applications"))
    }

    @Test func lookAlikeFoldersAreElsewhere() {
        #expect(verdict("/Applications Old/Mantel.app") == .elsewhere("/Applications Old"))
        #expect(verdict("/Users/x/Applications-old/Mantel.app") == .elsewhere("/Users/x/Applications-old"))
    }

    @Test func dotDotIsResolvedBeforeLooking() {
        #expect(verdict("/Applications/../Users/x/Downloads/Mantel.app") == .elsewhere("/Users/x/Downloads"))
        #expect(verdict("/Users/x/Downloads/../../../Applications/Mantel.app") == .applications)
    }

    // MARK: Links

    @Test func aFolderThatIsALinkToApplicationsIsApplications() throws {
        let folder = TemporaryFolder.shortForSockets()
        // Nothing else reads the folder after the files are made: held until the test is over, the files are there to be used.
        defer { withExtendedLifetime(folder) {} }
        let link = folder.url.appending(path: "Apps", directoryHint: .notDirectory)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(filePath: "/Applications", directoryHint: .isDirectory))
        let bundle = link.appending(path: "Mantel.app", directoryHint: .isDirectory)
        #expect(InstallLocation.verdict(for: bundle, home: home) == .applications)
    }

    @Test func aBundleThatIsALinkIsJudgedByWhereItLeads() throws {
        // `~/Applications/Mantel.app` that is only a link to a build folder isn't the user's Applications copy.
        let folder = TemporaryFolder.shortForSockets()
        // Nothing else reads the folder after the files are made: held until the test is over, the files are there to be used.
        defer { withExtendedLifetime(folder) {} }
        let home = folder.url.appending(path: "home", directoryHint: .isDirectory)
        let build = folder.url.appending(path: "build/Mantel.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        let applications = home.appending(path: "Applications", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        let link = applications.appending(path: "Mantel.app", directoryHint: .notDirectory)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: build)

        let verdict = InstallLocation.verdict(for: link, home: home)
        #expect(verdict == .elsewhere(CanonicalPath.of(build.deletingLastPathComponent())))
        // The same bundle, reached either way.
        #expect(InstallLocation.isSameBundle(link, build))
    }

    @Test func aUsersApplicationsThatIsALinkIsStillTheirApplications() throws {
        let folder = TemporaryFolder.shortForSockets()
        // Nothing else reads the folder after the files are made: held until the test is over, the files are there to be used.
        defer { withExtendedLifetime(folder) {} }
        let home = folder.url.appending(path: "home", directoryHint: .isDirectory)
        let real = folder.url.appending(path: "elsewhere/Apps", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appending(path: "Applications", directoryHint: .notDirectory),
                                                   withDestinationURL: real)
        // Reached through the link or by where it leads, it is the same folder.
        #expect(InstallLocation.verdict(for: home.appending(path: "Applications/Mantel.app", directoryHint: .isDirectory), home: home)
                == .userApplications)
        #expect(InstallLocation.verdict(for: real.appending(path: "Mantel.app", directoryHint: .isDirectory), home: home)
                == .userApplications)
    }

    // MARK: The same bundle

    @Test func aBundleIsTheSameThroughALinkAndWithOrWithoutATrailingSlash() throws {
        let folder = TemporaryFolder(prefix: "mantel-install")
        let bundle = folder.url.appending(path: "Mantel.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let link = folder.url.appending(path: "Link.app", directoryHint: .notDirectory)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bundle)

        #expect(InstallLocation.isSameBundle(bundle, link))
        #expect(InstallLocation.isSameBundle(bundle, URL(filePath: bundle.path, directoryHint: .notDirectory)))
        #expect(InstallLocation.isSameBundle(bundle, folder.url.appending(path: "x/../Mantel.app")))
    }

    @Test func twoBundlesAreNotTheSame() throws {
        let folder = TemporaryFolder(prefix: "mantel-install")
        // Nothing else reads the folder after the files are made: held until the test is over, the files are there to be used.
        defer { withExtendedLifetime(folder) {} }
        let one = folder.url.appending(path: "One/Mantel.app", directoryHint: .isDirectory)
        let two = folder.url.appending(path: "Two/Mantel.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: one, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: two, withIntermediateDirectories: true)
        #expect(!InstallLocation.isSameBundle(one, two))
    }

    @Test func aPathThatIsNotThereIsOnlyTheSameAsItself() {
        #expect(InstallLocation.isSameBundle(URL(filePath: "/Applications/Mantel.app"), URL(filePath: "/Applications/Mantel.app/")))
        #expect(!InstallLocation.isSameBundle(URL(filePath: "/Applications/Mantel.app"), URL(filePath: "/Applications/Other.app")))
    }

    // MARK: The bundle a running process is in

    @Test func theBundleOfAnExecutableIsTheAppItIsIn() {
        #expect(InstallLocation.bundle(containingExecutable: URL(filePath: "/Applications/Mantel.app/Contents/MacOS/Mantel"))
            == URL(filePath: "/Applications/Mantel.app", directoryHint: .isDirectory))
        #expect(InstallLocation.bundle(containingExecutable: URL(filePath: "/Applications/Mantel.app/Contents/Helpers/mantel"))
            == URL(filePath: "/Applications/Mantel.app", directoryHint: .isDirectory))
    }

    @Test func anExecutableNotInAnAppHasNoBundle() {
        #expect(InstallLocation.bundle(containingExecutable: URL(filePath: "/usr/local/bin/mantel")) == nil)
    }

    // MARK: When the move must not go on

    private let source = URL(filePath: "/Users/x/Downloads/Mantel.app", directoryHint: .isDirectory)
    private let destination = URL(filePath: "/Applications/Mantel.app", directoryHint: .isDirectory)

    private func refusal(sourceExists: Bool = true, executable: String? = "/Users/x/Downloads/Mantel.app/Contents/MacOS/Mantel",
                         running: [String] = []) -> InstallLocation.MoveRefusal? {
        InstallLocation.moveRefusal(source: source, sourceExists: sourceExists,
                                    currentExecutable: executable.map { URL(filePath: $0) },
                                    runningBundles: running.map { URL(filePath: $0, directoryHint: .isDirectory) },
                                    destination: destination)
    }

    @Test func aCopyThatIsStillWhereItStartedMayMove() {
        #expect(refusal() == nil)
        #expect(refusal(running: ["/Applications/Safari.app", "/Users/x/Downloads/Mantel.app"]) == nil)
    }

    @Test func aCopyWhoseBundleIsGoneHasAlreadyBeenMoved() {
        // Its own path is the one it started from, and the person has since moved it (a first move that worked but didn't
        // start the copy in Applications).
        #expect(refusal(sourceExists: false) == .alreadyMoved)
    }

    @Test func theCopyInApplicationsBeingThisProcessIsRefusedEvenWhenItsStartingPathIsStale() {
        // Its bundle URL still says where it started; where its executable is now says where it went.
        #expect(refusal(executable: "/Applications/Mantel.app/Contents/MacOS/Mantel") == .destinationIsRunning)
    }

    @Test func aRunningMantelInApplicationsIsRefused() {
        #expect(refusal(running: ["/Applications/Mantel.app"]) == .destinationIsRunning)
    }

    @Test func movingFromApplicationsToApplicationsIsRefused() {
        let same = InstallLocation.moveRefusal(source: destination, sourceExists: true, currentExecutable: nil,
                                               runningBundles: [], destination: destination)
        #expect(same == .destinationIsRunning)
    }

    @Test func anExecutableThatIsUnknownMeansItCannotBeChecked() {
        // The check fails closed: if it can't be told which copy is running, nothing is replaced.
        #expect(refusal(executable: nil) == .cannotConfirmRunningCopy)
    }

    @Test func anExecutableNotInsideAnAppMeansItCannotBeChecked() {
        #expect(refusal(executable: "/usr/local/bin/mantel") == .cannotConfirmRunningCopy)
        #expect(refusal(executable: "/") == .cannotConfirmRunningCopy)
    }

    @Test func whatIsKnownIsReportedBeforeWhatCannotBeChecked() {
        #expect(refusal(sourceExists: false, executable: nil) == .alreadyMoved)
        #expect(refusal(executable: nil, running: ["/Applications/Mantel.app"]) == .destinationIsRunning)
        let same = InstallLocation.moveRefusal(source: destination, sourceExists: true, currentExecutable: nil,
                                               runningBundles: [], destination: destination)
        #expect(same == .destinationIsRunning)
    }

    @Test func aMissingBundleIsReportedBeforeARunningOne() {
        #expect(refusal(sourceExists: false, running: ["/Applications/Mantel.app"]) == .alreadyMoved)
    }

    @Test func theMoveGoesToApplications() {
        #expect(InstallLocation.destination.path == "/Applications/Mantel.app")
    }
}
