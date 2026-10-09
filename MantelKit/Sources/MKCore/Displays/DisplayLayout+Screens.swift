import AppKit

extension DisplayLayout {
    /// The displays connected now, read from `NSScreen.screens`. The app calls it again whenever
    /// `NSApplication.didChangeScreenParametersNotification` arrives.
    @MainActor
    public static func current() -> DisplayLayout {
        DisplayLayout(displays: NSScreen.screens.compactMap(DisplayInfo.init(screen:)))
    }
}

extension DisplayInfo {
    /// What `NSScreen` and CoreGraphics say about one screen. A screen without a display number can't be told apart
    /// from the others or asked about, so it isn't a display here (AppKit gives every screen one).
    @MainActor
    fileprivate init?(screen: NSScreen) {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        let id = CGDirectDisplayID(number.uint32Value)
        self.init(
            uuid: Self.uuid(ofDisplay: id),
            name: screen.localizedName,
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            scale: screen.backingScaleFactor,
            notch: Self.notchRect(frame: screen.frame, safeAreaTop: screen.safeAreaInsets.top,
                                  auxiliaryTopLeft: screen.auxiliaryTopLeftArea,
                                  auxiliaryTopRight: screen.auxiliaryTopRightArea),
            isBuiltIn: CGDisplayIsBuiltin(id) != 0,
            isMain: screen.frame.origin == .zero)
    }

    /// The display's UUID. If CoreGraphics can't make one, the display ID stands in: it only lasts until the next
    /// restart, so a layout saved under it isn't found again, which is the safe way to fail.
    private static func uuid(ofDisplay id: CGDirectDisplayID) -> String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return "display-\(id)" }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
