import Foundation
import MKCore
import Synchronization

/// An observation made of the system, which ends when `cancel` is called.
struct DeviceObservation: Sendable {
    let cancel: @Sendable () -> Void
}

/// What one family of devices is read and watched through. `DeviceWatch` has the logic of keeping the watch up to date as devices come and
/// go, so that it is tested with a fake of this and the live ones stay thin. The camera's is a few calls into CoreMediaIO
/// (`CoreMediaCameras`); the mic's "devices" are the processes capturing sound (`InputProcesses`).
protocol DeviceSystem: Sendable {
    associatedtype Device: Hashable & Sendable

    /// The devices the system lists now that this kind of reading is about.
    func devices() -> [Device]
    func name(of device: Device) -> String
    /// Whether anything on this Mac is using the device. It never opens the device, and so never asks for permission.
    func isRunningSomewhere(_ device: Device) -> Bool
    /// Has `handler` called each time the system's list of devices changes.
    func observeList(_ handler: @escaping @Sendable () -> Void) -> DeviceObservation
    /// Has `handler` called each time the device starts or stops running somewhere.
    func observeRunning(of device: Device, _ handler: @escaping @Sendable () -> Void) -> DeviceObservation
}

/// The reader of one kind of device through a `DeviceSystem`.
///
/// **A device added while Mantel runs is watched too.** The list of devices is observed along with each device in it: when the list changes,
/// the devices that are new are observed, those that are gone are let go, and the change is signalled (a device that is plugged in
/// already running counts at once).
struct DeviceWatch<System: DeviceSystem>: MediaUseReading {
    let kind: MediaKind
    private let system: System

    init(kind: MediaKind, system: System) {
        self.kind = kind
        self.system = system
    }

    func runningDevices() -> [String] {
        system.devices().filter { system.isRunningSomewhere($0) }.map { system.name(of: $0) }
    }

    func changes() -> AsyncStream<Void> {
        // One signal waiting is as good as many: whoever reads reads the lot.
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let watching = Watching(system: system, continuation: continuation)
        continuation.onTermination = { _ in watching.stop() }
        watching.start()
        return stream
    }

    /// The observations of one stream of changes. The system is never called with the lock held: taking an observation away can wait for a
    /// handler that is running, and a handler that is running can be waiting for the lock.
    private final class Watching: Sendable {
        private struct State {
            var list: DeviceObservation?
            var devices: [System.Device: DeviceObservation] = [:]
            var stopped = false
        }

        private let system: System
        private let continuation: AsyncStream<Void>.Continuation
        private let state = Mutex(State())

        init(system: System, continuation: AsyncStream<Void>.Continuation) {
            self.system = system
            self.continuation = continuation
        }

        func start() {
            let list = system.observeList { [weak self] in self?.listChanged() }
            let stale = state.withLock { state -> DeviceObservation? in
                if state.stopped { return list }
                state.list = list
                return nil
            }
            stale?.cancel()
            watchDevices()
        }

        func stop() {
            let held = state.withLock { state -> [DeviceObservation] in
                state.stopped = true
                let held = Array(state.devices.values) + [state.list].compactMap { $0 }
                state.list = nil
                state.devices = [:]
                return held
            }
            for observation in held { observation.cancel() }
        }

        private func listChanged() {
            watchDevices()
            continuation.yield()
        }

        /// Observes the devices there are now that aren't observed yet, and lets go of those that are gone.
        private func watchDevices() {
            let present = Set(system.devices())
            let (added, gone) = state.withLock { state -> ([System.Device], [DeviceObservation]) in
                guard !state.stopped else { return ([], []) }
                let known = Set(state.devices.keys)
                let gone = known.subtracting(present).compactMap { state.devices.removeValue(forKey: $0) }
                return (Array(present.subtracting(known)), gone)
            }
            for observation in gone { observation.cancel() }
            for device in added {
                let observation = system.observeRunning(of: device) { [continuation] in continuation.yield() }
                let unwanted = state.withLock { state -> DeviceObservation? in
                    if state.stopped || state.devices[device] != nil { return observation }
                    state.devices[device] = observation
                    return nil
                }
                unwanted?.cancel()
            }
        }
    }
}
