#!/bin/sh
# Builds the disk image people open to install the app: a small window with the app on the left
# and the Applications folder on the right (layout in scripts/dmg-settings.py, background in
# Resources/DMG).
#
#   scripts/make-dmg.sh "build/Upload the File.app" build/UploadTheFile.dmg
#
# The image is written by dmgbuild, installed from scripts/requirements-dmg.txt (pinned, with
# hashes) into the private environment .build/dmg-venv. The environment is created from a Python
# 3.11 or newer, and its packages are installed again only when the requirements file changed.
# Signing and notarization are done by scripts/release.sh, after this.
set -eu
APP="${1:-}"
OUT="${2:-}"
[ -d "$APP" ] && [ -n "$OUT" ] || { echo "usage: scripts/make-dmg.sh <Upload the File.app> <output.dmg>" >&2; exit 64; }
# The paths are relative to where the command was typed, so they are made absolute before cd.
case "$APP" in /*) ;; *) APP="$PWD/$APP" ;; esac
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
cd "$(dirname "$0")/.."

VENV=".build/dmg-venv"
STAMP="$VENV/requirements.stamp"

if [ ! -x "$VENV/bin/dmgbuild" ] || ! cmp -s scripts/requirements-dmg.txt "$STAMP"; then
  if [ ! -x "$VENV/bin/python3" ]; then
    PYTHON=""
    for CANDIDATE in /opt/homebrew/bin/python3 python3; do
      if command -v "$CANDIDATE" > /dev/null 2>&1 &&
         "$CANDIDATE" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)'; then
        PYTHON="$CANDIDATE"
        break
      fi
    done
    [ -n "$PYTHON" ] || { echo "make-dmg.sh needs Python 3.11 or newer (for example: brew install python)." >&2; exit 1; }
    echo "==> Creating $VENV with $PYTHON"
    "$PYTHON" -m venv "$VENV"
  fi
  echo "==> Installing dmgbuild"
  "$VENV/bin/pip" install --disable-pip-version-check --require-hashes -r scripts/requirements-dmg.txt
  cp scripts/requirements-dmg.txt "$STAMP"
fi

echo "==> Disk image"
mkdir -p "$(dirname "$OUT")"
"$VENV/bin/dmgbuild" -s scripts/dmg-settings.py -D "app=$APP" "Upload the File" "$OUT"
[ -s "$OUT" ] || { echo "dmgbuild did not write $OUT" >&2; exit 1; }
echo "Built $OUT"
