import Foundation

/// What showing one of Mantel's windows does, and in what order, so that the window comes to the front on the first try.
///
/// The window of a menu bar app that is asked for from a menu used to take two or three tries: it was ordered front before Mantel was
/// active, from inside the menu's tracking, and an app that is only an accessory isn't always allowed to become active. So, in this order:
/// 1. **Mantel becomes an ordinary app** (`becomeRegular`), at once: a Dock icon and a place in ⌘-Tab, which is also what lets macOS
///    activate it.
/// 2. **The rest waits for the next turn of the main queue** (`later`), when called from a menu's action: the menu has finished
///    tracking then, and activating from inside it is what failed.
/// 3. **Mantel is asked to become the active app** (`activate`).
/// 4. **The window is made key and ordered front** (`makeKeyAndOrderFront`).
/// 5. **If Mantel still isn't active once the request has been made** (`isActive`: activation can take a moment, and may not be
///    granted), the window is ordered front regardless (`orderFrontRegardless`), so that it is at least on top.
@MainActor
public struct WindowShowing {
    private let becomeRegular: @MainActor () -> Void
    private let later: @MainActor (@escaping @MainActor () -> Void) -> Void
    private let activate: @MainActor () -> Void
    private let isActive: @MainActor () -> Bool
    private let makeKeyAndOrderFront: @MainActor () -> Void
    private let orderFrontRegardless: @MainActor () -> Void

    /// - Parameters:
    ///   - becomeRegular: makes Mantel an ordinary app, for the window that is being shown.
    ///   - later: runs what it is given on the next turn of the main queue, and not before.
    ///   - activate: asks for Mantel to be the active app.
    ///   - isActive: whether Mantel is the active app now.
    ///   - makeKeyAndOrderFront: brings the window back from the Dock if it was put there, makes it the key window and orders it front.
    ///   - orderFrontRegardless: orders the window front even though Mantel isn't the active app.
    public init(becomeRegular: @escaping @MainActor () -> Void,
                later: @escaping @MainActor (@escaping @MainActor () -> Void) -> Void,
                activate: @escaping @MainActor () -> Void,
                isActive: @escaping @MainActor () -> Bool,
                makeKeyAndOrderFront: @escaping @MainActor () -> Void,
                orderFrontRegardless: @escaping @MainActor () -> Void) {
        self.becomeRegular = becomeRegular
        self.later = later
        self.activate = activate
        self.isActive = isActive
        self.makeKeyAndOrderFront = makeKeyAndOrderFront
        self.orderFrontRegardless = orderFrontRegardless
    }

    public func show() {
        becomeRegular()
        let activate = activate, isActive = isActive
        let makeKeyAndOrderFront = makeKeyAndOrderFront, orderFrontRegardless = orderFrontRegardless
        later {
            activate()
            makeKeyAndOrderFront()
            if !isActive() { orderFrontRegardless() }
        }
    }
}
