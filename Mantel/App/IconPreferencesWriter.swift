import MKCore
import MKLayout

/// The one writer of `icons.json` (what the person tells Mantel about individual icons), which the coordinator owns: the Layout editor's
/// changes and the Hotkeys page's go through it. It makes the changes one after another, each on the file as it is when its turn comes, so
/// that two quick ones never lose each other.
@MainActor
final class IconPreferencesWriter {
    private var last: Task<IconPreferences, Never>?

    /// Queues `change`, made on the file as it is when the changes before it are saved; `saved` is called with what was saved, in the order
    /// of the changes. The task's value is the same.
    @discardableResult
    func update(in store: SettingsStore, _ change: @escaping @Sendable (inout IconPreferences) -> Void,
                saved: (@MainActor (IconPreferences) -> Void)? = nil) -> Task<IconPreferences, Never> {
        let previous = last
        let task = Task {
            _ = await previous?.value
            var preferences = await store.load(IconPreferences.self)
            change(&preferences)
            await store.save(preferences)
            saved?(preferences)
            return preferences
        }
        last = task
        return task
    }
}
