// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MantelKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "MKCore", targets: ["MKCore"]),
        .library(name: "MKCommands", targets: ["MKCommands"]),
        .library(name: "MKMenuBar", targets: ["MKMenuBar"]),
    ],
    // No `dependencies:`: Mantel uses no third-party code.
    targets: [
        // The pure logic every other module builds on: where Mantel keeps its files and, from later tasks, the logging,
        // the settings store, the journal, displays and geometry, permissions and hotkey models.
        .target(name: "MKCore"),
        // What the app and the `mantel` command-line tool say to each other: the commands, their JSON lines, the
        // command-line grammar, and the control socket with the check of who is on the other end of it.
        .target(name: "MKCommands", dependencies: ["MKCore"]),
        // The one Objective-C target: it loads macOS's private MenuBarClientCore, checks the methods it is about to call
        // (their type encodings) and only then calls them. It depends on nothing.
        .target(name: "MKPrivateShims", publicHeadersPath: "include"),
        // The platform layer: reading the menu bar through Accessibility, plist files and their journal, the strip
        // capture, the click-replay tap, and the probes that exercise each of them.
        .target(name: "MKMenuBar", dependencies: ["MKCore", "MKCommands", "MKPrivateShims"]),
        // What every test target shares: throwaway folders.
        .target(name: "MKTestSupport", dependencies: ["MKCore"], path: "Tests/MKTestSupport"),
        .testTarget(name: "MKCoreTests", dependencies: ["MKCore", "MKTestSupport"]),
        .testTarget(name: "MKCommandsTests", dependencies: ["MKCommands", "MKCore", "MKTestSupport"]),
        .testTarget(name: "MKMenuBarTests", dependencies: ["MKMenuBar", "MKCore", "MKCommands", "MKTestSupport"]),
    ]
)
