#!/bin/bash
# uninstall.sh, run from a clone in (fake) ~/Downloads. See helpers.sh.
. "$(dirname "$0")/helpers.sh"

DAEMON_FILES="eos-camera-manager.sh generate-images.sh errorNoDevice_connecting.jpg errorNoDevice_disconnected.jpg"

# A backup dir as an installer leaves it.
#   $1: new (Application Support, install.sh now) | legacy (the clone, older installers)
#   $3: originals | patched | empty | partial (no EWCProxy)
#       | mixed (EWCProxy patched, the rest original) | truncated (EWCProxy cut short)
make_backup() {
    local root kind="$3" src="$SANDBOX/fixture-$2" dir
    case "$1" in new) root="$(backup_root)" ;; legacy) root="$(legacy_backup_root)" ;; *) fail "bad root $1"; return 1 ;; esac
    dir="$root/$2"
    mkdir -p "$dir"
    if [ "$kind" != empty ]; then
        if [ "$kind" = patched ]; then
            /usr/bin/python3 "$FIXTURES/make-canon-plugin.py" "$src" --patched
        else
            /usr/bin/python3 "$FIXTURES/make-canon-plugin.py" "$src"
        fi
        cp "$src/Contents/MacOS/EOSWebcamUtility" "$src/Contents/Resources/EOSWebcamService" \
           "$src/Contents/Resources/errorNoDevice.jpg" "$src/Contents/Resources/errorBusy.jpg" \
           "$src/Contents/Resources/default.jpg" "$dir/"
        case "$kind" in
            partial) ;;
            mixed)
                /usr/bin/python3 "$FIXTURES/make-canon-plugin.py" "$src-patched" --patched
                cp "$src-patched/Contents/Resources/EWCProxy" "$dir/" ;;
            truncated)
                cp "$src/Contents/Resources/EWCProxy" "$dir/"
                # Cut after the last patch offset, so only the completeness check catches it.
                /usr/bin/python3 -c 'import os, sys; p = sys.argv[1]; os.truncate(p, os.path.getsize(p) - 16)' "$dir/EWCProxy" ;;
            *) cp "$src/Contents/Resources/EWCProxy" "$dir/" ;;
        esac
    fi
    echo "$dir"
}

# A patched, running fork install, as install.sh leaves it.
make_fork_install() {
    /usr/bin/python3 "$FIXTURES/make-canon-plugin.py" "$EOSWC_PLUGIN_DIR" --patched
    PATCHED="$SANDBOX/patched"
    /usr/bin/python3 "$FIXTURES/make-canon-plugin.py" "$PATCHED" --patched
    mkdir -p "$RUNTIME"
    local f
    for f in $DAEMON_FILES; do echo fork > "$RUNTIME/$f"; done
    echo '<fork config/>' > "$RUNTIME/config.plist"
    echo '<fork proconfig/>' > "$RUNTIME/proconfig.plist"
    printf '<string>%s/eos-camera-manager.sh</string>\n' "$RUNTIME" > "$AGENT"
}

assert_untouched() {
    assert_lacks "$STUB_LOG" "launchctl unload"
    assert_lacks "$STUB_LOG" "osascript"
    assert_file "$AGENT"
    assert_file "$RUNTIME/eos-camera-manager.sh"
    assert_same "$RES/EOSWebcamService" "$PATCHED/Contents/Resources/EOSWebcamService"
}

test_refuses_when_only_backup_is_empty() {
    make_fork_install
    make_backup legacy pre-v1.4.1-20260921-100000 empty >/dev/null
    run_uninstall; assert_status "$RC" 1
    assert_contains "$OUT" "No backup in"
    assert_contains "$OUT" "Nothing was changed."
    assert_untouched
}

test_refuses_when_backup_lacks_a_binary() {
    make_fork_install
    make_backup legacy pre-v1.4.1-20260921-100000 partial >/dev/null
    run_uninstall; assert_status "$RC" 1
    assert_contains "$OUT" "Skipping backup without Canon's original binaries"
    assert_untouched
}

