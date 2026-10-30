import CoreGraphics
import Foundation
import MKCommands
import MKCore
import MKTestSupport
import Synchronization
import Testing

@testable import MKMenuBar

extension PlistIO {
    /// Both strategies done on the file itself. Tests use it, and never the real `cfprefsd`: it is the system's
    /// preferences service, shared with every app, and a domain in a folder that looks like a group container isn't one a
    /// test can be sure stays in its temporary folder. (`PlistFileAccessTests` tries the real one on a plain temporary file.)
    static let filesOnly = PlistIO(
        read: { url, key, _ in try readFile(url, key: key) },
        write: { value, key, url, _ in try writeFile(value, key: key, to: url) })
}
