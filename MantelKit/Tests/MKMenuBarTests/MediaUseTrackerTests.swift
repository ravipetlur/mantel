import Foundation
import MKTestSupport
import Synchronization
import Testing

@testable import MKMenuBar

/// Whether the mic or camera is in use, as the tracker steadies it: on at once, off only after 10 seconds with nothing running. The readers
/// are fakes: no device on this Mac is read, and the clock is moved by the test.
@Suite("Media use tracker", .timeLimit(.minutes(1)))
struct MediaUseTrackerTests {
    private static let mic = "com.example.recorder"
    private static let camera = "FaceTime HD Camera"

    private final class Lines: Sendable {
        private let lines = Mutex<[String]>([])
        var all: [String] { lines.withLock { $0 } }
        func add(_ line: String) { lines.withLock { $0.append(line) } }
    }

    private final class Uses: Sendable {
        private let uses = Mutex<[MediaUse]>([])
        var all: [MediaUse] { uses.withLock { $0 } }
        func add(_ use: MediaUse) { uses.withLock { $0.append(use) } }
    }

    /// A tracker over these readers, a clock the test moves, the log lines it said, and the uses its stream told (a task that gathers them).
    private struct Rig {
        let tracker: MediaUseTracker
        let clock: FakeClock
        let lines: Lines
        let told: Uses
        let gathering: Task<Void, Never>

        /// Returns once the stream has told this many uses.
        func told(_ count: Int) async -> Bool {
            let told = told
            return await waitUntil { told.all.count >= count }
        }

        /// Returns once the tracker's wait for the delay is under way.
        func waiting() async -> Bool {
            await clock.waitForSleepers(1, within: .seconds(5))
        }
    }

    private func rig(_ readers: [FakeMediaReader]) async -> Rig {
        let clock = FakeClock()
        let lines = Lines()
        let tracker = MediaUseTracker(readers: readers, clock: clock, offDelay: MediaUseTracker.offDelay, note: { lines.add($0) })
        let stream = await tracker.changes()
        let told = Uses()
        let gathering = Task { for await use in stream { told.add(use) } }
        return Rig(tracker: tracker, clock: clock, lines: lines, told: told, gathering: gathering)
    }

    @Test func inUseTurnsOnAtOnceAndOffOnlyAfterTenSecondsWithNothingRunning() async throws {
        let mic = FakeMediaReader(.mic, devices: [Self.mic: false])
        let rig = await rig([mic])
        defer { rig.gathering.cancel() }
        #expect(await rig.tracker.current() == .idle)

        // On the moment a device runs: the clock hasn't moved, and nothing waits on it.
        mic.start(Self.mic)
        #expect(await rig.told(1))
        #expect(rig.told.all == [MediaUse([.mic: [Self.mic]])])
        #expect(rig.clock.sleeperCount == 0)

        // Off only after 10 seconds: a millisecond short of them it is on still, and the wait is still under way.
        mic.stop(Self.mic)
        #expect(await rig.waiting())
        rig.clock.advance(by: .milliseconds(9_999))
        #expect(rig.clock.sleeperCount == 1, "the wait isn't over")
        #expect(await rig.tracker.current().isInUse)
        #expect(rig.told.all.count == 1)

        rig.clock.advance(by: .milliseconds(1))
        #expect(await rig.told(2))
        #expect(rig.told.all.last == .idle)
        #expect(await rig.tracker.current() == .idle)
        #expect(rig.lines.all == ["the mic is in use (\(Self.mic))", "the mic is no longer in use"], "each change said once")
    }

    @Test func aDeviceSwitchInsideTheDelayChangesNothingButTheNameAndTheNextStopWaitsAWholeDelay() async throws {
        let usb = "com.example.dictation"
        let mic = FakeMediaReader(.mic, devices: [Self.mic: true, usb: false])
        let rig = await rig([mic])
        defer { rig.gathering.cancel() }
        #expect(await rig.tracker.current() == MediaUse([.mic: [Self.mic]]), "the use at the start is told at once")
        #expect(rig.lines.all == ["the mic is in use (\(Self.mic))"])

        // The built-in mic stops, and 3 seconds on the USB one starts: the use never went off.
        mic.stop(Self.mic)
        #expect(await rig.waiting())
        rig.clock.advance(by: .seconds(3))
        mic.start(usb)
        #expect(await rig.told(1))
        #expect(rig.told.all == [MediaUse([.mic: [usb]])])
        #expect(await waitUntil { rig.clock.sleeperCount == 0 }, "the wait ended")
        #expect(await rig.tracker.current().isInUse)

        // It stops: a whole delay from this stop, not what was left of the one before.
        mic.stop(usb)
        #expect(await rig.waiting())
        rig.clock.advance(by: .milliseconds(9_999))
        #expect(rig.clock.sleeperCount == 1)
        #expect(await rig.tracker.current().isInUse)
        rig.clock.advance(by: .milliseconds(1))
        #expect(await rig.told(2))
        #expect(rig.told.all.last == .idle)
        #expect(rig.lines.all == ["the mic is in use (\(Self.mic))", "the mic is in use (\(usb))", "the mic is no longer in use"])
    }

