import Synchronization

/// The displays as of the last time something read them, for code that runs off the main actor: `DisplayLayout.current()`
/// can only be read on the main actor, so the app reads it there when the screens change and puts it here.
public final class DisplayLayoutSource: Sendable {
    private let layout: Mutex<DisplayLayout>

    public init(_ layout: DisplayLayout = DisplayLayout(displays: [])) {
        self.layout = Mutex(layout)
    }

    public var current: DisplayLayout {
        layout.withLock { $0 }
    }

    public func set(_ layout: DisplayLayout) {
        self.layout.withLock { $0 = layout }
    }
}
