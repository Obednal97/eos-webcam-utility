#!/bin/bash
# H4: on macOS 14+ Canon's postinstall runs its Camera Extension installer
# last and exits 1 unless the user approves the extension. By then the DAL
# plug-in is installed, so install.sh treats exactly that failure as
# non-fatal and patches; any other installer failure still aborts. Install,
# uninstall and diagnose report the extension and say how to remove it, and
# never try to remove it themselves.
. "$(dirname "$0")/helpers.sh"

# The removal advice, as the VM showed it has to be: Canon's uninstaller
# deletes the DAL plug-in but leaves the extension active, so it is never
# offered as the way to remove it. Takes the file to check.
assert_extension_removal_advice() {
    assert_contains "$1" "Login Items & Extensions > Camera Extensions"
    assert_contains "$1" "EOS Webcam Camera Extension Installer.app\" to the Trash"
    assert_contains "$1" "Uninstaller does NOT remove it"
    assert_lacks "$1" "Canon uninstaller removes it"
    assert_contains "$1" "needs SIP disabled"
}

fresh_pinned_pkg() {
    printf 'xar!fake flat package\n' > "$HOME/Downloads/Canon.pkg"
    pin_test_pkg "$HOME/Downloads/Canon.pkg"
    ORIG="$SANDBOX/originals"; /usr/bin/python3 "$FIXTURES/make-canon-plugin.py" "$ORIG"
}

# The installer failed for real: nothing patched, services restarted.
assert_install_aborted() {
    assert_status "$RC" 1
    assert_lacks "$OUT" "Installation complete!"
    assert_contains "$OUT" "Nothing was patched."
    assert_contains "$STUB_LOG" "launchctl load /Library/LaunchAgents/com.canon.usa.EWCService.plist"
    assert_no_file "$AGENT"
    ! holds_patched "$EOSWC_PLUGIN_DIR/Contents" || fail "plug-in was patched"
}

test_unapproved_extension_does_not_stop_a_fresh_install() {
    fresh_pinned_pkg
    export STUB_INSTALLER_EXIT=1   # Canon's postinstall: extension not approved
    run_install --pkg "$HOME/Downloads/Canon.pkg"; assert_status "$RC" 0
    assert_contains "$OUT" "may open \"EOS Webcam Camera Extension"
    assert_contains "$OUT" "only its Camera Extension step failed (not approved)"
    assert_contains "$OUT" "Installation complete!"
    holds_patched "$EOSWC_PLUGIN_DIR/Contents" || fail "plug-in not patched"
    holds_originals "$(latest_backup)" || fail "no verified backup of Canon's originals"
    assert_contains "$OUT" "Canon's Camera Extension: not registered"
    assert_contains "$OUT" "reported an error only because this extension"
    assert_contains "$OUT" "SECOND camera called"
    assert_extension_removal_advice "$OUT"
}

test_installer_failure_on_macos_13_is_fatal() {
    fresh_pinned_pkg
    export STUB_INSTALLER_EXIT=1 STUB_SW_VERS=13.6.1
    run_install --pkg "$HOME/Downloads/Canon.pkg"
    assert_contains "$OUT" "Canon's installer failed (exit 1); nothing was patched."
    assert_lacks "$OUT" "Camera Extension Installer\" and ask"
    assert_install_aborted
}

test_installer_failure_without_the_extension_app_is_fatal() {
    fresh_pinned_pkg
    export STUB_INSTALLER_EXIT=1 STUB_INSTALLER_NO_APPS=1
    run_install --pkg "$HOME/Downloads/Canon.pkg"
    assert_contains "$OUT" "not only at its Camera Extension step; nothing was patched."
    assert_install_aborted
}

test_installer_failure_without_the_plugin_is_fatal() {
    fresh_pinned_pkg
    export STUB_INSTALLER_EXIT=1 STUB_INSTALLER_NO_PAYLOAD=1
    run_install --pkg "$HOME/Downloads/Canon.pkg"
    assert_contains "$OUT" "not only at its Camera Extension step; nothing was patched."
    assert_status "$RC" 1
    assert_lacks "$OUT" "Installation complete!"
    assert_no_file "$AGENT"
}

test_install_reports_an_approved_extension() {
    fresh_pinned_pkg
    export STUB_SYSEXT_STATE="activated enabled"
    run_install --pkg "$HOME/Downloads/Canon.pkg"; assert_status "$RC" 0
    assert_contains "$OUT" "Canon's Camera Extension: activated enabled"
    assert_contains "$OUT" "SECOND camera called"
    assert_lacks "$OUT" "reported an error only because"
}

test_install_over_canon_without_the_extension_says_nothing() {
    make_canon_install
    run_install; assert_status "$RC" 0
    assert_lacks "$OUT" "Camera Extension"
}

# A patched fork install plus a backup, with Canon's apps present.
fork_install_with_canon_apps() {
    make_canon_install --patched
    local b
    b="$(backup_root)/pre-v1.4.1-20260101-100000"
    mkdir -p "$b" "$EOSWC_CANON_APP_DIR/EOS Webcam Camera Extension Installer.app/Contents"
    /usr/bin/python3 "$FIXTURES/make-canon-plugin.py" "$SANDBOX/canon"
    cp "$SANDBOX/canon/Contents/MacOS/EOSWebcamUtility" "$SANDBOX/canon/Contents/Resources/EOSWebcamService" \
       "$SANDBOX/canon/Contents/Resources/EWCProxy" "$b/"
}

