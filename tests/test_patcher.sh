#!/bin/bash
# patch-binaries.py --check-original / --check-patched, which install.sh and
# uninstall.sh use to decide whether a backup really holds Canon's originals.
# Runs the real patcher against fake binaries; see helpers.sh.
. "$(dirname "$0")/helpers.sh"

PATCHER_UNDER_TEST() { /usr/bin/python3 -B "$CLONE/dist/v1.4/patch-binaries.py" "$@"; }

# check MODE DIR [DIR]: run a check, output in $OUT, status in RC.
check() {
    if PATCHER_UNDER_TEST "$@" > "$OUT" 2>&1; then RC=0; else RC=$?; fi
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
    cp -R "$SANDBOX/p" "$SANDBOX/before"
    PATCHER_UNDER_TEST "$SANDBOX/p/Contents" > "$OUT" 2>&1
    check --check-patched "$SANDBOX/p/Contents"; assert_status "$RC" 0
    # Only the patch offsets changed; everything else (the signature area
    # too: re-signing is install.sh's job) is byte for byte what it was.
    /usr/bin/python3 -B - "$CLONE/dist/v1.4/patch-binaries.py" "$SANDBOX/before/Contents" "$SANDBOX/p/Contents" \
        > "$SANDBOX/diff.txt" 2>&1 <<'PY' || { fail "patched files differ from the originals outside the patch offsets"; cat "$SANDBOX/diff.txt"; }
import importlib.util, sys
spec = importlib.util.spec_from_file_location("patcher", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
for rel, patches in m.PATCHES.items():
    want = bytearray(open(sys.argv[2] + "/" + rel, "rb").read())
    for off, _o, new in patches:
        want[off:off + len(bytes.fromhex(new))] = bytes.fromhex(new)
    got = open(sys.argv[3] + "/" + rel, "rb").read()
    assert got == bytes(want), rel
PY
}

# An install of fork v1.4.1/v1.4.2 still has the old fps bytes (REVERTS).
test_check_fork_accepts_an_earlier_fork_version_and_patch_mode_updates_it() {
    /usr/bin/python3 "$FIXTURES/make-canon-plugin.py" "$SANDBOX/old" --old-patched
    check --check-patched "$SANDBOX/old/Contents"; assert_status "$RC" 1
    assert_contains "$OUT" "EOSWebcamUtility: holds an earlier fork version's patched bytes"
    check --check-fork "$SANDBOX/old/Contents"; assert_status "$RC" 0
    assert_contains "$OUT" "EWCProxy: an earlier fork version's patched bytes at every patch offset"
    check --check-original "$SANDBOX/old/Contents"; assert_status "$RC" 1
    PATCHER_UNDER_TEST "$SANDBOX/old/Contents" > "$OUT" 2>&1 || fail "patcher failed"
    assert_contains "$OUT" "updated:         MacOS/EOSWebcamUtility (from an earlier fork version)"
    assert_contains "$OUT" "already patched: Resources/EOSWebcamService"
    check --check-patched "$SANDBOX/old/Contents"; assert_status "$RC" 0
    # Same code as patching Canon's originals with this version.
    /usr/bin/python3 "$FIXTURES/make-canon-plugin.py" "$SANDBOX/new" --patched
    check --same-code "$SANDBOX/old/Contents" "$SANDBOX/new/Contents"; assert_status "$RC" 0
}

test_check_fork_rejects_originals_and_a_half_reverted_binary() {
    /usr/bin/python3 "$FIXTURES/make-canon-plugin.py" "$SANDBOX/o"
    check --check-fork "$SANDBOX/o/Contents"; assert_status "$RC" 1
    assert_contains "$OUT" "holds Canon's original bytes"
    # Canon's bytes everywhere but the old fps patch: neither state.
    local b; b="$(flat_backup mix)"
    printf '\x89\x07' | dd of="$b/EOSWebcamUtility" bs=1 seek=$((0x3130c)) conv=notrunc 2>/dev/null
    check --check-original "$b"; assert_status "$RC" 1
    assert_contains "$OUT" "EOSWebcamUtility: a mix of original and patched bytes"
}

# The fps the plug-in advertises: StreamClient::GetGlobalStreamSettings maps
# the service's StreamFps (1 = FPS_30, 2 = FPS_60) with two mov
# instructions. Canon's are mov w9,#30 and mov w10,#60; the old patch made
# the first mov w9,#60, so every setting advertised 60. EWCProxy's dead reset
# held mov w8,#62.
movz_imm() {  # FILE OFFSET -> "wN #imm" of the 32-bit movz there
    /usr/bin/python3 -c '
import struct, sys
insn = struct.unpack_from("<I", open(sys.argv[1], "rb").read(), int(sys.argv[2], 0))[0]
assert insn & 0x7f800000 == 0x52800000, hex(insn)
print("w%d #%d" % (insn & 31, (insn >> 5) & 0xffff))' "$1" "$2"
}

test_patched_binaries_advertise_the_fps_the_service_is_set_to() {
    local p="$SANDBOX/p" o="$SANDBOX/old"
    /usr/bin/python3 "$FIXTURES/make-canon-plugin.py" "$p"
    PATCHER_UNDER_TEST "$p/Contents" >/dev/null 2>&1 || fail "patcher failed"
    [ "$(movz_imm "$p/Contents/MacOS/EOSWebcamUtility" 0x3130c)" = "w9 #30" ] || fail "FPS_30 does not advertise 30"
    [ "$(movz_imm "$p/Contents/MacOS/EOSWebcamUtility" 0x31310)" = "w10 #60" ] || fail "FPS_60 does not advertise 60"
    [ "$(movz_imm "$p/Contents/Resources/EWCProxy" 0x43810)" = "w8 #30" ] || fail "EWCProxy reset is not 30"
    # And an earlier version's 60/62 are put back.
    /usr/bin/python3 "$FIXTURES/make-canon-plugin.py" "$o" --old-patched
    [ "$(movz_imm "$o/Contents/MacOS/EOSWebcamUtility" 0x3130c)" = "w9 #60" ] || fail "setup: old fixture"
    [ "$(movz_imm "$o/Contents/Resources/EWCProxy" 0x43810)" = "w8 #62" ] || fail "setup: old fixture"
    PATCHER_UNDER_TEST "$o/Contents" >/dev/null 2>&1 || fail "patcher failed"
    [ "$(movz_imm "$o/Contents/MacOS/EOSWebcamUtility" 0x3130c)" = "w9 #30" ] || fail "old 60fps patch not reverted"
    [ "$(movz_imm "$o/Contents/Resources/EWCProxy" 0x43810)" = "w8 #30" ] || fail "old 62fps patch not reverted"
}

# --same-code: a backup of the installed originals, even re-signed.
test_same_code_matches_identical_and_re_signed_binaries_only() {
    local a="$SANDBOX/a" b="$SANDBOX/b"
    /usr/bin/python3 "$FIXTURES/make-canon-plugin.py" "$a"
    /usr/bin/python3 "$FIXTURES/make-canon-plugin.py" "$b"
    check --same-code "$a/Contents" "$b/Contents"; assert_status "$RC" 0
    assert_contains "$OUT" "EWCProxy: byte-identical"
    # Re-sign b's binaries ad hoc (what older uninstallers did).
    /usr/bin/python3 "$FIXTURES/make-canon-plugin.py" "$b" --sig old-fork
    ! cmp -s "$a/Contents/Resources/EWCProxy" "$b/Contents/Resources/EWCProxy" || fail "setup: not re-signed"
    check --same-code "$a/Contents" "$b/Contents"; assert_status "$RC" 0
    assert_contains "$OUT" "EWCProxy: the same code, signed differently"
    # A flat backup dir against a plug-in's Contents works too.
    local f; f="$(flat_backup flat)"
    check --same-code "$f" "$b/Contents"; assert_status "$RC" 0
    # Patched code is different code.
    /usr/bin/python3 "$FIXTURES/make-canon-plugin.py" "$SANDBOX/p" --patched
    check --same-code "$a/Contents" "$SANDBOX/p/Contents"; assert_status "$RC" 1
    assert_contains "$OUT" "EOSWebcamService: different code"
    # One byte of code changed outside any patch offset: different code.
    printf 'X' | dd of="$b/Contents/Resources/EWCProxy" bs=1 seek=4000 conv=notrunc 2>/dev/null
    check --same-code "$a/Contents" "$b/Contents"; assert_status "$RC" 1
    assert_contains "$OUT" "EWCProxy: different code"
    rm -f "${b:?}/Contents/Resources/EWCProxy"
    check --same-code "$a/Contents" "$b/Contents"; assert_status "$RC" 1
    assert_contains "$OUT" "EWCProxy: missing"
}

# Atomic writes: the patcher never leaves a half-written binary. Each case
# makes the write fail at a different point inside atomic_write (in-process,
# via the patcher module) and checks the binary is untouched, has its mode,
# and no temp file is left.
atomic_case() {  # PLUGIN MODE
    /usr/bin/python3 -B - "$CLONE/dist/v1.4/patch-binaries.py" "$1/Contents" "$2" <<'PY'
import builtins, importlib.util, os, sys
spec = importlib.util.spec_from_file_location("patcher", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
contents, mode = sys.argv[2], sys.argv[3]
path = os.path.join(contents, "Resources", "EOSWebcamService")
data = bytearray(open(path, "rb").read())

class Crash(Exception):
    pass

real_fsync, real_replace, real_fdopen = os.fsync, os.replace, os.fdopen
if mode == "mid-write":
    # The disk fills up (or the process dies) half way through the write.
    def fdopen(fd, *a, **k):
        f = real_fdopen(fd, *a, **k)
        w = f.write
        def half(b):
            w(b[:len(b) // 2])
            raise Crash("disk full")
        f.write = half
        return f
    os.fdopen = fdopen
elif mode == "fsync":
    def fsync(fd):
        raise Crash("fsync failed")
    os.fsync = fsync
elif mode == "rename":
    def replace(a, b):
        raise Crash("rename failed")
    os.replace = replace
try:
    m.write_patched(path, "Resources/EOSWebcamService", data)
except Crash:
    print("crashed as planned")
else:
    print("no crash")
PY
}

assert_untouched_after_crash() {  # PLUGIN
    assert_same "$1/Contents/Resources/EOSWebcamService" "$SANDBOX/orig/Contents/Resources/EOSWebcamService"
    [ "$(stat -f %Lp "$1/Contents/Resources/EOSWebcamService")" = 750 ] || fail "mode changed"
    [ -z "$(find "$1/Contents/Resources" -name '*.eoswc-patching-*')" ] || fail "temp file left behind"
    check --check-original "$1/Contents"; assert_status "$RC" 0
}

test_a_write_that_fails_part_way_leaves_the_original_intact() {
    /usr/bin/python3 "$FIXTURES/make-canon-plugin.py" "$SANDBOX/orig"
    local mode
    for mode in mid-write fsync rename; do
        rm -rf "${SANDBOX:?}/p-$mode"
        cp -R "$SANDBOX/orig" "$SANDBOX/p-$mode"
        chmod 750 "$SANDBOX/p-$mode/Contents/Resources/EOSWebcamService" "$SANDBOX/orig/Contents/Resources/EOSWebcamService"
        atomic_case "$SANDBOX/p-$mode" "$mode" > "$OUT" 2>&1
        assert_contains "$OUT" "crashed as planned"
        assert_untouched_after_crash "$SANDBOX/p-$mode"
    done
}

# The process is killed outright (no cleanup runs) after writing the temp
# file and before the rename: the binary is untouched, and the next run
# removes the leftover temp file and patches normally.
test_a_killed_patcher_leaves_the_original_and_the_next_run_cleans_up() {
    /usr/bin/python3 "$FIXTURES/make-canon-plugin.py" "$SANDBOX/orig"
    cp -R "$SANDBOX/orig" "$SANDBOX/p"
    /usr/bin/python3 -B - "$CLONE/dist/v1.4/patch-binaries.py" "$SANDBOX/p/Contents" <<'PY' && fail "the patcher was not killed"
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("patcher", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
def replace(a, b):
    os._exit(9)   # like SIGKILL: no except, no finally
os.replace = replace
sys.argv = ["patch-binaries.py", sys.argv[2]]
m.main()
PY
    assert_same "$SANDBOX/p/Contents/MacOS/EOSWebcamUtility" "$SANDBOX/orig/Contents/MacOS/EOSWebcamUtility"
    [ -n "$(find "$SANDBOX/p/Contents/MacOS" -name '.EOSWebcamUtility.eoswc-patching-*')" ] || fail "setup: expected a leftover temp file"
    PATCHER_UNDER_TEST "$SANDBOX/p/Contents" > "$OUT" 2>&1 || fail "second run failed"
    assert_contains "$OUT" "removed a temp file left by an interrupted run"
    [ -z "$(find "$SANDBOX/p/Contents/MacOS" -name '*.eoswc-patching-*')" ] || fail "leftover temp file not removed"
    check --check-patched "$SANDBOX/p/Contents"; assert_status "$RC" 0
}

test_patching_keeps_the_mode_and_replaces_the_file_atomically() {
    /usr/bin/python3 "$FIXTURES/make-canon-plugin.py" "$SANDBOX/p"
    local f="$SANDBOX/p/Contents/Resources/EWCProxy" before after
    chmod 751 "$f"
    before="$(stat -f '%i %u %g' "$f")"
    PATCHER_UNDER_TEST "$SANDBOX/p/Contents" > "$OUT" 2>&1 || fail "patcher failed"
    after="$(stat -f '%i %u %g' "$f")"
    [ "$(stat -f %Lp "$f")" = 751 ] || fail "mode not kept: $(stat -f %Lp "$f")"
    [ "${before#* }" = "${after#* }" ] || fail "owner changed: $before -> $after"
    # A new inode: renamed into place, not rewritten in place.
    [ "${before%% *}" != "${after%% *}" ] || fail "file was rewritten in place"
    # No open('wb') on a binary anywhere in the patcher.
    ! grep -nE "(^|[^a-z_.])open\([^)]*['\"]wb['\"]" "$CLONE/dist/v1.4/patch-binaries.py" || fail "patcher still writes a binary in place"
}

run_tests
