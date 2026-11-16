#!/bin/sh
# Build and run the tests. With Xcode (or in CI), this is plain `swift test`. With only the
# Command Line Tools, `swift test` silently runs nothing, so build the bundle and run it through
# scripts/run-tests.swift instead (see that file).
set -eu
cd "$(dirname "$0")/.."

CLT_FRAMEWORKS=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
if [ -d /Applications/Xcode.app ] || [ ! -d "$CLT_FRAMEWORKS/Testing.framework" ]; then
  exec swift test "$@"
fi

swift build --build-tests
BUNDLE=.build/debug/uploadthefile-macPackageTests.xctest/Contents/MacOS/uploadthefile-macPackageTests
DRIVER=.build/run-tests
if [ ! -x "$DRIVER" ] || [ scripts/run-tests.swift -nt "$DRIVER" ]; then
  swiftc -F "$CLT_FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$CLT_FRAMEWORKS" \
    -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib \
    scripts/run-tests.swift -o "$DRIVER"
fi
exec "$DRIVER" "$PWD/$BUNDLE"
