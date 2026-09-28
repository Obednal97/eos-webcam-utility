#!/bin/bash
# M10: the fork's first camera manager (LaunchAgent com.canon-camera-manager,
# running a canon-camera-manager.sh from the clone) is booted out and removed,
# with its launchd logs, by install and uninstall, but only if it really is
# the fork's. diagnose reports it.
. "$(dirname "$0")/helpers.sh"

LEGACY=""
LOGS=""
# legacy_plist LABEL PROGRAM [STDOUT] [STDERR]
legacy_plist() {
    LEGACY="$HOME/Library/LaunchAgents/com.canon-camera-manager.plist"
    LOGS="$HOME/Library/Logs"
    cat > "$LEGACY" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$1</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>$2</string>
	</array>
	<key>RunAtLoad</key><true/>
	<key>StandardOutPath</key><string>${3:-$HOME/Library/Logs/canon-camera-manager-stdout.log}</string>
	<key>StandardErrorPath</key><string>${4:-$HOME/Library/Logs/canon-camera-manager-stderr.log}</string>
</dict>
</plist>
PLIST
}
the_forks_legacy_agent() {
    legacy_plist com.canon-camera-manager "$HOME/development/webcam-utility/canon-camera-manager.sh"
    echo out > "$LOGS/canon-camera-manager-stdout.log"
    echo err > "$LOGS/canon-camera-manager-stderr.log"
    echo keep > "$LOGS/eos-camera-manager.log"          # the current daemon's
    echo keep > "$LOGS/something-else.log"
}

assert_legacy_removed() {
    assert_no_file "$LEGACY"
    assert_no_file "$LOGS/canon-camera-manager-stdout.log"
    assert_no_file "$LOGS/canon-camera-manager-stderr.log"
    assert_file "$LOGS/eos-camera-manager.log"
    assert_file "$LOGS/something-else.log"
    assert_contains "$STUB_LOG" "launchctl bootout gui/$(id -u)/com.canon-camera-manager"
    # Booted out while its plist was still there, i.e. before removing it.
    grep -q "^launchctl-bootout-saw: .*com.canon-camera-manager.plist" "$STUB_LOG" ||
        fail "bootout did not happen before the plist was removed"
    assert_contains "$OUT" "Removed the old camera manager LaunchAgent (com.canon-camera-manager)"
}

assert_legacy_kept() {
    assert_file "$LEGACY"
    assert_lacks "$STUB_LOG" "launchctl bootout"
    assert_contains "$OUT" "WARNING: left $LEGACY alone"
}

test_install_removes_the_forks_legacy_agent() {
    make_canon_install
    the_forks_legacy_agent
    run_install; assert_status "$RC" 0
    assert_legacy_removed
}

test_install_keeps_an_agent_that_runs_something_else() {
    make_canon_install
    legacy_plist com.canon-camera-manager /opt/other/some-tool.sh
    echo out > "$LOGS/canon-camera-manager-stdout.log"
    run_install; assert_status "$RC" 0
    assert_legacy_kept
    assert_file "$LOGS/canon-camera-manager-stdout.log"
}

test_install_keeps_a_plist_with_another_label() {
    make_canon_install
    legacy_plist com.example.not-the-fork "$HOME/development/webcam-utility/canon-camera-manager.sh"
    run_install; assert_status "$RC" 0
    assert_legacy_kept
}

test_install_only_removes_logs_in_library_logs() {
    make_canon_install
    legacy_plist com.canon-camera-manager "$HOME/development/webcam-utility/canon-camera-manager.sh" \
        "$HOME/Desktop/canon-camera-manager-stdout.log" "$HOME/Library/Logs/sub/canon-camera-manager-stderr.log"
    echo keep > "$HOME/Desktop/canon-camera-manager-stdout.log"
    mkdir -p "$LOGS/sub"; echo keep > "$LOGS/sub/canon-camera-manager-stderr.log"
    run_install; assert_status "$RC" 0
    assert_no_file "$LEGACY"
    assert_file "$HOME/Desktop/canon-camera-manager-stdout.log"
    assert_file "$LOGS/sub/canon-camera-manager-stderr.log"
}

test_install_does_not_follow_a_log_path_out_of_library_logs() {
    make_canon_install
    # Starts with the right name, but climbs out of ~/Library/Logs.
    legacy_plist com.canon-camera-manager "$HOME/development/webcam-utility/canon-camera-manager.sh" \
        "$HOME/Library/Logs/canon-camera-manager.d/../../../Desktop/victim.log"
    mkdir -p "$LOGS/canon-camera-manager.d"
    echo keep > "$HOME/Desktop/victim.log"
    run_install; assert_status "$RC" 0
    assert_no_file "$LEGACY"
    assert_file "$HOME/Desktop/victim.log"
}

test_install_without_a_legacy_agent_does_nothing_about_it() {
    make_canon_install
    run_install; assert_status "$RC" 0
    assert_lacks "$STUB_LOG" "launchctl bootout"
    assert_lacks "$OUT" "old camera manager LaunchAgent"
}

test_uninstall_removes_the_forks_legacy_agent() {
    make_canon_install --patched
    local b
    b="$(backup_root)/pre-v1.4.1-20260101-100000"
    mkdir -p "$b"
    /usr/bin/python3 "$FIXTURES/make-canon-plugin.py" "$SANDBOX/canon"
    cp "$SANDBOX/canon/Contents/MacOS/EOSWebcamUtility" "$SANDBOX/canon/Contents/Resources/EOSWebcamService" \
       "$SANDBOX/canon/Contents/Resources/EWCProxy" "$b/"
    the_forks_legacy_agent
    run_uninstall; assert_status "$RC" 0
    assert_legacy_removed
}

test_diagnose_reports_the_legacy_agent() {
    the_forks_legacy_agent
    launchctl_lists "777|0|com.canon-camera-manager"
    run_diagnose; assert_status "$RC" 0
    local r
    r="$HOME/Desktop/eos-webcam-diagnostics.txt"
    assert_contains "$r" "----- Old camera manager (com.canon-camera-manager) -----"
    assert_contains "$r" "[WARN] the old camera manager LaunchAgent of the fork is still installed"
    assert_contains "$r" "com.canon-camera-manager: RUNNING (PID 777)"
    assert_file "$LEGACY"   # diagnose is read-only
}

test_diagnose_without_a_legacy_agent() {
    run_diagnose; assert_status "$RC" 0
    assert_contains "$HOME/Desktop/eos-webcam-diagnostics.txt" "not installed (good)"
}

run_tests
