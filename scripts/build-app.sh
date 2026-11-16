#!/bin/sh
# Builds "Upload the File.app" into build/.
#
#   scripts/build-app.sh                       ad-hoc signed (runs on this Mac only; no hardened runtime)
#   SIGN_IDENTITY="Developer ID Application: ..." scripts/build-app.sh
#                                              signed with hardened runtime and a timestamp
#   UNIVERSAL=1 scripts/build-app.sh           Apple silicon + Intel (scripts/release.sh sets it)
#   RELEASE=1 scripts/build-app.sh             single architecture, but with the pinned package versions
#
# UNIVERSAL=1 and RELEASE=1 build with --force-resolved-versions: the build fails instead of
# re-resolving packages that differ from Package.resolved.
#
# The bundle holds the menu bar app (Contents/MacOS/UploadTheFile), the command-line tool
# (Contents/Resources/uptf) and Sparkle.framework (Contents/Frameworks), which updates the app.
# Notarization is done by scripts/release.sh, not here.
set -eu
cd "$(dirname "$0")/.."

APP_NAME="Upload the File"
APP="build/$APP_NAME.app"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
# Sparkle's binary package: one macOS slice holding Apple silicon and Intel, so a universal build
# embeds the same framework as a single-architecture one.
SPARKLE_SRC=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
VERSION="$(cat VERSION)"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
ENTITLEMENTS="Resources/UploadTheFile.entitlements"
# The entitlements file is empty on purpose: hardened runtime (--options runtime) without the App
# Sandbox, and no exceptions to the hardened runtime. See "Sandbox" in docs/DEVELOPMENT.md.
# (It must stay free of XML comments: the system's entitlement parser rejects them.)

echo "==> Building (release)"
# A release build uses exactly the package versions pinned in Package.resolved, and fails instead
# of re-resolving them: build-time packages (the OpenAPI generator and its dependencies) are not
# covered by THIRD_PARTY_NOTICES.txt, so a silent re-resolve would go unnoticed.
PIN=""
if [ "${UNIVERSAL:-0}" = "1" ] || [ "${RELEASE:-0}" = "1" ]; then
  PIN="--force-resolved-versions"
fi
if [ "${UNIVERSAL:-0}" = "1" ]; then
  # Apple silicon and Intel, one slice each, joined with lipo. (`--arch arm64 --arch x86_64`
  # needs Xcode's build system; per-triple builds work with the Command Line Tools alone.)
  for ARCH in arm64 x86_64; do
    swift build $PIN -c release --triple "$ARCH-apple-macosx14.0" --scratch-path ".build-$ARCH" --product UploadTheFile
    swift build $PIN -c release --triple "$ARCH-apple-macosx14.0" --scratch-path ".build-$ARCH" --product uptf
  done
  BIN_DIR="build/universal"
  rm -rf "$BIN_DIR"
  mkdir -p "$BIN_DIR"
  for PRODUCT in UploadTheFile uptf; do
    lipo -create -output "$BIN_DIR/$PRODUCT" \
      ".build-arm64/arm64-apple-macosx/release/$PRODUCT" \
      ".build-x86_64/x86_64-apple-macosx/release/$PRODUCT"
  done
else
  swift build $PIN -c release --product UploadTheFile
  swift build $PIN -c release --product uptf
  BIN_DIR="$(swift build -c release --show-bin-path)"
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/UploadTheFile" "$APP/Contents/MacOS/UploadTheFile"
cp "$BIN_DIR/uptf" "$APP/Contents/Resources/uptf"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Menu bar icon artwork (template PDFs; see Resources/MenuBarIcons/README.md).
mkdir -p "$APP/Contents/Resources/MenuBarIcons"
cp Resources/MenuBarIcons/*.pdf "$APP/Contents/Resources/MenuBarIcons/"
# The colour logo shown inside the app (header, signed-out screen).
cp Resources/BrandMark.pdf "$APP/Contents/Resources/BrandMark.pdf"
# Licences of the open-source packages compiled in (scripts/make-notices.sh) and the app's own.
cp THIRD_PARTY_NOTICES.txt "$APP/Contents/Resources/THIRD_PARTY_NOTICES.txt"
cp LICENSE "$APP/Contents/Resources/LICENSE"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Sparkle.framework, copied with ditto so the symlinks inside it survive (a plain copy breaks the
# framework's signature). The app is not sandboxed, so Sparkle's XPC services are never used;
# Sparkle documents removing them, and they must go before the framework is signed.
[ -d "$SPARKLE_SRC" ] || { echo "Missing $SPARKLE_SRC; run scripts/test.sh (or swift build) once to fetch the packages" >&2; exit 1; }
mkdir -p "$APP/Contents/Frameworks"
ditto --norsrc --noextattr --noqtn "$SPARKLE_SRC" "$FRAMEWORK"
rm -rf "$FRAMEWORK/Versions/B/XPCServices" "$FRAMEWORK/XPCServices"

PLIST_BUDDY=/usr/libexec/PlistBuddy
"$PLIST_BUDDY" -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
"$PLIST_BUDDY" -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"

echo "==> App icon"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
else
  # Fallback when Resources/AppIcon.icns is missing: a placeholder drawn by scripts/make-icon.swift.
  mkdir -p build
  swiftc -O scripts/make-icon.swift -o build/make-icon
  rm -rf build/AppIcon.iconset
  build/make-icon build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
fi

echo "==> Signing"
if [ -n "${SIGN_IDENTITY:-}" ]; then
  IDENTITY="$SIGN_IDENTITY"
  TIMESTAMP="--timestamp"
  RUNTIME="--options runtime"
else
  IDENTITY="-"
  TIMESTAMP="--timestamp=none"   # ad-hoc: no network round trip to a timestamp server
  # Library validation (part of the hardened runtime) refuses a framework that has no team in
  # its signature, so an ad-hoc build of an app that embeds Sparkle runs without the runtime.
  RUNTIME=""
  echo "    SIGN_IDENTITY is not set: ad-hoc signature, without the hardened runtime (this Mac only)"
fi
# Inside out, each piece signed on its own (never --deep): Sparkle's helper tool and helper app,
# the framework that contains them, the embedded CLI, then the app that contains all of it.
# shellcheck disable=SC2086
codesign --force $RUNTIME $TIMESTAMP --sign "$IDENTITY" "$FRAMEWORK/Versions/B/Autoupdate"
# shellcheck disable=SC2086
codesign --force $RUNTIME $TIMESTAMP --sign "$IDENTITY" "$FRAMEWORK/Versions/B/Updater.app"
# shellcheck disable=SC2086
codesign --force $RUNTIME $TIMESTAMP --sign "$IDENTITY" "$FRAMEWORK"
# shellcheck disable=SC2086
codesign --force $RUNTIME $TIMESTAMP --entitlements "$ENTITLEMENTS" \
  --identifier com.smilemasktechnology.uploadthefile.uptf --sign "$IDENTITY" "$APP/Contents/Resources/uptf"
# shellcheck disable=SC2086
codesign --force $RUNTIME $TIMESTAMP --entitlements "$ENTITLEMENTS" \
  --sign "$IDENTITY" "$APP"

echo "==> Verifying"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "Built $APP (version $VERSION, build $BUILD_NUMBER)"
