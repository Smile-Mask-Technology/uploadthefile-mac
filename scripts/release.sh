#!/bin/sh
# Builds a release: universal app, Developer ID signature, notarization, stapled DMG, and the
# Sparkle appcast that offers the DMG to installed copies of the app.
#
#   SIGN_IDENTITY="Developer ID Application: Smile Mask Technology FZE (G323SXP8VG)" \
#   NOTARY_PROFILE=uptf-notary RELEASE_NOTES_HTML=notes.html scripts/release.sh
#
# NOTARY_PROFILE is a notarytool keychain profile, stored once with
#   xcrun notarytool store-credentials <name> --apple-id <email> --team-id <team id>
# Nothing secret is read or printed here: notarytool takes the credentials from the Keychain, and
# so does Sparkle's sign_update (the update signing key, account uploadthefile-mac, in the login
# keychain; it is never exported).
#
# RELEASE_NOTES_HTML is an HTML file with this release's notes; it is embedded in the appcast and
# shown in the update window.
#
# Output: build/release/UploadTheFile.dmg and its SHA-256 (for the Homebrew cask), and
# build/release/appcast.xml, signed with the update key (attach it to the GitHub release as it is;
# a change to the file breaks its signature). The DMG name has no
# version on purpose: every release uploads the same asset name, so the README's link
# https://github.com/Smile-Mask-Technology/uploadthefile-mac/releases/latest/download/UploadTheFile.dmg
# always gives the newest version (the version is in the release's tag); the appcast works the same
# way, through releases/latest/download/appcast.xml.
set -eu
# The notes path is relative to where the command was typed, so it is made absolute before cd.
case "${RELEASE_NOTES_HTML:-}" in ""|/*) ;; *) RELEASE_NOTES_HTML="$PWD/$RELEASE_NOTES_HTML" ;; esac
cd "$(dirname "$0")/.."
fail() { echo "$*" >&2; exit 1; }

: "${SIGN_IDENTITY:?set SIGN_IDENTITY to a Developer ID Application identity}"
: "${RELEASE_NOTES_HTML:?set RELEASE_NOTES_HTML to an HTML file with the notes for this release}"
NOTARY_PROFILE="${NOTARY_PROFILE:-uptf-notary}"
VERSION="$(cat VERSION)"
APP="build/Upload the File.app"
OUT="build/release"
DMG="$OUT/UploadTheFile.dmg"
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"
SPARKLE_ACCOUNT="uploadthefile-mac"
DOWNLOAD_URL="https://github.com/Smile-Mask-Technology/uploadthefile-mac/releases/download/v$VERSION/UploadTheFile.dmg"

case "$SIGN_IDENTITY" in
  "Developer ID Application:"*) ;;
  *) echo "SIGN_IDENTITY must be a Developer ID Application identity" >&2; exit 64 ;;
esac
[ -s "$RELEASE_NOTES_HTML" ] || { echo "RELEASE_NOTES_HTML is missing or empty: $RELEASE_NOTES_HTML" >&2; exit 64; }
# The notes are shown to every user in the update window: they must be this release's (not the
# last one's, and not a Markdown file), and must not load anything from the network.
grep -qF "$VERSION" "$RELEASE_NOTES_HTML" ||
  { echo "RELEASE_NOTES_HTML does not mention version $VERSION: $RELEASE_NOTES_HTML" >&2; exit 64; }
if grep -Eqi 'src(set)?=' "$RELEASE_NOTES_HTML"; then
  echo "RELEASE_NOTES_HTML loads files from elsewhere (src=); the update window must not make requests." >&2
  exit 64
fi

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

# Sparkle offers an update only when its build number (CFBundleVersion, the commit count of main)
# is higher than the installed one. A shallow clone, another branch, or a history that lacks the
# previous release gives a number that is too low, or one that later releases from main cannot
# pass; nobody would be offered the update and nothing would report it.
[ "$(git rev-parse --is-shallow-repository)" = "false" ] ||
  { echo "This is a shallow clone: the build number (commit count) would be wrong." >&2; exit 65; }
[ "$(git symbolic-ref --short -q HEAD || true)" = "main" ] ||
  { echo "Release from main: the build number is main's commit count." >&2; exit 65; }
PREV_TAG="$(git tag --list 'v*' --sort=-v:refname | grep -vx "v$VERSION" | head -1 || true)"
[ -z "$PREV_TAG" ] || git merge-base --is-ancestor "$PREV_TAG" HEAD ||
  { echo "HEAD does not contain $PREV_TAG: this build would not compare as newer." >&2; exit 65; }

echo "==> Tests"
mkdir -p build
scripts/test.sh > build/release-tests.log 2>&1 || { tail -20 build/release-tests.log; exit 1; }
tail -1 build/release-tests.log

echo "==> Update signing key"
# Sparkle's tools come with the package (fetched by the test run above). The private key stays in
# the login keychain; only the public half is read, to compare it with the one in the app.
for TOOL in sign_update generate_keys; do
  [ -x "$SPARKLE_BIN/$TOOL" ] || { echo "Missing $SPARKLE_BIN/$TOOL" >&2; exit 1; }
done
KEYCHAIN_KEY="$("$SPARKLE_BIN/generate_keys" --account "$SPARKLE_ACCOUNT" -p)" || {
  echo "The update signing key (account $SPARKLE_ACCOUNT) is not in the login keychain" >&2; exit 1
}
[ -n "$KEYCHAIN_KEY" ] || { echo "The keychain returned no public key for account $SPARKLE_ACCOUNT" >&2; exit 1; }

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
# The updater: the app carries the public key the keychain's private key signs for, and the
# framework it embeds is signed by the same team with the hardened runtime and has no XPC services.
APP_KEY="$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$APP/Contents/Info.plist")"
[ "$APP_KEY" = "$KEYCHAIN_KEY" ] || fail "The app's SUPublicEDKey does not match the public key of keychain account $SPARKLE_ACCOUNT"
/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$APP/Contents/Info.plist" | grep -q '^https://' ||
  fail "The app has no https SUFeedURL"
# The update archive is checked before it is opened, and the feed must be signed (the appcast is
# signed below); the update window runs no scripts and opens no extra kinds of links.
[ "$(/usr/libexec/PlistBuddy -c "Print :SUVerifyUpdateBeforeExtraction" "$APP/Contents/Info.plist" 2>/dev/null)" = "true" ] ||
  fail "The app does not set SUVerifyUpdateBeforeExtraction to true"
[ "$(/usr/libexec/PlistBuddy -c "Print :SURequireSignedFeed" "$APP/Contents/Info.plist" 2>/dev/null)" = "true" ] ||
  fail "The app does not set SURequireSignedFeed to true"
/usr/libexec/PlistBuddy -c "Print :SUEnableJavaScript" "$APP/Contents/Info.plist" > /dev/null 2>&1 && fail "The app sets SUEnableJavaScript; the update window must not run scripts"
/usr/libexec/PlistBuddy -c "Print :SUAllowedURLSchemes" "$APP/Contents/Info.plist" > /dev/null 2>&1 && fail "The app sets SUAllowedURLSchemes; the update window must only open web links"
SPARKLE_FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
[ -d "$SPARKLE_FRAMEWORK" ] || fail "The app does not contain Sparkle.framework"
# The framework in the app is the version Package.resolved pins (the one the app was linked with).
SPARKLE_PINNED="$(grep -A5 '"identity" : "sparkle"' Package.resolved | sed -n 's/.*"version" : "\([^"]*\)".*/\1/p')"
SPARKLE_EMBEDDED="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$SPARKLE_FRAMEWORK/Versions/B/Resources/Info.plist")"
[ -n "$SPARKLE_PINNED" ] && [ "$SPARKLE_EMBEDDED" = "$SPARKLE_PINNED" ] ||
  fail "The embedded Sparkle.framework is version $SPARKLE_EMBEDDED but Package.resolved pins $SPARKLE_PINNED"
