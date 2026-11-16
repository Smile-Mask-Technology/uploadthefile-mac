#!/bin/sh
# Draws every screen state of the app (menu bar window, publish window, Options window; light and
# dark) to PNG files in build/snapshots/, off screen, with fixture data. Nothing is shown on the
# display and nothing touches the network, the Keychain or your files. Debug build only.
#
#   scripts/snapshots.sh
set -eu
cd "$(dirname "$0")/.."

OUT="build/snapshots"

echo "==> Building (debug)"
swift build --product UploadTheFile
BIN_DIR="$(swift build --show-bin-path)"

echo "==> Rendering into $OUT"
rm -rf "$OUT"
mkdir -p "$OUT"
"$BIN_DIR/UploadTheFile" --render-snapshots "$OUT" > /dev/null

echo "==> Files"
ls -l "$OUT"
