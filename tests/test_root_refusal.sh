#!/bin/bash
# M11: install.sh and uninstall.sh refuse to run as root (EUID 0), before
# touching anything. The id stub reports EUID 0 when STUB_EUID=0.
. "$(dirname "$0")/helpers.sh"

assert_refused_as_root() {
    assert_status "$RC" 1
    assert_contains "$OUT" "must not run as root (EUID 0): run without sudo; you'll be"
    assert_contains "$OUT" "prompted for your password. Nothing was changed."
    assert_lacks "$STUB_LOG" "osascript"
    assert_lacks "$STUB_LOG" "launchctl"
    assert_no_file "$RUNTIME"
}

test_install_refuses_under_euid_0() {
    make_canon_install
    export STUB_EUID=0
    run_install
    assert_refused_as_root
    assert_same "$RES/EOSWebcamService" "$ORIG/Contents/Resources/EOSWebcamService"
    assert_lacks "$OUT" "Pre-flight checks"
}

test_uninstall_refuses_under_euid_0() {
    make_canon_install --patched
    mkdir -p "$(backup_root)/pre-v1.4.1-20260101-100000"
    /usr/bin/python3 "$FIXTURES/make-canon-plugin.py" "$SANDBOX/canon"
    cp "$SANDBOX/canon/Contents/MacOS/EOSWebcamUtility" "$SANDBOX/canon/Contents/Resources/EOSWebcamService" \
       "$SANDBOX/canon/Contents/Resources/EWCProxy" "$(backup_root)/pre-v1.4.1-20260101-100000/"
    export STUB_EUID=0
    run_uninstall
    assert_status "$RC" 1
    assert_contains "$OUT" "run without sudo; you'll be"
    assert_lacks "$STUB_LOG" "osascript"
    assert_lacks "$STUB_LOG" "launchctl"
    holds_patched "$EOSWC_PLUGIN_DIR/Contents" || fail "plug-in changed"
}

test_install_runs_for_a_normal_user() {
    make_canon_install
    export STUB_EUID=501
    run_install; assert_status "$RC" 0
    assert_lacks "$OUT" "run without sudo"
}

run_tests
