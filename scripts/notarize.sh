#!/bin/bash
# Submits a file to Apple's notary service with an App Store Connect API key, waits for the verdict and says how long it
# took. The release workflow runs it on its Developer ID path, for a zip of the app and then for the signed DMG.
#
#   NOTARY_KEY_FILE=<path to the .p8> NOTARY_KEY_ID=<key ID> NOTARY_ISSUER_ID=<issuer ID> scripts/notarize.sh <file>
#
# It succeeds only when the submission is Accepted; otherwise it prints the notary service's log and fails. Stapling is
# left to the caller.
set -euo pipefail

if [ $# -ne 1 ]; then
    echo "usage: NOTARY_KEY_FILE=… NOTARY_KEY_ID=… NOTARY_ISSUER_ID=… $0 <file>" >&2
    exit 64
fi
file=$1
: "${NOTARY_KEY_FILE:?the path to the .p8 key}" "${NOTARY_KEY_ID:?the key ID}" "${NOTARY_ISSUER_ID:?the issuer ID}"
if [ ! -f "$file" ]; then
    echo "error: '$file' isn't a file" >&2
    exit 66
fi

credentials=(--key "$NOTARY_KEY_FILE" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
result=$(mktemp "${TMPDIR:-/tmp}/notarization.XXXXXX")
trap 'rm -f "$result"' EXIT

name=$(basename "$file")
echo "Submitting $name for notarization…"
start=$SECONDS
# The verdict is read from the JSON, not the exit status.
xcrun notarytool submit "$file" "${credentials[@]}" --wait --timeout 1h --output-format json > "$result" || true
elapsed=$((SECONDS - start))
status=$(plutil -extract status raw "$result" 2> /dev/null || echo "no answer")
submission=$(plutil -extract id raw "$result" 2> /dev/null || true)

took=$(printf '%dm %02ds' $((elapsed / 60)) $((elapsed % 60)))
echo "Notarization of $name: $status after $took${submission:+ (submission $submission)}"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    echo "- Notarization of \`$name\`: $status after $took" >> "$GITHUB_STEP_SUMMARY"
fi

if [ "$status" != Accepted ]; then
    if [ -n "$submission" ]; then
        xcrun notarytool log "$submission" "${credentials[@]}" || true
    fi
    echo "error: the notary service didn't accept $name ($status)" >&2
    exit 1
fi
