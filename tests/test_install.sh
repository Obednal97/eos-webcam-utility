#!/bin/bash
# install.sh, run from a clone in (fake) ~/Downloads with the root step unable
# to read it. See helpers.sh for how the sandbox works.
. "$(dirname "$0")/helpers.sh"

DAEMON_FILES="eos-camera-manager.sh generate-images.sh errorNoDevice_connecting.jpg errorNoDevice_disconnected.jpg"

# The binaries install.sh backs up (to Application Support) and patches.
assert_backup_of_originals() {
    local b="$1"
    [ -n "$b" ] || { fail "no backup dir created"; return 0; }
    case "$b" in "$(backup_root)"/pre-v*) ;; *) fail "backup $b is not under $(backup_root)" ;; esac
    holds_originals "$b" || fail "backup $b does not verify as Canon's originals"
    assert_same "$b/EOSWebcamUtility" "$ORIG/Contents/MacOS/EOSWebcamUtility"
    assert_same "$b/EOSWebcamService" "$ORIG/Contents/Resources/EOSWebcamService"
    assert_same "$b/EWCProxy" "$ORIG/Contents/Resources/EWCProxy"
}

assert_daemon_in_runtime_dir() {
    local f
    for f in $DAEMON_FILES; do assert_file "$RUNTIME/$f"; done
    [ -x "$RUNTIME/eos-camera-manager.sh" ] || fail "daemon not executable"
    [ -x "$RUNTIME/generate-images.sh" ] || fail "generate-images.sh not executable"
    assert_same "$RUNTIME/eos-camera-manager.sh" "$CLONE/dist/v1.4/eos-camera-manager.sh"
    assert_file "$AGENT"
    assert_contains "$AGENT" "<string>$RUNTIME/eos-camera-manager.sh</string>"
    assert_lacks "$AGENT" "$CLONE"
    for f in $DAEMON_FILES; do assert_no_file "$CLONE/$f"; done
}

test_patches_existing_install_from_protected_clone() {
    make_canon_install
    run_install; assert_status "$RC" 0
    assert_contains "$OUT" "Installation complete!"
    assert_contains "$OUT" "Mode:          Patch existing Canon v1.3.x"
    # Root ran the staged patcher, and its script never mentions the clone.
    assert_log_matches "^/usr/bin/python3 '/[^']*/eoswc-stage\.[A-Za-z0-9]+/patch-binaries\.py'"
    assert_lacks "$STUB_LOG" "/usr/bin/python3 '$CLONE"
    sed -n '/--- root script ---/,/--- end root script ---/p' "$STUB_LOG" > "$SANDBOX/root.txt"
    assert_lacks "$SANDBOX/root.txt" "$CLONE"
    # Root wrote the backup straight to Application Support (never via
    # staging), and nothing went into the clone.
    assert_backup_of_originals "$(latest_backup)"
    assert_file "$(latest_backup)/errorBusy.jpg"
    assert_no_file "$(legacy_backup_root)"
    assert_log_matches "^cp '[^']*/EWCProxy' '$(backup_root)/pre-v[^']*'/ "
    assert_lacks "$SANDBOX/root.txt" "/orig/"
    # The backup was verified before the patcher ran.
    grep -n -e "--check-original '$(backup_root)" -e "patch-binaries.py' '$EOSWC_PLUGIN_DIR/Contents'" "$SANDBOX/root.txt" \
        | cut -d: -f1 | tr '\n' ' ' > "$SANDBOX/order.txt"
    read -r check_line patch_line < "$SANDBOX/order.txt" || true
    [ -n "${patch_line:-}" ] && [ "$check_line" -lt "$patch_line" ] || fail "backup not verified before patching"
    # The plug-in was really patched and the loading screen swapped in.
    assert_differs "$RES/EOSWebcamService" "$ORIG/Contents/Resources/EOSWebcamService"
    assert_same "$RES/errorNoDevice.jpg" "$CLONE/dist/v1.4/images/errorNoDevice_connecting.jpg"
    assert_daemon_in_runtime_dir
    assert_file "$RUNTIME/config.plist"
    assert_lacks "$STUB_LOG" "installer -pkg"
}

test_fresh_install_from_flat_pkg_in_protected_folder() {
    printf 'xar!fake flat package\n' > "$HOME/Downloads/Canon.pkg"
    pin_test_pkg "$HOME/Downloads/Canon.pkg"
    ORIG="$SANDBOX/originals"; /usr/bin/python3 "$FIXTURES/make-canon-plugin.py" "$ORIG"
    run_install --pkg "$HOME/Downloads/Canon.pkg"; assert_status "$RC" 0
    assert_contains "$OUT" "Mode:          Fresh install"
    assert_contains "$OUT" "Verified: SHA-256 matches Canon's v1.3.16 package."
    assert_log_matches "^installer -pkg /[^ ]*/eoswc-stage\.[A-Za-z0-9]+/canon\.pkg -target /"
    assert_contains "$STUB_LOG" "installer-kind flat"
    assert_backup_of_originals "$(latest_backup)"
    assert_daemon_in_runtime_dir
}

