#!/bin/bash
# M3: a --pkg is checked before root ever runs Canon's installer on it. Only
# Canon's exact v1.3.16 package (the .zip or the .pkg inside, by SHA-256) is
# accepted; --allow-unverified-pkg overrides that, loudly. Tests pin a fake
# package through EOSWC_TEST_PKG_SHA256, honoured only in a marked sandbox.
. "$(dirname "$0")/helpers.sh"

PKG=""
fake_pkg() {
    PKG="$HOME/Downloads/Canon.pkg"
    printf 'xar!fake flat package %s\n' "${1:-}" > "$PKG"
}

# Refused in step 2: no admin prompt, nothing stopped, nothing installed.
assert_pkg_refused() {
    assert_status "$RC" 1
    assert_contains "$OUT" "ERROR: refusing to use $PKG"
    assert_contains "$OUT" "Nothing was changed."
    assert_lacks "$STUB_LOG" "osascript"
    assert_lacks "$STUB_LOG" "launchctl"
    assert_lacks "$STUB_LOG" "installer -pkg"
    assert_no_file "$EOSWC_PLUGIN_DIR"
    assert_no_file "$(backup_root)"
}

test_unpinned_unsigned_pkg_is_refused() {
    fake_pkg
    run_install --pkg "$PKG"
    assert_contains "$OUT" "isn't the one pinned for Canon's v1.3.16 package"
    assert_contains "$OUT" "it is NOT signed by Canon."
    assert_contains "$STUB_LOG" "pkgutil --check-signature $PKG"
    assert_pkg_refused
}

test_canon_signed_but_unpinned_pkg_is_refused() {
    fake_pkg
    export STUB_PKGUTIL_SIG=canon
    run_install --pkg "$PKG"
    assert_contains "$OUT" "signed by Canon (Developer ID Installer: Canon U.S.A., Inc. (NC5A977249)), but not the v1.3.16 build"
    assert_pkg_refused
}

test_tampered_pkg_is_refused() {
    fake_pkg
    pin_test_pkg "$PKG"
    printf 'x' >> "$PKG"   # one byte changed after it was pinned
    run_install --pkg "$PKG"
    assert_pkg_refused
}

test_bundle_pkg_is_refused_without_the_override() {
    PKG="$HOME/Downloads/Canon.pkg"
    mkdir -p "$PKG/Contents"
    echo '<plist/>' > "$PKG/Contents/Info.plist"
    run_install --pkg "$PKG"
    assert_contains "$OUT" "bundle-style (folder) package"
    assert_pkg_refused
}

test_zip_holding_an_unpinned_pkg_is_refused() {
    fake_pkg
    ditto -c -k --keepParent "$PKG" "$HOME/Downloads/Canon.pkg.zip"
    local zip="$HOME/Downloads/Canon.pkg.zip"
    run_install --pkg "$zip"
    assert_status "$RC" 1
    assert_contains "$OUT" "ERROR: refusing to use $zip"
    assert_lacks "$STUB_LOG" "osascript"
    assert_lacks "$STUB_LOG" "installer -pkg"
}

test_pinned_pkg_is_accepted() {
    fake_pkg
    pin_test_pkg "$PKG"
    run_install --pkg "$PKG"; assert_status "$RC" 0
    assert_contains "$OUT" "Verified: SHA-256 matches Canon's v1.3.16 package."
    assert_log_matches "^installer -pkg "
    assert_lacks "$OUT" "WARNING: --allow-unverified-pkg"
}

test_zip_whose_pkg_is_pinned_is_accepted() {
    fake_pkg
    pin_test_pkg "$PKG"   # the .pkg, not the .zip around it
    ditto -c -k --keepParent "$PKG" "$HOME/Downloads/Canon.pkg.zip"
    run_install --pkg "$HOME/Downloads/Canon.pkg.zip"; assert_status "$RC" 0
    assert_contains "$OUT" "Verified: the .pkg inside matches Canon's v1.3.16 package (SHA-256)."
    assert_log_matches "^installer -pkg "
}

test_override_installs_with_a_loud_warning() {
    fake_pkg
    run_install --pkg "$PKG" --allow-unverified-pkg; assert_status "$RC" 0
    assert_contains "$OUT" "!! WARNING: --allow-unverified-pkg: using a package that FAILED checks. !!"
    assert_contains "$OUT" "it is NOT signed by Canon"
    assert_contains "$OUT" "It will be run AS ROOT"
    assert_log_matches "^installer -pkg "
    holds_patched "$EOSWC_PLUGIN_DIR/Contents" || fail "plug-in not patched"
}

# A bundle-style .pkg can't be checked against the pin at all: the override
# still takes it, and the warning (saying why) comes before the password
# prompt, so the user can still cancel.
test_override_takes_a_bundle_pkg_and_warns_before_the_prompt() {
    PKG="$HOME/Downloads/Canon.pkg"
    mkdir -p "$PKG/Contents"
    echo '<plist/>' > "$PKG/Contents/Info.plist"
    export STUB_PKGUTIL_SIG=canon
    run_install --pkg "$PKG" --allow-unverified-pkg; assert_status "$RC" 0
    assert_contains "$OUT" "!! WARNING: --allow-unverified-pkg: using a package that FAILED checks. !!"
    assert_contains "$OUT" "bundle-style (folder) package"
    assert_contains "$OUT" "Cancel the password prompt"
    local warn prompt
    warn="$(grep -nF "WARNING: --allow-unverified-pkg" "$OUT" | head -1 | cut -d: -f1)"
    prompt="$(grep -nF "macOS asks for your admin password now" "$OUT" | head -1 | cut -d: -f1)"
    [ -n "$warn" ] && [ -n "$prompt" ] && [ "$warn" -lt "$prompt" ] || fail "warning not shown before the admin prompt"
    assert_contains "$STUB_LOG" "installer-kind bundle"
    holds_patched "$EOSWC_PLUGIN_DIR/Contents" || fail "plug-in not patched"
}

test_override_needs_a_pkg() {
    make_canon_install
    run_install --allow-unverified-pkg
    assert_status "$RC" 1
    assert_contains "$OUT" "--allow-unverified-pkg only applies to --pkg"
    assert_lacks "$STUB_LOG" "osascript"
}

# The pin hook, like EOSWC_PLUGIN_DIR, is refused outside a marked sandbox.
test_pin_hook_is_refused_outside_a_sandbox() {
    local out rc=0
    out="$(unset EOSWC_TEST_SANDBOX; export EOSWC_TEST_PKG_SHA256=abc
           . "$CLONE/dist/v1.4/common.sh" && eoswc_require_sandbox_for EOSWC_TEST_PKG_SHA256 2>&1)" || rc=$?
    assert_status "$rc" 1
    case "$out" in *"EOSWC_TEST_PKG_SHA256 is set (abc), but it is a test-only hook"*) ;; *) fail "unexpected: $out" ;; esac
    rc=0
    (export EOSWC_TEST_PKG_SHA256=abc; . "$CLONE/dist/v1.4/common.sh" && eoswc_require_sandbox_for EOSWC_TEST_PKG_SHA256) || rc=$?
    assert_status "$rc" 0
    # install.sh checks it before anything else can use it.
    grep -q '^eoswc_require_sandbox_for EOSWC_TEST_PKG_SHA256 || exit 1$' "$CLONE/dist/v1.4/install.sh" ||
        fail "install.sh does not guard EOSWC_TEST_PKG_SHA256"
}

run_tests
