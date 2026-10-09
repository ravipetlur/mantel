import Foundation

/// Reads where a permission stands. It only reads: it never asks, and never shows a prompt. The buttons that ask are in
/// the Permissions pane.
///
/// The app's `LivePermissionChecker` asks the system; tests and previews give the pane a checker of their own.
public protocol PermissionChecking: Sendable {
    func state(of kind: PermissionKind) async -> PermissionState
}