test_fresh_install_from_bundle_pkg_in_protected_folder() {
    mkdir -p "$HOME/Downloads/Canon.pkg/Contents"
    echo '<plist/>' > "$HOME/Downloads/Canon.pkg/Contents/Info.plist"
    echo 'payload' > "$HOME/Downloads/Canon.pkg/Contents/Archive.pax.gz"
    ORIG="$SANDBOX/originals"; /usr/bin/python3 "$FIXTURES/make-canon-plugin.py" "$ORIG"
    # A bundle-style package can't be checked against the pinned SHA-256, so
    # it needs the override (see test_pkg_verification.sh).
    run_install --pkg "$HOME/Downloads/Canon.pkg" --allow-unverified-pkg; assert_status "$RC" 0
    assert_contains "$OUT" "WARNING: --allow-unverified-pkg"
    assert_log_matches "^installer -pkg /[^ ]*/eoswc-stage\.[A-Za-z0-9]+/canon\.pkg -target /"
    assert_contains "$STUB_LOG" "installer-kind bundle"
    assert_backup_of_originals "$(latest_backup)"
    assert_daemon_in_runtime_dir
}

# The installed binaries can't be backed up as Canon's originals: stop in the
# pre-flight checks, before any prompt, stop or backup.
assert_refused_before_changes() {
    assert_status "$RC" 1
    assert_contains "$OUT" "Nothing was changed."
    assert_lacks "$OUT" "Installation complete!"
    assert_lacks "$STUB_LOG" "osascript"
    assert_lacks "$STUB_LOG" "launchctl"
    assert_same "$BIN/EOSWebcamUtility" "$ORIG/Contents/MacOS/EOSWebcamUtility"
    assert_no_file "$(backup_root)"
    assert_no_file "$AGENT"
}

# Nothing in the plug-in changed and the install did not claim success.
assert_aborted_unpatched() {
    assert_status "$RC" 1
    assert_contains "$OUT" "Nothing was patched."
    assert_lacks "$OUT" "Installation complete!"
    assert_lacks "$OUT" "Patched and signed"
    assert_same "$BIN/EOSWebcamUtility" "$ORIG/Contents/MacOS/EOSWebcamUtility"
    assert_same "$RES/EOSWebcamService" "$ORIG/Contents/Resources/EOSWebcamService"
    assert_contains "$OUT" "restarting Canon's service"
    assert_contains "$STUB_LOG" "launchctl load /Library/LaunchAgents/com.canon.usa.EWCService.plist"
    assert_no_file "$AGENT"
}

test_unexpected_bytes_are_refused_before_any_change() {
    make_canon_install --corrupt
    run_install
    assert_contains "$OUT" "EOSWebcamService: unexpected bytes"
    assert_refused_before_changes
}

test_truncated_binary_is_refused_before_any_change() {
    # EWCProxy cut after its last patch offset: the offsets alone still look
    # original, only the completeness check can tell.
    make_canon_install --truncated
    run_install
    assert_contains "$OUT" "EWCProxy: truncated"
    assert_refused_before_changes
}

# A fresh install: the binaries only exist once root has run Canon's
# installer, so the backup is verified in the root step, before patching.
fresh_install_with_payload() {
    export STUB_INSTALLER_ARGS="$1"
    printf 'xar!fake flat package\n' > "$HOME/Downloads/Canon.pkg"
    pin_test_pkg "$HOME/Downloads/Canon.pkg"
    ORIG="$SANDBOX/originals"; /usr/bin/python3 "$FIXTURES/make-canon-plugin.py" "$ORIG" "$1"
    run_install --pkg "$HOME/Downloads/Canon.pkg"
}

test_fresh_install_of_a_truncated_payload_aborts_before_patching() {
    fresh_install_with_payload --truncated
    assert_contains "$OUT" "EWCProxy: truncated"
    assert_contains "$OUT" "does not hold complete original Canon v1.3.16 binaries; nothing was patched."
    assert_aborted_unpatched
    assert_same "$RES/EWCProxy" "$ORIG/Contents/Resources/EWCProxy"
}

test_fresh_install_of_an_unexpected_payload_aborts_before_patching() {
    fresh_install_with_payload --corrupt
    assert_contains "$OUT" "EOSWebcamService: unexpected bytes"
    assert_contains "$OUT" "nothing was patched."
    assert_aborted_unpatched
}

