import Foundation
import MKCore
import MKUpdate

/// Mounts the downloaded disk image and ejects it, with macOS 27's own `diskutil` (the method tested on macOS 27: no prompt,
/// no Finder window, no deprecation warning).
///
/// Mounting checks nothing about the image (a tampered image still mounts), so it comes only after the checksum and
/// Gatekeeper have accepted the file.
nonisolated struct DiskImage: Sendable {
    private static let diskutil = "/usr/sbin/diskutil"

    /// Mounts `image` read-only at `mountPoint` and hides it from Finder's sidebar and the Desktop. The mount point's
    /// parent must exist; the mount point itself is made. Throws `UpdateFailure.mountFailed`.
    func mount(_ image: URL, at mountPoint: URL) async throws {
        let result = try await ProcessRunner.run(Self.diskutil, arguments: [
            "image", "attach", "--readOnly", "--nobrowse", "--mountPoint", mountPoint.path(percentEncoded: false),
            image.path(percentEncoded: false),
        ])
        guard result.status == 0 else {
            Log.update.warning("Mounting the disk image failed (diskutil status \(result.status)): \(Self.excerpt(result.output))")
            throw UpdateFailure.mountFailed
        }
        Log.update.info("The disk image is mounted")
    }

    /// Ejects the image mounted at `mountPoint`. A refusal (Spotlight or a code check may still have a file open for a
    /// moment) is tried again a couple of times, a second apart; a tool that doesn't answer in 30 s is given up on at
    /// once, so a stuck eject costs one timeout. True when it is no longer mounted there (or never was).
    func eject(_ mountPoint: URL) async -> Bool {
        let path = mountPoint.path(percentEncoded: false)
        guard Self.isMounted(mountPoint) else { return true }
        for attempt in 1...3 {
            do {
                let result = try await ProcessRunner.run(Self.diskutil, arguments: ["eject", path], timeout: .seconds(30))
                if result.status == 0 {
                    Log.update.info("The disk image is ejected")
                    return true
                }
                Log.update.warning("Ejecting the disk image failed (diskutil status \(result.status), try \(attempt)): \(Self.excerpt(result.output))")
            } catch {
                Log.update.warning("Ejecting the disk image didn't finish (try \(attempt)): \(error)")
                return !Self.isMounted(mountPoint)
            }
            if !Self.isMounted(mountPoint) { return true }
            if attempt < 3 { try? await Task.sleep(for: .seconds(1)) }
        }
        return !Self.isMounted(mountPoint)
    }

    /// Ejects the image mounted at `mountPoint` for a quit: the same `diskutil eject`, run to its end here, because the
    /// process is about to exit and an eject that runs in a task wouldn't be finished. A refusal (a check that was just
    /// cancelled may still have a file open for a moment) is tried again a moment later, and all of it, tries included,
    /// is over after `budget` seconds at the most, so a quit is never held up longer than that. Nothing when nothing is
    /// mounted there.
    static func ejectForQuit(_ mountPoint: URL, budget: TimeInterval = 3) {
        let deadline = Date.now.addingTimeInterval(budget)
        while isMounted(mountPoint) {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                Log.update.warning("The disk image was still mounted when the quit ran out of time")
                return
            }
            let process = Process()
            process.executableURL = URL(filePath: diskutil)
            process.arguments = ["eject", mountPoint.path(percentEncoded: false)]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let finished = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in finished.signal() }
            do {
                try process.run()
            } catch {
                Log.update.warning("The disk image couldn't be ejected for the quit: \(error.localizedDescription)")
                return
            }
            if finished.wait(timeout: .now() + remaining) == .timedOut {
                process.terminate()
                Log.update.warning("The eject for the quit didn't finish in time")
                return
            }
            if process.terminationStatus == 0 {
                Log.update.info("The disk image was ejected for the quit")
                return
            }
            Thread.sleep(forTimeInterval: min(0.25, max(deadline.timeIntervalSinceNow, 0)))
        }
    }

    /// Whether something is mounted at `mountPoint`: a mounted volume's folder is on another device than its parent's.
    static func isMounted(_ mountPoint: URL) -> Bool {
        let fileManager = FileManager.default
        let parent = mountPoint.deletingLastPathComponent()
        guard let inside = try? fileManager.attributesOfItem(atPath: mountPoint.path(percentEncoded: false))[.systemNumber] as? Int,
              let outside = try? fileManager.attributesOfItem(atPath: parent.path(percentEncoded: false))[.systemNumber] as? Int
        else { return false }
        return inside != outside
    }

    /// The last line of a tool's output, shortened, for the log.
    static func excerpt(_ output: String) -> String {
        let line = output.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        return line.count > 200 ? String(line.prefix(200)) + "\u{2026}" : line
    }
}