test_refuses_when_backups_hold_patched_binaries() {
    make_fork_install
    make_backup legacy pre-v1.4.1-20260921-100000 patched >/dev/null
    run_uninstall; assert_status "$RC" 1
    assert_contains "$OUT" "No backup in"
    assert_untouched
}

test_refuses_mixed_backup() {
    make_fork_install
    local mixed
    mixed="$(make_backup new pre-v1.4.1-20260921-100000 mixed)"
    run_uninstall; assert_status "$RC" 1
    assert_contains "$OUT" "Skipping backup without Canon's original binaries: $mixed"
    assert_contains "$OUT" "EWCProxy: holds the fork's patched bytes"
    assert_contains "$OUT" "No backup in"
    assert_untouched
}

test_refuses_truncated_backup() {
    make_fork_install
    local cut
    cut="$(make_backup new pre-v1.4.1-20260921-100000 truncated)"
    run_uninstall; assert_status "$RC" 1
    assert_contains "$OUT" "Skipping backup without Canon's original binaries: $cut"
    assert_contains "$OUT" "EWCProxy: truncated"
    assert_untouched
}

test_refuses_mixed_or_truncated_legacy_backups() {
    make_fork_install
    make_backup legacy pre-v1.4.1-20260921-100000 mixed >/dev/null
    make_backup legacy pre-v1.4.1-20260922-100000 truncated >/dev/null
    run_uninstall; assert_status "$RC" 1
    assert_contains "$OUT" "EWCProxy: holds the fork's patched bytes"
    assert_contains "$OUT" "EWCProxy: truncated"
    assert_untouched
}

test_restores_from_app_support_and_keeps_the_backup() {
    make_fork_install
    local good f
    good="$(make_backup new pre-v1.4.1-20260920-100000 originals)"
    echo '<canon config/>' > "$good/config.plist"
    run_uninstall; assert_status "$RC" 0
    assert_contains "$OUT" "Restoring from backup: $good"
    assert_contains "$OUT" "Original binaries restored"
    assert_contains "$OUT" "Uninstall complete."
    assert_same "$BIN/EOSWebcamUtility" "$good/EOSWebcamUtility"
    assert_same "$RES/EOSWebcamService" "$good/EOSWebcamService"
    assert_same "$RES/EWCProxy" "$good/EWCProxy"
    assert_same "$RUNTIME/config.plist" "$good/config.plist"
    # The daemon files went, the backup (inside the same dir) did not.
    for f in $DAEMON_FILES; do assert_no_file "$RUNTIME/$f"; done
    assert_no_file "$AGENT"
    for f in EOSWebcamUtility EOSWebcamService EWCProxy config.plist; do assert_file "$good/$f"; done
    holds_originals "$good" || fail "backup no longer verifies"
    assert_contains "$OUT" "Backups kept"
}

test_restores_from_the_first_v14_installers_fixed_path() {
    # That installer kept backups under ~/development/webcam-utility,
    # wherever the clone really was.
    make_fork_install
    local good
    good="$HOME/development/webcam-utility/backups/pre-v1.4-20240101-100000"
    mkdir -p "$good"
    /usr/bin/python3 "$FIXTURES/make-canon-plugin.py" "$SANDBOX/v14"
    cp "$SANDBOX/v14/Contents/MacOS/EOSWebcamUtility" "$SANDBOX/v14/Contents/Resources/EOSWebcamService" \
       "$SANDBOX/v14/Contents/Resources/EWCProxy" "$good/"
    run_uninstall; assert_status "$RC" 0
    assert_contains "$OUT" "Restoring from backup: $good"
    assert_same "$RES/EWCProxy" "$good/EWCProxy"
}

