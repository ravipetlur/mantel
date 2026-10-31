import Foundation
import MKCore

/// Whether the mic or camera is in use, as the readers say it, steadied so that a pause in a call doesn't change how icons are hidden.
///
/// - **In use turns on at once:** the moment a reader says a device is running.
/// - **It turns off only after `offDelay` (10 seconds) with nothing running.** A device switch, or a short stop in the middle of a call,
///   leaves it on: whatever runs again within the delay ends the wait, and the next stop starts a whole delay over. When the delay is up the
///   readers are read once more, so that a change that was missed can't leave it on.
/// - **Each change is said once in the log** (`[media]`), naming the kind and the apps or cameras: "the mic is in use (us.zoom.xos)",
///   "the mic and camera are no longer in use". A pause that ends within the delay says nothing.
///
/// It listens to the readers from the first time it is asked, and reads them again at each signal they give.
public actor MediaUseTracker: MediaUseSource {
    /// How long nothing has to be running before the use is taken as over.
    public static let offDelay: Duration = .seconds(10)

    private let readers: [any MediaUseReading]
    private let clock: any Clock
    private let offDelay: Duration
    private let note: @Sendable (String) -> Void

    private var isWatching = false
    private var listeners: [Task<Void, Never>] = []
    /// The use as the tracker says it: what the readers said the last time something was running, until the delay is up.
    private var lit = MediaUse.idle
    /// The wait for the delay, while nothing is running and the use is on. `timerNumber` tells a wait that was ended from one that went on.
    private var offTimer: Task<Void, Never>?
    private var timerNumber = 0
    private var subscribers: [Int: AsyncStream<MediaUse>.Continuation] = [:]
    private var nextSubscriber = 0

    public init(readers: [any MediaUseReading], clock: any Clock) {
        self.init(readers: readers, clock: clock, offDelay: Self.offDelay, note: { Log.info("media", $0) })
    }

    init(readers: [any MediaUseReading], clock: any Clock, offDelay: Duration, note: @escaping @Sendable (String) -> Void) {
        self.readers = readers
        self.clock = clock
        self.offDelay = offDelay
        self.note = note
    }

    deinit {
        offTimer?.cancel()
        for listener in listeners { listener.cancel() }
        for continuation in subscribers.values { continuation.finish() }
    }

    // MARK: The source

    public func current() -> MediaUse {
        watchIfNeeded()
        return lit
    }

    public func changes() -> AsyncStream<MediaUse> {
        watchIfNeeded()
        let (stream, continuation) = AsyncStream.makeStream(of: MediaUse.self, bufferingPolicy: .unbounded)
        nextSubscriber += 1
        let id = nextSubscriber
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.dropSubscriber(id) }
        }
        return stream
    }

    private func dropSubscriber(_ id: Int) {
        subscribers[id] = nil
    }

    // MARK: Watching

    /// Listens to each reader, and only then reads them, so that no change falls between: the use now is lit at once.
    private func watchIfNeeded() {
        guard !isWatching else { return }
        isWatching = true
        for reader in readers {
            let signals = reader.changes()
            listeners.append(Task { [weak self] in
                for await _ in signals { await self?.readersChanged() }
            })
        }
        light(reading())
    }

    private func reading() -> MediaUse {
        var devices: [MediaKind: [String]] = [:]
        for reader in readers { devices[reader.kind, default: []] += reader.runningDevices() }
        return MediaUse(devices)
    }

    /// A reader said something may have changed. Something running is the use, at once, and ends any wait; nothing running starts the wait
    /// if the use is on and it isn't started (a second stop in the wait doesn't start it over).
    private func readersChanged() {
        let seen = reading()
        if seen.isInUse {
            endWait()
            light(seen)
        } else if lit.isInUse, offTimer == nil {
            startWait()
        }
    }

    private func startWait() {
        timerNumber += 1
        let number = timerNumber
        offTimer = Task { [weak self, clock, offDelay] in
            do { try await clock.sleep(for: offDelay) } catch { return }
            await self?.waitIsOver(number)
        }
    }

    private func endWait() {
        offTimer?.cancel()
        offTimer = nil
        timerNumber += 1
    }

    /// The delay passed with nothing running (a wait that was ended meanwhile is `number`s behind, and does nothing). The readers are read
    /// once more: what they say now is the use, which is idle unless a change was missed.
    private func waitIsOver(_ number: Int) {
        guard number == timerNumber, offTimer != nil else { return }
        offTimer = nil
        light(reading())
    }

    /// Makes `use` the use, and says so in the log and to every stream, unless it is the one that is.
    private func light(_ use: MediaUse) {
        guard use != lit else { return }
        for line in MediaUse.changeLines(from: lit, to: use) { note(line) }
        lit = use
        for continuation in subscribers.values { continuation.yield(use) }
    }
}
