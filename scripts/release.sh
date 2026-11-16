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

# Everything the build reads from the working tree must be in the commit: modified tracked files
# and also files git does not know yet (SwiftPM compiles every .swift file in a target folder, so
# an untracked source would be built into the signed app).
BUILD_INPUTS="Sources Plugins Resources scripts Package.swift Package.resolved VERSION LICENSE THIRD_PARTY_NOTICES.txt"
check_tree_matches_commit() {
  if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    echo "$1 The working tree has uncommitted changes; commit them first so the build matches a commit." >&2
    git status --short --untracked-files=no >&2
    exit 65
  fi
  # shellcheck disable=SC2086
  UNTRACKED="$(git ls-files --others --exclude-standard -- $BUILD_INPUTS)"
  if [ -n "$UNTRACKED" ]; then
    echo "$1 These files are not in git, so the build would not match a commit:" >&2
    echo "$UNTRACKED" >&2
    exit 65
  fi
}
check_tree_matches_commit "Before the build:"

echo "==> Tests"
mkdir -p build
scripts/test.sh > build/release-tests.log 2>&1 || { tail -20 build/release-tests.log; exit 1; }
tail -1 build/release-tests.log

echo "==> Universal signed app"
UNIVERSAL=1 SIGN_IDENTITY="$SIGN_IDENTITY" scripts/build-app.sh
# The notices must match the package versions this build actually compiled in.
scripts/make-notices.sh > /dev/null
git diff --quiet -- THIRD_PARTY_NOTICES.txt || {
  echo "THIRD_PARTY_NOTICES.txt is out of date for this build; commit the regenerated file and rerun." >&2
  exit 1
}
# The build must not have changed or added anything it reads (a re-resolved Package.resolved, a
# regenerated file).
check_tree_matches_commit "After the build:"
for f in THIRD_PARTY_NOTICES.txt LICENSE; do
  [ -s "$APP/Contents/Resources/$f" ] || { echo "The app is missing Contents/Resources/$f" >&2; exit 1; }
done
fail() { echo "$*" >&2; exit 1; }

echo "==> Checking the built app"
for BIN in "$APP/Contents/MacOS/UploadTheFile" "$APP/Contents/Resources/uptf"; do
  ARCHS="$(lipo -archs "$BIN")"
  echo "    $(basename "$BIN"): $ARCHS"
  case " $ARCHS " in *" arm64 "*) ;; *) fail "$(basename "$BIN") has no Apple silicon (arm64) slice: $ARCHS" ;; esac
  case " $ARCHS " in *" x86_64 "*) ;; *) fail "$(basename "$BIN") has no Intel (x86_64) slice: $ARCHS" ;; esac
done
codesign --verify --strict --deep --verbose=2 "$APP"
codesign --verify --strict --verbose=2 "$APP/Contents/Resources/uptf"
for SIGNED in "$APP" "$APP/Contents/Resources/uptf"; do
  # No exceptions to the hardened runtime, and the hardened runtime itself is on.
  ENTITLEMENTS_OUT="$(codesign -d --entitlements :- "$SIGNED" 2>/dev/null || true)"
  case "$ENTITLEMENTS_OUT" in
    *"<key>"*) fail "$(basename "$SIGNED") is signed with entitlements; they must be empty" ;;
  esac
  codesign -d --verbose=2 "$SIGNED" 2>&1 | grep -q 'flags=.*runtime' ||
    fail "$(basename "$SIGNED") is not signed with the hardened runtime"
done
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
[ "$BUNDLE_VERSION" = "$VERSION" ] || fail "The app's version is $BUNDLE_VERSION but VERSION says $VERSION"
CLI_VERSION="$("$APP/Contents/Resources/uptf" --version)"
[ "$CLI_VERSION" = "$VERSION" ] || fail "The embedded uptf reports version $CLI_VERSION but VERSION says $VERSION"
# Debug-only snapshot code must not be in the release binary.
if strings "$APP/Contents/MacOS/UploadTheFile" | grep -q render-snapshots; then
  fail "render-snapshots found in the release binary"
fi

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
cp LICENSE "$STAGE/LICENSE.txt"
cp THIRD_PARTY_NOTICES.txt "$STAGE/THIRD_PARTY_NOTICES.txt"
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
