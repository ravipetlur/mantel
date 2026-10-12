# Mantel

Mantel is a menu bar organizer for macOS. I'm building it for my own daily use, to hide, reveal and arrange the icons in the menu bar. It works entirely on your Mac, with no account and no cloud service, and it's licensed under Apache 2.0.

It's in development. The foundation is built:
- a menu bar app that shows a Dock icon only while one of its windows is open;
- onboarding;
- a Settings window: General, Layout, Hotkeys, Permissions, Advanced, Diagnostics and About;
- its own global hotkeys, with clash warnings;
- a `mantel` command-line tool;
- a Diagnostics page that checks the macOS pieces Mantel relies on.

Hiding and revealing icons work now. In Settings I sort apps into Shown, Hidden and Always Hidden, and Mantel picks one of three ways of hiding them by itself. I reveal the hidden ones with the • and •• dots, by hovering over, clicking or scrolling on empty menu bar space, with hotkeys, or from the `mantel` command line, and they hide again after a delay. Focus Mode leaves only the clock and Control Center. Clicking the clock still opens Notification Center while icons are hidden. Icons that don't fit beside the notch move to Hidden on their own, and come back when there's room. Refresh and reset fix a stuck menu bar, and every change Mantel makes to macOS is undone when I quit, including when it's stopped from the command line, and after a crash. Reordering icons, a second bar for the hidden ones and icon images come in later versions.

To build it, you need macOS 27 on Apple Silicon, Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). Then:
- `make build` generates the project and builds a debug copy in `build/`;
- `make install` puts a release build in `/Applications` and opens it;
- `make test` runs the tests.

Mantel must run from `/Applications`, because macOS only honours its menu bar requests for the installed copy.

Builds are signed ad hoc under a placeholder bundle identifier. To use your own, copy `Config/Local.example.xcconfig` to `Config/Local.xcconfig` and fill it in. Sign with a certificate if you can: an ad hoc signature changes with every build, so macOS asks for Accessibility again each time.

The `mantel` tool lives inside the app, at `Mantel.app/Contents/Helpers/mantel`. Try `mantel ping`, `mantel show all`, `mantel focus on` or `mantel diagnostics`. Mantel keeps its settings, logs and backups in `~/Library/Application Support/Mantel` and `~/Library/Logs/Mantel`. The file `control.sock.lock` beside the socket is how Mantel knows another copy is running; leave it there.
