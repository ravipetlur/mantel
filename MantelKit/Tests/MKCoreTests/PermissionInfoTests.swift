import Foundation
import Testing

@testable import MKCore

@Suite("PermissionInfo", .timeLimit(.minutes(2)))
struct PermissionInfoTests {
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

    @Test(arguments: Array(anchors))
    func theSettingsLinkUsesTheDocumentedAnchor(kind: PermissionKind, anchor: String) {
        let info = PermissionInfo.info(for: kind)
        #expect(info.settingsURL?.absoluteString == "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }

    @Test func theTwoFileGrantsHaveNoSettingsLink() {
        #expect(PermissionInfo.info(for: .menuBarLayoutFile).settingsURL == nil)
        #expect(PermissionInfo.info(for: .controlCenterFile).settingsURL == nil)
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