test_picks_the_newest_good_backup_across_both_locations() {
    make_fork_install
    local old new
    old="$(make_backup legacy pre-v1.4.0-20260901-100000 originals)"
    new="$(make_backup new pre-v1.4.1-20260910-100000 originals)"
    touch -t 202609010000 "$old"; touch -t 202609100000 "$new"
    run_uninstall; assert_status "$RC" 0
    assert_contains "$OUT" "Restoring from backup: $new"
}

test_refuses_when_there_are_no_backups() {
    make_fork_install
    run_uninstall; assert_status "$RC" 1
    assert_contains "$OUT" "No backup found"
    assert_untouched
}

test_restores_from_protected_clone_and_removes_everything() {
    make_fork_install
    local good f
    good="$(make_backup legacy pre-v1.4.1-20260920-100000 originals)"
    echo '<canon config/>' > "$good/config.plist"
    echo '<canon proconfig/>' > "$good/proconfig.plist"
    echo 'PNG' > "$RUNTIME/logo.png"
    echo 'canon-owned' > "$RUNTIME/SomethingCanonWrote.plist"
    run_uninstall; assert_status "$RC" 0
    assert_contains "$OUT" "Restoring from backup: $good"
    # Root copied from staging, not from the clone (which it can't read).
    assert_log_matches "^cp '/[^']*/eoswc-restore\.[A-Za-z0-9]+/EOSWebcamService' "
    assert_lacks "$STUB_LOG" "cp '$CLONE"
    assert_same "$BIN/EOSWebcamUtility" "$good/EOSWebcamUtility"
    assert_same "$RES/EOSWebcamService" "$good/EOSWebcamService"
    assert_same "$RES/EWCProxy" "$good/EWCProxy"
    assert_same "$RES/errorNoDevice.jpg" "$good/errorNoDevice.jpg"
    assert_same "$RUNTIME/config.plist" "$good/config.plist"
    assert_same "$RUNTIME/proconfig.plist" "$good/proconfig.plist"
    # Everything the installer put in Application Support is gone, logo too...
    for f in $DAEMON_FILES logo.png; do assert_no_file "$RUNTIME/$f"; done
    # ...but not files it didn't create.
    assert_file "$RUNTIME/SomethingCanonWrote.plist"
    assert_no_file "$AGENT"
    assert_contains "$STUB_LOG" "launchctl load /Library/LaunchAgents/com.canon.usa.EWCService.plist"
    assert_file "$good/EOSWebcamUtility"   # backups are kept
}

test_removes_configs_the_installer_created_and_the_empty_dir() {
    make_fork_install
    make_backup legacy pre-v1.4.1-20260920-100000 originals >/dev/null   # no config in backup
    echo '<svg/>' > "$RUNTIME/logo.svg"
    run_uninstall; assert_status "$RC" 0
    assert_no_file "$RUNTIME/config.plist"
    assert_no_file "$RUNTIME/proconfig.plist"
    assert_no_file "$RUNTIME"
}

test_skips_newer_unusable_backups_for_an_older_good_one() {
    make_fork_install
    local good patched empty
    good="$(make_backup legacy pre-v1.4.0-20260901-100000 originals)"
    patched="$(make_backup legacy pre-v1.4.1-20260910-100000 patched)"
    empty="$(make_backup legacy pre-v1.4.1-20260920-100000 empty)"
    # uninstall orders backups by mtime (ls -dt): good oldest, empty newest.
    touch -t 202609010000 "$good"; touch -t 202609100000 "$patched"; touch -t 202609200000 "$empty"
    run_uninstall; assert_status "$RC" 0
    assert_contains "$OUT" "Skipping backup without Canon's original binaries: $empty"
    assert_contains "$OUT" "Skipping backup without Canon's original binaries: $patched"
    assert_contains "$OUT" "Restoring from backup: $good"
    assert_same "$RES/EOSWebcamService" "$good/EOSWebcamService"
}

