#!/bin/bash
# M4: an installed plug-in is only used if it says it is Canon's v1.3.16
# (CFBundleShortVersionString) and then verifies as Canon's originals or the
# fork's patched binaries (patch-binaries.py --check-original/--check-patched).
# A --pkg given alongside it is not silently ignored.
. "$(dirname "$0")/helpers.sh"

assert_refused_before_changes() {
    assert_status "$RC" 1
    assert_contains "$OUT" "Nothing was changed."
    assert_lacks "$OUT" "Installation complete!"
    assert_lacks "$STUB_LOG" "osascript"
    assert_lacks "$STUB_LOG" "launchctl"
    assert_same "$RES/EOSWebcamService" "$ORIG/Contents/Resources/EOSWebcamService"
    assert_no_file "$(backup_root)"
}

test_unknown_plugin_version_is_refused() {
    make_canon_install --version 1.4.0
    run_install
    assert_contains "$OUT" "the installed EOS Webcam Utility is version 1.4.0,"
    assert_contains "$OUT" "not Canon's v1.3.16, the only version this fork can patch."
    assert_refused_before_changes
}

test_plugin_without_an_info_plist_is_refused() {
    make_canon_install --no-info-plist
    run_install
    assert_contains "$OUT" "version unknown (no readable Info.plist)"
    assert_refused_before_changes
}

test_right_version_with_wrong_bytes_is_still_refused() {
    # Says 1.3.16.0, but the binaries aren't Canon's: --check-original decides.
    make_canon_install --corrupt
    run_install
    assert_contains "$OUT" "EOSWebcamService: unexpected bytes"
    assert_refused_before_changes
}

test_v1316_plugin_is_used_and_reported() {
    make_canon_install
    run_install; assert_status "$RC" 0
    assert_contains "$OUT" "Canon source:  already installed v1.3.16.0 (patch in place)"
}

test_pkg_is_not_silently_ignored_when_canon_is_installed() {
    make_canon_install
    printf 'xar!fake flat package\n' > "$HOME/Downloads/Canon.pkg"
    run_install --pkg "$HOME/Downloads/Canon.pkg"; assert_status "$RC" 0
    assert_contains "$OUT" "NOTE: --pkg is NOT used: EOS Webcam Utility is already installed"
    assert_contains "$OUT" "$HOME/Downloads/Canon.pkg"
    assert_lacks "$STUB_LOG" "installer -pkg"
    holds_patched "$EOSWC_PLUGIN_DIR/Contents" || fail "plug-in not patched"
}

run_tests
