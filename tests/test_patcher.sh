#!/bin/bash
# patch-binaries.py --check-original / --check-patched, which install.sh and
# uninstall.sh use to decide whether a backup really holds Canon's originals.
# Runs the real patcher against fake binaries; see helpers.sh.
. "$(dirname "$0")/helpers.sh"

PATCHER_UNDER_TEST() { /usr/bin/python3 -B "$CLONE/dist/v1.4/patch-binaries.py" "$@"; }

# check MODE DIR: run a check, output in $OUT, status in RC.
check() {
    if PATCHER_UNDER_TEST "$1" "$2" > "$OUT" 2>&1; then RC=0; else RC=$?; fi
}

# A flat backup dir (as install.sh writes it) of the fixture binaries.
flat_backup() {
    local src="$SANDBOX/src-$1" dir="$SANDBOX/$1"
    shift
    /usr/bin/python3 "$FIXTURES/make-canon-plugin.py" "$src" "$@"
    mkdir -p "$dir"
    cp "$src/Contents/MacOS/EOSWebcamUtility" "$src/Contents/Resources/EOSWebcamService" \
       "$src/Contents/Resources/EWCProxy" "$dir/"
    echo "$dir"
}

cut_tail() { /usr/bin/python3 -c 'import os, sys; p = sys.argv[1]; os.truncate(p, os.path.getsize(p) - int(sys.argv[2]))' "$1" "$2"; }

test_accepts_a_correct_original_backup() {
    local b; b="$(flat_backup good)"
    check --check-original "$b"; assert_status "$RC" 0
    assert_contains "$OUT" "holds Canon's original binaries"
    # Not byte-identical to Canon's package, so accepted on the fallback.
    assert_contains "$OUT" "EWCProxy: Canon's original bytes at every patch offset, complete Mach-O"
}

test_recognises_canon_package_files_by_sha256() {
    local b; b="$(flat_backup pkg)"
    # Point the patcher's table of Canon's package hashes at the fixture's
    # EWCProxy (the real table holds Canon's, which the fixtures can't match).
    /usr/bin/python3 -B - "$CLONE/dist/v1.4/patch-binaries.py" "$b" > "$OUT" 2>&1 <<'PY' || fail "check failed"
import hashlib, importlib.util, sys
spec = importlib.util.spec_from_file_location("patcher", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
data = open(sys.argv[2] + "/EWCProxy", "rb").read()
m.CANON_SHA256["Resources/EWCProxy"] = (hashlib.sha256(data).hexdigest(), len(data))
m.check_dir(sys.argv[2], "orig")
PY
    assert_contains "$OUT" "EWCProxy: identical to Canon's v1.3.16 package (SHA-256)"
    assert_contains "$OUT" "EOSWebcamService: Canon's original bytes at every patch offset, complete Mach-O"
}

test_canon_hash_table_matches_the_pinned_package_sizes() {
    # Sanity: the table covers exactly the three patched binaries.
    /usr/bin/python3 -B - "$CLONE/dist/v1.4/patch-binaries.py" <<'PY' || fail "hash table does not match PATCHES"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("patcher", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
assert set(m.CANON_SHA256) == set(m.PATCHES)
for rel, (h, size) in m.CANON_SHA256.items():
    assert len(h) == 64 and int(h, 16) >= 0 and size > max(o for o, _, _ in m.PATCHES[rel])
PY
}

test_accepts_originals_in_plugin_layout() {
    /usr/bin/python3 "$FIXTURES/make-canon-plugin.py" "$SANDBOX/p"
    check --check-original "$SANDBOX/p/Contents"; assert_status "$RC" 0
    check --check-patched "$SANDBOX/p/Contents"; assert_status "$RC" 1
}

test_rejects_a_backup_with_one_patched_binary() {
    local b; b="$(flat_backup mixed)"
    /usr/bin/python3 "$FIXTURES/make-canon-plugin.py" "$SANDBOX/patched" --patched
    cp "$SANDBOX/patched/Contents/Resources/EWCProxy" "$b/EWCProxy"
    check --check-original "$b"; assert_status "$RC" 1
    assert_contains "$OUT" "EWCProxy: holds the fork's patched bytes"
    assert_lacks "$OUT" "EOSWebcamService:"
}

test_rejects_a_binary_patched_at_only_some_offsets() {
    local b; b="$(flat_backup half)"
    # The isPro getter patched, the rest of EOSWebcamService original.
    printf '\x20\x00\x80\x52' | dd of="$b/EOSWebcamService" bs=1 seek=$((0x89b58)) conv=notrunc 2>/dev/null
    check --check-original "$b"; assert_status "$RC" 1
    assert_contains "$OUT" "EOSWebcamService: a mix of original and patched bytes"
}

test_rejects_a_truncated_backup() {
    local b; b="$(flat_backup cut)"
    cut_tail "$b/EOSWebcamUtility" 1
    check --check-original "$b"; assert_status "$RC" 1
    assert_contains "$OUT" "EOSWebcamUtility: truncated"
}

test_rejects_a_backup_cut_before_a_patch_offset() {
    local b; b="$(flat_backup short)"
    /usr/bin/python3 -c 'import os, sys; os.truncate(sys.argv[1], 0x40000)' "$b/EWCProxy"
    check --check-original "$b"; assert_status "$RC" 1
    assert_contains "$OUT" "EWCProxy: truncated"
}

test_rejects_missing_empty_or_symlinked_binaries() {
    local b; b="$(flat_backup odd)"
    rm -f "${b:?}/EWCProxy"
    : > "$b/EOSWebcamService"
    mv "$b/EOSWebcamUtility" "$SANDBOX/real-EOSWebcamUtility"
    ln -s "$SANDBOX/real-EOSWebcamUtility" "$b/EOSWebcamUtility"
    check --check-original "$b"; assert_status "$RC" 1
    assert_contains "$OUT" "EWCProxy: missing"
    assert_contains "$OUT" "EOSWebcamService: too short"
    assert_contains "$OUT" "EOSWebcamUtility: missing (or not a regular file)"
}

test_rejects_a_non_macho_file_with_the_right_bytes() {
    local b; b="$(flat_backup notmacho)"
    printf 'XXXX' | dd of="$b/EWCProxy" bs=1 seek=0 conv=notrunc 2>/dev/null
    check --check-original "$b"; assert_status "$RC" 1
    assert_contains "$OUT" "EWCProxy: not a thin arm64 Mach-O file"
}

test_rejects_unexpected_bytes() {
    local b; b="$(flat_backup corrupt --corrupt)"
    check --check-original "$b"; assert_status "$RC" 1
    assert_contains "$OUT" "EOSWebcamService: unexpected bytes"
}

test_check_patched_accepts_only_fully_patched() {
    local p; p="$(flat_backup patched --patched)"
    check --check-patched "$p"; assert_status "$RC" 0
    check --check-original "$p"; assert_status "$RC" 1
}

test_patch_mode_still_patches_and_then_verifies_as_patched() {
    /usr/bin/python3 "$FIXTURES/make-canon-plugin.py" "$SANDBOX/p"
    /usr/bin/python3 "$FIXTURES/make-canon-plugin.py" "$SANDBOX/want" --patched
    PATCHER_UNDER_TEST "$SANDBOX/p/Contents" > "$OUT" 2>&1
    assert_same "$SANDBOX/p/Contents/Resources/EWCProxy" "$SANDBOX/want/Contents/Resources/EWCProxy"
    check --check-patched "$SANDBOX/p/Contents"; assert_status "$RC" 0
}

run_tests
