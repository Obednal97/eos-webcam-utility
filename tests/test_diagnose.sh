#!/bin/bash
# diagnose.sh against a fake home. See helpers.sh.
. "$(dirname "$0")/helpers.sh"

installed_layout() {
    mkdir -p "$RUNTIME"
    local f
    for f in eos-camera-manager.sh generate-images.sh errorNoDevice_connecting.jpg errorNoDevice_disconnected.jpg config.plist; do
        echo x > "$RUNTIME/$f"
    done
    printf '<string>%s/eos-camera-manager.sh</string>\n' "$RUNTIME" > "$AGENT"
}

report() { echo "$HOME/Desktop/eos-webcam-diagnostics.txt"; }

test_reads_the_new_runtime_path() {
    installed_layout
    launchctl_lists "501|0|com.canon.usa.EWCService" "502|0|com.eos-camera-manager"
    run_diagnose; assert_status "$RC" 0
    local r; r="$(report)"
    assert_file "$r"
    assert_contains "$r" "----- Camera manager install -----"
    # The username is redacted in the report, so match the path's tail.
    assert_contains "$r" "Library/Application Support/EWCService/eos-camera-manager.sh"
    assert_contains "$r" "LaunchAgent runs: "
    assert_contains "$r" "errorNoDevice_disconnected.jpg"   # runtime dir listing
    assert_lacks "$r" "[WARN] LaunchAgent points at an old install location"
    assert_lacks "$r" "[WARN] that daemon file does not exist"
    assert_lacks "$r" "privacy-protected folder"
    assert_contains "$r" "com.canon.usa.EWCService: RUNNING (PID 501)"
    assert_contains "$r" "com.eos-camera-manager: RUNNING (PID 502)"
    assert_lacks "$r" "The camera manager isn't running"
}

test_flags_crash_looping_daemon_listed_without_pid() {
    installed_layout
    launchctl_lists "501|0|com.canon.usa.EWCService" "-|126|com.eos-camera-manager"
    echo "bash: eos-camera-manager.sh: Operation not permitted" > "$HOME/Library/Logs/eos-camera-manager-stderr.log"
    run_diagnose; assert_status "$RC" 0
    local r; r="$(report)"
    assert_contains "$r" "com.eos-camera-manager: LOADED BUT NOT RUNNING (last exit status 126)"
    assert_contains "$r" "The camera manager isn't running"
    assert_contains "$r" "Operation not permitted"
}

test_reports_jobs_that_are_not_loaded() {
    installed_layout
    run_diagnose; assert_status "$RC" 0
    local r; r="$(report)"
    assert_contains "$r" "com.canon.usa.EWCService: NOT LOADED"
    assert_contains "$r" "com.eos-camera-manager: NOT LOADED"
}

test_warns_about_old_daemon_in_protected_folder() {
    printf '<string>%s/eos-camera-manager.sh</string>\n' "$CLONE" > "$AGENT"
    run_diagnose; assert_status "$RC" 0
    local r; r="$(report)"
    assert_contains "$r" "[WARN] that daemon file does not exist"
    assert_contains "$r" "[WARN] LaunchAgent points at an old install location"
    assert_contains "$r" "[WARN] that is a privacy-protected folder"
}

test_reports_missing_launch_agent() {
    run_diagnose; assert_status "$RC" 0
    assert_contains "$(report)" "LaunchAgent: not installed"
}

run_tests
