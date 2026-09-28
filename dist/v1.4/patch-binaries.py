#!/usr/bin/env python3
#
# EOS Webcam Utility Fork — binary patcher
#
# Applies the fork's resolution / feature patches to Canon's ORIGINAL
# EOS Webcam Utility v1.3.16 binaries, in place. This ships only the byte
# offsets of the fork's own changes — never Canon's binaries. The originals
# come from the user's machine (an existing install or Canon's own package).
#
# The patcher is self-verifying and idempotent:
#   - if a binary holds the original bytes  -> it is patched
#   - if a binary already holds the patched bytes -> it is left unchanged
#   - if it holds an older fork version's patched bytes -> it is brought up
#     to date (see REVERTS)
#   - anything else (wrong version / unexpected bytes) -> abort, change nothing
#
# Each binary is written atomically: the new bytes go to a temp file in the
# same directory, which is fsynced and then renamed over the binary with the
# binary's mode and owner, so a crash or a full disk leaves either the old
# file or the new one, never a half-written one.
#
# Usage: patch-binaries.py <path to EOSWebcamUtility.plugin/Contents>
#        patch-binaries.py --check-original DIR
#        patch-binaries.py --check-patched DIR
#        patch-binaries.py --check-fork DIR
#        patch-binaries.py --same-code DIR_A DIR_B
#
# The --check modes change nothing. They exit 0 only if all three binaries in
# DIR are Canon's originals (--check-original), this version's patched
# binaries (--check-patched), or the patched binaries of this or an earlier
# fork version (--check-fork). An original is recognised by its full-file
# SHA-256 (the files in Canon's v1.3.16 package), or, if it isn't
# byte-identical (e.g. re-signed), by holding the original bytes at every
# patch offset and being a complete arm64 Mach-O file (not truncated). DIR is
# either a plug-in's Contents dir or a flat backup dir holding the three
# binaries.
# install.sh and uninstall.sh use --check-original to decide whether a backup
# really holds Canon's originals.
#
# --same-code exits 0 if the three binaries in DIR_A and DIR_B are the same
# code: byte-identical once their code signatures are left out. install.sh
# uses it to recognise a backup of what is installed even when one side was
# re-signed (older uninstallers re-signed Canon's originals ad hoc).
#
# Patch offsets were derived by diffing Canon v1.3.16 (sha256
# 5ad0333bd6a1c66f88c70aac631e5133c5f3dd6fc579e45dd473d1e964c02321) against
# the patched build; applying them to a clean original and re-signing ad-hoc
# reproduces the patched binaries exactly. The offsets are annotated inline below.

import hashlib
import os
import stat
import struct
import sys
import tempfile

# rel path under Contents/ -> list of (offset, original_hex, patched_hex)
PATCHES = {
    "MacOS/EOSWebcamUtility": [
        (0x312d9, "a08052694200b9095a", "f08052694200b90987"),  # case 2 width/height 1280x720 -> 1920x1080
        (0x13bcb0, "00050000d002", "800700003804"),             # fallback default 1280x720 -> 1920x1080
    ],
    "Resources/EOSWebcamService": [
        (0x62ad, "a08052694200b9095a", "f08052694200b90987"),   # case 2 width/height
        (0x89b58, "00c14339", "20008052"),                      # isPro getter -> always true
        (0x89bfd, "a0", "f0"),                                  # SetIsPro clamp width
        (0x89c09, "5a", "87"),                                  # SetIsPro clamp height
        (0xd8ae5, "a080521c5a", "f080521c87"),                  # CMVideoFormat width/height
        (0xd8af9, "a08052040080d2035a", "f08052040080d20387"),  # CMVideoFormat arg width/height
    ],
    "Resources/EWCProxy": [
        (0x434e1, "5a805209a0", "87805209f0"),                  # case 2 width/height
        (0x43849, "a0", "f0"),                                  # default width
        (0x43855, "5a", "87"),                                  # default height
        (0x43889, "a0", "f0"),                                  # alt-path width
        (0x43895, "5a", "87"),                                  # alt-path height
    ],
}

