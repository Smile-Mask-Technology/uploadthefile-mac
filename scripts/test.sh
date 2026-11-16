#!/bin/sh
# Build and run the tests. With Xcode (or in CI), this is plain `swift test`. With only the
# Command Line Tools, `swift test` silently runs nothing, so build the bundle and run it through
# scripts/run-tests.swift instead (see that file).
#
# The run must also prove it ran the tests: the Swift Testing summary has to report more than
# zero tests, and (when no arguments narrow the run) at least the number in scripts/min-test-count.
# A test target that silently stops being built or run would otherwise leave a green gate.
# Raise scripts/min-test-count when tests are added; lower it only when tests are removed on purpose.
set -eu
cd "$(dirname "$0")/.."

CLT_FRAMEWORKS=/Library/Developer/CommandLineTools/Library/Developer/Frameworks

run_tests() {
  if [ -d /Applications/Xcode.app ] || [ ! -d "$CLT_FRAMEWORKS/Testing.framework" ]; then
    swift test "$@"
    return $?
  fi

  swift build --build-tests || return $?
  BUNDLE=.build/debug/uploadthefile-macPackageTests.xctest/Contents/MacOS/uploadthefile-macPackageTests
  DRIVER=.build/run-tests
  if [ ! -x "$DRIVER" ] || [ scripts/run-tests.swift -nt "$DRIVER" ]; then
    swiftc -F "$CLT_FRAMEWORKS" \
      -Xlinker -rpath -Xlinker "$CLT_FRAMEWORKS" \
      -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib \
      scripts/run-tests.swift -o "$DRIVER" || return $?
  fi
  "$DRIVER" "$PWD/$BUNDLE"
}

LOG="$(mktemp -t uptf-tests)"
STATUS_FILE="$LOG.status"
trap 'rm -f "$LOG" "$STATUS_FILE"' EXIT

# Show the output as it arrives, and keep it to read the summary afterwards.
{ status=0; run_tests "$@" || status=$?; echo "$status" > "$STATUS_FILE"; } 2>&1 | tee "$LOG"

STATUS="$(cat "$STATUS_FILE" 2>/dev/null || true)"
if [ -z "$STATUS" ]; then
  echo "scripts/test.sh: the test run did not finish." >&2
  exit 1
fi
if [ "$STATUS" != "0" ]; then
  exit "$STATUS"
fi

# "✔ Test run with 143 tests in 14 suites passed after 1.2 seconds."
COUNT="$(sed -n 's/.*Test run with \([0-9][0-9]*\) test.*/\1/p' "$LOG" | tail -n 1)"
if [ -z "$COUNT" ] || [ "$COUNT" -eq 0 ]; then
  echo "scripts/test.sh: the run reported no tests, so nothing was checked." >&2
  echo "With the Command Line Tools selected, \`swift test\` runs none; select Xcode or remove /Applications/Xcode.app." >&2
  exit 1
fi
if [ "$#" -eq 0 ]; then
  MIN="$(tr -d '[:space:]' < scripts/min-test-count)"
  case "$MIN" in
    ''|*[!0-9]*) echo "scripts/test.sh: scripts/min-test-count must hold one whole number." >&2; exit 1 ;;
  esac
  if [ "$COUNT" -lt "$MIN" ]; then
    echo "scripts/test.sh: the run reported $COUNT tests; at least $MIN are expected (scripts/min-test-count)." >&2
    echo "A test target may have stopped running." >&2
    exit 1
  fi
fi
