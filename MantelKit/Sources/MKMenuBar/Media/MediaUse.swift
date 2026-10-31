import Foundation

/// What macOS marks with an indicator in the menu bar while something uses it: the orange dot for the mic, the green one for the camera.
public enum MediaKind: String, Sendable, CaseIterable {
    case mic
    case camera
}

/// The mic and the camera as they are in use, by kind: the names of what is using them. For the mic they are the apps that are capturing
/// sound (bundle IDs); for the camera, the cameras that are running. Mantel never opens either.
public struct MediaUse: Sendable, Equatable {
    /// What is in use, by kind; a kind with none has no entry. Each kind's names are sorted and each is there once (an app with several
    /// processes capturing is one name), so that the same use is the same value whatever order the system lists it in.
    public let devices: [MediaKind: [String]]

    public init(_ devices: [MediaKind: [String]] = [:]) {
        self.devices = devices.compactMapValues { $0.isEmpty ? nil : Set($0).sorted() }
    }

    /// Neither is in use.
    public static let idle = MediaUse()

    /// The mic or the camera is in use.
    public var isInUse: Bool { !devices.isEmpty }

    /// The kinds that are in use, the mic first.
    public var kinds: [MediaKind] { MediaKind.allCases.filter { devices[$0] != nil } }

    // MARK: Words

    /// "the mic", "the camera" or "the mic and camera".
    private static func phrase(_ kinds: [MediaKind]) -> String {
        "the " + kinds.map(\.rawValue).joined(separator: " and ")
    }

    /// What the log says for a change, one line for the kinds that are in use now and weren't, or are in use by others now, and one for the
    /// kinds that are no longer in use: "the mic is in use (us.zoom.xos)", "the mic and camera are no longer in use". The first names the
    /// apps (mic) and cameras, and the second doesn't need to. Nothing for no change.
    static func changeLines(from old: MediaUse, to new: MediaUse) -> [String] {
        var lines: [String] = []
        let started = new.kinds.filter { old.devices[$0] != new.devices[$0] }
        if !started.isEmpty {
            let names = started.flatMap { new.devices[$0] ?? [] }.joined(separator: ", ")
            lines.append("\(phrase(started)) \(started.count == 1 ? "is" : "are") in use (\(names))")
        }
        let ended = old.kinds.filter { new.devices[$0] == nil }
        if !ended.isEmpty {
            lines.append("\(phrase(ended)) \(ended.count == 1 ? "is" : "are") no longer in use")
        }
        return lines
    }

    /// What Diagnostics says: whether the mic or camera is in use. It names no app or device (a device's name can hold the person's own
    /// words, and the copied report is shared); the log has the names.
    public var diagnosticsLine: String {
        guard isInUse else { return "Neither the mic nor the camera is in use." }
        let kinds = kinds
        return "\(Self.phrase(kinds).capitalizedFirst) \(kinds.count == 1 ? "is" : "are") in use."
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// One kind, read in the thinnest way the system allows. The live ones are `LiveMediaReaders`; a test gives a fake.
///
/// Neither asks for permission: they read whether something is running, which no app has to be allowed to ask, and never open a device.
public protocol MediaUseReading: Sendable {
    var kind: MediaKind { get }
    /// The names of what is using this kind now: the apps capturing sound (mic), the cameras that are running.
    func runningDevices() -> [String]
    /// A signal each time `runningDevices()` may have changed: something started or stopped running, or a process or device was added or
    /// removed. The system's listeners are taken away when the stream is dropped.
    func changes() -> AsyncStream<Void>
}

/// Where the session learns whether the mic or camera is in use: `MediaUseTracker` in the app, a fake in a test.
public protocol MediaUseSource: Sendable {
    /// The use as it is now.
    func current() async -> MediaUse
    /// Each use after this one, as it comes. A caller that is to miss none asks for this first and reads `current()` after.
    func changes() async -> AsyncStream<MediaUse>
}

/// A source of a session that nothing watches: neither is ever in use, and nothing ever changes.
public struct IdleMediaUse: MediaUseSource {
    public init() {}

    public func current() async -> MediaUse { .idle }

    public func changes() async -> AsyncStream<MediaUse> {
        AsyncStream { $0.finish() }
    }
}
