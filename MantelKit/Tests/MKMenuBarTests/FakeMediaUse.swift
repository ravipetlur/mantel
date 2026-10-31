import Foundation
import Synchronization

@testable import MKMenuBar

/// A reader of one kind of device whose devices run when a test says so: nothing on this Mac is opened or read.
///
/// - `running` is what the test has made of the devices: each device by name, and whether it is running.
/// - `set`, `start`, `stop` and `add` change a device and signal, as the system's listeners do; `quietly` changes it with no signal (a
///   change the listener missed).
final class FakeMediaReader: MediaUseReading {
    let kind: MediaKind
    private struct State {
        var devices: [String: Bool]
        var continuations: [Int: AsyncStream<Void>.Continuation] = [:]
        var nextID = 0
    }

    private let state: Mutex<State>

    init(_ kind: MediaKind, devices: [String: Bool]) {
        self.kind = kind
        state = Mutex(State(devices: devices))
    }

    func runningDevices() -> [String] {
        state.withLock { $0.devices.filter(\.value).map(\.key) }
    }

    func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .unbounded)
        let id = state.withLock { state -> Int in
            state.nextID += 1
            state.continuations[state.nextID] = continuation
            return state.nextID
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { $0.continuations[id] = nil }
        }
        return stream
    }

    /// How many streams of changes are open.
    var openStreams: Int { state.withLock { $0.continuations.count } }

    func start(_ device: String) { set(device, running: true) }
    func stop(_ device: String) { set(device, running: false) }

    /// A device is plugged in (running or not), and the list of devices changes.
    func add(_ device: String, running: Bool) { set(device, running: running) }

    func set(_ device: String, running: Bool) {
        quietly(device, running: running)
        signal()
    }

    /// The device changes and nothing is signalled.
    func quietly(_ device: String, running: Bool) {
        state.withLock { $0.devices[device] = running }
    }

    private func signal() {
        let open = state.withLock { Array($0.continuations.values) }
        for continuation in open { continuation.yield() }
    }
}

/// A source of the use of the mic and camera that is what a test says it is, for a session: the use it began with, and each use `send`
/// has made, told to every stream that is open.
final class FakeMediaSource: MediaUseSource {
    private struct State {
        var use: MediaUse
        var continuations: [Int: AsyncStream<MediaUse>.Continuation] = [:]
        var nextID = 0
    }

    private let state: Mutex<State>

    init(_ use: MediaUse = .idle) {
        state = Mutex(State(use: use))
    }

    func current() async -> MediaUse {
        state.withLock { $0.use }
    }

    func changes() async -> AsyncStream<MediaUse> {
        let (stream, continuation) = AsyncStream.makeStream(of: MediaUse.self, bufferingPolicy: .unbounded)
        let id = state.withLock { state -> Int in
            state.nextID += 1
            state.continuations[state.nextID] = continuation
            return state.nextID
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { $0.continuations[id] = nil }
        }
        return stream
    }

    /// How many streams are open: a test that quits the session sees its listener go.
    var openStreams: Int { state.withLock { $0.continuations.count } }

    func send(_ use: MediaUse) {
        let open = state.withLock { state -> [AsyncStream<MediaUse>.Continuation] in
            state.use = use
            return Array(state.continuations.values)
        }
        for continuation in open { continuation.yield(use) }
    }
}

/// What a family of devices is made of for a test: the devices, whether each is running, and every observation made of them, with none of
/// them reaching the system.
final class FakeDeviceSystem: DeviceSystem {
    typealias Device = Int

    private struct State {
        var names: [Int: String] = [:]
        var running: Set<Int> = []
        var nextToken = 0
        var listHandlers: [Int: @Sendable () -> Void] = [:]
        var runningHandlers: [Int: (device: Int, handler: @Sendable () -> Void)] = [:]
    }

    private let state = Mutex(State())

    init(_ devices: [(id: Int, name: String, running: Bool)] = []) {
        state.withLock { state in
            for device in devices {
                state.names[device.id] = device.name
                if device.running { state.running.insert(device.id) }
            }
        }
    }

