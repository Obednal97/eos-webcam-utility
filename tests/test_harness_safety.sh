#!/bin/bash
# Self-test for the harness's delete guard and mktemp handling. Proves that
# safe_rm_sandbox refuses anything it shouldn't delete, never reaching rm,
# and that a mktemp failure aborts the run without deleting anything.
. "$(dirname "$0")/helpers.sh"

PASS=0
FAILED=0
ok()  { echo "ok   - $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL - $1"; FAILED=$((FAILED + 1)); }

# rm/chmod stand-ins that record and refuse, so a guard bug can't delete.
make_sandbox; WORK="$SANDBOX"
GUARD="$WORK/guard-bin"; GUARD_LOG="$WORK/guard.log"
mkdir -p "$GUARD"; : > "$GUARD_LOG"
for c in rm chmod; do
    printf '#!/bin/bash\necho "%s $*" >> "%s"\nexit 97\n' "$c" "$GUARD_LOG" > "$GUARD/$c"
    /bin/chmod +x "$GUARD/$c"
done

# expect_refusal NAME PATH [prep]: safe_rm_sandbox must fail, without calling rm.
expect_refusal() {
    local name="$1" target="$2" prep="${3:-true}" out status existed=0
    [ -n "$target" ] && [ -e "$target" ] && existed=1
    : > "$GUARD_LOG"
    set +e
    out="$( (PATH="$GUARD:$PATH"; eval "$prep"; safe_rm_sandbox "$target") 2>&1 )"
    status=$?
    set -e
    if [ "$status" != 0 ] && [ ! -s "$GUARD_LOG" ] && { [ "$existed" = 0 ] || [ -e "$target" ]; }; then
        ok "refuses $name ($(echo "$out" | tail -1 | sed 's/^HARNESS ABORT: //'))"
    else
        bad "refuses $name (status $status, rm/chmod calls: $(cat "$GUARD_LOG"))"
    fi
}

expect_refusal "an empty path" ""
expect_refusal "/" "/"
expect_refusal "the real HOME" "$REAL_HOME"
expect_refusal "the repo / worktree" "$REPO_DIR"
[ -n "$MAIN_CLONE" ] && expect_refusal "the main clone" "$(cd "$MAIN_CLONE/.." && pwd -P)"
expect_refusal "the real temp root" "$REAL_TMPDIR"
expect_refusal "a missing path" "$WORK/does-not-exist"

make_sandbox; UNLISTED="$SANDBOX"
expect_refusal "a sandbox this run did not register" "$UNLISTED" "CREATED_SANDBOXES=()"

make_sandbox; NOMARK="$SANDBOX"; /bin/rm -f "$NOMARK/$SANDBOX_MARKER"; echo x > "$NOMARK/file"
expect_refusal "a sandbox without its marker" "$NOMARK"
printf '%s\n' "$NOMARK" > "$NOMARK/$SANDBOX_MARKER"   # restore for cleanup

make_sandbox; WRONG="$SANDBOX"; echo /somewhere/else > "$WRONG/$SANDBOX_MARKER"
expect_refusal "a sandbox with a wrong marker" "$WRONG"
printf '%s\n' "$WRONG" > "$WRONG/$SANDBOX_MARKER"

make_sandbox; OUTSIDE_LINK="$SANDBOX"
ln -s "$REAL_HOME" "$OUTSIDE_LINK/home-link"
expect_refusal "a symlink to HOME inside a sandbox" "$OUTSIDE_LINK/home-link"

# A real sandbox is deleted.
make_sandbox; GOOD="$SANDBOX"; mkdir -p "$GOOD/a/b"; echo x > "$GOOD/a/b/c"
chmod 000 "$GOOD/a"
if (safe_rm_sandbox "$GOOD") && [ ! -e "$GOOD" ]; then
    ok "deletes a sandbox it created (even with an unreadable subdir)"
else
    bad "deletes a sandbox it created"
fi

# mktemp failure: point the run at an unwritable temp root, from inside a
# canary dir, and check it aborts and nothing is deleted or created.
make_sandbox; CANARY_BOX="$SANDBOX"
RO="$CANARY_BOX/readonly-tmp"; CANARY="$CANARY_BOX/canary"
mkdir -p "$RO" "$CANARY/sub"; echo keep > "$CANARY/keep.txt"; echo keep > "$CANARY/sub/keep.txt"
/bin/chmod 500 "$RO"
BEFORE="$(cd "$CANARY" && find . | sort | shasum)"
set +e
MT_OUT="$(cd "$CANARY" && TMPDIR="$RO" /bin/bash "$TESTS_DIR/test_install.sh" 2>&1)"
MT_STATUS=$?
set -e
AFTER="$(cd "$CANARY" && find . | sort | shasum)"
if [ "$MT_STATUS" = 3 ] && echo "$MT_OUT" | grep -q "HARNESS ABORT: mktemp failed" \
   && [ "$BEFORE" = "$AFTER" ] && [ -z "$(ls -A "$RO")" ] \
   && ! echo "$MT_OUT" | grep -q '^ok '; then
    ok "mktemp failure aborts the run (status 3) and deletes nothing"
else
    bad "mktemp failure aborts the run (status $MT_STATUS): $MT_OUT"
fi

set +e
NX_OUT="$(TMPDIR="$WORK/no-such-dir" /bin/bash "$TESTS_DIR/test_install.sh" 2>&1)"
NX_STATUS=$?
set -e
if [ "$NX_STATUS" = 3 ] && echo "$NX_OUT" | grep -q "HARNESS ABORT: cannot resolve TMPDIR"; then
    ok "a missing TMPDIR aborts the run (status 3)"
else
    bad "a missing TMPDIR aborts the run (status $NX_STATUS): $NX_OUT"
fi

for d in "$UNLISTED" "$NOMARK" "$WRONG" "$OUTSIDE_LINK" "$CANARY_BOX" "$WORK"; do
    safe_rm_sandbox "$d"
done
[ -e "$REAL_HOME" ] && [ -d "$REPO_DIR/.." ] && [ -f "$REPO_DIR/tests/helpers.sh" ] \
    && ok "HOME and the repo are still there" || bad "HOME or the repo is missing"

echo "$PASS passed, $FAILED failed"
[ "$FAILED" = 0 ]
