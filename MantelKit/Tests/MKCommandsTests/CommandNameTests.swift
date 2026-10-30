import MKCommands
import MKCore
import Testing

@Suite("Command names")
struct CommandNameTests {
    @Test func theIconCommandsNameThemselvesForTheLog() {
        #expect(MantelCommand.icons(.hidden).name == "icons")
        #expect(MantelCommand.icons(nil).name == "icons")
        #expect(MantelCommand.icon(.show, query: "x", kind: .left).name == "icon show")
        #expect(MantelCommand.icon(.click, query: "x", kind: .right).name == "icon click")
        #expect(MantelCommand.bar(.open, all: true).name == "bar")
        #expect(MantelCommand.recapture.name == "recapture")
        #expect(MantelCommand.restoreLayout.name == "layout restore")
    }

    @Test(arguments: [IconCommand.show, .click], ClickKind.allCases)
    func iconQueryIsNeverInName(command: IconCommand, kind: ClickKind) {
        // The query is the person's words: a network's name, an app they would rather not have in a log. Nothing of it is in the name,
        // which is all the log says of a command.
        let query = "Zq-private-words 7"
        let name = MantelCommand.icon(command, query: query, kind: kind).name
        #expect(!name.contains("Zq"))
        #expect(!name.contains("private"))
        #expect(!name.contains(query))
        #expect(name == "icon \(command.rawValue)")
    }
}
