import AppKit

// The app starts here. `NSApplication.delegate` is weak, so the delegate is kept in this top-level constant.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