# Offsets that fork v1.4.1 and v1.4.2 patched and this version puts back to
# Canon's bytes: (offset, canon_hex, old_fork_hex). Canon's pipeline has
# exactly two stream frame rates, 30 and 60 (the service's StreamFps enum
# FPS_30/FPS_60; the setters in the service and EWCProxy accept 30 or 60 and
# nothing else). The frame rate apps are told comes from the DAL plug-in,
# which asks the service for its StreamFps setting. The fps now follows
# config.plist's StreamFps (30), which is what the camera really delivers
# over USB. See work-log/006 (addendum) for the disassembly.
REVERTS = {
    "MacOS/EOSWebcamUtility": [
        # StreamClient::GetGlobalStreamSettings maps the service's StreamFps
        # to the fps the plug-in advertises (FrameRate, FrameRateRanges,
        # MinimumFrameRate) and paces its frame timer at:
        #   mov w9,#30; mov w10,#60; cmp w8,#2; csel w10,w10,w9,eq
        #   cmp w8,#1; csel w8,w9,w10,eq     (1 = FPS_30 -> 30, 2 = FPS_60 -> 60)
        # The old patch (mov w9,#30 -> mov w9,#60) made that 60 for every
        # setting, while the camera sends ~26-30 frames a second.
        (0x3130c, "c90380528a0780521f0900714a01891a1f05007128018a1a",
                  "890780528a0780521f0900714a01891a1f05007128018a1a"),
    ],
    "Resources/EWCProxy": [
        # mov w8,#30 in EWCProxy's "Pro turned off" reset. The old patch made
        # it mov w8,#62 (not 60, and a value EWCProxy's own fps setter
        # rejects), in a function nothing in EWCProxy calls.
        (0x43810, "c8038052", "c8078052"),
    ],
}


# SHA-256 and size of each binary as shipped in Canon's v1.3.16 package
# (EOSWebcamUtility-MAC1.3.16.pkg.zip, sha256 5ad0333b...02321 above).
CANON_SHA256 = {
    "MacOS/EOSWebcamUtility": ("d84007ad254f54ce86c2d07a6a4827ff88e314dd7cdeb258264b341547ba4c04", 2039328),
    "Resources/EOSWebcamService": ("0f18655f1c3733d3dddb5ddf0e0708c1811eb3a51a166a07497f82695a9f4a36", 5698384),
    "Resources/EWCProxy": ("12d2b00a0b15e766d3a8cca85858cf2a38210e41e0cc65015deced56bc8ad28a", 1791920),
}

MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_ARM64 = 0x0100000C
LC_SEGMENT_64 = 0x19
LC_CODE_SIGNATURE = 0x1D

# Temp files the atomic write leaves behind only if the process is killed
# between creating and renaming one: ".<name>.eoswc-patching-XXXXXXXX".
TMP_TAG = ".eoswc-patching-"


def macho_problem(data):
    """Return why data is not a complete thin arm64 Mach-O, or None if it is.

    "Complete" means the file is at least as long as every segment and the
    code signature its load commands declare, so a truncated copy fails even
    if the cut falls after the last patch offset.
    """
    if len(data) < 32:
        return "too short to be a Mach-O file (%d bytes)" % len(data)
    magic, cputype, _sub, _ftype, ncmds, sizeofcmds = struct.unpack_from("<6I", data, 0)
    if magic != MH_MAGIC_64 or cputype != CPU_TYPE_ARM64:
        return "not a thin arm64 Mach-O file"
    if 32 + sizeofcmds > len(data):
        return "truncated (load commands run past the end of the file)"
    end, off = 32 + sizeofcmds, 32
    for _ in range(ncmds):
        if off + 8 > 32 + sizeofcmds:
            return "malformed load commands"
        cmd, cmdsize = struct.unpack_from("<2I", data, off)
        if cmdsize < 8 or off + cmdsize > 32 + sizeofcmds:
            return "malformed load commands"
        if cmd == LC_SEGMENT_64 and cmdsize >= 64:
            fileoff, filesize = struct.unpack_from("<2Q", data, off + 40)
            end = max(end, fileoff + filesize)
        elif cmd == LC_CODE_SIGNATURE and cmdsize >= 16:
            dataoff, datasize = struct.unpack_from("<2I", data, off + 8)
            end = max(end, dataoff + datasize)
        off += cmdsize
    if len(data) < end:
        return "truncated (%d bytes, the Mach-O header declares %d)" % (len(data), end)
    return None


def code_bytes(data):
    """The file without its code signature, or None if it isn't a complete Mach-O.

    Re-signing rewrites the signature blob at the end of __LINKEDIT and, with
    it, the blob's size in LC_CODE_SIGNATURE and __LINKEDIT's size; nothing
    else. Those fields are zeroed and the blob is left out, so two copies of
    the same code compare equal whoever signed them. Anything after the blob
    (a real binary has nothing there) still counts.
    """
    if macho_problem(data):
        return None
    d = bytearray(data)
    ncmds = struct.unpack_from("<I", d, 16)[0]
    off, sig_at, sig_end = 32, len(d), len(d)
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<2I", d, off)
        if cmd == LC_SEGMENT_64 and cmdsize >= 72 and bytes(d[off + 8:off + 24]).rstrip(b"\0") == b"__LINKEDIT":
            struct.pack_into("<Q", d, off + 32, 0)   # vmsize
            struct.pack_into("<Q", d, off + 48, 0)   # filesize
        elif cmd == LC_CODE_SIGNATURE and cmdsize >= 16:
            sig_at, size = struct.unpack_from("<2I", d, off + 8)
            sig_end = sig_at + size
            struct.pack_into("<I", d, off + 12, 0)   # datasize
        off += cmdsize
    return bytes(d[:sig_at]) + b"\0after-signature\0" + bytes(d[sig_end:])