for XPC in "$SPARKLE_FRAMEWORK/XPCServices" "$SPARKLE_FRAMEWORK/Versions/B/XPCServices"; do
  { [ -e "$XPC" ] || [ -L "$XPC" ]; } && fail "Sparkle.framework still contains XPCServices (the app is not sandboxed)"
done
team_of() { codesign -dvv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p'; }
APP_TEAM="$(team_of "$APP")"
[ -n "$APP_TEAM" ] && [ "$APP_TEAM" != "not set" ] || fail "The app has no team in its signature"
[ "$APP_TEAM" = "G323SXP8VG" ] || fail "The app is signed by team $APP_TEAM, not G323SXP8VG (Smile Mask Technology FZE)"
for PART in "$SPARKLE_FRAMEWORK" "$SPARKLE_FRAMEWORK/Versions/B/Autoupdate" "$SPARKLE_FRAMEWORK/Versions/B/Updater.app"; do
  codesign --verify --strict --verbose=2 "$PART"
  [ "$(team_of "$PART")" = "$APP_TEAM" ] || fail "$(basename "$PART") is not signed by the app's team ($APP_TEAM)"
  codesign -d --verbose=2 "$PART" 2>&1 | grep -q 'flags=.*runtime' ||
    fail "$(basename "$PART") is not signed with the hardened runtime"
done
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

echo "==> Update feed"
# Signed after stapling: stapling changes the DMG, and the signature covers its final bytes.
SIGNATURE="$("$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" -p "$DMG")" || { printf '%s\n' "$SIGNATURE" >&2; fail "sign_update failed"; }
[ -n "$SIGNATURE" ] || fail "sign_update returned no signature"
"$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" --verify "$DMG" "$SIGNATURE" ||
  fail "The update signature of the DMG does not verify"
DMG_LENGTH="$(/usr/bin/stat -f %z "$DMG")"
BUNDLE_BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")"
# The oldest macOS the appcast offers the update to is the one the app itself declares.
MIN_SYSTEM="$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP/Contents/Info.plist")"
case "$MIN_SYSTEM" in *.*.*) ;; *.*) MIN_SYSTEM="$MIN_SYSTEM.0" ;; *) MIN_SYSTEM="$MIN_SYSTEM.0.0" ;; esac
sh scripts/make-appcast.sh --version "$VERSION" --build "$BUNDLE_BUILD" \
  --url "$DOWNLOAD_URL" --signature "$SIGNATURE" --length "$DMG_LENGTH" --min-system "$MIN_SYSTEM" \
  --notes "$RELEASE_NOTES_HTML" --output "$OUT/appcast.xml"
# The feed is signed in place (the app requires it). Never edit the file afterwards: any change,
# even to the notes, needs this signing step again.
"$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" "$OUT/appcast.xml" || fail "Signing the appcast failed"
"$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" --verify "$OUT/appcast.xml" || fail "The signature of the appcast does not verify"
xmllint --noout "$OUT/appcast.xml"

echo "Release ready: $DMG (version $VERSION, build $BUNDLE_BUILD)"
echo "SHA-256: $SHA"
echo "Appcast: $OUT/appcast.xml (signed; attach it to the GitHub release next to the DMG, and never edit it)"
