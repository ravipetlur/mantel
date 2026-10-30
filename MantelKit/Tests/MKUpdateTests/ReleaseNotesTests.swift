import Foundation
import MKUpdate
import Testing

/// The window shows what's new and not the steps for installing by hand (the checksum commands, the Gatekeeper workaround): the
/// notes end at the first `## Install` heading. A cut in the wrong place shows a person steps that aren't theirs.
@Suite("Where the release notes end", .timeLimit(.minutes(2)))
struct ReleaseNotesTests {
    func text(of block: ReleaseNotes.Block) -> String {
        switch block {
        case .heading(_, let text), .paragraph(let text), .quote(let text), .listItem(_, _, let text): String(text.characters)
        case .codeBlock(let code): code
        case .rule: "---"
        }
    }

    @Test func theWindowShowsTheNotesUpToTheInstallSection() {
        let body = "## What's new\n\n- Updates arrive in the app.\n\n## Install\n\nDownload the disk image.\n\n## Verify the download\n\n`shasum`\n"
        let blocks = ReleaseNotes.blocks(fromMarkdown: body)
        #expect(blocks.map(text(of:)) == ["What's new", "Updates arrive in the app."])
        // No Install heading: the whole body is the notes.
        let plain = "## What's new\n\nA fix.\n\n## Verify the download\n\nA check."
        #expect(ReleaseNotes.whatsNew(in: plain) == plain)
        #expect(ReleaseNotes.blocks(fromMarkdown: "## Install\n\nSteps.").isEmpty)
        #expect(ReleaseNotes.blocks(fromMarkdown: "").isEmpty)
    }

    @Test(arguments: ["## Install", "## INSTALL", "##   Install  ", "##\tInstall", "## Install ##", " ## Install", "   ## Install"])
    func theInstallHeadingIsFoundWhateverItsCaseAndSpacing(heading: String) {
        #expect(ReleaseNotes.whatsNew(in: "Notes.\n\n\(heading)\n\nSteps.") == "Notes.\n\n")
        #expect(ReleaseNotes.whatsNew(in: "A\r\n## Install\r\nB") == "A\r\n")
        #expect(ReleaseNotes.whatsNew(in: "A\n## Install\nB\n## Install\nC") == "A\n")
    }

    /// Only a level-2 heading that says just "Install" ends the notes.
    @Test(arguments: ["## Installation", "## Install notes", "### Install", "# Install", "##Install", "Install", "Run ## Install",
                      "- ## Install", "> ## Install", "    ## Install", "**## Install**", "## Reinstall"])
    func otherHeadingsAndLinesDoNotEndTheNotes(line: String) {
        let notes = "Notes.\n\n\(line)\n\nMore."
        #expect(ReleaseNotes.whatsNew(in: notes) == notes)
    }

    /// A line inside a code block is code, whatever it looks like; a fence is closed by its own kind, at least as long.
    @Test func anInstallHeadingInACodeBlockIsCode() {
        let notes = "Notes.\n\n```\n## Install\n```\n\nMore.\n\n~~~\n## Install\n~~~\n\nEven more."
        #expect(ReleaseNotes.whatsNew(in: notes) == notes)
        #expect(ReleaseNotes.whatsNew(in: notes + "\n\n## Install\n\nSteps.") == notes + "\n\n")
        #expect(ReleaseNotes.whatsNew(in: "Notes.\n\n```\n## Install\n\nmore") == "Notes.\n\n```\n## Install\n\nmore")
        let longer = "````\n```\n## Install\n```\n````\nafter\n## Install\nSteps."
        #expect(ReleaseNotes.whatsNew(in: longer) == "````\n```\n## Install\n```\n````\nafter\n")
    }

    /// Only a web link is a link: a click can't open a file or reach another app.
    @Test func onlyWebLinksStayLinks() {
        let blocks = ReleaseNotes.blocks(fromMarkdown: "[web](https://example.com/n) and [file](file:///etc/hosts) and [app](tel:123)")
        guard case .paragraph(let paragraph) = blocks.first else {
            Issue.record("expected a paragraph")
            return
        }
        let links = paragraph.runs.compactMap(\.link)
        #expect(links == [URL(string: "https://example.com/n")!])
    }
}
