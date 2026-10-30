import AppKit
import MKCore

/// The one way the app shows a modal alert or open panel: the modal loop runs from the run loop, inside no queued block or task, and the
/// code that asked awaits the answer (`ModalHandoff` says why). It looks and answers as `runModal()` does.
@MainActor
enum ModalLoop {
    /// Shows `alert` and gives the person's answer.
    @discardableResult
    static func run(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        await ModalHandoff.run(through: schedule) { alert.runModal() }
    }

    /// Shows `panel` and gives the person's answer.
    static func run(_ panel: NSOpenPanel) async -> NSApplication.ModalResponse {
        await ModalHandoff.run(through: schedule) { panel.runModal() }
    }

    private static func schedule(_ modes: [RunLoop.Mode], _ work: @escaping @Sendable () -> Void) {
        RunLoop.main.perform(inModes: modes, block: work)
    }
}
