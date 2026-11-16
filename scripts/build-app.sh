#!/bin/sh
# Builds "Upload the File.app" into build/.
#
#   scripts/build-app.sh                       ad-hoc signed (runs on this Mac only)
#   SIGN_IDENTITY="Developer ID Application: ..." scripts/build-app.sh
#                                              signed with hardened runtime and a timestamp
#   UNIVERSAL=1 scripts/build-app.sh           Apple silicon + Intel (scripts/release.sh sets it)
#
# The bundle holds the menu bar app (Contents/MacOS/UploadTheFile) and the command-line tool
# (Contents/Resources/uptf). Notarization is done by scripts/release.sh, not here.
set -eu
cd "$(dirname "$0")/.."

APP_NAME="Upload the File"
APP="build/$APP_NAME.app"
VERSION="$(cat VERSION)"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
ENTITLEMENTS="Resources/UploadTheFile.entitlements"
# The entitlements file is empty on purpose: hardened runtime (--options runtime) without the App
# Sandbox, and no exceptions to the hardened runtime. See "Sandbox" in docs/DEVELOPMENT.md.
# (It must stay free of XML comments: the system's entitlement parser rejects them.)

echo "==> Building (release)"
if [ "${UNIVERSAL:-0}" = "1" ]; then
  # Apple silicon and Intel, one slice each, joined with lipo. (`--arch arm64 --arch x86_64`
  # needs Xcode's build system; per-triple builds work with the Command Line Tools alone.)
  for ARCH in arm64 x86_64; do
    swift build -c release --triple "$ARCH-apple-macosx14.0" --scratch-path ".build-$ARCH" --product UploadTheFile
    swift build -c release --triple "$ARCH-apple-macosx14.0" --scratch-path ".build-$ARCH" --product uptf
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
  swift build -c release --product UploadTheFile
  swift build -c release --product uptf
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
else
  IDENTITY="-"
  TIMESTAMP="--timestamp=none"   # ad-hoc: no network round trip to a timestamp server
  echo "    SIGN_IDENTITY is not set: ad-hoc signature (this Mac only)"
fi
# The embedded CLI first, then the app that contains it.
codesign --force --options runtime $TIMESTAMP --entitlements "$ENTITLEMENTS" \
  --identifier com.smilemasktechnology.uploadthefile.uptf --sign "$IDENTITY" "$APP/Contents/Resources/uptf"
codesign --force --options runtime $TIMESTAMP --entitlements "$ENTITLEMENTS" \
  --sign "$IDENTITY" "$APP"

echo "==> Verifying"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "Built $APP (version $VERSION, build $BUILD_NUMBER)"