def offsets_state(data, patches):
    """'orig' or 'patched' if every offset agrees; otherwise a description."""
    states = set()
    for off, orig_hex, patched_hex in patches:
        cur = bytes(data[off:off + len(bytes.fromhex(orig_hex))])
        if cur == bytes.fromhex(orig_hex):
            states.add("orig")
        elif cur == bytes.fromhex(patched_hex):
            states.add("patched")
        else:
            return "unexpected bytes %s @ 0x%x (not Canon v1.3.16)" % (cur.hex() or "(none)", off)
    if len(states) != 1:
        return "a mix of original and patched bytes"
    return states.pop()


def binary_state(data, rel):
    """'orig', 'patched' (this version) or 'patched-old' (an earlier fork
    version, which still has REVERTS bytes to put back); otherwise a
    description of what is wrong."""
    state = offsets_state(data, PATCHES[rel])
    if state not in ("orig", "patched"):
        return state
    old = False
    for off, canon_hex, old_hex in REVERTS.get(rel, []):
        cur = bytes(data[off:off + len(bytes.fromhex(canon_hex))])
        if cur == bytes.fromhex(old_hex):
            old = True
        elif cur != bytes.fromhex(canon_hex):
            return "unexpected bytes %s @ 0x%x (not Canon v1.3.16)" % (cur.hex() or "(none)", off)
    if state == "orig":
        return "a mix of original and patched bytes" if old else "orig"
    return "patched-old" if old else "patched"


def binary_path(root, rel):
    """rel inside a plug-in Contents dir, or its bare name in a flat backup dir."""
    if os.path.isdir(os.path.join(root, "MacOS")) and os.path.isdir(os.path.join(root, "Resources")):
        return os.path.join(root, rel)
    return os.path.join(root, os.path.basename(rel))


def read_binary(root, rel):
    """(data, None), or (None, why it can't be read)."""
    path = binary_path(root, rel)
    if os.path.islink(path) or not os.path.isfile(path):
        return None, "missing (or not a regular file)"
    try:
        with open(path, "rb") as f:
            return f.read(), None
    except OSError as e:
        return None, "cannot read (%s)" % e.strerror


CHECK_WANT = {
    "orig": ("Canon's original", ("orig",)),
    "patched": ("the fork's patched", ("patched",)),
    "fork": ("the fork's patched (this or an earlier version)", ("patched", "patched-old")),
}


def check_dir(root, want):
    """Exit 0 if all three binaries under root are complete and in state want."""
    label, accepted = CHECK_WANT[want]
    problems = []
    how = []
    for rel in PATCHES:
        name = os.path.basename(rel)
        data, why = read_binary(root, rel)
        if data is None:
            problems.append("%s: %s" % (name, why))
            continue
        if want == "orig" and (hashlib.sha256(data).hexdigest(), len(data)) == CANON_SHA256.get(rel):
            how.append("%s: identical to Canon's v1.3.16 package (SHA-256)" % name)
            continue
        bad = macho_problem(data)
        state = binary_state(data, rel)
        if not bad and state in accepted:
            how.append("%s: %s bytes at every patch offset, complete Mach-O"
                       % (name, "an earlier fork version's patched" if state == "patched-old" else label))
        if bad:
            problems.append("%s: %s" % (name, bad))
        elif state not in accepted:
            problems.append("%s: %s" % (name, "holds the fork's patched bytes" if state == "patched"
                                               else "holds an earlier fork version's patched bytes" if state == "patched-old"
                                               else "holds Canon's original bytes" if state == "orig"
                                               else state))
    if problems:
        print("  %s does not hold %s binaries:" % (root, label), file=sys.stderr)
        for p in problems:
            print("    - " + p, file=sys.stderr)
        sys.exit(1)
    print("  verified: %s holds %s binaries" % (root, label))
    for h in how:
        print("    - " + h)


