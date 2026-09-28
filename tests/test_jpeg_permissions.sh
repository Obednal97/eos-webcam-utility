#!/bin/bash
# M5: the plug-in's loading-screen JPEGs are never world-writable. Older
# installers chmod'ed all three 666. Now errorNoDevice.jpg (the one the fork
# writes: the camera manager, running as the user, swaps it) belongs to the
# installing user, 644; errorBusy.jpg and default.jpg go back to 644 with
# Canon's owner untouched. chown is a stub that only records; chmod records
# and really runs.
. "$(dirname "$0")/helpers.sh"

JPEGS="errorNoDevice.jpg errorBusy.jpg default.jpg"
mode_of() { stat -f %Lp "$1"; }

assert_jpegs_644() {
    local f
    for f in $JPEGS; do
        assert_file "$RES/$f"
        [ "$(mode_of "$RES/$f")" = 644 ] || fail "$f is mode $(mode_of "$RES/$f"), expected 644"
    done
}

# What older installers left behind.
world_writable_jpegs() {
    local f
    for f in $JPEGS; do /bin/chmod 666 "$RES/$f"; done   # not via the logging stub
}

test_install_leaves_no_world_writable_jpegs() {
    make_canon_install
    world_writable_jpegs
    run_install; assert_status "$RC" 0
    assert_jpegs_644
    assert_lacks "$STUB_LOG" "chmod 666"
    # errorNoDevice.jpg is handed to the installing user, the others aren't
    # re-owned at all.
    assert_log_matches "^chown $(whoami):staff $RES/errorNoDevice\.jpg$"
    ! grep -qE "^chown .*(errorBusy|default)\.jpg" "$STUB_LOG" || fail "Canon's other JPEGs were re-owned"
    # The user (and so the camera manager) can still swap the loading screen.
    [ -w "$RES/errorNoDevice.jpg" ] || fail "errorNoDevice.jpg not writable by its owner"
    assert_same "$RES/errorNoDevice.jpg" "$CLONE/dist/v1.4/images/errorNoDevice_connecting.jpg"
}

test_fresh_install_leaves_no_world_writable_jpegs() {
    printf 'xar!fake flat package\n' > "$HOME/Downloads/Canon.pkg"
    pin_test_pkg "$HOME/Downloads/Canon.pkg"
    run_install --pkg "$HOME/Downloads/Canon.pkg"; assert_status "$RC" 0
    assert_jpegs_644
    assert_lacks "$STUB_LOG" "chmod 666"
}

test_reinstall_over_the_fork_repairs_world_writable_jpegs() {
    make_canon_install --patched
    world_writable_jpegs
    run_install; assert_status "$RC" 0
    assert_jpegs_644
}

test_uninstall_repairs_world_writable_jpegs() {
    make_canon_install --patched
    world_writable_jpegs
    local b
    b="$(backup_root)/pre-v1.4.1-20260101-100000"
    mkdir -p "$b"
    /usr/bin/python3 "$FIXTURES/make-canon-plugin.py" "$SANDBOX/canon"
    cp "$SANDBOX/canon/Contents/MacOS/EOSWebcamUtility" "$SANDBOX/canon/Contents/Resources/"* "$b/"
    run_uninstall; assert_status "$RC" 0
    assert_jpegs_644
    assert_same "$RES/errorBusy.jpg" "$b/errorBusy.jpg"
}

# The installer re-owns errorNoDevice.jpg, so it records the owner it had
# (Canon's bundle ships it as uid 502:staff) in the backup, and uninstall
# puts that owner back.
backup_with_canon_files() {
    local b
    b="$(backup_root)/$1"
    mkdir -p "$b"
    /usr/bin/python3 "$FIXTURES/make-canon-plugin.py" "$SANDBOX/canon"
    cp "$SANDBOX/canon/Contents/MacOS/EOSWebcamUtility" "$SANDBOX/canon/Contents/Resources/"* "$b/"
    echo "$b"
}

test_install_records_the_original_owner_of_errorNoDevice() {
    make_canon_install
    local want b
    want="$(stat -f %u:%g "$RES/errorNoDevice.jpg")"
    run_install; assert_status "$RC" 0
    b="$(latest_backup)"
    assert_file "$b/errorNoDevice.owner"
    [ "$(cat "$b/errorNoDevice.owner" 2>/dev/null)" = "$want" ] ||
        fail "recorded owner '$(cat "$b/errorNoDevice.owner" 2>/dev/null)', expected $want"
    # Recorded before root re-owned the file.
    local rec chown
    rec="$(grep -nF "errorNoDevice.owner" "$STUB_LOG" | grep -v '^[0-9]*:#' | head -1 | cut -d: -f1)"
    chown="$(grep -nE "^chown $(whoami):staff $RES/errorNoDevice\.jpg$" "$STUB_LOG" | head -1 | cut -d: -f1)"
    [ -n "$rec" ] && [ -n "$chown" ] && [ "$rec" -lt "$chown" ] || fail "owner not recorded before the chown"
}

test_reused_backup_gets_the_owner_recorded_too() {
    make_canon_install
    local b
    b="$(backup_root)/pre-v1.4.1-20260101-100000"
    mkdir -p "$b"
    cp "$BIN/EOSWebcamUtility" "$RES/EOSWebcamService" "$RES/EWCProxy" "$b/"
    # Reused only while the installed plug-in isn't Canon's own signed bundle
    # (then a full backup is taken instead): re-signed, as older uninstallers
    # left it.
    codesign --force --deep --sign - "$EOSWC_PLUGIN_DIR" 2>/dev/null
    run_install; assert_status "$RC" 0
    assert_contains "$OUT" "already backed up in $b"
    [ "$(cat "$b/errorNoDevice.owner" 2>/dev/null)" = "$(stat -f %u:%g "$ORIG/Contents/Resources/errorNoDevice.jpg")" ] ||
        fail "owner not recorded in the reused backup"
}

test_uninstall_restores_the_recorded_owner_of_errorNoDevice() {
    make_canon_install --patched
    local b
    b="$(backup_with_canon_files pre-v1.4.1-20260101-100000)"
    echo "502:20" > "$b/errorNoDevice.owner"
    run_uninstall; assert_status "$RC" 0
    assert_log_matches "^chown 502:20 $RES/errorNoDevice\.jpg$"
    assert_same "$RES/errorNoDevice.jpg" "$b/errorNoDevice.jpg"
}

test_uninstall_ignores_a_malformed_owner_record() {
    make_canon_install --patched
    local b
    b="$(backup_with_canon_files pre-v1.4.1-20260101-100000)"
    printf '502:20; touch %s/pwned\n' "$SANDBOX" > "$b/errorNoDevice.owner"
    run_uninstall; assert_status "$RC" 0
    assert_no_file "$SANDBOX/pwned"
    ! grep -qE "^chown [^ ]* $RES/errorNoDevice\.jpg$" "$STUB_LOG" || fail "chowned from a malformed record"
    assert_contains "$OUT" "not restoring the owner of errorNoDevice.jpg"
}

test_uninstall_without_an_owner_record_leaves_the_owner() {
    make_canon_install --patched
    backup_with_canon_files pre-v1.4.1-20260101-100000 >/dev/null
    run_uninstall; assert_status "$RC" 0
    ! grep -qE "^chown [^ ]* $RES/errorNoDevice\.jpg$" "$STUB_LOG" || fail "chowned without a record"
}

run_tests
