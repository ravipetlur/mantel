import AppKit
import MKCore
import MKSearch

/// The window the command bar is shown in: a sibling of `FloatingBarPanel` with the same rules (it floats above the menu bar's windows on
/// every Space, is kept out of screenshots and screen shares, and never makes Mantel the active app), and always key, so that it takes
/// what is typed.
///
/// - **Keys come here first.** `sendEvent` offers each key press to `keyHandler` before the search field sees it, so that ↑, ↓, Esc and
///   the Return variants are the command bar's and everything else is typed.
/// - **Editing keys are handled here too** (`performKeyEquivalent`): ⌘V, ⌘C, ⌘X, ⌘A, ⌘Z and ⇧⌘Z are the Edit menu's key equivalents, and
///   Mantel has no Edit menu while it is a menu bar app with no window open, so nothing else would carry them to the field.
/// - **Losing key closes it** (`resignedKey`).
/// - **Nothing here calls `NSApp.activate`.** Ordering the panel out gives the key back to the front app's window.
final class CommandBarPanel: NSPanel {
    /// Offered every key press; true when it was the command bar's and goes no further.
    var keyHandler: (NSEvent) -> Bool = { _ in false }
    /// The panel lost key.
    var resignedKey: () -> Void = {}

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        level = FloatingBarPanel.panelLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isMovable = false
        isMovableByWindowBackground = false
        animationBehavior = .utilityWindow
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        sharingType = .none
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        titleVisibility = .hidden
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler(event) { return }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = ModifierSet(cocoaFlags: event.modifierFlags.rawValue)
        // What ⌘ makes comes first: on a layout that doesn't type Latin letters it is the Latin one the Edit menu would match, while the
        // key without its modifiers is the layout's own letter.
        if event.type == .keyDown,
           let editing = CommandBarKeys.editing(characters: event.characters ?? "", modifiers: modifiers)
               ?? CommandBarKeys.editing(characters: event.charactersIgnoringModifiers ?? "", modifiers: modifiers),
           let responder = firstResponder, responder.tryToPerform(Self.selector(for: editing), with: self) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// What the Edit menu sends for each of them, to whatever has the focus (the field editor).
    private static func selector(for editing: CommandBarEditing) -> Selector {
        switch editing {
        case .undo: Selector(("undo:"))
        case .redo: Selector(("redo:"))
        case .cut: #selector(NSText.cut(_:))
        case .copy: #selector(NSText.copy(_:))
        case .paste: #selector(NSText.paste(_:))
        case .selectAll: #selector(NSText.selectAll(_:))
        }
    }

    override func resignKey() {
        super.resignKey()
        resignedKey()
    }
}