test_cancelled_admin_prompt_restarts_services() {
    make_fork_install
    make_backup legacy pre-v1.4.1-20260920-100000 originals >/dev/null
    export STUB_OSASCRIPT_CANCEL=1
    run_uninstall; assert_status "$RC" 1
    assert_contains "$OUT" "Uninstall did not finish"
    assert_contains "$OUT" "Nothing was restored: the fork is still installed"
    assert_lacks "$OUT" "Original binaries restored"
    assert_contains "$STUB_LOG" "launchctl load /Library/LaunchAgents/com.canon.usa.EWCService.plist"
    assert_contains "$STUB_LOG" "launchctl load $AGENT"
    # Nothing removed: the fork is still installed and working.
    assert_file "$AGENT"
    assert_file "$RUNTIME/eos-camera-manager.sh"
    assert_same "$RES/EOSWebcamService" "$PATCHED/Contents/Resources/EOSWebcamService"
}

test_failed_restore_is_reported_as_failure() {
    make_fork_install
    local good
    good="$(make_backup new pre-v1.4.1-20260920-100000 originals)"
    # Root's copy of the third binary fails, after the first two went in.
    chmod 444 "$RES/EWCProxy"
    run_uninstall
    [ "$RC" != 0 ] || fail "uninstall exited 0 after a failed restore"
    assert_lacks "$OUT" "Original binaries restored"
    assert_lacks "$OUT" "Uninstall complete."
    assert_contains "$OUT" "The restore stopped part-way"
    assert_contains "$OUT" "Your backup is untouched: $good"
    # It stopped at the failed cp: no signing, nothing removed afterwards.
    sed '/--- root script ---/,/--- end root script ---/d' "$STUB_LOG" > "$SANDBOX/calls-only.log"
    assert_lacks "$SANDBOX/calls-only.log" "codesign"
    assert_same "$BIN/EOSWebcamUtility" "$good/EOSWebcamUtility"
    assert_same "$RES/EWCProxy" "$PATCHED/Contents/Resources/EWCProxy"
    assert_file "$AGENT"
    assert_file "$RUNTIME/eos-camera-manager.sh"
    holds_originals "$good" || fail "backup no longer verifies"
    assert_contains "$STUB_LOG" "launchctl load $AGENT"
}

# VM scenario 6b, uninstall side: v1.4.1 is still installed from another
# clone (X), with its backups in X/backups; uninstall runs from this clone.
test_restores_from_the_clone_the_launchagent_runs_the_daemon_from() {
    make_fork_install
    local other="$HOME/Desktop/old-clone" good
    good="$other/backups/pre-v1.4.1-20260920-100000"
    mkdir -p "$good"
    /usr/bin/python3 "$FIXTURES/make-canon-plugin.py" "$SANDBOX/canon"
    cp "$SANDBOX/canon/Contents/MacOS/EOSWebcamUtility" "$SANDBOX/canon/Contents/Resources/EOSWebcamService" \
       "$SANDBOX/canon/Contents/Resources/EWCProxy" "$good/"
    echo old > "$other/eos-camera-manager.sh"
    printf '<string>%s/eos-camera-manager.sh</string>\n' "$other" > "$AGENT"
    run_uninstall; assert_status "$RC" 0
    assert_contains "$OUT" "Restoring from backup: $good"
    holds_originals "$EOSWC_PLUGIN_DIR/Contents" || fail "plug-in not restored"
    assert_no_file "$other/eos-camera-manager.sh"
    assert_file "$good/EWCProxy"   # never deleted
}

test_removes_old_in_clone_daemon() {
    make_fork_install
    make_backup legacy pre-v1.4.1-20260920-100000 originals >/dev/null
    local f
    for f in $DAEMON_FILES; do echo old > "$CLONE/$f"; done
    echo 'PNG' > "$CLONE/logo.png"
    printf '<string>%s/eos-camera-manager.sh</string>\n' "$CLONE" > "$AGENT"
    run_uninstall; assert_status "$RC" 0
    for f in $DAEMON_FILES; do assert_no_file "$CLONE/$f"; done
    assert_file "$CLONE/logo.png"   # the user's own file in their clone stays
}

run_tests
