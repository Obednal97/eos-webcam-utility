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
    # The whole signed bundle, byte for byte, with the flat files as hard
    # links into it (no second copy).
    [ -d "$b/EOSWebcamUtility.plugin" ] || { fail "backup $b has no plug-in bundle"; return 0; }
    diff -r "$b/EOSWebcamUtility.plugin" "$ORIG" > "$SANDBOX/bundle-diff.txt" 2>&1 ||
        fail "the backed-up bundle differs from Canon's: $(head -3 "$SANDBOX/bundle-diff.txt")"
    [ "$b/EWCProxy" -ef "$b/EOSWebcamUtility.plugin/Contents/Resources/EWCProxy" ] || fail "flat EWCProxy is not a hard link into the bundle"
    [ "$b/EOSWebcamUtility" -ef "$b/EOSWebcamUtility.plugin/Contents/MacOS/EOSWebcamUtility" ] || fail "flat EOSWebcamUtility is not a hard link"
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
    assert_log_matches "^ditto '$EOSWC_PLUGIN_DIR' '$(backup_root)/pre-v[^']*/EOSWebcamUtility\.plugin'"
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
    assert_contains "$OUT" "could not back up the plug-in (EOSWebcamUtility.plugin); nothing was patched."
    assert_aborted_unpatched
    holds_originals "$EOSWC_PLUGIN_DIR/Contents" || fail "plug-in no longer holds the originals"
}

