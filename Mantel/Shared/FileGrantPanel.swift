import AppKit
import MKCore
import UniformTypeIdentifiers

/// The open panel that has the person choose one of the files Mantel needs to be given (the layout file, the approvals file), and keeps it.
/// Settings › Permissions and the Layout pane's banner both use it.
@MainActor
enum FileGrantPanel {
    /// The person picks the file in an open panel that starts in its folder with its name selected, and Mantel keeps it. True when it was
    /// kept; false when the person cancelled or the file couldn't be used (an alert says why in that case).
    @discardableResult
    static func choose(_ kind: FileGrantKind, grants: FileGrantStore) async -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let expected = ExpectedFile.expected(kind, home: home)
        guard let path = expected.candidates.first else { return false }

        let panel = NSOpenPanel()
        panel.directoryURL = URL(filePath: path).deletingLastPathComponent()
        panel.nameFieldStringValue = expected.fileName
        panel.allowedContentTypes = [.propertyList]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose \(expected.fileName)"
        panel.prompt = "Choose"
        guard await panel.begin() == .OK, let url = panel.url else { return false }

        do {
            _ = try await grants.grant(kind, chosen: url, home: home)
            return true
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn't use that file"
            alert.informativeText = error.localizedDescription
            await ModalLoop.run(alert)
            return false
        }
    }
}
