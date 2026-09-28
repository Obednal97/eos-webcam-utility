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
    run_with_stdout_closed_after install.sh "[4/7]" --agree
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
    signed="$(last_line_re "^codesign --force --sign - /[^ ]*/EOSWebcamUtility\\.plugin$")"
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
    assert_log_matches "^codesign --force --sign - /[^ ]*/EOSWebcamUtility\\.plugin$"
}

test_term_during_the_uninstall_admin_step_waits_for_it() {
    fork_install
    backup_of_originals
    export STUB_OSASCRIPT_DETACH=1 STUB_SLOW_CMD=codesign
    run_uninstall
    wait_detached
    assert_status "$RC" 143
    local signed reload
    signed="$(last_line_re "^codesign --force --sign - /[^ ]*/EOSWebcamUtility\\.plugin$")"
    reload="$(first_line "launchctl load $CANON_PLIST")"
    [ -n "$signed" ] && [ -n "$reload" ] && [ "$reload" -gt "$signed" ] ||
        fail "Canon's service was reloaded (line ${reload:-none}) before the restore finished (line ${signed:-none})"
    holds_originals "$EOSWC_PLUGIN_DIR/Contents" || fail "the restore did not run to the end"
}

# VM: Ctrl-C at the patch step killed osascript, which closed root's stdout
# pipe. Root ignores SIGINT, but the patcher then died of BrokenPipeError and
# set -e stopped root before codesign: patched, with an invalid signature.
# Root's output now goes to a log in staging, shown afterwards.
test_install_admin_step_survives_a_closed_stdout() {
    make_canon_install
    export STUB_ROOT_STDOUT_CLOSED=1
    run_install; assert_status "$RC" 0
    holds_patched "$EOSWC_PLUGIN_DIR/Contents" || fail "plug-in not patched"
    assert_log_matches "^codesign --force --sign - /[^ ]*/EOSWebcamUtility\\.plugin$"
    assert_lacks "$OUT" "BrokenPipeError"
    # Root's own output, shown from its log once it's done.
    assert_contains "$OUT" "patched:         MacOS/EOSWebcamUtility"
    assert_contains "$OUT" "Installation complete!"
}

# The same with stderr closed too: codesign reports re-signing on stderr.
test_install_admin_step_survives_closed_stdout_and_stderr() {
    make_canon_install
    export STUB_ROOT_STDOUT_CLOSED=both
    run_install; assert_status "$RC" 0
    holds_patched "$EOSWC_PLUGIN_DIR/Contents" || fail "plug-in not patched"
    assert_log_matches "^codesign --force --sign - /[^ ]*/EOSWebcamUtility\\.plugin$"
    assert_contains "$OUT" "replacing existing signature"
}

test_uninstall_admin_step_survives_closed_stdout_and_stderr() {
    fork_install
    backup_of_originals
    export STUB_ROOT_STDOUT_CLOSED=both
    run_uninstall; assert_status "$RC" 0
    holds_originals "$EOSWC_PLUGIN_DIR/Contents" || fail "plug-in not restored"
    assert_log_matches "^codesign --force --sign - /[^ ]*/EOSWebcamUtility\\.plugin$"
    assert_contains "$OUT" "replacing existing signature"
    assert_contains "$OUT" "Uninstall complete."
}

# A step after the patcher fails (here codesign): with a verified backup,
# root copies Canon's originals back rather than leave a patched plug-in
# with invalid signatures.
test_failed_signing_rolls_back_to_the_originals() {
    make_canon_install
    export STUB_FAIL_CMD_ONCE=codesign
    run_install; assert_status "$RC" 1
    holds_originals "$EOSWC_PLUGIN_DIR/Contents" || fail "plug-in not rolled back"
    assert_same "$RES/EWCProxy" "$ORIG/Contents/Resources/EWCProxy"
    assert_contains "$OUT" "rolled back"
    assert_lacks "$OUT" "Installation complete!"
}

# The same over an already patched fork (no backup taken; here an earlier
# fork version, so there is something to patch and sign): root re-signs.
test_failed_signing_over_the_fork_re_signs() {
    make_canon_install --old-patched
    printf '<string>%s/eos-camera-manager.sh</string>\n' "$RUNTIME" > "$AGENT"
    export STUB_FAIL_CMD_ONCE=codesign
    run_install; assert_status "$RC" 1
    local failed resigned
    failed="$(first_line "codesign-failed")"
    resigned="$(last_line_re "^codesign --force --sign - /[^ ]*/EOSWebcamUtility\\.plugin$")"
    [ -n "$failed" ] && [ -n "$resigned" ] && [ "$resigned" -gt "$failed" ] ||
        fail "the plug-in was not re-signed after the failed step"
    assert_contains "$OUT" "re-signed"
    holds_patched "$EOSWC_PLUGIN_DIR/Contents" || fail "plug-in changed"
}

# Interrupted (osascript killed) while root ran: its output is kept in
# ~/Library/Logs, since staging is deleted and it was never shown.
test_interrupted_install_keeps_the_admin_step_log() {
    make_canon_install
    export STUB_OSASCRIPT_DETACH=1 STUB_SLOW_CMD=codesign
    run_install
    wait_detached
    assert_status "$RC" 143
    assert_file "$HOME/Library/Logs/eos-webcam-utility-admin-step.log"
    assert_contains "$HOME/Library/Logs/eos-webcam-utility-admin-step.log" "patched:         MacOS/EOSWebcamUtility"
    assert_contains "$OUT" "eos-webcam-utility-admin-step.log"
}

run_tests
