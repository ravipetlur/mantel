import Foundation

/// A release's notes, cut into blocks for the update window to lay out.
///
/// The notes are Markdown. Interpreting all of it (`AttributedString(markdown:)` with the full syntax) marks each run
/// with the block it belongs to and each word with its style, but SwiftUI's `Text` draws only the styles: it runs
/// paragraphs together and shows no heading or list. Interpreting only the inline syntax shows headings as `## Title`
/// and lists as `- item`. So the full interpretation is cut into blocks here, one per paragraph, heading, list item,
/// quote and code block, each keeping its own inline styles (bold, italic, code, links).
public enum ReleaseNotes {
    public enum Block: Equatable, Sendable {
        case heading(level: Int, text: AttributedString)
        case paragraph(AttributedString)
        /// `marker` is a bullet or the item's number with a dot; `depth` is 0 for a top level item.
        case listItem(marker: String, depth: Int, text: AttributedString)
        case quote(AttributedString)
        /// The lines as written, without a newline after the last.
        case codeBlock(String)
        /// A thematic break (`---`).
        case rule
    }

    /// The most of the notes that is read. A release's notes can run to 125,000 characters; what follows this many is
    /// left out, and the last block says so with an ellipsis.
    public static let characterLimit = 20_000

    /// The blocks of the notes the update window shows (`whatsNew(in:)`), in order. Nothing for empty notes.
    public static func blocks(fromMarkdown markdown: String) -> [Block] {
        let shown = whatsNew(in: markdown)
        let cut = shown.count > characterLimit
        let source = cut ? String(shown.prefix(characterLimit)) : shown
        guard !source.allSatisfy(\.isWhitespace) else { return [] }
        var blocks = parse(source)
        if cut { blocks.append(.paragraph(AttributedString("\u{2026}"))) }
        return blocks
    }

    // MARK: Where the notes end

    /// The part of a release's body that is its notes: everything before the first `## Install` heading, or the whole
    /// body when there is none. What follows is for someone downloading by hand (the manual install steps and the
    /// `shasum` commands, then the generated list of changes), and the update window, which installs for them, has no
    /// use for it.
    ///
    /// The heading is an ATX heading of level 2 (`##`, indented by up to three spaces) whose text is just "Install", in
    /// any case, with or without a closing run of `#`. Other headings ("Installation", "### Install") and lines in a code
    /// block don't count.
    public static func whatsNew(in markdown: String) -> String {
        var fence: (character: Character, length: Int)?
        var lineStart = markdown.startIndex
        while lineStart < markdown.endIndex {
            let lineEnd = markdown[lineStart...].firstIndex(where: \.isNewline) ?? markdown.endIndex
            let line = markdown[lineStart..<lineEnd]
            if let open = fence {
                if closesFence(line, open: open) { fence = nil }
            } else if let opened = opensFence(line) {
                fence = opened
            } else if isInstallHeading(line) {
                return String(markdown[..<lineStart])
            }
            guard lineEnd < markdown.endIndex else { break }
            lineStart = markdown.index(after: lineEnd)
        }
        return markdown
    }

    /// The line without up to three leading spaces (more makes it an indented code block), or nil when it has more.
    private static func unindented(_ line: Substring) -> Substring? {
        let trimmed = line.drop(while: { $0 == " " })
        return line.count - trimmed.count <= 3 ? trimmed : nil
    }

    /// The fence a line opens: three or more backticks or tildes (a backtick fence's text after them has no backtick).
    private static func opensFence(_ line: Substring) -> (character: Character, length: Int)? {
        guard let text = unindented(line), let first = text.first, first == "`" || first == "~" else { return nil }
        let run = text.prefix(while: { $0 == first })
        guard run.count >= 3 else { return nil }
        if first == "`", text.dropFirst(run.count).contains("`") { return nil }
        return (first, run.count)
    }