def same_code(root_a, root_b):
    """Exit 0 if the three binaries are the same code in both dirs."""
    problems = []
    how = []
    for rel in PATCHES:
        name = os.path.basename(rel)
        a, why_a = read_binary(root_a, rel)
        b, why_b = read_binary(root_b, rel)
        if a is None or b is None:
            problems.append("%s: %s" % (name, why_a or why_b))
        elif a == b:
            how.append("%s: byte-identical" % name)
        else:
            ca, cb = code_bytes(a), code_bytes(b)
            if ca is None or cb is None:
                problems.append("%s: not a complete arm64 Mach-O file" % name)
            elif ca == cb:
                how.append("%s: the same code, signed differently" % name)
            else:
                problems.append("%s: different code" % name)
    if problems:
        print("  %s and %s do not hold the same binaries:" % (root_a, root_b), file=sys.stderr)
        for p in problems:
            print("    - " + p, file=sys.stderr)
        sys.exit(1)
    print("  same code: %s and %s" % (root_a, root_b))
    for h in how:
        print("    - " + h)


def check_file(path, rel):
    """Return (state, data): state is 'orig', 'patched' or 'patched-old'; exit otherwise."""
    with open(path, "rb") as f:
        data = bytearray(f.read())
    state = binary_state(data, rel)
    if state not in ("orig", "patched", "patched-old"):
        sys.exit(
            "ERROR: %s: %s.\n"
            "       This is not the supported Canon v1.3.16 build (or the fork's patched\n"
            "       binaries) — aborting, nothing changed." % (os.path.basename(path), state)
        )
    return state, data


def remove_stale_temps(path):
    """Delete temp files an earlier, killed run left next to path."""
    d, name = os.path.split(path)
    prefix = "." + name + TMP_TAG
    for entry in os.listdir(d or "."):
        p = os.path.join(d, entry)
        if entry.startswith(prefix) and os.path.isfile(p) and not os.path.islink(p):
            os.unlink(p)
            print("  removed a temp file left by an interrupted run: %s" % p)


def atomic_write(path, data):
    """Replace path's content with data, keeping its mode and owner.

    The bytes go to a temp file in the same directory (same volume, so the
    rename is atomic), which is fsynced, given path's mode and owner, and
    renamed over path. On any error the temp file is removed and path is
    left exactly as it was.
    """
    st = os.stat(path)
    d, name = os.path.split(path)
    fd, tmp = tempfile.mkstemp(prefix="." + name + TMP_TAG, dir=d or ".")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, stat.S_IMODE(st.st_mode))
        if (os.stat(tmp).st_uid, os.stat(tmp).st_gid) != (st.st_uid, st.st_gid):
            os.chown(tmp, st.st_uid, st.st_gid)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    try:
        dfd = os.open(d or ".", os.O_RDONLY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)
    except OSError:
        pass


def write_patched(path, rel, data):
    for off, _orig_hex, patched_hex in PATCHES[rel]:
        patched = bytes.fromhex(patched_hex)
        data[off:off + len(patched)] = patched
    for off, canon_hex, _old_hex in REVERTS.get(rel, []):
        canon = bytes.fromhex(canon_hex)
        data[off:off + len(canon)] = canon
    atomic_write(path, bytes(data))


USAGE = ("usage: patch-binaries.py <path to EOSWebcamUtility.plugin/Contents>\n"
         "       patch-binaries.py --check-original DIR | --check-patched DIR | --check-fork DIR\n"
         "       patch-binaries.py --same-code DIR_A DIR_B")

CHECK_MODES = {"--check-original": "orig", "--check-patched": "patched", "--check-fork": "fork"}


def main():
    args = sys.argv[1:]
    if len(args) == 2 and args[0] in CHECK_MODES:
        check_dir(args[1], CHECK_MODES[args[0]])
        return
    if len(args) == 3 and args[0] == "--same-code":
        same_code(args[1], args[2])
        return
    if len(args) != 1 or args[0].startswith("-"):
        sys.exit(USAGE)
    contents = args[0]
    # Verify every binary before writing any, so an abort really changes nothing.
    checked = []
    for rel in PATCHES:
        path = os.path.join(contents, rel)
        if not os.path.exists(path):
            sys.exit("ERROR: expected binary not found: %s" % path)
        state, data = check_file(path, rel)
        checked.append((rel, path, state, data))
    any_patched = False
    for rel, path, state, data in checked:
        remove_stale_temps(path)
        if state == "patched":
            print("  already patched: %s" % rel)
            continue
        write_patched(path, rel, data)
        any_patched = True
        if state == "orig":
            print("  patched:         %s" % rel)
        else:
            print("  updated:         %s (from an earlier fork version)" % rel)
    print("  done — %s" % ("changes applied" if any_patched else "nothing to do (already patched)"))


if __name__ == "__main__":
    main()
