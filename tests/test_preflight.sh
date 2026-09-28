#!/bin/bash
# L2: before anything is stopped, the pre-flight checks really run python3
# (without letting the Command Line Tools shim pop up a dialog) and check
# every tool the scripts need.
. "$(dirname "$0")/helpers.sh"

fresh_pinned_pkg() {
    printf 'xar!fake flat package\n' > "$HOME/Downloads/Canon.pkg"
    pin_test_pkg "$HOME/Downloads/Canon.pkg"
}

# Stopped in the pre-flight checks: no prompt, no service stopped, nothing
# installed, nothing backed up.
assert_stopped_before_teardown() {
    assert_status "$RC" 1
    assert_contains "$OUT" "Nothing was changed."
    assert_lacks "$STUB_LOG" "osascript"
    assert_lacks "$STUB_LOG" "launchctl"
    assert_lacks "$STUB_LOG" "installer -pkg"
    assert_no_file "$(backup_root)"
}

# A python3 on PATH that exists but doesn't run.
broken_python3_on_path() {
    mkdir -p "$SANDBOX/badbin"
    printf '#!/bin/bash\necho "python3-stub $*" >> "$STUB_LOG"\nexit 1\n' > "$SANDBOX/badbin/python3"
    chmod +x "$SANDBOX/badbin/python3"
    export PATH="$SANDBOX/badbin:$PATH"
}

test_install_without_command_line_tools_stops_before_teardown() {
    fresh_pinned_pkg
    export STUB_NO_CLT=1
    run_install --pkg "$HOME/Downloads/Canon.pkg"
    assert_contains "$OUT" "python3 needs Apple's Command Line Tools"
    assert_contains "$STUB_LOG" "xcode-select -p"
    assert_stopped_before_teardown
    assert_no_file "$EOSWC_PLUGIN_DIR"
}

test_install_with_a_broken_python3_stops_before_teardown() {
    fresh_pinned_pkg
    broken_python3_on_path
    run_install --pkg "$HOME/Downloads/Canon.pkg"
    assert_contains "$OUT" "python3 is installed but doesn't run"
    assert_contains "$STUB_LOG" "python3-stub -c import sys; sys.exit(0)"
    assert_stopped_before_teardown
}

test_install_over_canon_with_a_broken_python3_stops_before_teardown() {
    make_canon_install
    broken_python3_on_path
    run_install
    assert_contains "$OUT" "python3 is installed but doesn't run"
    assert_stopped_before_teardown
    assert_same "$RES/EOSWebcamService" "$ORIG/Contents/Resources/EOSWebcamService"
}

test_uninstall_without_command_line_tools_changes_nothing() {
    make_canon_install --patched
    export STUB_NO_CLT=1
    run_uninstall
    assert_status "$RC" 1
    assert_contains "$OUT" "python3 needs Apple's Command Line Tools"
    assert_lacks "$STUB_LOG" "osascript"
    assert_lacks "$STUB_LOG" "launchctl"
    holds_patched "$EOSWC_PLUGIN_DIR/Contents" || fail "plug-in changed"
}

test_a_missing_tool_is_reported() {
    local out rc=0
    out="$(. "$CLONE/dist/v1.4/common.sh" && eoswc_require_tools eoswc-no-such-tool 2>&1)" || rc=$?
    assert_status "$rc" 1
    case "$out" in *"required tool(s) not found: eoswc-no-such-tool"*) ;; *) fail "unexpected output: $out" ;; esac
}

test_the_normal_toolset_passes() {
    local rc=0
    (. "$CLONE/dist/v1.4/common.sh" && eoswc_require_tools installer pkgutil curl >/dev/null) || rc=$?
    assert_status "$rc" 0
}

run_tests
