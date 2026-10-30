import AppKit
import MKCore
import MKLayout
import MKMenuBar
import SwiftUI
import UniformTypeIdentifiers

/// "Selected icon": what the token that was clicked is, and the fields that change it.
///
/// - **An app:** its picture, name and number of icons, where it is (a picker that moves it), the names it is searched by, and, when it
///   can't be reordered, the line that says so, and its shortcut with the button that opens the Hotkeys page.
/// - **A spacer:** its width and label. **A group:** its title, look and whether it opens when the pointer rests on it.
/// - **The marker:** what it is. **Mantel's own items** can be removed.
///
/// Each kind of field is committed on Return or when the field is left, never on each key.
struct SelectedIconSection: View {
    let token: StripToken
    /// The strip the token is in.
    let strip: StripID
    let context: StripContext
    /// Every strip a token of this kind can be moved to, the one it is in included.
    let targets: [MoveTarget]
    let store: SettingsStore
    let preferences: IconPreferencesWriter
    /// What was saved to `icons.json`, after each change made here (the coordinator keeps its copy of the file current with it).
    let saved: @MainActor (IconPreferences) -> Void
    /// The shortcut the app's icons have, as the Hotkeys page shows it (the first of them that has a working one); nil when none has.
    let shortcut: ([ItemID]) -> String?
    let editInHotkeys: () -> Void
    let moveTo: (StripID) -> Void
    let update: (LayoutSpacer) -> Void
    let updateGroup: (IconGroup) -> Void
    let remove: (ItemID) -> Void

    var body: some View {
        Section {
            switch token {
            case .app(let bundleID, let items):
                AppFields(bundleID: bundleID, items: items, strip: strip, context: context, targets: targets, store: store,
                          preferences: preferences, saved: saved, shortcut: shortcut, editInHotkeys: editInHotkeys, moveTo: moveTo)
                    .id(token.id)
            case .own(let item):
                if let spacer = LayoutEditorModel.spacer(of: token, in: context.sections) {
                    SpacerFields(spacer: spacer, update: update).id(token.id)
                } else if let group = LayoutEditorModel.group(of: token, in: context.sections) {
                    GroupFields(group: group, ownImages: context.ownImages, update: updateGroup).id(token.id)
                }
                Button(LayoutCopy.remove, role: .destructive) { remove(item) }
            case .marker:
                Text(LayoutCopy.markerNote)
            }
        } header: {
            Text(LayoutCopy.selectedIconHeader)
        }
    }
}

// MARK: An app

private struct AppFields: View {
    let bundleID: String
    let items: [ItemID]
    let strip: StripID
    let context: StripContext
    let targets: [MoveTarget]
    let store: SettingsStore
    let preferences: IconPreferencesWriter
    let saved: @MainActor (IconPreferences) -> Void
    let shortcut: ([ItemID]) -> String?
    let editInHotkeys: () -> Void
    let moveTo: (StripID) -> Void

    @State private var namesText = ""
    @State private var savedNames: [String] = []
    @FocusState private var namesFocused: Bool

    private var name: String { context.names[bundleID] ?? bundleID }
    private var row: AppRow? { context.rows[bundleID] }

