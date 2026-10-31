import Foundation
import MKTestSupport
import Synchronization
import Testing

@testable import MKMenuBar

/// The mic as the apps that are capturing sound: which processes count, what they are called, and what the tracker's log then says. The
/// process objects are a fake's: nothing on this Mac is read.
@Suite("Input processes", .timeLimit(.minutes(1)))
struct InputProcessesTests {
    private static let own: pid_t = 100

    private func mic(_ objects: FakeProcessObjects) -> DeviceWatch<InputProcesses<FakeProcessObjects>> {
        DeviceWatch(kind: .mic, system: InputProcesses(objects: objects, ownPID: Self.own))
    }

    @Test func aProcessIsNamedByItsBundleIDOrByItsPID() {
        let objects = FakeProcessObjects([
            (1, 200, "com.example.recorder", true),
            (2, 4321, nil, true),
            (3, 55, "", true),
            (4, nil, nil, true),
            (5, 300, "com.example.idle", false),
        ])
        #expect(mic(objects).runningDevices() == ["com.example.recorder", "process 4321", "process 55", "unnamed process"],
                "an app by its bundle ID, one with none by its PID, and one that can't be read as unnamed; one that isn't capturing isn't there")
    }

    @Test func mantelsOwnProcessIsNeverTheMicInUse() async throws {
        let objects = FakeProcessObjects([(1, Self.own, "com.example.mantel", true), (2, 200, "com.example.recorder", false)])
        let watch = mic(objects)
        var signals = watch.changes().makeAsyncIterator()
        #expect(watch.runningDevices().isEmpty, "Mantel's process has input running, and doesn't count")
        #expect(objects.observedProcesses == [2], "and isn't watched")

        // Another app captures: it is the use, and Mantel's process is still left out.
        objects.setCapturing(2, true)
        #expect(await signals.next() != nil)
        #expect(watch.runningDevices() == ["com.example.recorder"])
    }

    @Test func aProcessThatStartsUsingAudioAfterTheWatchBeganCountsAndIsWatched() async throws {
        let objects = FakeProcessObjects([(1, 200, "com.example.recorder", false)])
        let watch = mic(objects)
        var signals = watch.changes().makeAsyncIterator()

        objects.appear(2, pid: 300, bundleID: "com.example.meeting", capturing: true)
        #expect(await signals.next() != nil)
        #expect(watch.runningDevices() == ["com.example.meeting"])

        // It is watched from then on: its input stopping is a signal of its own, and the use ends when the process does.
        #expect(objects.observedProcesses == [1, 2])
        objects.setCapturing(2, false)
        #expect(await signals.next() != nil)
        #expect(watch.runningDevices().isEmpty)
    }

    @Test func theLogNamesTheAppThatHoldsTheMicOnceHoweverManyProcessesItHas() async throws {
        let objects = FakeProcessObjects([(1, 200, "com.example.recorder", false), (2, 201, "com.example.recorder", false)])
        let clock = FakeClock()
        let lines = Mutex<[String]>([])
        let tracker = MediaUseTracker(readers: [mic(objects)], clock: clock, offDelay: MediaUseTracker.offDelay,
                                      note: { line in lines.withLock { $0.append(line) } })
        let stream = await tracker.changes()
        let told = Mutex(0)
        let gathering = Task { for await _ in stream { told.withLock { $0 += 1 } } }
        defer { gathering.cancel() }

        objects.setCapturing(1, true)
        #expect(await waitUntil { told.withLock { $0 } == 1 })
        objects.setCapturing(2, true)
        // The second process of the same app is the same use: nothing more is told or said (the lines are checked at the end).
        #expect(await tracker.current() == MediaUse([.mic: ["com.example.recorder"]]))

        objects.setCapturing(1, false)
        objects.setCapturing(2, false)
        #expect(await clock.waitForSleepers(1, within: .seconds(5)))
        clock.advance(by: MediaUseTracker.offDelay)
        #expect(await waitUntil { told.withLock { $0 } == 2 })
        #expect(lines.withLock { $0 } == ["the mic is in use (com.example.recorder)", "the mic is no longer in use"])
        #expect(MediaUse([.mic: ["b", "a", "b"]]) == MediaUse([.mic: ["a", "b"]]), "a name is there once, whatever the order")
    }
}
