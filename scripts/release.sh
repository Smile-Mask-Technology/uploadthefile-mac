#!/bin/sh
# Builds a release: universal app, Developer ID signature, notarization, stapled DMG.
#
#   SIGN_IDENTITY="Developer ID Application: Smile Mask Technology FZE (G323SXP8VG)" \
#   NOTARY_PROFILE=uptf-notary scripts/release.sh
#
# NOTARY_PROFILE is a notarytool keychain profile, stored once with
#   xcrun notarytool store-credentials <name> --apple-id <email> --team-id <team id>
# Nothing secret is read or printed here: notarytool takes the credentials from the Keychain.
#
# Output: build/release/UploadTheFile.dmg and its SHA-256 (for the Homebrew cask). The name has no
# version on purpose: every release uploads the same asset name, so the README's link
# https://github.com/Smile-Mask-Technology/uploadthefile-mac/releases/latest/download/UploadTheFile.dmg
# always gives the newest version (the version is in the release's tag).
set -eu
cd "$(dirname "$0")/.."

: "${SIGN_IDENTITY:?set SIGN_IDENTITY to a Developer ID Application identity}"
NOTARY_PROFILE="${NOTARY_PROFILE:-uptf-notary}"
VERSION="$(cat VERSION)"
APP="build/Upload the File.app"
OUT="build/release"
DMG="$OUT/UploadTheFile.dmg"

case "$SIGN_IDENTITY" in
  "Developer ID Application:"*) ;;
  *) echo "SIGN_IDENTITY must be a Developer ID Application identity" >&2; exit 64 ;;
esac

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "The working tree has uncommitted changes; commit them first so the build matches a commit." >&2
  exit 65
fi

echo "==> Tests"
scripts/test.sh > build/release-tests.log 2>&1 || { tail -20 build/release-tests.log; exit 1; }
tail -1 build/release-tests.log

echo "==> Universal signed app"
UNIVERSAL=1 SIGN_IDENTITY="$SIGN_IDENTITY" scripts/build-app.sh
for BIN in "$APP/Contents/MacOS/UploadTheFile" "$APP/Contents/Resources/uptf"; do
  echo "    $(basename "$BIN"): $(lipo -archs "$BIN")"
done

echo "==> Notarizing the app"
rm -rf "$OUT"
mkdir -p "$OUT"
ditto -c -k --keepParent "$APP" "$OUT/app.zip"
xcrun notarytool submit "$OUT/app.zip" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 30m
xcrun stapler staple "$APP"
rm "$OUT/app.zip"

echo "==> DMG"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Upload the File.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Upload the File" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" > /dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"

echo "==> Notarizing the DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 30m
xcrun stapler staple "$DMG"

echo "==> Gatekeeper"
spctl --assess --type execute --verbose=2 "$APP"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
xcrun stapler validate "$DMG"

SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo "$SHA  $(basename "$DMG")" > "$DMG.sha256"
echo "Release ready: $DMG (version $VERSION)"
echo "SHA-256: $SHA"