    /// Mantel moved the app here to make room. (No `.accessibilityLabel` on a `Text`: see `HotkeysPane`, where one made SwiftUI's
    /// accessibility loop; the help is what the accessibility tools get.)
    private var autoCapsule: some View {
        Text(LayoutCopy.auto)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.secondary.opacity(0.18)))
            .help(LayoutCopy.autoHelp)
    }

    var body: some View {
        HStack(spacing: 12) {
            if let first = items.first {
                let image = context.images.image(for: first, appearance: context.appearance)
                let size = LayoutEditorModel.fittedSize(image.size, in: CGSize(width: 32, height: 32))
                Image(nsImage: image)
                    .resizable()
                    .frame(width: size.width, height: size.height)
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(name).font(.headline)
                    if context.sections.apps[bundleID]?.isAuto == true { autoCapsule }
                }
                // What the icons are: their number, unless something is the matter with them.
                Text(row?.statusText ?? LayoutCopy.iconCount(items.count))
                    .font(.caption)
                    .foregroundStyle(row?.needsAttention == true ? Color.orange : Color.secondary)
                if let note = row?.note {
                    Text(note).font(.caption).foregroundStyle(Color.orange).fixedSize(horizontal: false, vertical: true)
                }
                if items.count > 1 {
                    Text(LayoutCopy.movesWithOthers(count: items.count - 1, app: name)).font(.caption).foregroundStyle(.secondary)
                }
                if context.cantReorder.contains(bundleID) {
                    Text(LayoutCopy.cantReorderHelp).font(.caption).foregroundStyle(.secondary)
                }
            }
        }

        Picker(LayoutCopy.moveTo, selection: Binding(get: { strip }, set: { moveTo($0) })) {
            ForEach(targets) { target in
                Text(target.title).tag(target.strip)
            }
        }

        HStack {
            Text(LayoutCopy.searchNames)
            TextField(LayoutCopy.searchNames, text: $namesText, prompt: Text(LayoutCopy.searchNamesPrompt))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .focused($namesFocused)
                .onSubmit(commitNames)
                .onChange(of: namesFocused) { _, focused in
                    if !focused { commitNames() }
                }
                .onDisappear(perform: commitNames)
        }
        .task {
            // What is kept of the first icon's names stands for the app's.
            guard let first = items.first else { return }
            let kept = await store.load(IconPreferences.self).searchNames[first] ?? []
            savedNames = kept
            namesText = kept.joined(separator: ", ")
        }

        // The app's shortcut is that of the first of its icons that has a working one.
        HStack {
            Text(LayoutCopy.shortcut(shortcut(items)))
            Spacer(minLength: 8)
            Button(LayoutCopy.editInHotkeys, action: editInHotkeys)
        }
    }

    /// The names are read when the field is committed: split at the commas and kept as `IconPreferences` keeps them.
    private func commitNames() {
        let cleaned = IconPreferences.cleanedNames(namesText.split(separator: ",", omittingEmptySubsequences: true).map(String.init))
        namesText = cleaned.joined(separator: ", ")
        guard cleaned != savedNames else { return }
        savedNames = cleaned
        let items = items
        preferences.update(in: store, { preferences in
            for item in items { preferences.searchNames[item] = cleaned.isEmpty ? nil : cleaned }
        }, saved: saved)
    }
}

// MARK: A spacer

private struct SpacerFields: View {
    let spacer: LayoutSpacer
    let update: (LayoutSpacer) -> Void

    private enum LabelKind: CaseIterable {
        case none, text, emoji, symbol

        var title: String {
            switch self {
            case .none: LayoutCopy.labelNone
            case .text: LayoutCopy.labelText
            case .emoji: LayoutCopy.labelEmoji
            case .symbol: LayoutCopy.labelSymbol
            }
        }
    }

    @State private var width: ClampedNumberDraft
    @State private var value: String
    @FocusState private var widthFocused: Bool
    @FocusState private var valueFocused: Bool

    init(spacer: LayoutSpacer, update: @escaping (LayoutSpacer) -> Void) {
        self.spacer = spacer
        self.update = update
        _width = State(initialValue: ClampedNumberDraft(committed: spacer.width, format: ClampedIntegerFormat(range: LayoutSpacer.widthRange)))
        _value = State(initialValue: Self.value(of: spacer.label))
    }

    private static func value(of label: OwnItemLabel?) -> String {
        switch label {
        case .text(let text), .emoji(let text), .symbol(let text): text
        case nil: ""
        }
    }

    private var kind: LabelKind {
        switch spacer.label {
        case nil: .none
        case .text: .text
        case .emoji: .emoji
        case .symbol: .symbol
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(LayoutCopy.width)
            Spacer(minLength: 8)
            TextField(LayoutCopy.width, text: $width.text)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 64)
                .focused($widthFocused)
                .onSubmit(commitWidth)
                .onChange(of: widthFocused) { _, focused in
                    if !focused { commitWidth() }
                }
                .onDisappear(perform: commitWidth)
            Stepper(LayoutCopy.width, value: Binding(
                get: { width.committed },
                set: { number in
                    width.follow(number)
                    save { $0.width = number }
                }), in: LayoutSpacer.widthRange)
                .labelsHidden()
            Text("points").foregroundStyle(.secondary)
        }

        Picker(LayoutCopy.label, selection: Binding(get: { kind }, set: setKind)) {
            ForEach(LabelKind.allCases, id: \.self) { kind in
                Text(kind.title).tag(kind)
            }
        }

