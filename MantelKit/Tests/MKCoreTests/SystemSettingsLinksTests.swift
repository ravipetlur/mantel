import Foundation
import Testing

@testable import MKCore

@Suite("SystemSettingsLinks", .timeLimit(.minutes(2)))
struct SystemSettingsLinksTests {
    private static let privacyPane = "x-apple.systempreferences:com.apple.preference.security?"

    @Test func settingsLinksOpenTheRightPrivacyPane() {
        #expect(SystemSettingsLinks.privacy(.screenRecording)?.absoluteString == "\(Self.privacyPane)Privacy_ScreenCapture")
        #expect(SystemSettingsLinks.privacy(.microphone)?.absoluteString.hasSuffix("?Privacy_Microphone") == true)
        #expect(SystemSettingsLinks.privacy(.accessibility)?.absoluteString.hasSuffix("?Privacy_Accessibility") == true)
    }

    @Test func theOtherPermissionsHaveTheirPanes() {
        #expect(SystemSettingsLinks.privacy(.inputMonitoring)?.absoluteString == "\(Self.privacyPane)Privacy_ListenEvent")
        #expect(SystemSettingsLinks.privacy(.calendars)?.absoluteString == "\(Self.privacyPane)Privacy_Calendars")
        #expect(SystemSettingsLinks.privacy(.location)?.absoluteString == "\(Self.privacyPane)Privacy_LocationServices")
        #expect(SystemSettingsLinks.privacy(.bluetooth)?.absoluteString == "\(Self.privacyPane)Privacy_Bluetooth")
        #expect(SystemSettingsLinks.privacy(.fullDiskAccess)?.absoluteString == "\(Self.privacyPane)Privacy_AllFiles")
    }

    @Test func theFileGrantsHaveNoPane() {
        #expect(SystemSettingsLinks.privacy(.menuBarLayoutFile) == nil)
        #expect(SystemSettingsLinks.privacy(.controlCenterFile) == nil)
    }

    @Test func everyPrivacyLinkIsAnotherAnchorOnTheSamePane() {
        let anchors = PermissionKind.allCases.compactMap { SystemSettingsLinks.privacy($0)?.absoluteString }
        #expect(anchors.count == 8)
        #expect(anchors.allSatisfy { $0.hasPrefix(Self.privacyPane) })
        #expect(Set(anchors).count == anchors.count, "no two permissions share an anchor")
    }

    @Test func theKeyboardLink() {
        #expect(SystemSettingsLinks.keyboard.absoluteString == "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
    }
}
