#!/bin/bash
# EOSWC_PLUGIN_DIR (the fake plug-in hook) is honoured only inside a marked
# test sandbox. Everywhere else install, uninstall and diagnose refuse to run
# before touching anything. See eoswc_select_plugin_dir in common.sh.
. "$(dirname "$0")/helpers.sh"

# Every script refuses with the current environment, and does nothing else.
assert_all_refuse() {
    local s
    for s in install.sh uninstall.sh diagnose.sh; do
        : > "$STUB_LOG"
        if [ "$s" = install.sh ]; then run_install; else run_script "dist/v1.4/$s"; fi
        [ "$RC" = 1 ] || fail "$s: expected exit status 1, got $RC"
        grep -q "Refusing to run" "$OUT" || fail "$s did not refuse: $(head -3 "$OUT")"
        assert_lacks "$STUB_LOG" "osascript"
        assert_lacks "$STUB_LOG" "launchctl"
        assert_no_file "$HOME/Desktop/eos-webcam-diagnostics.txt"
    done
    assert_no_file "$RUNTIME"
}

# Somewhere outside this sandbox that does not exist.
OUTSIDE="$REAL_TMPDIR/eoswc-guard-probe-does-not-exist.$$/EOSWebcamUtility.plugin"

test_refused_without_the_sandbox_variable() {
    make_canon_install
    unset EOSWC_TEST_SANDBOX
    assert_all_refuse
}

test_refused_for_a_path_outside_the_sandbox() {
    export EOSWC_PLUGIN_DIR="$OUTSIDE"
    assert_all_refuse
}

test_refused_for_a_dotdot_escape() {
    export EOSWC_PLUGIN_DIR="$SANDBOX/Library/../../eoswc-guard-probe/EOSWebcamUtility.plugin"
    assert_all_refuse
}

test_refused_for_a_symlink_escape() {
    ln -s "$REAL_TMPDIR" "$SANDBOX/escape"
    export EOSWC_PLUGIN_DIR="$SANDBOX/escape/eoswc-guard-probe-does-not-exist/EOSWebcamUtility.plugin"
    assert_all_refuse
}

test_refused_when_the_sandbox_is_not_marked() {
    make_canon_install
    # A real dir that contains the plug-in, but not one the harness marked.
    export EOSWC_TEST_SANDBOX="$SANDBOX/Library"
    assert_all_refuse
}

test_refused_when_the_sandbox_is_root() {
    export EOSWC_TEST_SANDBOX=/
    assert_all_refuse
}

test_honoured_inside_the_sandbox() {
    make_canon_install
    run_script dist/v1.4/diagnose.sh; assert_status "$RC" 0
    assert_lacks "$OUT" "Refusing to run"
    assert_contains "$HOME/Desktop/eos-webcam-diagnostics.txt" "EOSWebcamUtility.plugin"
}

run_tests
