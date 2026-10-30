import AppKit
import Foundation
import MKCore
import MKUpdate
import Synchronization

/// Downloads a release, verifies it, replaces the running app with it and relaunches. It reports each step to the flow
/// through `report` (which says whether the flow took the event, and so whether this install is still the one that
/// counts), and returns how it ended.
///
/// It isn't tied to the main actor, and `install` is `@concurrent`: the downloading, hashing, verifying and copying run
/// off the main thread, and only what must (opening the image in Finder, the relaunch) goes back to it. (The app's
/// default is the main actor, and an `async` function that isn't `@concurrent` would run on its caller's.)
nonisolated protocol UpdateInstaller: Sendable {
    /// `currentVersion` is the version in the running app's place now: the running one, or the newer one an earlier
    /// update installed that this process hasn't restarted into (`UpdateCenter.effectiveVersion`). The offered app must
    /// be newer than it, and the backup of the old copy is named after it.
    @concurrent func install(release: ReleaseInfo, currentVersion: VersionNumber,
                             report: @escaping InstallSteps.Report) async -> InstallOutcome

    /// The app is quitting: ejects the disk image an install has mounted and not ejected yet, now, so a quit during the
    /// verification doesn't leave it mounted. It blocks for a few seconds at most. Nothing when no image is mounted.
    func ejectMountedImageForQuit()
}

