import Foundation
import MKTestSupport
import Testing

@testable import MKMenuBar

/// The reader of one kind of device through a system's few calls: which devices are running, and the watch that keeps up with devices
/// that come and go. The system is a fake: nothing on this Mac is read.
@Suite("Device watch", .timeLimit(.minutes(1)))
struct DeviceWatchTests {
    /// Returns once the stream has signalled again; false if it ended.
    private func signalled(_ iterator: inout AsyncStream<Void>.Iterator) async -> Bool {
        await iterator.next() != nil
    }

    @Test func readsTheNamesOfTheDevicesThatAreRunning() {
        let system = FakeDeviceSystem([(1, "Built-in Microphone", false), (2, "USB Microphone", true), (3, "Headset", true)])
        let watch = DeviceWatch(kind: .mic, system: system)
        #expect(watch.kind == .mic)
        #expect(watch.runningDevices().sorted() == ["Headset", "USB Microphone"])
        system.setRunning(2, false)
        #expect(watch.runningDevices() == ["Headset"])
    }

    @Test func aDeviceAddedWhileRunningIsWatchedAndSignalled() async throws {
        let system = FakeDeviceSystem([(1, "Built-in Microphone", false)])
        let watch = DeviceWatch(kind: .mic, system: system)
        var signals = watch.changes().makeAsyncIterator()
        #expect(system.observedDevices == [1], "the devices there are at the start are watched")

        // Plugged in already running: the list's change is signalled, and the new device is read as running.
        system.plugIn(2, named: "USB Microphone", running: true)
        #expect(await signalled(&signals))
        #expect(watch.runningDevices() == ["USB Microphone"])

        // And the new device is watched from then on: its stop is a signal of its own.
        #expect(system.observedDevices == [1, 2])
        system.setRunning(2, false)
        #expect(await signalled(&signals))
        #expect(watch.runningDevices().isEmpty)

        // A device that is unplugged is let go.
        system.unplug(2)
        #expect(await signalled(&signals))
        #expect(system.observedDevices == [1])
    }

    @Test func droppingTheStreamTakesEveryObservationAway() async throws {
        let system = FakeDeviceSystem([(1, "Built-in Microphone", false), (2, "USB Microphone", true)])
        let watch = DeviceWatch(kind: .mic, system: system)
        #expect(system.observations == 0)
        let listening = Task {
            for await _ in watch.changes() {}
        }
        #expect(await waitUntil { system.observations == 3 }, "the list, and each of the two devices")
        listening.cancel()
        #expect(await waitUntil { system.observations == 0 })
    }
}
