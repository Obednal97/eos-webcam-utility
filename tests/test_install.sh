#!/bin/bash
# install.sh, run from a clone in (fake) ~/Downloads with the root step unable
# to read it. See helpers.sh for how the sandbox works.
. "$(dirname "$0")/helpers.sh"

DAEMON_FILES="eos-camera-manager.sh generate-images.sh errorNoDevice_connecting.jpg errorNoDevice_disconnected.jpg"

# The binaries install.sh snapshots and patches.
assert_backup_of_originals() {
    local b="$1"
    [ -n "$b" ] || { fail "no backup dir created"; return 0; }
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
    # Snapshots made it back into the backup dir in the clone.
    assert_backup_of_originals "$(latest_backup)"
    assert_file "$(latest_backup)/errorBusy.jpg"
    # The plug-in was really patched and the loading screen swapped in.
    assert_differs "$RES/EOSWebcamService" "$ORIG/Contents/Resources/EOSWebcamService"
    assert_same "$RES/errorNoDevice.jpg" "$CLONE/dist/v1.4/images/errorNoDevice_connecting.jpg"
    assert_daemon_in_runtime_dir
    assert_file "$RUNTIME/config.plist"
    assert_lacks "$STUB_LOG" "installer -pkg"
}

test_fresh_install_from_flat_pkg_in_protected_folder() {
    printf 'xar!fake flat package\n' > "$HOME/Downloads/Canon.pkg"
    ORIG="$SANDBOX/originals"; /usr/bin/python3 "$FIXTURES/make-canon-plugin.py" "$ORIG"
    run_install --pkg "$HOME/Downloads/Canon.pkg"; assert_status "$RC" 0
    assert_contains "$OUT" "Mode:          Fresh install"
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
    run_install --pkg "$HOME/Downloads/Canon.pkg"; assert_status "$RC" 0
    assert_log_matches "^installer -pkg /[^ ]*/eoswc-stage\.[A-Za-z0-9]+/canon\.pkg -target /"
    assert_contains "$STUB_LOG" "installer-kind bundle"
    assert_backup_of_originals "$(latest_backup)"
    assert_daemon_in_runtime_dir
}

test_failed_patch_keeps_snapshots_and_restarts_canon() {
    make_canon_install --corrupt
    run_install; assert_status "$RC" 1
    assert_contains "$OUT" "unexpected bytes"
    assert_contains "$OUT" "restarting Canon's service"
    assert_contains "$STUB_LOG" "launchctl load /Library/LaunchAgents/com.canon.usa.EWCService.plist"
    # The originals were snapshotted before the patcher died; they survive.
    assert_backup_of_originals "$(latest_backup)"
    # And the patcher changed nothing, not even the binary it checked first.
    assert_same "$BIN/EOSWebcamUtility" "$ORIG/Contents/MacOS/EOSWebcamUtility"
    assert_no_file "$AGENT"
}

test_refuses_to_patch_without_a_snapshot() {
    make_canon_install
    rm -f "${RES:?}/EWCProxy"
    run_install; assert_status "$RC" 1
    assert_contains "$OUT" "could not back up EWCProxy; nothing was patched."
    assert_same "$RES/EOSWebcamService" "$ORIG/Contents/Resources/EOSWebcamService"
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
