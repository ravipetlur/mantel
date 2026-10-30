// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MantelKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "MKCore", targets: ["MKCore"]),
        .library(name: "MKCommands", targets: ["MKCommands"]),
        .library(name: "MKLayout", targets: ["MKLayout"]),
        .library(name: "MKMenuBar", targets: ["MKMenuBar"]),
        .library(name: "MKSearch", targets: ["MKSearch"]),
        .library(name: "MKUpdate", targets: ["MKUpdate"]),
    ],
    // No `dependencies:`: Mantel uses no third-party code.
    targets: [
        // The pure logic every other module builds on: where Mantel keeps its files and, from later tasks, the logging,
        // the settings store, the journal, displays and geometry, permissions and hotkey models.
        .target(name: "MKCore"),
        // What the app and the `mantel` command-line tool say to each other: the commands, their JSON lines, the
        // command-line grammar, and the control socket with the check of who is on the other end of it.
        .target(name: "MKCommands", dependencies: ["MKCore"]),
        // The pure logic of which icons are shown and which are hidden: the sections apps are sorted into and their profile file,
        // the visibility plan and how it is built, the lists of what can't be changed, automatic overflow, room estimates and swaps,
        // and the state machine that decides what a reveal shows, with the driver that keeps its timers. It reads no Accessibility
        // and draws nothing.
        .target(name: "MKLayout", dependencies: ["MKCore"]),
        // The one Objective-C target: it loads macOS's private MenuBarClientCore, checks the methods it is about to call
        // (their type encodings) and only then calls them. It depends on nothing.
        .target(name: "MKPrivateShims", publicHeadersPath: "include"),
        // The platform layer: reading the menu bar through Accessibility into an inventory of items, plist files and their
        // journal, the strip capture, the click-replay tap, the three ways of hiding icons and the controller that keeps one in
        // charge, and the session that turns events into plans for it.
        .target(name: "MKMenuBar", dependencies: ["MKCore", "MKCommands", "MKLayout", "MKPrivateShims"]),
        // The command bar's brain: the fuzzy matcher, the candidates it searches and where they come from (the icons and Mantel's own
        // actions, behind a protocol later providers join), the ranked search over what the providers offered when the bar opened, and the
        // resolver that turns an icon named in words into the one icon. It reads no Accessibility and draws nothing.
        .target(name: "MKSearch", dependencies: ["MKCore", "MKLayout"]),
        // The updater's pure logic: version numbers, the release feed, the checksum file, who a release may be installed over, the
        // daily schedule, the order of an install and its recovery, and what a check answers. The networking, the system's code checks
        // and the file replacing are the app's.
        .target(name: "MKUpdate", dependencies: ["MKCore"]),
        // What every test target shares: throwaway folders.
        .target(name: "MKTestSupport", dependencies: ["MKCore"], path: "Tests/MKTestSupport"),
        .testTarget(name: "MKCoreTests", dependencies: ["MKCore", "MKTestSupport"]),
        .testTarget(name: "MKCommandsTests", dependencies: ["MKCommands", "MKCore", "MKTestSupport"]),
        .testTarget(name: "MKLayoutTests", dependencies: ["MKLayout", "MKCore", "MKTestSupport"]),
        .testTarget(name: "MKMenuBarTests", dependencies: ["MKMenuBar", "MKCore", "MKCommands", "MKLayout", "MKTestSupport"]),
        .testTarget(name: "MKSearchTests", dependencies: ["MKSearch", "MKCore", "MKLayout", "MKTestSupport"]),
        .testTarget(name: "MKUpdateTests", dependencies: ["MKUpdate", "MKCore", "MKTestSupport"]),
    ]
)