test_uninstall_reports_the_extension_and_leaves_it() {
    fork_install_with_canon_apps
    export STUB_SYSEXT_STATE="activated enabled"
    run_uninstall; assert_status "$RC" 0
    assert_contains "$OUT" "Canon's Camera Extension is still installed (activated enabled)"
    assert_contains "$OUT" "second 'EOS Webcam Utility' camera"
    assert_extension_removal_advice "$OUT"
    [ -d "$EOSWC_CANON_APP_DIR/EOS Webcam Camera Extension Installer.app" ] || fail "the extension host app was removed"
    assert_contains "$STUB_LOG" "systemextensionsctl list"
    assert_lacks "$STUB_LOG" "systemextensionsctl uninstall"
}

# VM scenario 9: Canon's uninstaller ran first. The DAL plug-in is gone, the
# extension is still active: uninstall still says how to remove it.
test_uninstall_after_canons_uninstaller_reports_the_active_extension() {
    mkdir -p "$EOSWC_CANON_APP_DIR/EOS Webcam Camera Extension Installer.app/Contents"
    mkdir -p "$RUNTIME"
    echo fork > "$RUNTIME/eos-camera-manager.sh"
    printf '<string>%s/eos-camera-manager.sh</string>\n' "$RUNTIME" > "$AGENT"
    export STUB_SYSEXT_STATE="activated enabled"
    run_uninstall; assert_status "$RC" 0
    assert_contains "$OUT" "Nothing was restored"
    assert_contains "$OUT" "Canon's Camera Extension is still installed (activated enabled)"
    assert_extension_removal_advice "$OUT"
    assert_lacks "$STUB_LOG" "systemextensionsctl uninstall"
    [ -d "$EOSWC_CANON_APP_DIR/EOS Webcam Camera Extension Installer.app" ] || fail "the extension host app was removed"
}

test_uninstall_without_the_extension_says_nothing() {
    fork_install_with_canon_apps
    rm -rf "${EOSWC_CANON_APP_DIR:?}/EOS Webcam Camera Extension Installer.app"
    run_uninstall; assert_status "$RC" 0
    assert_lacks "$OUT" "Camera Extension"
}

test_diagnose_reports_an_unapproved_extension() {
    mkdir -p "$EOSWC_CANON_APP_DIR/EOS Webcam Camera Extension Installer.app/Contents"
    export STUB_SYSEXT_STATE="activated waiting for user"
    run_diagnose; assert_status "$RC" 0
    local r
    r="$HOME/Desktop/eos-webcam-diagnostics.txt"
    assert_contains "$r" "----- Canon Camera Extension -----"
    assert_contains "$r" "EOS Webcam Camera Extension Installer.app (installed)"
    assert_contains "$r" "state (systemextensionsctl): activated waiting for user"
    assert_contains "$r" "installed but not approved"
    assert_contains "$r" "To remove the Canon Camera Extension"
    assert_extension_removal_advice "$r"
}

test_diagnose_without_the_extension() {
    run_diagnose; assert_status "$RC" 0
    local r
    r="$HOME/Desktop/eos-webcam-diagnostics.txt"
    assert_contains "$r" "host app: not installed"
    assert_contains "$r" "state (systemextensionsctl): not registered"
    assert_lacks "$r" "To remove the Canon Camera Extension"
}

# EOSWC_CANON_APP_DIR is a test-only hook, guarded like EOSWC_PLUGIN_DIR.
test_app_dir_hook_is_guarded() {
    local rc=0 out
    out="$(unset EOSWC_TEST_SANDBOX; . "$CLONE/dist/v1.4/common.sh" && eoswc_select_canon_app_dir 2>&1)" || rc=$?
    assert_status "$rc" 1
    case "$out" in *"EOSWC_CANON_APP_DIR is set"*"Refusing to run"*) ;; *) fail "not refused outside a sandbox: $out" ;; esac
    rc=0
    out="$(export EOSWC_CANON_APP_DIR="/Applications/EOS Webcam Utility"; . "$CLONE/dist/v1.4/common.sh" && eoswc_select_canon_app_dir 2>&1)" || rc=$?
    assert_status "$rc" 1
    case "$out" in *"outside the test sandbox"*) ;; *) fail "real path not refused: $out" ;; esac
    rc=0
    out="$(. "$CLONE/dist/v1.4/common.sh" && eoswc_select_canon_app_dir && echo "$EOSWC_CANON_APPS")" || rc=$?
    assert_status "$rc" 0
    [ "$out" = "$(cd "$SANDBOX" && pwd -P)/Applications/EOS Webcam Utility" ] || fail "sandbox path not honoured: $out"
    local s
    for s in install.sh uninstall.sh diagnose.sh; do
        grep -q '^eoswc_select_canon_app_dir || exit 1$' "$CLONE/dist/v1.4/$s" || fail "$s does not guard EOSWC_CANON_APP_DIR"
    done
}

run_tests
