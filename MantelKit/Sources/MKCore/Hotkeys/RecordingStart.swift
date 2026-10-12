/// When the global hotkeys are put aside for a shortcut recording: **only once Mantel is the active app**.
///
/// A recording hears keys through a local monitor, which hears only the active app's. It is started by a press that may come while another
/// app is in front (an assistive tool pressing the field), so Mantel is asked to become active first, and macOS may not grant it. The
/// hotkeys were put aside at the start whatever came of that, and a refused request left every one of them unregistered, with a recording
/// that hears nothing, until the person clicked. So the hotkeys wait for Mantel to be active, and a recording that never gets there ends
/// without having touched them.
///
/// The app feeds it what happens and does what it answers.
public struct RecordingStart: Sendable, Equatable {
    /// How long a recording waits for Mantel to become active (`waitedLongEnough` is what happens when it has).
    public static let activationWait: Duration = .seconds(1)

    /// What the app does.
    public enum Step: Sendable, Equatable {
        /// Put the hotkeys aside: the recording can hear.
        case putHotkeysAside
        /// End the recording: Mantel never became active, and nothing was put aside.
        case giveUp
        /// Nothing now.
        case nothing
    }

    private enum Phase: Sendable, Equatable {
        case notRecording
        /// Started while another app was in front: waiting for Mantel to become active.
        case waiting
        /// Active, and the hotkeys are aside.
        case listening
    }

    private var phase = Phase.notRecording

    public init() {}

    /// Whether the hotkeys are aside.
    public var hotkeysAreAside: Bool { phase == .listening }

    /// Whether a recording is under way, listening or still waiting to be able to.
    public var isRecording: Bool { phase != .notRecording }

    /// A recording starts, with Mantel active or not as it does.
    public mutating func began(mantelIsActive: Bool) -> Step {
        guard phase == .notRecording else { return .nothing }
        if mantelIsActive {
            phase = .listening
            return .putHotkeysAside
        }
        phase = .waiting
        return .nothing
    }

    /// Mantel became the active app.
    public mutating func mantelBecameActive() -> Step {
        guard phase == .waiting else { return .nothing }
        phase = .listening
        return .putHotkeysAside
    }

    /// `activationWait` has passed.
    public mutating func waitedLongEnough() -> Step {
        guard phase == .waiting else { return .nothing }
        phase = .notRecording
        return .giveUp
    }

    /// The recording ended, in whatever way. Returns whether the hotkeys are to be put back: they are only if they were put aside.
    public mutating func ended() -> Bool {
        let wereAside = phase == .listening
        phase = .notRecording
        return wereAside
    }
}
