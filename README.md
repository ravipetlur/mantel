# Mantel

A menu bar organizer for macOS. I built it for my own Mac: it hides the menu bar icons I don't need and keeps them one click away.

Your icons and settings stay on your Mac. No account, no cloud. The only time Mantel goes online is to check GitHub for a new version once a day (you can turn that off in Settings › About), and to download one when you choose to install it.

## What it does

- **Hide icons.** Sort apps into Shown, Hidden and Always Hidden, then click the • dot to see the hidden ones.
- **A second bar.** When hidden icons don't fit, say beside the notch, they open in a small bar under the dot. Click one and its own menu opens.
- **Arrange the menu bar.** Drag icons in Settings to reorder the real menu bar. Add spacers, groups and a divider.
- **Find any icon.** A command bar finds an icon by name and clicks it, and any icon can have its own hotkey.
- **Focus Mode** leaves just the clock and Control Center.
- **Check for Updates…** in the dot's menu. Nothing installs until you say so.

When Mantel quits, every hidden icon comes back. The order you set stays until you choose Restore original layout.

## Status

Early. It works on my Mac; expect rough edges.

## Build it

You need macOS 27 on Apple Silicon, Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```
make install   # builds Mantel and puts it in /Applications
make test      # runs the tests
```

Mantel has to run from `/Applications`. It asks for Device control and data access, to see and move the icons, and optionally Screen Recording, for pictures of the hidden ones.

To sign with your own identity, copy `Config/Local.example.xcconfig` to `Config/Local.xcconfig` and fill it in.

## Releases

Push a tag like `v1.2.0` and GitHub builds, signs and notarizes the DMG and publishes it as a release. Write what's new in `release-notes/1.2.0.md` first. Installed copies are offered the signed release in the app.

## License

Apache 2.0
