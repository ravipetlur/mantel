import Foundation
import MKCommands
import MKTestSupport

/// A throwaway app bundle signed ad hoc, with a program in `Contents/Helpers/mantel`, for the tests of how the app tells its own
/// tool. The programs are copies of the system's own small ones, signed again here, or (for the tests with a program that
/// connects) a small C program compiled with `clang`; nothing outside the temporary folder is touched.
struct MiniApp {
    enum Failure: Error { case toolFailed(String) }

    /// Held for as long as the app is used: the app is in it.
    let folder: TemporaryFolder
    var appURL: URL { folder.url.appending(path: "Mini.app", directoryHint: .isDirectory) }
    var helperURL: URL { appURL.appending(path: OwnSigning.helperPathInBundle) }

    static var canSign: Bool { FileManager.default.isExecutableFile(atPath: "/usr/bin/codesign") }

    /// Whether the program that connects can be built and run here: `clang` is a stub in `/usr/bin` that is there without the
    /// developer tools (`xcode-select -p` fails without them), and the program is built for arm64 only, which only an arm64 Mac runs.
    static let canCompileConnector: Bool = {
        #if arch(arm64)
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/clang") else { return false }
        return (try? run("/usr/bin/xcode-select", ["-p"])) != nil
        #else
        return false
        #endif
    }()

    /// An app with the program at `helper` as its tool, signed with `identifier`. With `signApp` false the app itself is left
    /// unsigned.
    init(helper: String = "/usr/bin/true", identifier: String = "com.example.mini.cli", signApp: Bool = true,
         withHelper: Bool = true) throws {
        folder = TemporaryFolder.shortForSockets()
        let fileManager = FileManager.default
        let macOS = appURL.appending(path: "Contents/MacOS", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fileManager.copyItem(at: URL(filePath: "/usr/bin/true"), to: macOS.appending(path: "Mini"))
        let info: [String: Any] = ["CFBundleExecutable": "Mini", "CFBundleIdentifier": "com.example.mini",
                                   "CFBundleName": "Mini", "CFBundlePackageType": "APPL", "CFBundleVersion": "1"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: appURL.appending(path: "Contents/Info.plist"))
        if withHelper {
            try fileManager.createDirectory(at: helperURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: URL(filePath: helper), to: helperURL)
            try Self.sign(helperURL, identifier: identifier)
        }
        if signApp { try Self.sign(appURL, identifier: "com.example.mini") }
    }

    /// Puts another program, with a good signature of its own, where the tool is, and leaves the app's signature as it was.
    func swapHelper(for source: String, identifier: String) throws {
        let fileManager = FileManager.default
        try fileManager.removeItem(at: helperURL)
        try fileManager.copyItem(at: URL(filePath: source), to: helperURL)
        try Self.sign(helperURL, identifier: identifier)
    }

    /// A program that connects to the Unix socket whose path is its first argument and waits there until its input ends: a
    /// stand-in for the tool, made for one architecture (the Mac's own, as the tool is) so that what runs is what is hashed.
    /// `variant` makes the programs differ.
    static func compileConnector(variant: Int, in folder: TemporaryFolder) throws -> String {
        let source = folder.url.appending(path: "connector\(variant).c")
        let output = folder.url.appending(path: "connector\(variant)")
        let code = """
        #include <string.h>
        #include <sys/socket.h>
        #include <sys/un.h>
        #include <unistd.h>
        static const int variant = \(variant);
        int main(int argc, char **argv) {
            if (argc < 2) return variant;
            int fd = socket(AF_UNIX, SOCK_STREAM, 0);
            struct sockaddr_un address;
            memset(&address, 0, sizeof address);
            address.sun_family = AF_UNIX;
            strncpy(address.sun_path, argv[1], sizeof address.sun_path - 1);
            if (connect(fd, (struct sockaddr *)&address, sizeof address) != 0) return 1;
            char byte;
            (void)read(0, &byte, 1);
            return 0;
        }
        """
        try Data(code.utf8).write(to: source)
        try run("/usr/bin/clang", ["-arch", "arm64", "-o", output.path, source.path])
        return output.path
    }

    /// What `codesign` says the code directory hash of `url` is, written as the app writes it.
    static func codeDirectoryHash(of url: URL) throws -> String {
        let output = try run("/usr/bin/codesign", ["-d", "--verbose=4", url.path])
        guard let line = output.split(separator: "\n").first(where: { $0.hasPrefix("CDHash=") }) else {
            throw Failure.toolFailed("no CDHash in: \(output)")
        }
        return String(line.dropFirst("CDHash=".count))
    }

    static func sign(_ url: URL, identifier: String) throws {
        _ = try run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", identifier, url.path])
    }

    /// Runs a program and returns what it wrote to the output and error streams. Throws if it fails.
    @discardableResult
    static func run(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw Failure.toolFailed("\(path) \(arguments): \(text)") }
        return text
    }
}
