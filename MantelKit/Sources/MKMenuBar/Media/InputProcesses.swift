import Foundation

/// What the mic is read through: CoreAudio's process objects, one for each app that uses audio, in a few calls and nothing else. The
/// logic of what counts is `InputProcesses`', so that it is tested with a fake of this and the live one (`CoreAudioProcessObjects`) stays thin.
protocol AudioProcessObjects: Sendable {
    associatedtype Process: Hashable & Sendable

    /// The processes the system lists now that use audio, input or output.
    func processes() -> [Process]
    func pid(of process: Process) -> pid_t?
    /// The process's bundle ID; nil for a process that has none (a command-line tool), and possibly empty.
    func bundleID(of process: Process) -> String?
    /// Whether the process has an input stream running: it is capturing sound, from whichever device. Playing sound doesn't count. It
    /// never opens anything, and so never asks for permission.
    func isRunningInput(_ process: Process) -> Bool
    /// Has `handler` called each time the system's list of processes changes.
    func observeList(_ handler: @escaping @Sendable () -> Void) -> DeviceObservation
    /// Has `handler` called each time the process starts or stops running input.
    func observeRunningInput(of process: Process, _ handler: @escaping @Sendable () -> Void) -> DeviceObservation
}

/// The mic, as the apps that are capturing sound: a `DeviceSystem` whose "devices" are processes and whose names are the apps'.
///
/// - **The mic is in use when a process other than Mantel's own has input running.** Asking each process rather than each device is what
///   keeps sound that is only played through a headset (one device to CoreAudio, with a mic in it) from reading as the mic in use.
/// - **Mantel's own process is left out** (`ownPID`): it never captures, and nothing it does is the person's use of the mic.
/// - **A process is named by its bundle ID,** or "process <pid>" when it has none, so that the log says which app holds the mic.
///
/// The list of processes is observed like a list of devices (`DeviceWatch`): one that starts to use audio mid-call is watched from then on.
struct InputProcesses<Objects: AudioProcessObjects>: DeviceSystem {
    typealias Device = Objects.Process

    private let objects: Objects
    private let ownPID: pid_t

    init(objects: Objects, ownPID: pid_t) {
        self.objects = objects
        self.ownPID = ownPID
    }

    func devices() -> [Objects.Process] {
        objects.processes().filter { objects.pid(of: $0) != ownPID }
    }

    func name(of device: Objects.Process) -> String {
        if let bundleID = objects.bundleID(of: device), !bundleID.isEmpty { return bundleID }
        return objects.pid(of: device).map { "process \($0)" } ?? "unnamed process"
    }

    func isRunningSomewhere(_ device: Objects.Process) -> Bool {
        objects.isRunningInput(device)
    }

    func observeList(_ handler: @escaping @Sendable () -> Void) -> DeviceObservation {
        objects.observeList(handler)
    }

    func observeRunning(of device: Objects.Process, _ handler: @escaping @Sendable () -> Void) -> DeviceObservation {
        objects.observeRunningInput(of: device, handler)
    }
}
