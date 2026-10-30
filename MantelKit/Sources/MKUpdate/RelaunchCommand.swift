/// Restarting Mantel after an update: a `/bin/sh` that waits for this process to exit, so the single-instance check passes
/// (`SingleInstance`), then opens the app again. The PID and the app's path are the script's positional parameters, never part
/// of the script, so nothing in a path (quotes, `;`, `$`) is run.
public enum RelaunchCommand {
    static let script = "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; /usr/bin/open \"$2\""

    /// The arguments for `/bin/sh`: the script, then `$0` ("sh"), `$1` (the PID) and `$2` (the app's path).
    public static func arguments(pid: Int32, appPath: String) -> [String] {
        ["-c", script, "sh", String(pid), appPath]
    }
}