# The old installer copied the snapshots out of staging after patching,
# ignored copy errors, deleted staging and still reported success. Now a
# backup that can't be written stops the install before anything is patched.
test_unwritable_backup_aborts_before_patching() {
    make_canon_install
    STUB_ROOT_READONLY="$(backup_root)"; export STUB_ROOT_READONLY
    run_install
    assert_contains "$OUT" "could not back up EOSWebcamUtility; nothing was patched."
    assert_aborted_unpatched
    holds_originals "$EOSWC_PLUGIN_DIR/Contents" || fail "plug-in no longer holds the originals"
}

test_failed_patch_keeps_verified_originals_in_app_support() {
    make_canon_install
    # The patcher dies writing EOSWebcamService, after EOSWebcamUtility.
    chmod 444 "$RES/EOSWebcamService"
    run_install; assert_status "$RC" 1
    assert_contains "$OUT" "Permission denied"
    assert_differs "$BIN/EOSWebcamUtility" "$ORIG/Contents/MacOS/EOSWebcamUtility"
    # The originals were backed up and verified before patching; they survive
    # outside staging, and the failure says where they are.
    assert_backup_of_originals "$(latest_backup)"
    assert_contains "$OUT" "Canon's original binaries are safe in $(latest_backup)"
    assert_lacks "$OUT" "Installation complete!"
    assert_contains "$OUT" "restarting Canon's service"
    assert_no_file "$AGENT"
}

# Backups of the installed originals already in Application Support.
count_backups() { ls -d "$(backup_root)"/pre-v* 2>/dev/null | wc -l | tr -d ' '; }
backup_of_live() {
    local dir
    dir="$(backup_root)/$1"
    mkdir -p "$dir"
    cp "$BIN/EOSWebcamUtility" "$RES/EOSWebcamService" "$RES/EWCProxy" "$dir/"
    echo "$dir"
}

test_rerun_over_canon_reuses_a_matching_backup() {
    make_canon_install
    local existing
    existing="$(backup_of_live pre-v1.4.1-20260101-100000)"
    run_install; assert_status "$RC" 0
    assert_contains "$OUT" "already backed up in $existing"
    assert_contains "$OUT" "Backups:        $existing"
    [ "$(count_backups)" = 1 ] || fail "expected no new backup, have $(count_backups)"
    # Root re-checked it against the installed files before patching.
    assert_log_matches "^cmp -s '[^']*/EWCProxy' '$(backup_root)/pre-v1.4.1-20260101-100000/EWCProxy'"
    holds_patched "$EOSWC_PLUGIN_DIR/Contents" || fail "plug-in not patched"
    holds_originals "$existing" || fail "backup no longer verifies"
}

test_rerun_over_canon_backs_up_again_if_the_backup_differs() {
    make_canon_install
    local existing
    existing="$(backup_of_live pre-v1.4.1-20260101-100000)"
    printf 'x' >> "$existing/EWCProxy"   # still verifies, but isn't what's installed
    holds_originals "$existing" || fail "setup: backup should still verify"
    run_install; assert_status "$RC" 0
    [ "$(count_backups)" = 2 ] || fail "expected a new backup, have $(count_backups)"
    assert_backup_of_originals "$(latest_backup)"
    assert_same "$(latest_backup)/EWCProxy" "$ORIG/Contents/Resources/EWCProxy"
}

test_legacy_clone_backup_is_not_reused() {
    # Root could not read it (the clone may be privacy-protected), so a copy
    # is made in Application Support; after that, re-runs reuse that copy.
    make_canon_install
    mkdir -p "$(legacy_backup_root)/pre-v1.4.1-20260101-100000"
    cp "$BIN/EOSWebcamUtility" "$RES/EOSWebcamService" "$RES/EWCProxy" "$(legacy_backup_root)/pre-v1.4.1-20260101-100000/"
    run_install; assert_status "$RC" 0
    [ "$(count_backups)" = 1 ] || fail "expected one backup in Application Support, have $(count_backups)"
    assert_backup_of_originals "$(latest_backup)"
}

test_home_with_a_quote_in_it() {
    # Move the whole fake home to a path with a quote and a space in it.
    local old="$HOME"
    export HOME="$SANDBOX/o'brien home"
    mkdir -p "$HOME"
    mv "$old/Downloads" "$old/Desktop" "$old/Library" "$HOME/"
    export TCC_PROTECTED="$HOME/Downloads"
    CLONE="$HOME/Downloads/eos-webcam-utility"
    RUNTIME="$HOME/Library/Application Support/EWCService"
    AGENT="$HOME/Library/LaunchAgents/com.eos-camera-manager.plist"
    make_canon_install
    run_install; assert_status "$RC" 0
    assert_contains "$STUB_LOG" "o'\\''brien home"   # shell-quoted in root's script
    assert_backup_of_originals "$(latest_backup)"
    holds_patched "$EOSWC_PLUGIN_DIR/Contents" || fail "plug-in not patched"
    run_uninstall; assert_status "$RC" 0
    holds_originals "$EOSWC_PLUGIN_DIR/Contents" || fail "plug-in not restored"
}

