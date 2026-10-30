import AppKit
import MKCore
import MKLayout

/// One panel of cells on the screen, and what keeps it there: the window, the monitors that close it and the watch on the app that is in
/// front. The second bar and a group's panel each have one; what is listed, where it goes and what a click does are theirs.
///
/// - **Closing.** A mouse-down outside the panel and outside every status item of Mantel's (`PanelMath.isOutsideClick`) closes it, and so
///   does another app becoming active unless a click from the panel is in flight (`PanelMath.closesOnAppSwitch`). The global monitor
///   can't swallow a click, and the local one hands the event back: the click still does what it was for.
/// - **Never activating.** Nothing here makes Mantel the active app; `makeKey` gives the panel the keyboard and no more.
@MainActor
final class BarPanelHost {
    private static let mouseDowns: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]

    let model = IconBarModel()
    private let panel: FloatingBarPanel
    private let container: BarContainerView
    private let layout: () -> DisplayLayout
    private let ownItemFrames: () -> [CGRect]
    private let clickInFlight: () -> Bool
    private let barAppearance: () -> NSAppearance?
    private let closeRequested: (PanelCloseReason) -> Void
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var activationObserver: (any NSObjectProtocol)?
    /// The activation that is not the person leaving: the app a takeover of the menu bar has just handed the focus back to, or the next
    /// app in line when Mantel stepped back instead. It is only waited for a while: an app that was in front already never announces itself.
    private var ignoredActivation: (expected: ExpectedActivation, until: Date)?

    /// - Parameters:
    ///   - layout: the displays as they are now.
    ///   - ownItemFrames: where Mantel's own status items are, in CoreGraphics global points (a click on one is never an outside click).
    ///   - clickInFlight: whether a click from a panel is being sent.
    ///   - barAppearance: how the menu bar looks (the dots' button's appearance), for a panel that follows it.
    ///   - activate: a cell was clicked, or the keyboard chose it, in this way.
    ///   - closeRequested: the panel is to close, for this reason (Esc, a click outside it, another app in front).
    init(images: ItemImages, layout: @escaping () -> DisplayLayout, ownItemFrames: @escaping () -> [CGRect],
         clickInFlight: @escaping () -> Bool, barAppearance: @escaping () -> NSAppearance?,
         activate: @escaping (Int, ClickKind) -> Void, closeRequested: @escaping (PanelCloseReason) -> Void) {
        self.layout = layout
        self.ownItemFrames = ownItemFrames
        self.clickInFlight = clickInFlight
        self.barAppearance = barAppearance
        self.closeRequested = closeRequested
        container = BarContainerView(model: model, images: images, activate: activate, close: { closeRequested(.escape) })
        panel = FloatingBarPanel(contentRect: NSRect(x: 0, y: 0, width: 16, height: 16))
        panel.contentView = container
    }

    var isVisible: Bool { panel.isVisible }

    /// The panel's frame in CoreGraphics global points.
    var frame: CGRect { layout().cgRect(fromAppKit: panel.frame) }

    // MARK: Showing

    /// Puts the panel on the screen with these cells, in this look and place (CoreGraphics global points). With `makeKey` it takes the
    /// keyboard too, without becoming the active app.
    ///
    /// - Parameter ignoringActivationOf: the activation that is about to come because a takeover of the menu bar ended as the panel opened
    ///   (Mantel handed the focus back to an app, or stepped back): it, once, doesn't close the panel.
    func show(entries: [SecondBarEntry], cells: SecondBarLayout, style: PanelStyle, frame: CGRect, makeKey: Bool,
              ignoringActivationOf expected: ExpectedActivation? = nil) {
        if let expected { ignoredActivation = (expected, Date().addingTimeInterval(PanelMath.expectedActivationWait)) }
        apply(style: style)
        model.set(entries: entries, layout: cells)
        place(frame)
        container.refreshToolTips()
        panel.orderFrontRegardless()
        if makeKey {
            panel.makeKey()
            panel.makeFirstResponder(container)
        }
        installMonitors()
    }

    /// Gives a panel that is up the keyboard, without becoming the active app.
    func makeKey() {
        guard panel.isVisible else { return }
        panel.makeKey()
        panel.makeFirstResponder(container)
    }

    /// The cells or the place changed while the panel is up.
    func update(entries: [SecondBarEntry], cells: SecondBarLayout, style: PanelStyle, frame: CGRect) {
        apply(style: style)
        model.set(entries: entries, layout: cells)
        place(frame)
        container.refreshToolTips()
    }

    /// Takes the panel off the screen and stops watching.
    func hide() {
        ignoredActivation = nil
        removeMonitors()
        panel.orderOut(nil)
    }

    private func apply(style: PanelStyle) {
        model.style = style
        panel.hasShadow = style.shadow
        panel.appearance = switch style.appearance {
        case .matchMenuBar: barAppearance()
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    private func place(_ cgFrame: CGRect) {
        panel.setFrame(layout().appKitRect(fromCG: cgFrame), display: true)
        panel.invalidateShadow()
    }

    // MARK: Monitors

    private func installMonitors() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.mouseDowns) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDown() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.mouseDowns) { [weak self] event in
            MainActor.assumeIsolated { self?.mouseDown() }
            return event
        }
        let own = NSRunningApplication.current.processIdentifier
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { self?.appActivated(pid, own: own) }
        }
    }

    private func removeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        globalMonitor = nil
        localMonitor = nil
        activationObserver = nil
    }

    private func mouseDown() {
        guard panel.isVisible else { return }
        let spot = layout().cgPoint(fromAppKit: NSEvent.mouseLocation)
        if PanelMath.isOutsideClick(spot, panel: frame, ownItemFrames: ownItemFrames()) { closeRequested(.outsideClick) }
    }

    private func appActivated(_ pid: pid_t?, own: pid_t) {
        // Mantel's own windows coming forward (Settings, say) is not the person leaving for another app.
        guard panel.isVisible, let pid, pid != own else { return }
        if let ignored = ignoredActivation {
            ignoredActivation = nil
            if PanelMath.isExpectedActivation(ignored.expected, activated: pid, now: Date(), until: ignored.until) { return }
        }
        guard PanelMath.closesOnAppSwitch(clickInFlight: clickInFlight()) else { return }
        closeRequested(.appSwitch)
    }
}
