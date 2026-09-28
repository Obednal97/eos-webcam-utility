#!/bin/bash
# bash -n every shell script (with /bin/bash, which is what macOS runs them
# with), and shellcheck the ones this suite covers when shellcheck exists.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd -P)"
cd "$REPO_DIR"
PASS=0
FAILED=0

SCRIPTS="$(find dist tests -type f \( -name '*.sh' -o -path 'tests/stubs/*' \) ! -name '*.py' | sort)"
# Older scripts are only syntax-checked so their pre-existing style notes
# don't fail the suite.
UNLINTED="dist/v1.4/eos-camera-manager.sh dist/v1.4/images/generate-images.sh"

for s in $SCRIPTS; do
    if err="$(/bin/bash -n "$s" 2>&1)"; then
        echo "ok   - bash -n $s"; PASS=$((PASS + 1))
    else
        echo "FAIL - bash -n $s"; echo "$err" | sed 's/^/    | /'; FAILED=$((FAILED + 1))
    fi
done

if command -v shellcheck >/dev/null 2>&1; then
    for s in $SCRIPTS; do
        case " $UNLINTED " in *" $s "*) continue ;; esac
        if out="$(shellcheck -x -S warning "$s" 2>&1)"; then
            echo "ok   - shellcheck $s"; PASS=$((PASS + 1))
        else
            echo "FAIL - shellcheck $s"; echo "$out" | sed 's/^/    | /'; FAILED=$((FAILED + 1))
        fi
    done
else
    echo "skip - shellcheck not installed"
fi

echo "$PASS passed, $FAILED failed"
[ "$FAILED" = 0 ]