    /// Whether a line closes `open`: the same character at least as many times, and nothing else but spaces.
    private static func closesFence(_ line: Substring, open: (character: Character, length: Int)) -> Bool {
        guard let text = unindented(line) else { return false }
        let run = text.prefix(while: { $0 == open.character })
        return run.count >= open.length && text.dropFirst(run.count).allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func isInstallHeading(_ line: Substring) -> Bool {
        guard let text = unindented(line), text.hasPrefix("##") else { return false }
        let rest = text.dropFirst(2)
        // A space or tab must follow the marks ("##Install" is text), and "###" is a level 3 heading.
        guard let separator = rest.first, separator == " " || separator == "\t" else { return false }
        var content = rest.drop(while: { $0 == " " || $0 == "\t" })
        // An optional closing run of `#`, set off by a space.
        let withoutTrailingSpace = content.reversed().drop(while: { $0 == " " || $0 == "\t" })
        let closing = withoutTrailingSpace.prefix(while: { $0 == "#" })
        let before = withoutTrailingSpace.dropFirst(closing.count)
        if !closing.isEmpty, before.isEmpty || before.first == " " || before.first == "\t" {
            content = Substring(String(before.reversed()))
        }
        return content.trimmingCharacters(in: .whitespaces).lowercased() == "install"
    }

    // MARK: Cutting

    private static func parse(_ source: String) -> [Block] {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: source, options: options) else {
            // Unreadable as Markdown: show it as written.
            return [.paragraph(AttributedString(source))]
        }

        var blocks: [Block] = []
        var current: (identity: Int?, kind: Kind, text: AttributedString)?
        func flush() {
            guard let finished = current else { return }
            current = nil
            blocks.append(block(for: finished.kind, text: finished.text))
        }

        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let identity = components.first?.identity
            if current?.identity != identity || current == nil {
                flush()
                current = (identity, Kind(components), AttributedString())
            }
            var piece = AttributedString(parsed[run.range])
            piece.presentationIntent = nil
            if run.inlinePresentationIntent?.contains(.softBreak) == true {
                piece = AttributedString("\n")
            } else if let link = piece.runs.first?.link, !isWebLink(link) {
                piece.link = nil
            }
            current?.text.append(piece)
        }
        flush()
        return blocks
    }

    /// Only a web link may be a link: a click can't then open a file or reach another app.
    private static func isWebLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return false }
        return url.host() != nil
    }

    /// What kind of block a run's components describe.
    private enum Kind {
        case heading(Int), paragraph, listItem(marker: String, depth: Int), quote, codeBlock, rule

        /// `components` run from the innermost out: a list item's paragraph is `[paragraph, listItem, list]`, a
        /// nested one has another `[listItem, list]` after that.
        init(_ components: [PresentationIntent.IntentType]) {
            var item: (ordinal: Int, ordered: Bool)?
            var pendingOrdinal: Int?
            var lists = 0
            var innermostList: Bool?
            var heading: Int?
            var isCode = false, isQuote = false, isRule = false
            for component in components {
                switch component.kind {
                case .header(let level): if heading == nil { heading = level }
                case .codeBlock: isCode = true
                case .blockQuote: isQuote = true
                case .thematicBreak: isRule = true
                case .listItem(let ordinal): if pendingOrdinal == nil, item == nil { pendingOrdinal = ordinal }
                case .orderedList, .unorderedList:
                    lists += 1
                    if innermostList == nil {
                        innermostList = component.kind == .orderedList
                        if let ordinal = pendingOrdinal { item = (ordinal, innermostList ?? false) }
                    }
                default: break
                }
            }
            if let heading { self = .heading(heading) }
            else if isCode { self = .codeBlock }
            else if isRule { self = .rule }
            else if let item {
                self = .listItem(marker: item.ordered ? "\(item.ordinal)." : "\u{2022}", depth: max(lists - 1, 0))
            } else if isQuote { self = .quote }
            else { self = .paragraph }
        }
    }

    private static func block(for kind: Kind, text: AttributedString) -> Block {
        switch kind {
        case .heading(let level): .heading(level: level, text: text)
        case .paragraph: .paragraph(text)
        case .listItem(let marker, let depth): .listItem(marker: marker, depth: depth, text: text)
        case .quote: .quote(text)
        case .codeBlock:
            .codeBlock(String(text.characters).trimmingCharacters(in: CharacterSet(charactersIn: "\n")))
        case .rule: .rule
        }
    }
}
