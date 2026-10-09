import AppKit
import SwiftUI

/// The SwiftUI content of a window that is kept after it is closed, and lives only while the window is open.
///
/// A closed window is ordered out, not destroyed (Settings and onboarding keep their windows), and SwiftUI doesn't reliably
/// end a view's `.task` when its window is ordered out: the panes' polling loops would run on for as long as the app does.
/// Dropping the content ends them; `restore()` builds it again when the window is shown.
@MainActor
final class DroppableContent {
    let controller: NSHostingController<AnyView>
    private let make: () -> AnyView
    private var isShown = true

    init(make: @escaping () -> AnyView) {
        self.make = make
        controller = NSHostingController(rootView: make())
        // The window's size is the window's own. With the content swapped out, a size that followed it would shrink the
        // window, and the frame the system keeps for it with it.
        controller.sizingOptions = []
    }

    /// Replaces the content with nothing, which ends its tasks.
    func drop() {
        guard isShown else { return }
        controller.rootView = AnyView(EmptyView())
        isShown = false
    }

    /// Builds the content again if it was dropped.
    func restore() {
        guard !isShown else { return }
        controller.rootView = make()
        isShown = true
    }
}
