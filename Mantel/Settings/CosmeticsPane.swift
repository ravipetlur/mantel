import AppKit
import MKCore
import MKMenuBar
import SwiftUI

/// Settings › Cosmetics: how the two dots are drawn and when •• is there, and the divider.
struct CosmeticsPane: View {
    let coordinator: AppCoordinator

    @State private var confirmingHide = false

    private var dots: DotSettings { coordinator.settingsModel.settings.dots }

    var body: some View {
        Form {
            Section("Dots") {
                DotStyleRows(coordinator: coordinator)
                Picker("Show ••", selection: Binding(get: { dots.alwaysDot }, set: { value in edit { $0.alwaysDot = value } })) {
                    Text("When something is in Always Hidden").tag(AlwaysDotVisibility.whenNeeded)
                    Text("Always").tag(AlwaysDotVisibility.always)
                }
                // Hiding asks first; showing them again doesn't.
                SettingsToggle("Hide both dots", isOn: Binding(
                    get: { dots.hideBothDots },
                    set: { hide in
                        if hide { confirmingHide = true } else { edit { $0.hideBothDots = false } }
                    }))
            }
            Section("Divider") {
                SettingsToggle("Show a divider left of your shown icons", isOn: Binding(
                    get: { dots.showsDivider }, set: { value in edit { $0.showsDivider = value } }))
            }
        }
        .formStyle(.grouped)
        .alert("Hide both dots?", isPresented: $confirmingHide) {
            Button("Hide") { edit { $0.hideBothDots = true } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Mantel keeps working. Open its menu with the hotkey you set in Hotkeys, use the command bar, or open Mantel again to get back to Settings.")
        }
    }

    private func edit(_ change: (inout DotSettings) -> Void) {
        coordinator.updateGeneralSettings { change(&$0.dots) }
    }
}

/// The kinds of dot style the picker lists.
private enum DotStyleKind: CaseIterable {
    case dots, chevrons, symbol, image

    var title: String {
        switch self {
        case .dots: "Dots"
        case .chevrons: "Chevrons"
        case .symbol: "SF Symbol"
        case .image: "Image"
        }
    }

    init(_ style: DotGlyphStyle) {
        switch style {
        case .dots: self = .dots
        case .chevrons: self = .chevrons
        case .symbol: self = .symbol
        case .image: self = .image
        }
    }
}

private struct DotStyleRows: View {
    /// What each symbol field starts as when the style is switched to SF Symbol.
    private static let startingSymbols = (hidden: "circle.fill", always: "circle.grid.2x1.fill")

    let coordinator: AppCoordinator

    /// The Image style, chosen in the picker and not yet saved (it waits for its two light pictures).
    @State private var imageInProgress: DotImageDraft?

    private var style: DotGlyphStyle { coordinator.settingsModel.settings.dots.style }
    private var kind: DotStyleKind { imageInProgress == nil ? DotStyleKind(style) : .image }

    var body: some View {
        Picker("Style", selection: Binding(get: { kind }, set: choose)) {
            ForEach(DotStyleKind.allCases, id: \.self) { kind in
                Text(kind.title).tag(kind)
            }
        }
        switch kind {
        case .dots, .chevrons:
            EmptyView()
        case .symbol:
            if case .symbol(let hidden, let always) = style {
                SymbolField(title: "• symbol", name: hidden) { name in saveSymbols(hidden: name) }
                SymbolField(title: "•• symbol", name: always) { name in saveSymbols(always: name) }
            }
        case .image:
            imageRows
        }
    }

    private func save(_ style: DotGlyphStyle) {
        coordinator.updateGeneralSettings { $0.dots.style = style }
    }

    /// Saves a symbol name over the style as it is when this runs: a field that commits as it disappears can't bring a symbol style back
    /// after another one was chosen.
    private func saveSymbols(hidden: String? = nil, always: String? = nil) {
        coordinator.updateGeneralSettings {
            guard case .symbol(let currentHidden, let currentAlways) = $0.dots.style else { return }
            $0.dots.style = .symbol(hidden: hidden ?? currentHidden, always: always ?? currentAlways)
        }
    }

    private func choose(_ kind: DotStyleKind) {
        guard kind != self.kind else { return }
        let saved = DotStyleKind(style)
        switch kind {
        case .dots, .chevrons, .symbol:
            imageInProgress = nil
            // Going back to the kind that is saved (the Image rows were only up) changes nothing, so nothing is written.
            guard kind != saved else { return }
            switch kind {
            case .dots: save(.dots)
            case .chevrons: save(.chevrons)
            default: save(.symbol(hidden: Self.startingSymbols.hidden, always: Self.startingSymbols.always))
            }
        case .image:
            imageInProgress = DotImageDraft(style)
        }
    }

