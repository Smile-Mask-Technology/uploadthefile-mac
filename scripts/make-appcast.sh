#!/bin/sh
# Writes the Sparkle appcast (the feed the app reads to find updates) with one item.
#
#   scripts/make-appcast.sh --version 0.1.2 --build 57 \
#     --url https://github.com/<owner>/<repo>/releases/download/v0.1.2/UploadTheFile.dmg \
#     --signature <EdDSA signature of the DMG> --length <size of the DMG in bytes> \
#     --notes release-notes.html --output build/release/appcast.xml
#
#   --version    the app's CFBundleShortVersionString (shown to people)
#   --build      the app's CFBundleVersion (what Sparkle compares)
#   --url        where the DMG is downloaded from
#   --signature  sparkle:edSignature of the DMG, from sign_update (scripts/release.sh passes it)
#   --length     the DMG's size in bytes
#   --notes      an HTML file; its content is embedded as the item's description
#   --output     the file to write
#   --min-system (optional) sparkle:minimumSystemVersion, default 14.0.0 (LSMinimumSystemVersion)
#   --date       (optional) pubDate in RFC 822 form, default now (UTC)
#
# Every required option is checked before anything is written. No network, no keys.
set -eu

fail() { echo "make-appcast.sh: $*" >&2; exit 64; }

VERSION="" BUILD="" URL="" SIGNATURE="" LENGTH="" NOTES="" OUTPUT="" MIN_SYSTEM="14.0.0" DATE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --version|--build|--url|--signature|--length|--notes|--output|--min-system|--date)
      [ "$#" -ge 2 ] || fail "$1 needs a value"
      case "$1" in
        --version) VERSION="$2" ;;
        --build) BUILD="$2" ;;
        --url) URL="$2" ;;
        --signature) SIGNATURE="$2" ;;
        --length) LENGTH="$2" ;;
        --notes) NOTES="$2" ;;
        --output) OUTPUT="$2" ;;
        --min-system) MIN_SYSTEM="$2" ;;
        --date) DATE="$2" ;;
      esac
      shift 2 ;;
    *) fail "unknown option $1" ;;
  esac
done

[ -n "$VERSION" ] || fail "--version is required"
[ -n "$BUILD" ] || fail "--build is required"
[ -n "$URL" ] || fail "--url is required"
[ -n "$SIGNATURE" ] || fail "--signature is required"
[ -n "$LENGTH" ] || fail "--length is required"
[ -n "$NOTES" ] || fail "--notes is required (an HTML file with the release notes)"
[ -n "$OUTPUT" ] || fail "--output is required"
[ -n "$MIN_SYSTEM" ] || fail "--min-system must not be empty"

case "$LENGTH" in *[!0-9]*) fail "--length must be a whole number of bytes, got $LENGTH" ;; esac
[ "$LENGTH" -gt 0 ] || fail "--length must be more than zero"
case "$BUILD" in *[!0-9.]*) fail "--build must be a number (CFBundleVersion), got $BUILD" ;; esac
case "$URL" in https://*) ;; *) fail "--url must start with https://" ;; esac
# The signature is base64.
case "$SIGNATURE" in *[!A-Za-z0-9+/=]*) fail "--signature is not a base64 signature" ;; esac
[ -f "$NOTES" ] || fail "release notes file not found: $NOTES"
[ -s "$NOTES" ] || fail "release notes file is empty: $NOTES"

[ -n "$DATE" ] || DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

# Text that goes into an XML element or attribute.
escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

mkdir -p "$(dirname "$OUTPUT")"
TMP="$OUTPUT.tmp.$$"
trap 'rm -f "$TMP"' EXIT
{
  echo '<?xml version="1.0" encoding="utf-8"?>'
  echo '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">'
  echo '  <channel>'
  echo '    <title>Upload the File</title>'
  echo '    <item>'
  echo "      <title>Version $(escape "$VERSION")</title>"
  # The notes are HTML inside CDATA; a "]]>" in them would end the section early, so it is split.
  echo '      <description><![CDATA['
  sed -e 's/]]>/]]]]><![CDATA[>/g' "$NOTES"
  echo ']]></description>'
  echo "      <pubDate>$(escape "$DATE")</pubDate>"
  echo "      <sparkle:version>$(escape "$BUILD")</sparkle:version>"
  echo "      <sparkle:shortVersionString>$(escape "$VERSION")</sparkle:shortVersionString>"
  echo "      <sparkle:minimumSystemVersion>$(escape "$MIN_SYSTEM")</sparkle:minimumSystemVersion>"
  echo "      <enclosure url=\"$(escape "$URL")\" sparkle:edSignature=\"$SIGNATURE\" length=\"$LENGTH\" type=\"application/octet-stream\"/>"
  echo '    </item>'
  echo '  </channel>'
  echo '</rss>'
} > "$TMP"
mv "$TMP" "$OUTPUT"
trap - EXIT
echo "Wrote $OUTPUT"
