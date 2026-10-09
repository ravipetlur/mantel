import Testing

@testable import MKCore

@Suite("PermissionBadge")
struct PermissionBadgeTests {
    /// Where macOS only says whether access is on, so "off" is "not decided" (see `PermissionState`).
    private static let onOffOnly: [PermissionKind] = [.accessibility, .screenRecording, .inputMonitoring]
    private static let others = PermissionKind.allCases.filter { !onOffOnly.contains($0) }

    @Test(arguments: PermissionKind.allCases)
    func grantedIsGreen(kind: PermissionKind) {
        #expect(PermissionBadge.make(state: .granted, kind: kind) == PermissionBadge(title: "Granted", tone: .good))
    }

    @Test(arguments: onOffOnly)
    func offIsNotGrantedWhereTheSystemCannotSayDenied(kind: PermissionKind) {
        #expect(PermissionBadge.make(state: .notDetermined, kind: kind) == PermissionBadge(title: "Not granted", tone: .warning))
    }

    @Test(arguments: others)
    func notDecidedIsNotAskedYetElsewhere(kind: PermissionKind) {
        #expect(PermissionBadge.make(state: .notDetermined, kind: kind) == PermissionBadge(title: "Not asked yet", tone: .warning))
    }

    @Test(arguments: PermissionKind.allCases)
    func deniedIsNotGranted(kind: PermissionKind) {
        #expect(PermissionBadge.make(state: .denied, kind: kind) == PermissionBadge(title: "Not granted", tone: .warning))
    }

    @Test(arguments: PermissionKind.allCases)
    func unknownIsGrey(kind: PermissionKind) {
        #expect(PermissionBadge.make(state: .unknown, kind: kind) == PermissionBadge(title: "Unknown", tone: .neutral))
    }
}
