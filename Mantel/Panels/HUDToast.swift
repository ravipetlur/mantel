import AppKit
import MKCore
import MKLayout
import SwiftUI

/// A short confirmation or failure near the pointer that needs no action: a capsule of material with an SF Symbol and one line of text.
/// It takes no clicks (they go to what is under it), isn't key, isn't in screenshots, and goes by itself after 1.5 seconds with a
/// quarter of a second's fade (none with Reduce Motion). A new toast replaces the one on the screen.
@MainActor
enum HUDToast {
    private static let shownFor: Duration = .milliseconds(1500)
    private static let fadeSeconds: TimeInterval = 0.25

    private static var panel: NSPanel?
    private static var dismissal: Task<Void, Never>?

    static func show(symbol: String, text: String) {
        dismissal?.cancel()
        panel?.orderOut(nil)

        let hosting = NSHostingView(rootView: ToastView(symbol: symbol, text: text))
        let size = hosting.fittingSize
        let toast = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered,
                            defer: true)
        toast.level = .statusBar
        toast.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        toast.sharingType = .none
        toast.ignoresMouseEvents = true
        toast.hidesOnDeactivate = false
        toast.isReleasedWhenClosed = false
        toast.isOpaque = false
        toast.backgroundColor = .clear
        toast.hasShadow = true
        toast.animationBehavior = .none
        toast.contentView = hosting

        let displays = DisplayLayout.current()
        let pointer = NSEvent.mouseLocation
        if let screen = displays.display(containing: pointer) ?? displays.main {
            let frame = PanelMath.toastFrame(size: size, pointer: displays.cgPoint(fromAppKit: pointer),
                                             screen: displays.cgRect(fromAppKit: screen.frame))
            toast.setFrame(displays.appKitRect(fromCG: frame), display: true)
        }
        toast.alphaValue = 1
        toast.orderFrontRegardless()
        panel = toast
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])

        dismissal = Task {
            do { try await SystemClock().sleep(for: shownFor) } catch { return }
            fadeOut(toast)
        }
    }

    private static func fadeOut(_ toast: NSPanel) {
        guard toast === panel else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            finish(toast)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fadeSeconds
            toast.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { finish(toast) }
        }
    }

    private static func finish(_ toast: NSPanel) {
        toast.orderOut(nil)
        if toast === panel { panel = nil }
    }
}

private struct ToastView: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
            Text(text).font(.headline).lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .fixedSize()
    }
}
