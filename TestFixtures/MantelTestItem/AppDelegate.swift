import AppKit

/// MantelTestItem: a menu-bar-only app with status items of its own, for Mantel's probes to hide, show, move and click, so that they never
/// have to touch the person's own apps. It does nothing else.
///
/// - **Items one and two** are `mantel.fixture.one` and `mantel.fixture.two` (their autosave names, which is what the menu bar layout keeps
///   their places under), drawn as the symbols `1.circle` and `2.circle`. They have no `menu` of their own: each sends its action when the
///   mouse goes up, with either button, and writes what it was to the click log (`ClickLog`). Item one then opens its menu the way a dot of
///   Mantel's does (it is given the menu and clicked, and has it taken away when it closes); item two opens a popover with its name.
/// - **`--extra N`** (1 to 20) adds items `mantel.fixture.extra.<n>`, drawn as `<n>.square`, each with a plain `menu` of one item, as most apps'
///   items have. They write no click log. Each is a little wider than the one before, so that the bar can tell their slots apart.
/// - **A notification** named for the test item's bundle ID and `toggle-extra-1` hides the first extra item, or shows it again.
/// - **`--single`** has item one alone.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var items: [NSStatusItem] = []
    private var oneItem: NSStatusItem?
    private var extras: [Int: NSStatusItem] = [:]
    private let clickLog = ClickLog()
    private let menuForOne = NSMenu()
    private let popover = NSPopover()
    /// Set while item one is being given its menu: the action it sends meanwhile is no click.
    private var isOpeningMenu = false

    /// The most extra items, and the width each is wider than the one before, in points.
    private static let maximumExtras = 20
    private static let extraWidthStep: CGFloat = 2

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // macOS 27 can quit an accessory app that has no windows open; the items have to stay.
        ProcessInfo.processInfo.disableAutomaticTermination("MantelTestItem keeps its status items")
        ProcessInfo.processInfo.disableSuddenTermination()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        let single = arguments.contains("--single")

        let one = makeItem(autosaveName: "mantel.fixture.one", symbol: "1.circle", title: "Fixture item one", length: NSStatusItem.squareLength)
        configureClicks(of: one, action: #selector(oneClicked(_:)))
        oneItem = one
        items = [one]
        menuForOne.autoenablesItems = false
        menuForOne.delegate = self
        menuForOne.addItem(withTitle: "Fixture item one", action: nil, keyEquivalent: "").isEnabled = true
        menuForOne.addItem(.separator())
        menuForOne.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        guard !single else { return }
        // A little wider than the first, so that their slots in the bar can be told apart.
        let two = makeItem(autosaveName: "mantel.fixture.two", symbol: "2.circle", title: "Fixture item two",
                           length: NSStatusBar.system.thickness + Self.extraWidthStep)
        configureClicks(of: two, action: #selector(twoClicked(_:)))
        items.append(two)
        configurePopover()

        let count = Self.extraCount(in: arguments)
        for number in stride(from: 1, through: count, by: 1) {
            let length = NSStatusBar.system.thickness + Self.extraWidthStep * CGFloat(number + 1)
            let extra = makeItem(autosaveName: "mantel.fixture.extra.\(number)", symbol: "\(number).square", title: "Fixture extra \(number)", length: length)
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.addItem(withTitle: "Fixture extra \(number)", action: nil, keyEquivalent: "").isEnabled = true
            extra.menu = menu
            extras[number] = extra
        }

        // Told by a notification that carries the test item's own bundle ID, which a probe sends to hide the first extra item and show it again.
        let name = Notification.Name("\(Bundle.main.bundleIdentifier ?? "com.example.mantel.testitem").toggle-extra-1")
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(toggleExtraOne(_:)), name: name, object: nil,
                                                            suspensionBehavior: .deliverImmediately)
    }

    // MARK: Items

    private func makeItem(autosaveName: String, symbol: String, title: String, length: CGFloat) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: length)
        item.autosaveName = autosaveName
        // macOS 27 doesn't give Accessibility the autosave name, so the button carries it as its identifier: it is how Mantel's reads,
        // and the probes, tell the items apart.
        item.button?.setAccessibilityIdentifier(autosaveName)
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        item.button?.setAccessibilityLabel(title)
        return item
    }

    /// The item sends its action when either mouse button goes up, and has no menu: a status item that has one opens it on every click and
    /// sends nothing.
    private func configureClicks(of item: NSStatusItem, action: Selector) {
        item.menu = nil
        guard let button = item.button else { return }
        button.target = self
        button.action = action
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// How many extra items the arguments ask for: `--extra N` or `--extra=N`, from 1 to 20; none when there is no such argument, or N isn't
    /// a number.
    private static func extraCount(in arguments: [String]) -> Int {
        var text: String?
        if let index = arguments.firstIndex(of: "--extra"), arguments.indices.contains(index + 1) {
            text = arguments[index + 1]
        } else if let argument = arguments.first(where: { $0.hasPrefix("--extra=") }) {
            text = String(argument.dropFirst("--extra=".count))
        }
        guard let text, let count = Int(text) else { return 0 }
        return min(max(count, 0), maximumExtras)
    }

    // MARK: Clicks

    /// Writes what the click was: the kind comes from the event the action was sent for, which counts only when it is a mouse-up on this
    /// item's own window that was dispatched a moment ago (the app's current event is the last one it saw, and a press comes with none of its
    /// own). `ClickEventRule` decides.
    private func recordClick(item name: String, from sender: NSStatusBarButton) {
        let last = NSApp.currentEvent.map { event -> ClickEventRule.LastEvent in
            let button: ClickEventRule.LastEvent.Button? = switch event.type {
            case .leftMouseUp: .left
            case .rightMouseUp: .right
            default: nil
            }
            return ClickEventRule.LastEvent(mouseUp: button, isOptionHeld: event.modifierFlags.contains(.option),
                                            isOnTheItem: event.window === sender.window,
                                            age: ProcessInfo.processInfo.systemUptime - event.timestamp)
        }
        clickLog.write(item: name, kind: ClickEventRule.kind(of: last))
    }

    @objc private func oneClicked(_ sender: NSStatusBarButton) {
        // The menu is being asked for, and the system sent the action in the middle of it: that is no click.
        guard !isOpeningMenu else { return }
        recordClick(item: "one", from: sender)
        isOpeningMenu = true
        defer { isOpeningMenu = false }
        // Given the menu for as long as it is open, and clicked: the system puts it under the item.
        oneItem?.menu = menuForOne
        sender.performClick(nil)
    }

    /// The item's menu is taken away on the next turn of the main queue, not here: the item that was chosen has its action sent as the menu
    /// closes.
    func menuDidClose(_ menu: NSMenu) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.oneItem?.menu = nil }
        }
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 200, height: 80)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        let label = NSTextField(labelWithString: "Fixture item two")
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)
        NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                                     label.centerYAnchor.constraint(equalTo: content.centerYAnchor)])
        let controller = NSViewController()
        controller.view = content
        popover.contentViewController = controller
    }

    @objc private func twoClicked(_ sender: NSStatusBarButton) {
        recordClick(item: "two", from: sender)
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }

    // MARK: Told what to do

    @objc private func toggleExtraOne(_ notification: Notification) {
        guard let first = extras[1] else { return }
        first.isVisible.toggle()
    }
}
