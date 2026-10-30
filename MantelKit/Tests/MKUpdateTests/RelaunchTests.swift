import Foundation
import MKUpdate
import Testing

/// The relaunch after an update: it starts the new copy only after this one has gone (so the single-instance check passes), and
/// nothing in a path is ever run; it holds off for an open dialog and for a change of the menu bar's order being written.
@Suite("The relaunch", .timeLimit(.minutes(2)))
struct RelaunchTests {
    /// The script is fixed and the PID and the path are positional parameters, so a path with quotes, `;` or `$()` is only a
    /// path.
    @Test func theScriptWaitsForTheProcessAndTheirValuesAreNeverPartOfIt() {
        let hostile = "/Applications/Mantel.app\"; touch /tmp/x; echo \"$(id)"
        let arguments = RelaunchCommand.arguments(pid: 4242, appPath: hostile)
        #expect(arguments.count == 5)
        #expect(arguments[0] == "-c")
        #expect(!arguments[1].contains(hostile))
        #expect(!arguments[1].contains("4242"))
        #expect(Array(arguments[2...]) == ["sh", "4242", hostile])
    }

    @Test(arguments: [
        (false, false, 0.0, false), (true, false, 0.0, true), (true, true, 100.0, true), (false, true, 0.0, true),
        (false, true, RelaunchWait.layoutLimit - 1, true), (false, true, RelaunchWait.layoutLimit, false),
    ] as [(Bool, Bool, TimeInterval, Bool)])
    func theRelaunchWaitsForADialogAndBrieflyForALayoutWrite(dialog: Bool, layout: Bool, waited: TimeInterval, mustWait: Bool) {
        #expect(RelaunchWait.mustWait(dialogIsOpen: dialog, layoutWriteIsUnderWay: layout, layoutWaited: waited) == mustWait)
    }
}
