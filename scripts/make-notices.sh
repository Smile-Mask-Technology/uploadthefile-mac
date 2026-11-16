#!/bin/sh
# Writes THIRD_PARTY_NOTICES.txt: the licences and NOTICE texts of the packages compiled into the
# app and `uptf`, at the versions pinned in Package.resolved. Run after changing dependencies
# (`swift package resolve` first); BundleResourceTests fails when the file is out of date.
#
# Linked into the shipped binaries (check with `nm <binary> | swift demangle | grep <Module>.`):
#   swift-openapi-runtime, swift-openapi-urlsession, swift-http-types (Apache-2.0 with NOTICE)
#   swift-collections (DequeModule), swift-argument-parser (uptf only): Apache-2.0 with the
#   Runtime Library Exception.
# swift-openapi-generator, OpenAPIKit, Yams, swift-algorithms and swift-numerics run at build time
# only and are not distributed.
set -eu
cd "$(dirname "$0")/.."

PACKAGES="swift-openapi-runtime swift-openapi-urlsession swift-http-types swift-collections swift-argument-parser"
OUT=THIRD_PARTY_NOTICES.txt
CHECKOUTS=.build/checkouts

version_of() {
  # The "version" that follows the package's "identity" line in Package.resolved.
  awk -v id="\"$1\"" '
    $0 ~ "\"identity\" : " id { found = 1 }
    found && /"version"/ { gsub(/[",]/, "", $3); print $3; exit }
  ' Package.resolved
}

url_of() {
  awk -v id="\"$1\"" '
    $0 ~ "\"identity\" : " id { found = 1 }
    found && /"location"/ { gsub(/[",]/, "", $3); print $3; exit }
  ' Package.resolved
}

for p in $PACKAGES; do
  [ -f "$CHECKOUTS/$p/LICENSE.txt" ] || { echo "Missing $CHECKOUTS/$p; run swift package resolve" >&2; exit 1; }
  [ -n "$(version_of "$p")" ] || { echo "$p is not in Package.resolved" >&2; exit 1; }
done

{
  echo "Upload the File for Mac and uptf include the following open-source software."
  echo "Each is licensed under the Apache License, Version 2.0, whose full text is at the end"
  echo "of this file."
  echo
  for p in $PACKAGES; do
    echo "================================================================================"
    echo "$p $(version_of "$p")"
    echo "$(url_of "$p")"
    echo "================================================================================"
    echo
    if [ -f "$CHECKOUTS/$p/NOTICE.txt" ]; then
      cat "$CHECKOUTS/$p/NOTICE.txt"
    else
      echo "Licensed under the Apache License, Version 2.0 with the Runtime Library Exception."
    fi
    echo
  done
  echo "================================================================================"
  echo "Apache License, Version 2.0"
  echo "================================================================================"
  echo
  # The licence text without the Runtime Library Exception, which only some packages add.
  awk '/^## Runtime Library Exception/ { exit } { print }' "$CHECKOUTS/swift-openapi-runtime/LICENSE.txt"
} > "$OUT"

echo "Wrote $OUT"
