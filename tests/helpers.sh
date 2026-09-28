#!/bin/bash
# shellcheck disable=SC2034  # RUNTIME, AGENT, RC, ... are used by the test files
#
# Shared harness for the shell test suite. Sourced by tests/test_*.sh.
#
# Nothing here touches the real system. Each test runs in a subshell inside a
# throwaway sandbox:
#   - HOME is a fake home in the sandbox (so ~/Library is fake too)
#   - the Canon plug-in is a FAKE one (EOSWC_PLUGIN_DIR) built by
#     fixtures/make-canon-plugin.py and patched by the real patch-binaries.py.
#     The scripts honour EOSWC_PLUGIN_DIR only inside a marked sandbox
#     (EOSWC_TEST_SANDBOX), and run_script refuses to run a script unless that
#     guard is provably in place, so a script without it can never reach the
#     real /Library plug-in
#   - tests/stubs comes first on PATH: osascript, launchctl, installer,
#     codesign, pkill, sleep, ... are stubs that record their calls; sudo and
#     curl refuse to run
#   - the clone is a copy of dist/ under the fake ~/Downloads, and the
#     osascript stub makes ~/Downloads unreadable while the "root" step runs,
#     the way TCC does for the real elevated shell
#
# Deleting a sandbox goes through safe_rm_sandbox, which refuses anything
# this run didn't create with mktemp under the real temp dir.
#

set -euo pipefail

die() {
    echo "HARNESS ABORT: $*" >&2
    exit 3
}

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd -P)"
STUBS_DIR="$TESTS_DIR/stubs"
FIXTURES="$TESTS_DIR/fixtures"
SANDBOX_MARKER=".eoswc-test-sandbox"

# Captured once, before any test can change them. Sandboxes never export
# TMPDIR outside their own subshell.
REAL_HOME="$(cd "${HOME:?}" && pwd -P)" || die "cannot resolve HOME"
REAL_TMPDIR="$(cd "${TMPDIR:-/tmp}" 2>/dev/null && pwd -P)" || die "cannot resolve TMPDIR (${TMPDIR:-/tmp})"
SYS_TMP="$(cd /tmp && pwd -P)"
# macOS `mktemp -t` (what the scripts use for staging) ignores TMPDIR and
# uses the per-user temp dir, so staging leftovers are checked for there.
STAGE_ROOT="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)"
STAGE_ROOT="$(cd "${STAGE_ROOT:-$REAL_TMPDIR}" && pwd -P)" || die "cannot resolve the staging temp dir"

# Paths no sandbox may be, or contain.
PROTECTED_PATHS=("/" "$REAL_HOME" "$REPO_DIR")
MAIN_CLONE="$(git -C "$REPO_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
if [ -n "$MAIN_CLONE" ]; then
    PROTECTED_PATHS+=("$(cd "$MAIN_CLONE/.." && pwd -P)")
fi

CREATED_SANDBOXES=()

# Make a sandbox dir with mktemp under the real temp dir, and mark it.
# Aborts the whole run if that fails; never falls back to anything else.
make_sandbox() {
    local dir
    dir="$(mktemp -d "$REAL_TMPDIR/eoswc-test.XXXXXX")" || die "mktemp failed under $REAL_TMPDIR"
    [ -n "$dir" ] && [ -d "$dir" ] || die "mktemp returned no directory"
    dir="$(cd "$dir" && pwd -P)" || die "cannot resolve sandbox $dir"
    printf '%s\n' "$dir" > "$dir/$SANDBOX_MARKER"
    CREATED_SANDBOXES+=("$dir")
    SANDBOX="$dir"
}

