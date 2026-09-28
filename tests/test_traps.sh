#!/bin/bash
# L1: when install or uninstall stops part-way, the EXIT trap reloads Canon's
# service AND the camera manager, before printing anything (a closed stdout
# must not stop the reload), and never while the admin step is still running.
. "$(dirname "$0")/helpers.sh"

CANON_PLIST="/Library/LaunchAgents/com.canon.usa.EWCService.plist"

# A patched, running fork install with its LaunchAgent.
fork_install() {
    make_canon_install --patched
    printf '<string>%s/eos-camera-manager.sh</string>\n' "$RUNTIME" > "$AGENT"
}
backup_of_originals() {
    local b
    b="$(backup_root)/pre-v1.4.1-20260101-100000"
    mkdir -p "$b"
    /usr/bin/python3 "$FIXTURES/make-canon-plugin.py" "$SANDBOX/canon"
    cp "$SANDBOX/canon/Contents/MacOS/EOSWebcamUtility" "$SANDBOX/canon/Contents/Resources/EOSWebcamService" \
       "$SANDBOX/canon/Contents/Resources/EWCProxy" "$b/"
}

# First line number of fixed string $1 in the call log (0 if absent).
first_line() { grep -nF -- "$1" "$STUB_LOG" | head -1 | cut -d: -f1 || true; }
last_line_re() { grep -nE -- "$1" "$STUB_LOG" | tail -1 | cut -d: -f1 || true; }

# Both services were reloaded, after they had been stopped.
assert_both_reloaded_after_stop() {
    local stop canon mgr
    stop="$(first_line "launchctl unload $CANON_PLIST")"
    canon="$(first_line "launchctl load $CANON_PLIST")"
    mgr="$(first_line "launchctl load $AGENT")"
    [ -n "$stop" ] || { fail "Canon's service was never stopped"; return 0; }
    [ -n "$canon" ] && [ "$canon" -gt "$stop" ] || fail "Canon's service not reloaded after the stop"
    [ -n "$mgr" ] && [ "$mgr" -gt "$stop" ] || fail "camera manager not reloaded after the stop"
}

# run_with_stdout_closed_after SCRIPT MARKER [ARGS...]: run SCRIPT with
# stdout into a reader that goes away as soon as it has read a line
# containing MARKER. The admin step (which the osascript stub cancels) only
# starts once the reader is gone, so every later write hits a closed pipe.
run_with_stdout_closed_after() {
    local script="$1" marker="$2"
    shift 2
    require_sandbox_hook "$CLONE/dist/v1.4/$script"
    export STUB_OSASCRIPT_CANCEL=1 STUB_OSASCRIPT_WAIT_FOR="$SANDBOX/reader-gone"
    set +e
    (cd "$CLONE" && /bin/bash "dist/v1.4/$script" "$@" 2>"$SANDBOX/err.txt") | {
        while IFS= read -r line; do
            printf '%s\n' "$line" >> "$OUT"
            case "$line" in *"$marker"*) break ;; esac
        done
        exec 0<&-
        : > "$SANDBOX/reader-gone"
    }
    RC="${PIPESTATUS[0]}"
    set -e
}

# Wait for a root step the osascript stub left running in the background.
wait_detached() {
    local pid _
    pid="$(cat "$SANDBOX/detached.pid" 2>/dev/null)" || return 0
    for _ in $(seq 300); do
        ps -p "$pid" >/dev/null 2>&1 || return 0
        /bin/sleep 0.05
    done
    fail "the detached root step is still running"
}

test_failed_install_reloads_canon_and_the_camera_manager() {
    fork_install
    export STUB_OSASCRIPT_CANCEL=1
    run_install; assert_status "$RC" 1
    assert_both_reloaded_after_stop
    assert_contains "$OUT" "restarting Canon's service and the camera manager"
}

test_install_cleanup_survives_a_closed_stdout() {
    fork_install
    run_with_stdout_closed_after install.sh "[5/8]" --agree
    [ "$RC" != 141 ] || fail "install was killed by SIGPIPE, so its EXIT trap never ran"
    [ "$RC" != 0 ] || fail "install claimed success"
    assert_both_reloaded_after_stop
}

test_uninstall_cleanup_survives_a_closed_stdout() {
    fork_install
    backup_of_originals
    run_with_stdout_closed_after uninstall.sh "[1/4]"
    [ "$RC" != 141 ] || fail "uninstall was killed by SIGPIPE, so its EXIT trap never ran"
    [ "$RC" != 0 ] || fail "uninstall claimed success"
    assert_both_reloaded_after_stop
    holds_patched "$EOSWC_PLUGIN_DIR/Contents" || fail "plug-in changed"
}

# osascript dies (Ctrl-C/TERM) while root is still patching. The install's
# trap must wait for root to finish before restarting Canon's service.
test_term_during_the_install_admin_step_waits_for_it() {
    make_canon_install
    export STUB_OSASCRIPT_DETACH=1 STUB_SLOW_CMD=codesign
    run_install
    wait_detached
    assert_status "$RC" 143
    local signed reload
    signed="$(last_line_re "^codesign --force --deep --sign - /")"
    reload="$(first_line "launchctl load $CANON_PLIST")"
    [ -n "$signed" ] || fail "the admin step never finished (no final codesign)"
    [ -n "$reload" ] || fail "Canon's service was not reloaded"
    [ -n "$signed" ] && [ -n "$reload" ] && [ "$reload" -gt "$signed" ] ||
        fail "Canon's service was reloaded (line $reload) before the admin step finished (line $signed)"
    holds_patched "$EOSWC_PLUGIN_DIR/Contents" || fail "the admin step did not run to the end"
    assert_contains "$OUT" "Install did not finish"
}

# Ctrl-C reaches root too (same terminal process group): the admin step
# ignores it and runs to the end rather than leave a half-patched plug-in.
test_the_install_admin_step_ignores_term() {
    make_canon_install
    export STUB_OSASCRIPT_DETACH=group STUB_SLOW_CMD=codesign
    run_install
    wait_detached
    holds_patched "$EOSWC_PLUGIN_DIR/Contents" || fail "the admin step was stopped part-way"
    assert_log_matches "^codesign --force --deep --sign - /"
}

test_term_during_the_uninstall_admin_step_waits_for_it() {
    fork_install
    backup_of_originals
    export STUB_OSASCRIPT_DETACH=1 STUB_SLOW_CMD=codesign
    run_uninstall
    wait_detached
    assert_status "$RC" 143
    local signed reload
    signed="$(last_line_re "^codesign --force --deep --sign - /")"
    reload="$(first_line "launchctl load $CANON_PLIST")"
    [ -n "$signed" ] && [ -n "$reload" ] && [ "$reload" -gt "$signed" ] ||
        fail "Canon's service was reloaded (line ${reload:-none}) before the restore finished (line ${signed:-none})"
    holds_originals "$EOSWC_PLUGIN_DIR/Contents" || fail "the restore did not run to the end"
}

run_tests
