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

run_tests
