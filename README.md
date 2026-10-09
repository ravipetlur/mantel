# Mantel

Mantel is a menu bar organizer for macOS. I'm building it for my own daily use, to hide, reveal and arrange the icons in the menu bar. It works entirely on your Mac, with no account and no cloud service, and it's licensed under Apache 2.0.

It's in development. The foundation is built:
- a menu bar app with no Dock icon;
- onboarding;
- a Settings window: General, Hotkeys, Permissions, Diagnostics and About;
- its own global hotkeys, with clash warnings;
- a `mantel` command-line tool;
- a Diagnostics page that checks the macOS pieces Mantel relies on.

Hiding, revealing and arranging icons come in later versions.

To build it, you need macOS 27 on Apple Silicon, Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). Then:
- `make build` generates the project and builds a debug copy in `build/`;
- `make install` puts a release build in `/Applications` and opens it;
- `make test` runs the tests.

Mantel must run from `/Applications`, because macOS only honours its menu bar requests for the installed copy.

Builds are signed ad hoc under a placeholder bundle identifier. To use your own, copy `Config/Local.example.xcconfig` to `Config/Local.xcconfig` and fill it in. Sign with a certificate if you can: an ad hoc signature changes with every build, so macOS asks for Accessibility again each time.

The `mantel` tool lives inside the app, at `Mantel.app/Contents/Helpers/mantel`. Try `mantel ping` or `mantel diagnostics`. Mantel keeps its settings, logs and backups in `~/Library/Application Support/Mantel` and `~/Library/Logs/Mantel`. The file `control.sock.lock` beside the socket is how Mantel knows another copy is running; leave it there.