test_rerun_over_fork_uses_existing_backup() {
    make_canon_install --patched
    local legacy
    legacy="$(legacy_backup_root)/pre-v1.4.0-20260101-100000"
    mkdir -p "$legacy"
    /usr/bin/python3 "$FIXTURES/make-canon-plugin.py" "$SANDBOX/canon"
    cp "$SANDBOX/canon/Contents/MacOS/EOSWebcamUtility" "$SANDBOX/canon/Contents/Resources/EOSWebcamService" \
       "$SANDBOX/canon/Contents/Resources/EWCProxy" "$legacy/"
    run_install; assert_status "$RC" 0
    assert_contains "$OUT" "Mode:          Update existing fork"
    assert_contains "$OUT" "already patched: no Canon originals to back up"
    assert_contains "$OUT" "Backups:        $legacy"
    assert_no_file "$(backup_root)"   # no useless backup of patched binaries
    assert_log_matches "--check-patched '$EOSWC_PLUGIN_DIR/Contents'"
    holds_patched "$EOSWC_PLUGIN_DIR/Contents" || fail "plug-in not patched"
}

test_rerun_over_fork_without_backup_warns() {
    make_canon_install --patched
    run_install; assert_status "$RC" 0
    assert_contains "$OUT" "WARNING: no backup of Canon's original binaries was found"
    assert_contains "$OUT" "Backups:        none"
    assert_no_file "$(backup_root)"
}

test_refuses_an_install_missing_a_binary() {
    make_canon_install
    rm -f "${RES:?}/EWCProxy"
    run_install
    assert_contains "$OUT" "EWCProxy: missing"
    assert_refused_before_changes
}

test_upgrade_cleans_up_old_in_clone_daemon() {
    make_canon_install
    # What an older installer left: daemon + images in the clone root, a
    # LaunchAgent running it from there, and the user's logo.
    local f
    for f in $DAEMON_FILES; do echo old > "$CLONE/$f"; done
    echo 'PNG' > "$CLONE/logo.png"
    cat > "$AGENT" <<PLIST
<plist version="1.0"><dict>
	<key>Label</key><string>com.eos-camera-manager</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>$CLONE/eos-camera-manager.sh</string>
	</array>
</dict></plist>
PLIST
    run_install; assert_status "$RC" 0
    assert_contains "$STUB_LOG" "launchctl unload $AGENT"
    assert_file "$CLONE/logo.png"
    assert_same "$RUNTIME/logo.png" "$CLONE/logo.png"
    assert_contains "$OUT" "Copied your logo.png"
    assert_daemon_in_runtime_dir
}

test_upgrade_cleans_up_daemon_from_another_clone() {
    make_canon_install
    local other="$HOME/Desktop/old-clone"
    mkdir -p "$other"
    echo old > "$other/eos-camera-manager.sh"
    echo keep > "$other/notes.txt"
    printf '<string>%s/eos-camera-manager.sh</string>\n' "$other" > "$AGENT"
    run_install; assert_status "$RC" 0
    assert_no_file "$other/eos-camera-manager.sh"
    assert_file "$other/notes.txt"
    assert_daemon_in_runtime_dir
}

test_summary_running_when_both_jobs_have_a_pid() {
    make_canon_install
    launchctl_lists "501|0|com.canon.usa.EWCService" "502|0|com.eos-camera-manager"
    run_install; assert_status "$RC" 0
    assert_contains "$OUT" "EOS Service:    RUNNING"
    assert_contains "$OUT" "Camera Manager: RUNNING"
    assert_lacks "$OUT" "Something isn't running"
}

test_summary_not_running_when_listed_without_pid() {
    make_canon_install
    # The crash loop from the bug: listed, PID "-", last exit 126.
    launchctl_lists "501|0|com.canon.usa.EWCService" "-|126|com.eos-camera-manager"
    run_install; assert_status "$RC" 0
    assert_contains "$OUT" "EOS Service:    RUNNING"
    assert_contains "$OUT" "Camera Manager: NOT RUNNING"
    assert_contains "$OUT" "Something isn't running"
}

test_summary_not_running_when_not_listed() {
    make_canon_install
    launchctl_lists "777|0|com.example.other"
    run_install; assert_status "$RC" 0
    assert_contains "$OUT" "EOS Service:    NOT RUNNING"
    assert_contains "$OUT" "Camera Manager: NOT RUNNING"
}

test_summary_ignores_labels_that_only_contain_the_name() {
    make_canon_install
    launchctl_lists "900|0|com.eos-camera-manager.helper" "-|0|com.eos-camera-manager"
    run_install; assert_status "$RC" 0
    assert_contains "$OUT" "Camera Manager: NOT RUNNING"
}

run_tests
