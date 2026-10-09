import Foundation
import MKCore
import MKTestSupport
import Testing

@Suite("Display layout source", .timeLimit(.minutes(1)))
struct DisplayLayoutSourceTests {
    @Test func itStartsWithTheLayoutItIsGiven() {
        #expect(DisplayLayoutSource(.desk).current == .desk)
        #expect(DisplayLayoutSource().current == DisplayLayout(displays: []), "no displays until it is told of some")
    }

    @Test func aNewLayoutReplacesTheOldOne() {
        let source = DisplayLayoutSource(.desk)
        source.set(.laptop)
        #expect(source.current == .laptop)
    }

    @Test func itCanBeReadFromOtherTasksWhileItChanges() async {
        let source = DisplayLayoutSource(.desk)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<50 {
                group.addTask { source.set(index.isMultiple(of: 2) ? .desk : .laptop) }
                group.addTask { let layout = source.current; #expect(layout == .desk || layout == .laptop) }
            }
        }
    }
}
