import Foundation
import Testing

@testable import MKCore

@Suite("PermissionInfo")
struct PermissionInfoTests {
    /// The copy of the permissions table, word for word.
    private static let reasons: [PermissionKind: String] = [
        .accessibility: "Mantel reads your menu bar and clicks its icons for you.",
        .screenRecording: "Real pictures of your menu bar icons in the second bar, the command bar and Layout. Without it, app icons stand in.",
        .inputMonitoring: "Lets a modifier key on its own work as push-to-talk.",
        .microphone: "Needed for the AirPods squeeze and the level meter.",
        .calendars: "Shows your next meetings in the top shelf.",
        .location: "macOS shows Wi-Fi network names only to apps with Location.",
        .bluetooth: "Shows your AirPods and other devices' battery.",
        .menuBarLayoutFile: "Lets Mantel put your icons in the order you choose.",
        .controlCenterFile: "Keeps the mic indicator visible during calls.",
        .fullDiskAccess: "Optional: covers both files above in one step.",
    ]

    private static let titles: [PermissionKind: String] = [
        .accessibility: "Device control and data access",
        .screenRecording: "Screen Recording",
        .inputMonitoring: "Input Monitoring",
        .microphone: "Microphone",
        .calendars: "Calendars",
        .location: "Location",
        .bluetooth: "Bluetooth",
        .menuBarLayoutFile: "Menu bar layout",
        .controlCenterFile: #""Allow in the Menu Bar" list"#,
        .fullDiskAccess: "Full Disk Access",
    ]

    private static let anchors: [PermissionKind: String] = [
        .accessibility: "Privacy_Accessibility",
        .screenRecording: "Privacy_ScreenCapture",
        .inputMonitoring: "Privacy_ListenEvent",
        .microphone: "Privacy_Microphone",
        .calendars: "Privacy_Calendars",
        .location: "Privacy_LocationServices",
        .bluetooth: "Privacy_Bluetooth",
        .fullDiskAccess: "Privacy_AllFiles",
    ]

    @Test func theKindsAreTheTenInTheirDocumentedOrder() {
        #expect(PermissionKind.allCases == [
            .accessibility, .screenRecording, .inputMonitoring, .microphone, .calendars, .location, .bluetooth,
            .menuBarLayoutFile, .controlCenterFile, .fullDiskAccess,
        ])
    }

    @Test(arguments: PermissionKind.allCases)
    func everyKindHasATitleAndAReasonThatEndsWithAFullStop(kind: PermissionKind) {
        let info = PermissionInfo.info(for: kind)
        #expect(info.kind == kind)
        #expect(!info.title.isEmpty)
        #expect(!info.reason.isEmpty)
        #expect(info.reason.hasSuffix("."), "\(kind): \(info.reason)")
    }

    @Test(arguments: PermissionKind.allCases)
    func theCopyIsTheOneInTheTable(kind: PermissionKind) {
        let info = PermissionInfo.info(for: kind)
        #expect(info.reason == Self.reasons[kind])
        #expect(info.title == Self.titles[kind])
    }

    @Test func screenRecordingPurpose() {
        #expect(PermissionInfo.info(for: .screenRecording).reason
            == "Real pictures of your menu bar icons in the second bar, the command bar and Layout. Without it, app icons stand in.")
    }

    @Test func everyTitleIsDifferent() {
        let titles = PermissionKind.allCases.map { PermissionInfo.info(for: $0).title }
        #expect(Set(titles).count == titles.count)
    }

    @Test(arguments: Array(anchors))
    func theSettingsLinkUsesTheDocumentedAnchor(kind: PermissionKind, anchor: String) {
        let info = PermissionInfo.info(for: kind)
        #expect(info.settingsURL?.absoluteString == "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }

    @Test func theTwoFileGrantsHaveNoSettingsLink() {
        #expect(PermissionInfo.info(for: .menuBarLayoutFile).settingsURL == nil)
        #expect(PermissionInfo.info(for: .controlCenterFile).settingsURL == nil)
    }

    @Test func everyOtherKindHasASettingsLink() {
        for kind in PermissionKind.allCases where kind != .menuBarLayoutFile && kind != .controlCenterFile {
            #expect(PermissionInfo.info(for: kind).settingsURL != nil, "\(kind)")
        }
    }

    @Test func theLinkIsTheOneSystemSettingsLinksGives() {
        for kind in PermissionKind.allCases {
            #expect(PermissionInfo.info(for: kind).settingsURL == SystemSettingsLinks.privacy(kind), "\(kind)")
        }
    }

    @Test func theFileGrantKindsMapToTheirGrants() {
        #expect(PermissionKind.menuBarLayoutFile.fileGrantKind == .menuBarLayout)
        #expect(PermissionKind.controlCenterFile.fileGrantKind == .controlCenterApprovals)
        for kind in PermissionKind.allCases where kind != .menuBarLayoutFile && kind != .controlCenterFile {
            #expect(kind.fileGrantKind == nil, "\(kind)")
        }
    }

    @Test func kindsAndStatesAreWrittenByName() throws {
        let encoder = JSONEncoder()
        #expect(try String(decoding: encoder.encode(PermissionKind.menuBarLayoutFile), as: UTF8.self) == #""menuBarLayoutFile""#)
        #expect(try String(decoding: encoder.encode(PermissionState.notDetermined), as: UTF8.self) == #""notDetermined""#)
    }
}