test_failed_patch_keeps_verified_originals_in_app_support() {
    make_canon_install
    # The patcher dies writing EOSWebcamService, after EOSWebcamUtility: it
    # can't create its temp file in a read-only Resources dir.
    chmod 555 "$RES"
    run_install; assert_status "$RC" 1
    chmod 755 "$RES"
    assert_contains "$OUT" "Permission denied"
    # Root rolled the half-patched plug-in back from the verified backup
    # instead of leaving EOSWebcamUtility patched with a broken signature.
    assert_same "$BIN/EOSWebcamUtility" "$ORIG/Contents/MacOS/EOSWebcamUtility"
    holds_originals "$EOSWC_PLUGIN_DIR/Contents" || fail "plug-in not rolled back to Canon's originals"
    assert_contains "$OUT" "rolled back"
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
# A backup of the live plug-in as an older installer made it: the three
# binaries only.
backup_of_live() {
    local dir
    dir="$(backup_root)/$1"
    mkdir -p "$dir"
    cp "$BIN/EOSWebcamUtility" "$RES/EOSWebcamService" "$RES/EWCProxy" "$dir/"
    echo "$dir"
}
# ... and as this version makes it: the whole signed bundle, flat hard links.
bundle_backup_of_live() {
    local dir f
    dir="$(backup_root)/$1"
    mkdir -p "$dir"
    ditto "$EOSWC_PLUGIN_DIR" "$dir/EOSWebcamUtility.plugin"
    for f in MacOS/EOSWebcamUtility Resources/EOSWebcamService Resources/EWCProxy; do
        ln "$dir/EOSWebcamUtility.plugin/Contents/$f" "$dir/"
    done
    echo "$dir"
}
# The installed plug-in's binaries, re-signed ad hoc the way uninstallers
# before this version left Canon's originals (same code, new signature).
resign_live_like_old_uninstall() {
    codesign --force --sign - "$RES/EOSWebcamService" 2>/dev/null
    codesign --force --sign - "$RES/EWCProxy" 2>/dev/null
    codesign --force --deep --sign - "$EOSWC_PLUGIN_DIR" 2>/dev/null
}

test_rerun_over_canon_reuses_a_matching_backup() {
    make_canon_install
    local existing
    existing="$(bundle_backup_of_live pre-v1.4.3-20260101-100000)"
    run_install; assert_status "$RC" 0
    assert_contains "$OUT" "already backed up in $existing"
    assert_contains "$OUT" "it holds exactly the installed files"
    assert_contains "$OUT" "Backups:        $existing"
    [ "$(count_backups)" = 1 ] || fail "expected no new backup, have $(count_backups)"
    # Root re-checked it against the installed files before patching.
    assert_log_matches "--same-code '$existing' '$EOSWC_PLUGIN_DIR/Contents'"
    holds_patched "$EOSWC_PLUGIN_DIR/Contents" || fail "plug-in not patched"
    holds_originals "$existing" || fail "backup no longer verifies"
}

# Goal: no new ~11.5 MB backup per uninstall/reinstall. An older uninstall
# re-signed Canon's originals ad hoc, so the installed files no longer match
# the (Canon-signed) backup byte for byte: still the same code, so reused.
test_rerun_over_re_signed_originals_reuses_the_older_backup() {
    make_canon_install
    local existing
    existing="$(backup_of_live pre-v1.4.1-20260101-100000)"
    resign_live_like_old_uninstall
    ! cmp -s "$RES/EWCProxy" "$existing/EWCProxy" || fail "setup: not re-signed"
    run_install; assert_status "$RC" 0
    assert_contains "$OUT" "already backed up in $existing"
    assert_contains "$OUT" "the same code, re-signed by an earlier uninstall"
    [ "$(count_backups)" = 1 ] || fail "expected no new backup, have $(count_backups)"
    assert_log_matches "--same-code '$existing' '$EOSWC_PLUGIN_DIR/Contents'"
    # The backup still has Canon's signatures, untouched.
    assert_same "$existing/EWCProxy" "$ORIG/Contents/Resources/EWCProxy"
    holds_patched "$EOSWC_PLUGIN_DIR/Contents" || fail "plug-in not patched"
}

# An older backup has only the three binaries; the installed plug-in is
# Canon's own signed bundle. One full backup is taken (so uninstall can put
# Canon's signature back); after an uninstall, reinstalling reuses it.
test_legacy_backup_over_a_canon_signed_plugin_is_upgraded_once() {
    make_canon_install
    local legacy full
    legacy="$(backup_of_live pre-v1.4.1-20260101-100000)"
    touch -t 202601010000 "$legacy"
    run_install; assert_status "$RC" 0
    assert_contains "$OUT" "has only Canon's three binaries, but the installed"
    [ "$(count_backups)" = 2 ] || fail "expected one full backup next to the old one, have $(count_backups)"
    full="$(latest_backup)"
    [ -d "$full/EOSWebcamUtility.plugin" ] || fail "the new backup has no plug-in bundle"
    run_uninstall; assert_status "$RC" 0
    assert_contains "$OUT" "Restoring from backup: $full"
    run_install; assert_status "$RC" 0
    assert_contains "$OUT" "already backed up in $full"
    [ "$(count_backups)" = 2 ] || fail "reinstall made another backup: have $(count_backups)"
}

# The whole cycle from a fresh Canon install: install, uninstall,
# reinstall, uninstall, reinstall makes one backup, not three.
test_install_uninstall_cycles_make_one_backup() {
    make_canon_install
    local i
    for i in 1 2 3; do
        run_install; assert_status "$RC" 0
        [ "$i" = 1 ] || assert_contains "$OUT" "already backed up in"
        run_uninstall; assert_status "$RC" 0
    done
    [ "$(count_backups)" = 1 ] || fail "expected one backup after three cycles, have $(count_backups)"
    diff -r "$EOSWC_PLUGIN_DIR" "$ORIG" > "$SANDBOX/diff.txt" 2>&1 || fail "plug-in is not byte-identical to Canon's after the cycles: $(head -3 "$SANDBOX/diff.txt")"
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

# --- signing (M6) ---
# The call log without the root script text osascript records.
calls_only() { sed '/--- root script ---/,/--- end root script ---/d' "$STUB_LOG"; }
# What (fake) codesign says about a signed file.
sig_info() { codesign -dv "$1" 2>&1; codesign -d --entitlements - "$1" 2>&1; }

assert_signed_like_canon_ad_hoc() {  # the two helpers, after install
    local h id
    for h in EOSWebcamService:EWCService EWCProxy:EWCProxy; do
        id="${h#*:}"; h="$RES/${h%%:*}"
        sig_info "$h" > "$SANDBOX/sig.txt"
        assert_contains "$SANDBOX/sig.txt" "Identifier=$id"
        assert_contains "$SANDBOX/sig.txt" "flags=0x10002(adhoc,runtime)"
        assert_contains "$SANDBOX/sig.txt" "com.apple.security.device.camera"
        assert_contains "$SANDBOX/sig.txt" "com.apple.security.cs.disable-library-validation"
        codesign --verify --strict "$h" 2>/dev/null || fail "$h does not verify"
    done
    # The DAL plug-in's own executable: ad hoc, no runtime (Canon's has none).
    sig_info "$EOSWC_PLUGIN_DIR" > "$SANDBOX/sig.txt"
    assert_contains "$SANDBOX/sig.txt" "flags=0x2(adhoc)"
}

test_install_keeps_canons_runtime_and_entitlements_when_re_signing() {
    make_canon_install
    run_install; assert_status "$RC" 0
    assert_contains "$OUT" "Patched and signed (ad hoc, with Canon's hardened runtime and camera entitlement)"
    local stage="/[^']*/eoswc-stage\\.[A-Za-z0-9]+"
    assert_log_matches "^    codesign --force --sign - --identifier EWCService --options runtime --entitlements '$stage/entitlements\\.plist' '$RES/EOSWebcamService' &&$"
    assert_log_matches "^    codesign --force --sign - --identifier EWCProxy --options runtime --entitlements '$stage/entitlements\\.plist' '$RES/EWCProxy' &&$"
    assert_log_matches "^    codesign --force --sign - '$EOSWC_PLUGIN_DIR'$"
    # They ran, helpers first, the bundle last, and nothing with --deep.
    calls_only > "$SANDBOX/calls.txt"
    local svc proxy bundle
    svc="$(grep -n -- "--identifier EWCService --options runtime" "$SANDBOX/calls.txt" | head -1 | cut -d: -f1)"
    proxy="$(grep -n -- "--identifier EWCProxy --options runtime" "$SANDBOX/calls.txt" | head -1 | cut -d: -f1)"
    bundle="$(grep -nx -- "codesign --force --sign - $EOSWC_PLUGIN_DIR" "$SANDBOX/calls.txt" | tail -1 | cut -d: -f1)"
    [ -n "$svc" ] && [ -n "$proxy" ] && [ -n "$bundle" ] && [ "$bundle" -gt "$svc" ] && [ "$bundle" -gt "$proxy" ] ||
        fail "helpers not signed before the bundle (svc=$svc proxy=$proxy bundle=$bundle)"
    assert_lacks "$SANDBOX/calls.txt" "--deep"
    assert_signed_like_canon_ad_hoc
    # The entitlements used are the dist file, which holds exactly Canon's
    # entitlement plus the library-validation exception EDSDK needs.
    /usr/bin/python3 -c '
import plistlib, sys
e = plistlib.load(open(sys.argv[1], "rb"))
sys.exit(e != {"com.apple.security.device.camera": True, "com.apple.security.cs.disable-library-validation": True})
' "$CLONE/dist/v1.4/fork-entitlements.plist" ||
        fail "fork-entitlements.plist is not Canon's camera entitlement + disable-library-validation"
}

test_rerun_over_the_current_fork_does_not_re_sign() {
    make_canon_install --patched
    run_install; assert_status "$RC" 0
    assert_contains "$OUT" "Already patched and signed by this version: not re-signing."
    assert_contains "$OUT" "Already patched and signed: nothing changed"
    calls_only > "$SANDBOX/calls.txt"
    assert_lacks "$SANDBOX/calls.txt" "codesign --force"
    assert_same "$RES/EWCProxy" "$SANDBOX/originals/Contents/Resources/EWCProxy"
    holds_patched "$EOSWC_PLUGIN_DIR/Contents" || fail "plug-in changed"
}

# Over an install whose signature isn't this version's (runtime dropped):
# nothing to patch, but it is re-signed.
test_rerun_over_a_fork_without_the_runtime_re_signs() {
    make_canon_install --patched --sig old-fork
    run_install; assert_status "$RC" 0
    assert_lacks "$OUT" "not re-signing"
    assert_signed_like_canon_ad_hoc
}

# --- frame rate (M2) ---
movz_imm() {  # FILE OFFSET -> "wN #imm" of the 32-bit movz there
    /usr/bin/python3 -c '
import struct, sys
insn = struct.unpack_from("<I", open(sys.argv[1], "rb").read(), int(sys.argv[2], 0))[0]
assert insn & 0x7f800000 == 0x52800000, hex(insn)
print("w%d #%d" % (insn & 31, (insn >> 5) & 0xffff))' "$1" "$2"
}

# The fps apps are told is the DAL plug-in's mapping of the service's
# StreamFps (config.plist): 30 -> FPS_30 -> mov w9,#30. All of it must say 30.
assert_advertises_30fps() {
    [ "$(plutil -extract StreamFps raw -o - "$RUNTIME/config.plist")" = 30 ] || fail "config StreamFps is not 30"
    [ "$(plutil -extract PreviewFps raw -o - "$RUNTIME/config.plist")" = 30 ] || fail "config PreviewFps is not 30"
    [ "$(plutil -extract StreamFps raw -o - "$RUNTIME/proconfig.plist")" = 30 ] || fail "proconfig StreamFps is not 30"
    [ "$(movz_imm "$BIN/EOSWebcamUtility" 0x3130c)" = "w9 #30" ] || fail "the plug-in does not advertise 30 for FPS_30: $(movz_imm "$BIN/EOSWebcamUtility" 0x3130c)"
    [ "$(movz_imm "$BIN/EOSWebcamUtility" 0x31310)" = "w10 #60" ] || fail "FPS_60 mapping changed"
    [ "$(movz_imm "$RES/EWCProxy" 0x43810)" = "w8 #30" ] || fail "EWCProxy fps reset is not 30"
    assert_contains "$OUT" "Config: 1920x1080 @ 30fps"
    assert_contains "$OUT" "Resolution:     1920x1080 @ 30fps"
    assert_lacks "$OUT" "60fps"
}

test_fps_config_output_and_advertised_rate_all_say_30() {
    make_canon_install
    run_install; assert_status "$RC" 0
    assert_advertises_30fps
}

# v1.4.1/v1.4.2 made the plug-in advertise 60 (and EWCProxy hold 62) while
# the config and the output said 30. Upgrading puts Canon's bytes back.
test_upgrade_from_an_earlier_fork_version_fixes_the_fps_and_re_signs() {
    make_canon_install --old-patched
    [ "$(movz_imm "$BIN/EOSWebcamUtility" 0x3130c)" = "w9 #60" ] || fail "setup: old fixture should advertise 60"
    run_install; assert_status "$RC" 0
    assert_contains "$OUT" "Mode:          Update existing fork"
    assert_contains "$OUT" "updated:         MacOS/EOSWebcamUtility (from an earlier fork version)"
    assert_log_matches "--check-fork '$EOSWC_PLUGIN_DIR/Contents'"
    holds_patched "$EOSWC_PLUGIN_DIR/Contents" || fail "plug-in not brought up to date"
    assert_advertises_30fps
    assert_signed_like_canon_ad_hoc
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
    # The legacy backup is copied (verified) to Application Support and left
    # where it was; that copy is the only backup made: none of the patched
    # binaries.
    local copy
    copy="$(backup_root)/pre-v1.4.0-20260101-100000"
    assert_contains "$OUT" "Backups:        $copy"
    holds_originals "$copy" || fail "the copy does not verify"
    [ "$(count_backups)" = 1 ] || fail "expected only the copy, have $(count_backups)"
    assert_same "$copy/EWCProxy" "$legacy/EWCProxy"
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

# VM scenario 6b. v1.4.1 was installed from another clone (X): its daemon
# ran from X, its LaunchAgent says so, and its backups are in X/backups.
# This install runs from a different clone.
make_v141_install_in_other_clone() {
    make_canon_install --patched
    OLDCLONE="$HOME/Desktop/old-clone"
    mkdir -p "$OLDCLONE/dist/v1.4" "$OLDCLONE/backups"
    echo old > "$OLDCLONE/eos-camera-manager.sh"
    echo old > "$OLDCLONE/generate-images.sh"
    cat > "$AGENT" <<PLIST
<plist version="1.0"><dict>
	<key>Label</key><string>com.eos-camera-manager</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>$OLDCLONE/eos-camera-manager.sh</string>
	</array>
</dict></plist>
PLIST
    /usr/bin/python3 "$FIXTURES/make-canon-plugin.py" "$SANDBOX/canon"
    local b
    for b in pre-v1.4.1-20260901-100000 pre-v1.4.1-20260910-100000; do
        mkdir -p "$OLDCLONE/backups/$b"
        cp "$SANDBOX/canon/Contents/MacOS/EOSWebcamUtility" "$SANDBOX/canon/Contents/Resources/EOSWebcamService" \
           "$SANDBOX/canon/Contents/Resources/EWCProxy" "$SANDBOX/canon/Contents/Resources/errorNoDevice.jpg" \
           "$OLDCLONE/backups/$b/"
    done
    echo '<canon config/>' > "$OLDCLONE/backups/pre-v1.4.1-20260910-100000/config.plist"
    touch -t 202609010000 "$OLDCLONE/backups/pre-v1.4.1-20260901-100000"
    touch -t 202609100000 "$OLDCLONE/backups/pre-v1.4.1-20260910-100000"
    (cd "$OLDCLONE/backups" && find . -type f -exec shasum {} + | sort) > "$SANDBOX/oldclone-backups.sum"
}

test_upgrade_from_another_clone_finds_and_keeps_its_backups() {
    make_v141_install_in_other_clone
    local newest="$OLDCLONE/backups/pre-v1.4.1-20260910-100000" copy
    run_install; assert_status "$RC" 0
    assert_contains "$OUT" "Mode:          Update existing fork"
    assert_lacks "$OUT" "WARNING: no backup of Canon's original binaries was found"
    assert_contains "$OUT" "Found a backup of Canon's originals left by an older installer: $newest"
    # A verified copy now lives in Application Support, so it outlives X.
    copy="$(latest_backup)"
    [ -n "$copy" ] || { fail "no copy of the old clone's backup in $(backup_root)"; return 0; }
    holds_originals "$copy" || fail "the copy in $copy does not verify"
    local f
    for f in EOSWebcamUtility EOSWebcamService EWCProxy errorNoDevice.jpg config.plist; do
        assert_same "$copy/$f" "$newest/$f"
    done
    assert_contains "$OUT" "Backups:        $copy"
    # The old clone's backups are never moved, changed or deleted.
    (cd "$OLDCLONE/backups" && find . -type f -exec shasum {} + | sort) > "$SANDBOX/oldclone-after.sum"
    assert_same "$SANDBOX/oldclone-after.sum" "$SANDBOX/oldclone-backups.sum"
    # The old daemon copy in X went, as before.
    assert_no_file "$OLDCLONE/eos-camera-manager.sh"
    assert_daemon_in_runtime_dir
    # And uninstall, from this clone, restores from the copy even with X gone.
    mv "$OLDCLONE" "$SANDBOX/old-clone-moved-away"
    run_uninstall; assert_status "$RC" 0
    assert_contains "$OUT" "Restoring from backup: $copy"
    holds_originals "$EOSWC_PLUGIN_DIR/Contents" || fail "plug-in not restored"
}

test_upgrade_from_another_clone_copies_its_backup_only_once() {
    make_v141_install_in_other_clone
    run_install; assert_status "$RC" 0
    run_install; assert_status "$RC" 0
    [ "$(count_backups)" = 1 ] || fail "expected one copy in Application Support, have $(count_backups)"
}

# VM scenario 7: the unprivileged side's EXIT trap deleted staging while the
# root step was still running, so root couldn't open the staged patcher to
# check the backup. That must not be reported as a bad backup.
test_staging_vanishing_mid_root_step_is_reported_as_such() {
    make_canon_install
    export STUB_ROOT_VANISH_STAGED=1
    run_install; assert_status "$RC" 1
    assert_lacks "$OUT" "does not hold complete original Canon v1.3.16 binaries"
    assert_contains "$OUT" "staging folder disappeared"
    assert_lacks "$OUT" "Installation complete!"
    holds_originals "$EOSWC_PLUGIN_DIR/Contents" || fail "plug-in changed"
    holds_originals "$(latest_backup)" || fail "backup does not verify"
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
