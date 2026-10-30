import CoreGraphics
import Foundation
import MKCommands
import MKCore
import MKTestSupport
import Synchronization
import Testing

@testable import MKMenuBar

/// A yes or no a test can turn over while something runs.
final class Switch: Sendable {
    private let flag: Mutex<Bool>

    init(_ isOn: Bool) { flag = Mutex(isOn) }

    var isOn: Bool { flag.withLock { $0 } }
    func set(_ isOn: Bool) { flag.withLock { $0 = isOn } }
}
