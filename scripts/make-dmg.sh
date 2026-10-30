#!/bin/bash
# Packs Mantel.app into Mantel-<version>.dmg: a compressed (UDZO), read-only disk image named "Mantel" holding
# the app and an Applications shortcut to drag it onto. Uses only macOS's own tools (ditto, hdiutil, codesign).
#
#   scripts/make-dmg.sh <path to Mantel.app> <version> [output folder, default build]
#
# `make dmg` runs it after the Release build; so does the release workflow. It packs the app as it is signed and doesn't
# sign the image: the release workflow signs, notarizes and staples it when it has a Developer ID.
set -euo pipefail

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
    echo "usage: $0 <path to Mantel.app> <version> [output folder]" >&2
    exit 64
fi
app=$1
version=$2
output=${3:-build}

# The version goes into a file name: letters, digits, dots, plus and hyphens only (1.2.0, 1.2.0-beta.1, 0.0.0-local).
if ! [[ $version =~ ^[0-9A-Za-z][0-9A-Za-z.+-]*$ ]]; then
    echo "error: '$version' isn't a version (letters, digits, '.', '+' and '-' only)" >&2
    exit 65
fi
if [ ! -d "$app" ] || [ "$(basename "$app")" != "Mantel.app" ]; then
    echo "error: '$app' isn't a Mantel.app bundle" >&2
    exit 66
fi
# A broken or partial signature would only show once someone opens the app.
codesign --verify --strict --deep "$app"

mkdir -p "$output"
dmg="$output/Mantel-$version.dmg"
staging=$(mktemp -d "${TMPDIR:-/tmp}/mantel-dmg.XXXXXX")
trap 'rm -rf "$staging"' EXIT
# The folder becomes the volume's root, which mktemp made private.
chmod 755 "$staging"

# ditto keeps the bundle exactly as built: its signature, extended attributes and symlinks.
ditto "$app" "$staging/Mantel.app"
ln -s /Applications "$staging/Applications"
# Exactly these two, nothing else.
contents=$(cd "$staging" && LC_ALL=C ls -A | tr '\n' ' ')
if [ "$contents" != "Applications Mantel.app " ]; then
    echo "error: the image would hold: $contents" >&2
    exit 70
fi

# macOS 27 marks `hdiutil create` and `attach` deprecated in favour of `diskutil image`; they still work as before.
rm -f "$dmg"
hdiutil create -quiet -volname Mantel -srcfolder "$staging" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$dmg"
hdiutil verify -quiet "$dmg"

echo "$dmg ($(du -h "$dmg" | cut -f 1))"
