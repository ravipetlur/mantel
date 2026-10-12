import Foundation
import MKTestSupport
import Testing

@testable import MKMenuBar

/// Which copy of the app is the one macOS honours the allowlist for.
@Suite("Probe platform", .timeLimit(.minutes(1)))
struct ProbePlatformTests {
    private let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)

    private func isInstalled(_ path: String) -> Bool {
        ProbePlatform.isInstalledCopy(at: URL(filePath: path, directoryHint: .isDirectory), home: home)
    }

    @Test func onlyTheCopyDirectlyInApplicationsIsTheInstalledCopy() {
        #expect(isInstalled("/Applications/Mantel.app"))
        #expect(!isInstalled("/Users/someone/Applications/Mantel.app"), "the person's own Applications is not where macOS honours the allowlist")
        #expect(!isInstalled("/Applications/Utilities/Mantel.app"))
        #expect(!isInstalled("/Users/someone/dev/Mantel/build/Debug/Mantel.app"))
        #expect(!isInstalled("/private/var/folders/xx/AppTranslocation/ABC/d/Mantel.app"))
    }

    @Test func symlinkedApplicationsCopyCounts() throws {
        let folder = TemporaryFolder.shortForSockets()
        // Nothing else reads the folder after the links are made: held until the test is over, the links are there to be used.
        defer { withExtendedLifetime(folder) {} }
        let home = folder.url.appending(path: "home", directoryHint: .isDirectory)
        // A folder that leads to Applications holds the installed copy, however it is reached.
        let apps = folder.url.appending(path: "Apps", directoryHint: .notDirectory)
        try FileManager.default.createSymbolicLink(at: apps, withDestinationURL: URL(filePath: "/Applications", directoryHint: .isDirectory))
        #expect(ProbePlatform.isInstalledCopy(at: apps.appending(path: "Mantel.app", directoryHint: .isDirectory), home: home))
        // Reached the other way round, through a link made in the person's own folder that leads to the same place.
        let applications = home.appending(path: "Applications", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: applications, withDestinationURL: URL(filePath: "/Applications", directoryHint: .isDirectory))
        #expect(ProbePlatform.isInstalledCopy(at: applications.appending(path: "Mantel.app", directoryHint: .isDirectory), home: home),
                "the person's Applications, which is a link to /Applications, is /Applications")

        // And an entry in Applications that is a link to a build folder is the build's: it is not the installed copy.
        let build = folder.url.appending(path: "build/Mantel.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        let linked = folder.url.appending(path: "Linked.app", directoryHint: .notDirectory)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: build)
        #expect(!ProbePlatform.isInstalledCopy(at: linked, home: home))
    }
}