/// The installer with the real steps: `Downloader`, `DiskImage`, `CodeVerifier` and `AppInstaller` behind the
/// `InstallSteps` sequencer, which owns the order, the endings and the cleanup.
nonisolated struct LiveUpdateInstaller: UpdateInstaller {
    /// The running app's bundle, which is replaced.
    let app: URL
    /// The running app's bundle identifier, which the new app must have too.
    let bundleIdentifier: String
    let userAgent: String
    /// Returns once nothing is in the relaunch's way (`RelaunchGate.waitUntilQuiet`), or at once when the install is
    /// cancelled. The relaunch waits on it.
    let waitUntilQuiet: @Sendable () async -> Void
    /// Where the install's disk image is mounted while it is, for the quit to eject.
    private let mounted = MountedImage()

    @MainActor init(configuration: UpdateConfiguration, bundle: Bundle = .main,
                    waitUntilQuiet: @escaping @Sendable () async -> Void) {
        app = bundle.bundleURL
        bundleIdentifier = bundle.bundleIdentifier ?? ""
        userAgent = configuration.userAgent
        self.waitUntilQuiet = waitUntilQuiet
    }

    @concurrent func install(release: ReleaseInfo, currentVersion: VersionNumber,
                             report: @escaping InstallSteps.Report) async -> InstallOutcome {
        await steps(for: release, currentVersion: currentVersion).run(report: report)
    }

    func ejectMountedImageForQuit() {
        guard let mountPoint = mounted.current else { return }
        DiskImage.ejectForQuit(mountPoint)
    }

    /// The sequencer wired to the real parts. Each install has a work folder of its own, made by its download step.
    private func steps(for release: ReleaseInfo, currentVersion: VersionNumber) -> InstallSteps {
        let work = UpdateWorkFolder()
        let downloader = Downloader(userAgent: userAgent)
        let images = DiskImage()
        let verifier = CodeVerifier()
        let installer = AppInstaller(running: app, currentVersion: currentVersion, verifier: verifier)
        let identifier = bundleIdentifier
        let mounted = mounted
        let quiet = waitUntilQuiet

        return InstallSteps(
            download: { progress in
                try work.create()
                // The small checksum file first: a release without a usable one fails before the large download.
                let checksum = try await downloader.download(release.checksum, into: work.url)
                let image = try await downloader.download(release.dmg, into: work.url, progress: progress)
                return InstallSteps.Files(image: image, checksum: checksum)
            },
            checksum: { files in
                try Self.checkChecksum(files, expectedName: release.dmg.name)
            },
            gatekeeperImage: { image in
                try await verifier.assessImage(at: image)
            },
            mount: { image in
                // Noted first: a mount that is cut short may still leave the image attached.
                mounted.set(work.mountPoint)
                try await images.mount(image, at: work.mountPoint)
                return work.mountPoint
            },
            appIdentity: { volume in
                let app = try Self.appInside(volume)
                try verifier.checkIdentity(of: app, expectedIdentifier: identifier, offered: release.version,
                                           running: currentVersion)
                return app
            },
            appSignature: { app in
                try verifier.checkSignature(of: app)
            },
            gatekeeperApp: { app in
                try await verifier.assessApp(at: app)
            },
            destinationIsWritable: {
                installer.destinationIsWritable
            },
            openImage: { volume in
                // Left mounted for the person to finish with: the quit must not eject it.
                mounted.clear(volume)
                await MainActor.run {
                    if !NSWorkspace.shared.open(volume) { Log.update.warning("The disk image couldn't be shown in Finder") }
                }
            },
            stageAndReplace: { app in
                try installer.stageAndReplace(app, version: release.version)
            },
            removeBackup: { backup in
                try installer.removeBackup(backup)
            },
            detach: { _ in
                // The one eject: the cleanup after it doesn't try again, it only removes the folder (or keeps it).
                await work.detach(using: images)
                mounted.clear(work.mountPoint)
            },
            cleanup: {
                // Also what is still mounted when `detach` never ran: a mount that was cut short has none of its own.
                await work.remove(using: images)
            },
            waitUntilQuiet: {
                await quiet()
            },
            relaunch: {
                await AppInstaller.relaunch()
            },
            note: { text in
                Log.update.info(text)
            })
    }

    // MARK: Steps that need no part of their own

    /// The checksum file names the image's hash (`<64 hex>  <file name>`), and the image has it. Throws
    /// `checksumFileInvalid` for a file that can't be read or has no line for the image, and `checksumMismatch` for a
    /// hash that differs. The hashing reads the whole image, so this runs off the main actor.
    private static func checkChecksum(_ files: InstallSteps.Files, expectedName: String) throws {
        // The file is a line or two. A large one isn't a checksum file.
        let size = (try? FileManager.default.attributesOfItem(atPath: files.checksum.path(percentEncoded: false))[.size] as? Int) ?? -1
        guard (1...64 * 1024).contains(size),
              let data = try? Data(contentsOf: files.checksum),
              let text = String(data: data, encoding: .utf8),
              let expected = ChecksumFile.expectedHash(in: text, forFile: expectedName)
        else {
            Log.update.warning("The checksum file has no usable line for \(expectedName)")
            throw UpdateFailure.checksumFileInvalid
        }
        let matches: Bool
        do {
            matches = try ChecksumFile.matches(fileAt: files.image, expectedHash: expected)
        } catch {
            Log.update.warning("The disk image couldn't be read for its checksum: \(error.localizedDescription)")
            throw UpdateFailure.checksumMismatch
        }
        guard matches else {
            Log.update.warning("The disk image doesn't match its published checksum")
            throw UpdateFailure.checksumMismatch
        }
        Log.update.info("The disk image matches its published checksum")
    }

    /// The app in the mounted image, by its exact name: the image also holds a shortcut to Applications, which a search
    /// of the volume would follow. A folder of that name that is a symbolic link doesn't count.
    private static func appInside(_ volume: URL) throws -> URL {
        let app = volume.appending(path: InstallNames.appName, directoryHint: .isDirectory)
        let values = try? app.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else {
            Log.update.warning("The disk image doesn't hold \(InstallNames.appName)")
            throw UpdateFailure.appMissing
        }
        return app
    }
}

/// The mount point of the disk image an install has mounted and not ejected yet, shared between the install (which sets
/// and clears it) and the quit (which ejects what is left).
nonisolated final class MountedImage: Sendable {
    private let mountPoint = Mutex<URL?>(nil)

    var current: URL? { mountPoint.withLock { $0 } }

    func set(_ url: URL) {
        mountPoint.withLock { $0 = url }
    }

    /// Forgets `url`, unless a later install has set another since: that one is still mounted.
    func clear(_ url: URL) {
        mountPoint.withLock { if $0 == url { $0 = nil } }
    }
}