        if kind != .none {
            TextField(kind == .symbol ? LayoutCopy.labelSymbol : LayoutCopy.label, text: $value)
                .labelsHidden()
                .focused($valueFocused)
                .onSubmit(commitValue)
                .onChange(of: valueFocused) { _, focused in
                    if !focused { commitValue() }
                }
                .onDisappear(perform: commitValue)
        }
    }

    private func save(_ change: (inout LayoutSpacer) -> Void) {
        var changed = spacer
        change(&changed)
        if changed != spacer { update(changed) }
    }

    private func commitWidth() {
        if let number = width.commit() { save { $0.width = number } }
    }

    private func setKind(_ kind: LabelKind) {
        switch kind {
        case .none:
            value = ""
            save { $0.label = nil }
        case .text:
            save { $0.label = .text(value) }
        case .emoji:
            save { $0.label = .emoji(value) }
        case .symbol:
            save { $0.label = .symbol(value) }
        }
    }

    private func commitValue() {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .none: break
        case .text: save { $0.label = .text(text) }
        case .emoji: save { $0.label = .emoji(text) }
        case .symbol: save { $0.label = .symbol(text) }
        }
    }
}

// MARK: A group

private struct GroupFields: View {
    let group: IconGroup
    let ownImages: URL
    let update: (IconGroup) -> Void

    private enum LookKind: CaseIterable {
        case symbol, emoji, image

        var title: String {
            switch self {
            case .symbol: LayoutCopy.lookSymbol
            case .emoji: LayoutCopy.lookEmoji
            case .image: LayoutCopy.lookImage
            }
        }
    }

    @State private var title: String
    @State private var value: String
    @FocusState private var titleFocused: Bool
    @FocusState private var valueFocused: Bool

    init(group: IconGroup, ownImages: URL, update: @escaping (IconGroup) -> Void) {
        self.group = group
        self.ownImages = ownImages
        self.update = update
        _title = State(initialValue: group.title ?? "")
        switch group.look {
        case .symbol(let text), .emoji(let text): _value = State(initialValue: text)
        case .image: _value = State(initialValue: "")
        }
    }

    private var kind: LookKind {
        switch group.look {
        case .symbol: .symbol
        case .emoji: .emoji
        case .image: .image
        }
    }

    var body: some View {
        HStack {
            Text(LayoutCopy.title)
            TextField(LayoutCopy.title, text: $title)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .focused($titleFocused)
                .onSubmit(commitTitle)
                .onChange(of: titleFocused) { _, focused in
                    if !focused { commitTitle() }
                }
                .onDisappear(perform: commitTitle)
        }

        HStack(spacing: 8) {
            Picker(LayoutCopy.look, selection: Binding(get: { kind }, set: setKind)) {
                ForEach(LookKind.allCases, id: \.self) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            OwnPicture.group(group.look, folder: ownImages, side: 20)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
        }

        switch kind {
        case .symbol, .emoji:
            TextField(kind == .symbol ? LayoutCopy.lookSymbol : LayoutCopy.lookEmoji, text: $value)
                .labelsHidden()
                .focused($valueFocused)
                .onSubmit(commitValue)
                .onChange(of: valueFocused) { _, focused in
                    if !focused { commitValue() }
                }
                .onDisappear(perform: commitValue)
        case .image:
            Button(LayoutCopy.lookImage, action: chooseImage)
        }

        SettingsToggle(LayoutCopy.opensOnHover, isOn: Binding(
            get: { group.opensOnHover },
            set: { opens in save { $0.opensOnHover = opens } }))
    }

    private func save(_ change: (inout IconGroup) -> Void) {
        var changed = group
        change(&changed)
        if changed != group { update(changed) }
    }

    private func commitTitle() {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        save { $0.title = text.isEmpty ? nil : text }
    }

    private func setKind(_ kind: LookKind) {
        switch kind {
        case .symbol:
            save { $0.look = .symbol(Self.symbolName(of: $0.look)) }
        case .emoji:
            save { $0.look = .emoji(Self.emoji(of: $0.look)) }
        case .image:
            chooseImage()
        }
    }

    private static func symbolName(of look: GroupLook) -> String {
        if case .symbol(let name) = look { name } else { "square.grid.2x2" }
    }

    private static func emoji(of look: GroupLook) -> String {
        if case .emoji(let text) = look { text } else { "⭐️" }
    }

    private func commitValue() {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        switch kind {
        case .symbol: save { $0.look = .symbol(text) }
        case .emoji: save { $0.look = .emoji(text) }
        case .image: break
        }
    }

    /// The person chooses a picture; Mantel keeps a copy of its own in its folder for the pictures of groups and the dots.
    private func chooseImage() {
        Task { await chooseImageFile() }
    }

    private func chooseImageFile() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a PNG or PDF under 1 MB"
        panel.prompt = "Choose"
        guard await ModalLoop.run(panel) == .OK, let url = panel.url else { return }
        do {
            let fileName = try ImageImport.copy(url, into: ownImages)
            save { $0.look = .image(fileName: fileName) }
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn't use that image"
            alert.informativeText = error.localizedDescription
            await ModalLoop.run(alert)
        }
    }
}
