/// What Diagnostics and Settings tell the person about how hiding with each engine behaves on macOS.
public enum EngineNotes {
    /// What the allowlist takes along with the icons it hides: macOS lets go of these items for any app that isn't on the list.
    public static let sideEffects = "While icons are hidden with the allowlist, macOS also hides Now Playing, Focus, Live Activities, AirDrop and the microphone and camera indicator."

    /// What the clock and Control Center do to the allowlist while it is held.
    public static let clockNote = "Clicking the clock or Control Center shows every icon until what it opens closes."

    /// How long a crash leaves icons hidden.
    public static let crashNote = "After a crash, hidden icons take about 5 seconds to come back."
}