# rm -rf a sandbox, but only if every check passes. Any failure aborts loudly.
safe_rm_sandbox() {
    local target="${1:?safe_rm_sandbox: no path given}" resolved p known=0
    [ -d "$target" ] || die "refusing to delete $target: not a directory"
    resolved="$(cd "$target" && pwd -P)" || die "refusing to delete $target: cannot resolve"
    for p in "${CREATED_SANDBOXES[@]+"${CREATED_SANDBOXES[@]}"}"; do
        [ "$p" = "$resolved" ] && known=1
    done
    [ "$known" = 1 ] || die "refusing to delete $resolved: not created by this run"
    case "$resolved" in
        "$REAL_TMPDIR"/eoswc-test.*|"$SYS_TMP"/eoswc-test.*) ;;
        *) die "refusing to delete $resolved: not under $REAL_TMPDIR or $SYS_TMP" ;;
    esac
    for p in "${PROTECTED_PATHS[@]}"; do
        case "$p/" in
            "$resolved"/*) die "refusing to delete $resolved: it is or contains $p" ;;
        esac
    done
    [ -f "$resolved/$SANDBOX_MARKER" ] || die "refusing to delete $resolved: no marker"
    [ "$(cat "$resolved/$SANDBOX_MARKER")" = "$resolved" ] || die "refusing to delete $resolved: wrong marker"
    [ -n "$(ls -A "$resolved")" ] || die "refusing to delete $resolved: empty"
    chmod -R u+rwx "${resolved:?}"
    rm -rf -- "${resolved:?}"
}

# --- assertions (in a test subshell) ---
CURRENT_FAILED=0
fail() {
    echo "    FAIL: $*"
    CURRENT_FAILED=1
}
assert_file()     { [ -f "$1" ] || fail "expected file: $1"; }
assert_no_file()  { [ ! -e "$1" ] || fail "expected no file: $1"; }
assert_same()     { cmp -s "$1" "$2" || fail "expected $1 to equal $2"; }
assert_differs()  { ! cmp -s "$1" "$2" || fail "expected $1 to differ from $2"; }
assert_contains() { grep -qF -- "$2" "$1" || fail "expected '$2' in $1"; }
assert_lacks()    { ! grep -qF -- "$2" "$1" || fail "did not expect '$2' in $1"; }
assert_status()   { [ "$1" = "$2" ] || fail "expected exit status $2, got $1"; }

# Point the environment at the sandbox. Only ever called inside the test's
# subshell, so none of these exports outlive the test.
enter_sandbox() {
    export EOSWC_TEST_SANDBOX="${SANDBOX:?}"
    export HOME="$SANDBOX/home"
    export TMPDIR="$SANDBOX/tmp"
    export STUB_LOG="$SANDBOX/calls.log"
    export STUB_LAUNCHCTL_LIST="$SANDBOX/launchctl-list"
    export EOSWC_PLUGIN_DIR="$SANDBOX/Library/CoreMediaIO/Plug-Ins/DAL/EOSWebcamUtility.plugin"
    # Canon's apps folder (Camera Extension host app, Canon's uninstaller).
    export EOSWC_CANON_APP_DIR="$SANDBOX/Applications/EOS Webcam Utility"
    export TCC_PROTECTED="$HOME/Downloads"
    export FIXTURES
    export PATH="$STUBS_DIR:/usr/bin:/bin:/usr/sbin:/sbin"
    unset STUB_OSASCRIPT_CANCEL STUB_ROOT_READONLY STUB_INSTALLER_ARGS \
          STUB_INSTALLER_EXIT STUB_INSTALLER_NO_APPS STUB_INSTALLER_NO_PAYLOAD \
          STUB_OSASCRIPT_WAIT_FOR STUB_OSASCRIPT_DETACH STUB_SLOW_CMD \
          STUB_EUID STUB_NO_CLT STUB_PKGUTIL_SIG STUB_SYSEXT_STATE STUB_SW_VERS \
          EOSWC_TEST_PKG_SHA256 STUB_ROOT_VANISH_STAGED STUB_ROOT_STDOUT_CLOSED \
          STUB_FAIL_CMD_ONCE

    mkdir -p "$HOME/Downloads" "$HOME/Desktop" "$HOME/Library/LaunchAgents" \
             "$HOME/Library/Logs" "$TMPDIR"
    : > "$STUB_LOG"
    : > "$STUB_LAUNCHCTL_LIST"

    CLONE="$HOME/Downloads/eos-webcam-utility"
    mkdir -p "$CLONE/dist/v1.4"
    (cd "$REPO_DIR/dist/v1.4" && tar cf - --exclude __pycache__ --exclude .DS_Store .) |
        (cd "$CLONE/dist/v1.4" && tar xf -)

    RUNTIME="$HOME/Library/Application Support/EWCService"
    AGENT="$HOME/Library/LaunchAgents/com.eos-camera-manager.plist"
    RES="$EOSWC_PLUGIN_DIR/Contents/Resources"
    BIN="$EOSWC_PLUGIN_DIR/Contents/MacOS"
    OUT="$SANDBOX/out.txt"
    : > "$OUT"
    STAGING_BEFORE="$(staging_dirs)"

    # Refuse to run anything unless the stubs really shadow the real tools.
    local t
    for t in osascript launchctl installer codesign pkill sudo curl \
             pkgutil systemextensionsctl xcode-select id chown chmod; do
        [ "$(command -v "$t")" = "$STUBS_DIR/$t" ] ||
            die "$t is not stubbed (resolves to $(command -v "$t"))"
    done
}

# A pristine (fake) Canon install at the plug-in path, and a copy of it.
make_canon_install() {
    /usr/bin/python3 "$FIXTURES/make-canon-plugin.py" "$EOSWC_PLUGIN_DIR" "$@"
    ORIG="$SANDBOX/originals"
    /usr/bin/python3 "$FIXTURES/make-canon-plugin.py" "$ORIG" "$@"
}

# Abort the run (before the script is started) unless the script under test
# can only act on the sandbox's fake plug-in. It must take its plug-in path
# from common.sh's eoswc_select_plugin_dir and never name the real path
# itself; and that common.sh must honour a path inside the sandbox and refuse
# the real one. A script without the guard (e.g. an older version) would run
# against the real /Library plug-in, so it is never run at all.
REAL_PLUGIN_PATH="/Library/CoreMediaIO/Plug-Ins/DAL/EOSWebcamUtility.plugin"
require_sandbox_hook() {
    local script="$1" common probe="$SANDBOX/hook-probe/EOSWebcamUtility.plugin"
    common="$(dirname "$script")/common.sh"
    [ -f "$script" ] || die "no such script: $script"
    grep -qE '^[[:space:]]*eoswc_select_plugin_dir \|\| exit 1' "$script" ||
        die "$script does not take its plug-in path from eoswc_select_plugin_dir; refusing to run it"
    ! grep -qF '/Library/CoreMediaIO/' "$script" ||
        die "$script names the real plug-in path itself; refusing to run it"
    [ -f "$common" ] || die "$common not found; refusing to run $script"
    # shellcheck disable=SC1090
    (
        . "$common"
        export EOSWC_TEST_SANDBOX="$SANDBOX" EOSWC_PLUGIN_DIR="$probe"
        eoswc_select_plugin_dir 2>/dev/null && [ "$EOSWC_PLUGIN" = "$probe" ]
    ) || die "$common does not honour EOSWC_PLUGIN_DIR inside the sandbox; refusing to run $script"
    # shellcheck disable=SC1090
    (
        . "$common"
        export EOSWC_TEST_SANDBOX="$SANDBOX" EOSWC_PLUGIN_DIR="$REAL_PLUGIN_PATH"
        ! eoswc_select_plugin_dir 2>/dev/null
    ) || die "$common does not refuse a plug-in dir outside the sandbox; refusing to run $script"
}

# Accept file $1 as Canon's package: install.sh honours EOSWC_TEST_PKG_SHA256
# (one more pinned --pkg checksum) only inside a marked sandbox.
pin_test_pkg() {
    EOSWC_TEST_PKG_SHA256="$(shasum -a 256 "$1" | awk '{print $1}')"
    export EOSWC_TEST_PKG_SHA256
}

# Run a script under test; its exit status lands in RC.
RC=0
run_script() {
    require_sandbox_hook "$CLONE/$1"
    if (cd "$CLONE" && /bin/bash "$@") > "$OUT" 2>&1; then RC=0; else RC=$?; fi
}
run_install()   { run_script dist/v1.4/install.sh --agree "$@"; }
run_uninstall() { run_script dist/v1.4/uninstall.sh "$@"; }
run_diagnose()  { run_script dist/v1.4/diagnose.sh; }

# launchctl list rows given as "PID|Status|Label".
launchctl_lists() {
    printf '%s\n' "$@" | tr '|' '\t' > "$STUB_LAUNCHCTL_LIST"
}

# Where install.sh puts backups now, and where older installers put them.
backup_root()        { echo "$RUNTIME/backups"; }
legacy_backup_root() { echo "$CLONE/backups"; }
latest_backup() {
    ls -dt "$(backup_root)/pre-v"* 2>/dev/null | head -1 || true
}

# patch-binaries.py --check-original / --check-patched on a dir.
holds_originals() { /usr/bin/python3 -B "$CLONE/dist/v1.4/patch-binaries.py" --check-original "$1" >/dev/null 2>&1; }
holds_patched()   { /usr/bin/python3 -B "$CLONE/dist/v1.4/patch-binaries.py" --check-patched "$1" >/dev/null 2>&1; }

staging_dirs() {
    find "$STAGE_ROOT" "$TMPDIR" -mindepth 1 -maxdepth 1 \
        \( -name 'eoswc-stage.*' -o -name 'eoswc-restore.*' -o -name 'eoswc-deploy.*' -o -name 'eoswc.*' \) 2>/dev/null | sort || true
}

# Checked after every test: no forbidden command ran, no staging dir left.
common_checks() {
    assert_lacks "$STUB_LOG" "FORBIDDEN"
    local now
    now="$(staging_dirs)"
    [ "$now" = "$STAGING_BEFORE" ] || fail "staging dir left behind: $(comm -13 <(echo "$STAGING_BEFORE") <(echo "$now"))"
}

# grep -E on the call log.
assert_log_matches() { grep -qE -- "$1" "$STUB_LOG" || fail "expected /$1/ in the call log"; }

# Run every test_* function in the calling file: each gets a fresh sandbox
# and its own subshell; the sandbox is removed afterwards via safe_rm_sandbox.
run_tests() {
    local t pass=0 failed=0 status
    for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
        make_sandbox
        set +e
        (
            set -euo pipefail
            enter_sandbox
            "$t"
            common_checks
            [ "$CURRENT_FAILED" = 0 ]
        )
        status=$?
        set -e
        if [ "$status" = 3 ]; then
            echo "HARNESS ABORT in $t; sandbox kept: $SANDBOX" >&2
            exit 3
        fi
        if [ "$status" = 0 ]; then
            echo "ok   - $t"
            pass=$((pass + 1))
            safe_rm_sandbox "$SANDBOX"
        else
            echo "FAIL - $t"
            echo "    --- last script output ---"
            sed 's/^/    | /' "$SANDBOX/out.txt" 2>/dev/null | tail -40 || true
            failed=$((failed + 1))
            if [ -n "${KEEP_SANDBOX:-}" ]; then
                echo "    sandbox kept: $SANDBOX"
            else
                safe_rm_sandbox "$SANDBOX"
            fi
        fi
    done
    echo "$pass passed, $failed failed"
    [ "$failed" = 0 ]
}
