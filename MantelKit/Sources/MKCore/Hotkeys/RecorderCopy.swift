/// What the shortcut recorder says to the accessibility tools while it listens.
///
/// It is said as an announcement, when the recording can hear, and not as a label on the field that listens: SwiftUI's accessibility looped
/// without end (a stack overflow in the app) while it resolved a `Text` that had a label of its own in a row whose title was linked to it,
/// so the listening field carries none. The title isn't linked to the field now: VoiceOver reads it as the field's neighbour, so the
/// announcement names the action.
public enum RecorderCopy {
    /// Said when a recording can hear, for `action` (the action's title, which is also the row's title).
    public static func announcement(for action: String) -> String {
        "Recording a shortcut for \(action). Press the new shortcut, Delete to remove it, or Escape to cancel."
    }

    /// Said when a recording ends because Mantel never became the active app, so that it couldn't hear a key.
    public static let couldntComeToTheFront = "Mantel couldn't come to the front, so no shortcut was recorded."
}
