#!/bin/sh
# Run by hand after `gh release create` (docs/RELEASING.md): checks that what GitHub serves is what
# scripts/release.sh built, because every installed copy reads these two files.
#
#   scripts/check-published.sh
#
# It downloads releases/latest/download/appcast.xml and the release's UploadTheFile.dmg, and
# compares them with build/release/appcast.xml and build/release/UploadTheFile.dmg.sha256. It only
# reads: nothing is uploaded, changed or signed. Exit status 0 means they match.
set -eu
cd "$(dirname "$0")/.."

VERSION="$(cat VERSION)"
RELEASES="https://github.com/Smile-Mask-Technology/uploadthefile-mac/releases"
OUT="build/release"
fail() { printf '%s\n' "$*" >&2; exit 1; }

[ -s "$OUT/appcast.xml" ] || fail "Missing $OUT/appcast.xml; run scripts/release.sh first"
[ -s "$OUT/UploadTheFile.dmg.sha256" ] || fail "Missing $OUT/UploadTheFile.dmg.sha256; run scripts/release.sh first"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

curl -fsSL "$RELEASES/latest/download/appcast.xml" -o "$WORK/appcast.xml" ||
  fail "MISMATCH: the published feed ($RELEASES/latest/download/appcast.xml) cannot be downloaded; fix the release before anyone updates"
cmp -s "$WORK/appcast.xml" "$OUT/appcast.xml" ||
  fail "MISMATCH: the published feed differs from $OUT/appcast.xml; fix the release before anyone updates"

curl -fsSL "$RELEASES/download/v$VERSION/UploadTheFile.dmg" -o "$WORK/UploadTheFile.dmg" ||
  fail "MISMATCH: the disk image of v$VERSION cannot be downloaded (is the tag exactly v$VERSION?); fix the release before anyone updates"
PUBLISHED_SHA="$(shasum -a 256 "$WORK/UploadTheFile.dmg" | cut -d' ' -f1)"
BUILT_SHA="$(cut -d' ' -f1 "$OUT/UploadTheFile.dmg.sha256")"
[ "$PUBLISHED_SHA" = "$BUILT_SHA" ] ||
  fail "MISMATCH: the published disk image ($PUBLISHED_SHA) is not the one built ($BUILT_SHA); fix the release before anyone updates"

printf '%s\n' "The published feed and disk image match this build (version $VERSION)."