    @Test func aDeviceAddedWhileRunningCounts() async throws {
        let usb = "com.example.dictation"
        let mic = FakeMediaReader(.mic, devices: [Self.mic: false])
        let rig = await rig([mic])
        defer { rig.gathering.cancel() }

        // A device plugged in already running is in use, though the one that was there never ran.
        mic.add(usb, running: true)
        #expect(await rig.told(1))
        #expect(rig.told.all == [MediaUse([.mic: [usb]])])
        #expect(rig.lines.all == ["the mic is in use (\(usb))"])

        // Mid-call: the one that ran stops, which starts the wait, and another is plugged in running, which ends it.
        mic.stop(usb)
        #expect(await rig.waiting())
        mic.add("com.example.meeting", running: true)
        #expect(await rig.told(2))
        #expect(rig.told.all.last == MediaUse([.mic: ["com.example.meeting"]]))
        #expect(await waitUntil { rig.clock.sleeperCount == 0 }, "the wait ended: something is running")
        #expect(await rig.tracker.current().isInUse)
    }

    @Test func eachChangeIsSaidOnceWithTheKindAndTheDevice() async throws {
        let mic = FakeMediaReader(.mic, devices: [Self.mic: false])
        let camera = FakeMediaReader(.camera, devices: [Self.camera: false])
        let rig = await rig([mic, camera])
        defer { rig.gathering.cancel() }

        mic.start(Self.mic)
        #expect(await rig.told(1))
        camera.start(Self.camera)
        #expect(await rig.told(2))
        #expect(rig.told.all.last == MediaUse([.mic: [Self.mic], .camera: [Self.camera]]))

        // Both stop, close together: one line for the two, said when the delay is up.
        mic.stop(Self.mic)
        camera.stop(Self.camera)
        #expect(await rig.waiting())
        rig.clock.advance(by: MediaUseTracker.offDelay)
        #expect(await rig.told(3))
        #expect(rig.lines.all == ["the mic is in use (\(Self.mic))", "the camera is in use (\(Self.camera))",
                                  "the mic and camera are no longer in use"])
        #expect(MediaUse.changeLines(from: .idle, to: MediaUse([.mic: [Self.mic], .camera: [Self.camera]]))
                == ["the mic and camera are in use (\(Self.mic), \(Self.camera))"])
        #expect(MediaUse.changeLines(from: .idle, to: .idle).isEmpty)
    }

    @Test func aChangeNoReaderSignalledIsFoundWhenTheDelayIsUp() async throws {
        let mic = FakeMediaReader(.mic, devices: [Self.mic: true])
        let rig = await rig([mic])
        defer { rig.gathering.cancel() }
        mic.stop(Self.mic)
        #expect(await rig.waiting())

        // The device runs again, and the listener never said.
        mic.quietly(Self.mic, running: true)
        rig.clock.advance(by: MediaUseTracker.offDelay)
        #expect(await waitUntil { rig.clock.sleeperCount == 0 })
        #expect(await rig.tracker.current().isInUse, "the readers are read once more before the use is taken as over")
        #expect(rig.lines.all == ["the mic is in use (\(Self.mic))"])
    }

    @Test func diagnosticsSaysWhichKindsAreInUseAndNamesNoDevice() {
        #expect(MediaUse.idle.diagnosticsLine == "Neither the mic nor the camera is in use.")
        #expect(MediaUse([.mic: [Self.mic]]).diagnosticsLine == "The mic is in use.")
        #expect(MediaUse([.camera: [Self.camera]]).diagnosticsLine == "The camera is in use.")
        let both = MediaUse([.mic: [Self.mic], .camera: [Self.camera]])
        #expect(both.diagnosticsLine == "The mic and camera are in use.")
        #expect(!both.diagnosticsLine.contains(Self.mic) && !both.diagnosticsLine.contains(Self.camera))
    }
}
