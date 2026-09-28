#!/bin/bash
#
# Run the shell test suite:  bash tests/run.sh [tests/test_foo.sh ...]
#
# Nothing here touches the real system: no sudo, no real osascript,
# launchctl or installer, no writes outside mktemp sandboxes, no Canon
# binaries. See tests/helpers.sh. KEEP_SANDBOX=1 keeps a failing test's
# sandbox for inspection.
#
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd -P)"
if [ $# -gt 0 ]; then
    FILES=("$@")
else
    # The harness self-test runs first: nothing else runs if it fails.
    FILES=("$TESTS_DIR/test_harness_safety.sh")
    for f in "$TESTS_DIR"/test_*.sh; do
        [ "$f" = "$TESTS_DIR/test_harness_safety.sh" ] || FILES+=("$f")
    done
fi

FAILED=""
for f in "${FILES[@]}"; do
    echo "== $(basename "$f")"
    if /bin/bash "$f"; then :; else
        status=$?
        FAILED="$FAILED $(basename "$f")"
        if [ "$status" = 3 ] || [ "$(basename "$f")" = test_harness_safety.sh ]; then
            echo "Harness problem; stopping."
            exit 3
        fi
    fi
    echo ""
done

if [ -n "$FAILED" ]; then
    echo "FAILED:$FAILED"
    exit 1
fi
echo "All test files passed."
