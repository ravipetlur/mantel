import Foundation

/// The pictures chosen so far for the Image style of the dots. The style can only be saved once both light pictures are there (the
/// dark ones are optional), so until then the dots keep the style they had.
public struct DotImageDraft: Equatable, Sendable {
    public var hiddenLight: String?
    public var hiddenDark: String?
    public var alwaysLight: String?
    public var alwaysDark: String?

    public init() {}

    /// What `style` holds: its pictures when it is the Image style, nothing otherwise.
    public init(_ style: DotGlyphStyle) {
        if case .image(let hiddenLight, let hiddenDark, let alwaysLight, let alwaysDark) = style {
            self.hiddenLight = hiddenLight
            self.hiddenDark = hiddenDark
            self.alwaysLight = alwaysLight
            self.alwaysDark = alwaysDark
        }
    }

    /// The Image style these pictures make, or nil while a light picture is missing.
    public var style: DotGlyphStyle? {
        guard let hiddenLight, let alwaysLight else { return nil }
        return .image(hiddenLight: hiddenLight, hiddenDark: hiddenDark, alwaysLight: alwaysLight, alwaysDark: alwaysDark)
    }
}

/// What the symbol field of a dot does with what was typed.
public enum DotSymbolName {
    /// The outcome of committing a field: the text it shows afterwards, and the name to save (nil when nothing changed).
    public struct Commit: Equatable, Sendable {
        public let text: String
        public let save: String?
    }

    /// The name as it is looked up and saved: without the spaces and line breaks around it.
    public static func trimmed(_ typed: String) -> String {
        typed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// An empty field goes back to the `saved` name and saves nothing; a name is saved as typed (trimmed) when it differs from the
    /// saved one, whether or not the system has such a symbol.
    public static func commit(typed: String, saved: String) -> Commit {
        let name = trimmed(typed)
        guard !name.isEmpty else { return Commit(text: saved, save: nil) }
        return Commit(text: name, save: name == saved ? nil : name)
    }
}