    // MARK: Image

    private var choices: DotImageDraft { imageInProgress ?? DotImageDraft(style) }

    @ViewBuilder
    private var imageRows: some View {
        imageRow("• light", fileName: choices.hiddenLight, removable: false) { $0.hiddenLight = $1 }
        imageRow("• dark (optional)", fileName: choices.hiddenDark, removable: true) { $0.hiddenDark = $1 }
        imageRow("•• light", fileName: choices.alwaysLight, removable: false) { $0.alwaysLight = $1 }
        imageRow("•• dark (optional)", fileName: choices.alwaysDark, removable: true) { $0.alwaysDark = $1 }
        if imageInProgress != nil {
            Text("Choose both light pictures to use this style.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func imageRow(_ title: String, fileName: String?, removable: Bool, set: @escaping (inout DotImageDraft, String?) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer()
            if let fileName {
                PicturePreview(url: coordinator.paths.ownImages.appending(path: fileName, directoryHint: .notDirectory))
            }
            if removable, fileName != nil {
                Button("Remove") { update { set(&$0, nil) } }
                    .accessibilityLabel("Remove \(title)")
            }
            Button("Choose…") { choosePicture(set) }
                .accessibilityLabel("Choose… \(title)")
                .accessibilityValue(fileName == nil ? "None" : "Chosen")
        }
    }

    /// Applies a change to the pictures chosen: the Image style is saved as soon as it is complete, and kept as a draft until then.
    private func update(_ change: (inout DotImageDraft) -> Void) {
        var updated = choices
        change(&updated)
        if let style = updated.style {
            imageInProgress = nil
            save(style)
        } else {
            imageInProgress = updated
        }
    }

    private func choosePicture(_ set: @escaping (inout DotImageDraft, String?) -> Void) {
        Task {
            guard let name = await chooseImageFile() else { return }
            update { set(&$0, name) }
        }
    }

    /// The person chooses a picture; Mantel keeps a copy of its own, and the copy's name comes back. A picture it can't use is refused
    /// with the import's own text, as the Layout editor refuses one.
    private func chooseImageFile() async -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a PNG or PDF under 1 MB"
        panel.prompt = "Choose"
        guard await ModalLoop.run(panel) == .OK, let url = panel.url else { return nil }
        do {
            return try ImageImport.copy(url, into: coordinator.paths.ownImages)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn't use that image"
            alert.informativeText = error.localizedDescription
            await ModalLoop.run(alert)
            return nil
        }
    }
}

/// A chosen picture at 18 points: its own size when it is smaller, as the dot is drawn. It is read from disk when the file changes, not
/// each time the pane is drawn.
private struct PicturePreview: View {
    private static let box: CGFloat = 18

    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                let size = Self.fitted(image.size)
                Image(nsImage: image)
                    .resizable()
                    .frame(width: size.width, height: size.height)
            }
        }
        .accessibilityHidden(true)
        .onChange(of: url, initial: true) { _, url in image = NSImage(contentsOf: url) }
    }

    private static func fitted(_ size: NSSize) -> NSSize {
        guard size.width > 0, size.height > 0 else { return size }
        let factor = min(box / size.width, box / size.height, 1)
        return NSSize(width: size.width * factor, height: size.height * factor)
    }
}

/// One dot's symbol name: a text field committed on Return or on leaving it, a preview of the symbol at 18 points, and a caption when
/// the system has no symbol by that name.
private struct SymbolField: View {
    let title: String
    let name: String
    let save: (String) -> Void
    @State private var text: String
    @FocusState private var isFocused: Bool

    init(title: String, name: String, save: @escaping (String) -> Void) {
        self.title = title
        self.name = name
        self.save = save
        _text = State(initialValue: name)
    }

    private var trimmed: String { DotSymbolName.trimmed(text) }
    private var exists: Bool { NSImage(systemSymbolName: trimmed, accessibilityDescription: nil) != nil }
    /// An empty field is still being typed in: the caption waits for a name.
    private var missing: Bool { !trimmed.isEmpty && !exists }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title)
                TextField(title, text: $text)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .focused($isFocused)
                    .onSubmit(commit)
                    .onChange(of: isFocused) { _, focused in
                        if !focused { commit() }
                    }
                    .onDisappear(perform: commit)
                    .accessibilityHint(missing ? "No symbol by that name" : "")
                Group {
                    if exists {
                        Image(systemName: trimmed).font(.system(size: 18))
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            }
            if missing {
                Text("No symbol by that name")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
            }
        }
    }

    private func commit() {
        let outcome = DotSymbolName.commit(typed: text, saved: name)
        text = outcome.text
        if let name = outcome.save { save(name) }
    }
}
