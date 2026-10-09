import ApplicationServices
import AVFoundation
import CoreBluetooth
import CoreGraphics
import CoreLocation
import EventKit
import Foundation
import MKCore

/// Reads where each permission stands from the system. It only reads: nothing here asks for a permission or shows a
/// prompt (the buttons that ask are in the Permissions pane), and nothing starts a service: Bluetooth and Location are
/// read from their authorization status, without a manager that would begin scanning or locating.
///
/// Nothing in it needs the main actor, except the location manager, which is made and read there. The app's target is
/// on the main actor by default, so the class is marked `nonisolated` and the one method `@concurrent`: a read of the
/// system's state is never what makes the interface wait.
nonisolated final class LivePermissionChecker: PermissionChecking {
    private let grants: FileGrantStore

    init(grants: FileGrantStore) {
        self.grants = grants
    }

    @concurrent
    func state(of kind: PermissionKind) async -> PermissionState {
        switch kind {
        // These three only say whether access is on, so "off" is "not decided" (see `PermissionState`).
        case .accessibility:
            AXIsProcessTrusted() ? .granted : .notDetermined
        case .screenRecording:
            CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        case .inputMonitoring:
            CGPreflightListenEventAccess() ? .granted : .notDetermined
        case .microphone:
            Self.state(of: AVCaptureDevice.authorizationStatus(for: .audio))
        case .calendars:
            Self.state(of: EKEventStore.authorizationStatus(for: .event))
        case .location:
            await MainActor.run { Self.state(of: CLLocationManager().authorizationStatus) }
        case .bluetooth:
            Self.state(of: CBManager.authorization)
        case .menuBarLayoutFile, .controlCenterFile:
            await fileGrantState(of: kind)
        case .fullDiskAccess:
            // The system has no public check for it.
            .unknown
        }
    }

    /// Granted if a file was chosen and is still where it was chosen. A grant whose file has gone is as good as none: the
    /// person has to choose again.
    private func fileGrantState(of kind: PermissionKind) async -> PermissionState {
        guard let grantKind = kind.fileGrantKind, let grant = await grants.grant(for: grantKind) else {
            return .notDetermined
        }
        return FileManager.default.fileExists(atPath: grant.path) ? .granted : .notDetermined
    }

    // MARK: The system's own states, in ours

    private static func state(of status: AVAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .unknown
        }
    }

    /// Full access is what reading meetings needs; write-only access (which can add events but not read any) is not it.
    private static func state(of status: EKAuthorizationStatus) -> PermissionState {
        switch status {
        case .fullAccess: .granted
        case .writeOnly, .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .unknown
        }
    }

    private static func state(of status: CLAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .unknown
        }
    }

    private static func state(of status: CBManagerAuthorization) -> PermissionState {
        switch status {
        case .allowedAlways: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .unknown
        }
    }
}