    func devices() -> [Int] { state.withLock { $0.names.keys.sorted() } }
    func name(of device: Int) -> String { state.withLock { $0.names[device] ?? "" } }
    func isRunningSomewhere(_ device: Int) -> Bool { state.withLock { $0.running.contains(device) } }

    func observeList(_ handler: @escaping @Sendable () -> Void) -> DeviceObservation {
        let token = state.withLock { state -> Int in
            state.nextToken += 1
            state.listHandlers[state.nextToken] = handler
            return state.nextToken
        }
        return DeviceObservation { [weak self] in self?.state.withLock { $0.listHandlers[token] = nil } }
    }

    func observeRunning(of device: Int, _ handler: @escaping @Sendable () -> Void) -> DeviceObservation {
        let token = state.withLock { state -> Int in
            state.nextToken += 1
            state.runningHandlers[state.nextToken] = (device, handler)
            return state.nextToken
        }
        return DeviceObservation { [weak self] in self?.state.withLock { $0.runningHandlers[token] = nil } }
    }

    /// The devices that have a listener for their running now.
    var observedDevices: Set<Int> { state.withLock { Set($0.runningHandlers.values.map(\.device)) } }
    /// How many observations are in place: the list's, and each device's.
    var observations: Int { state.withLock { $0.listHandlers.count + $0.runningHandlers.count } }

    /// A device is plugged in: the list changes.
    func plugIn(_ device: Int, named name: String, running: Bool) {
        let handlers = state.withLock { state -> [@Sendable () -> Void] in
            state.names[device] = name
            if running { state.running.insert(device) }
            return Array(state.listHandlers.values)
        }
        for handler in handlers { handler() }
    }

    func unplug(_ device: Int) {
        let handlers = state.withLock { state -> [@Sendable () -> Void] in
            state.names[device] = nil
            state.running.remove(device)
            return Array(state.listHandlers.values)
        }
        for handler in handlers { handler() }
    }

    /// A device starts or stops running: the observation made of it says so.
    func setRunning(_ device: Int, _ running: Bool) {
        let handlers = state.withLock { state -> [@Sendable () -> Void] in
            if running { state.running.insert(device) } else { state.running.remove(device) }
            return state.runningHandlers.values.filter { $0.device == device }.map(\.handler)
        }
        for handler in handlers { handler() }
    }
}

/// The processes that use audio, for a test: each with its PID, its bundle ID (or none) and whether it has input running, and the
/// observations made of them, none of which reaches the system. The list and the observations are a `FakeDeviceSystem`'s.
final class FakeProcessObjects: AudioProcessObjects {
    typealias Process = Int

    private struct Identity {
        var pid: pid_t?
        var bundleID: String?
    }

    private let devices: FakeDeviceSystem
    private let identities = Mutex<[Int: Identity]>([:])

    init(_ processes: [(object: Int, pid: pid_t?, bundleID: String?, capturing: Bool)] = []) {
        devices = FakeDeviceSystem(processes.map { ($0.object, "", $0.capturing) })
        identities.withLock { identities in
            for process in processes { identities[process.object] = Identity(pid: process.pid, bundleID: process.bundleID) }
        }
    }

    func processes() -> [Int] { devices.devices() }
    func pid(of process: Int) -> pid_t? { identities.withLock { $0[process]?.pid } }
    func bundleID(of process: Int) -> String? { identities.withLock { $0[process]?.bundleID } }
    func isRunningInput(_ process: Int) -> Bool { devices.isRunningSomewhere(process) }

    func observeList(_ handler: @escaping @Sendable () -> Void) -> DeviceObservation {
        devices.observeList(handler)
    }

    func observeRunningInput(of process: Int, _ handler: @escaping @Sendable () -> Void) -> DeviceObservation {
        devices.observeRunning(of: process, handler)
    }

    /// The processes that have a listener for their input now.
    var observedProcesses: Set<Int> { devices.observedDevices }

    /// A process starts to use audio (capturing or not): the list changes.
    func appear(_ process: Int, pid: pid_t?, bundleID: String?, capturing: Bool) {
        identities.withLock { $0[process] = Identity(pid: pid, bundleID: bundleID) }
        devices.plugIn(process, named: "", running: capturing)
    }

    func setCapturing(_ process: Int, _ capturing: Bool) { devices.setRunning(process, capturing) }
}
