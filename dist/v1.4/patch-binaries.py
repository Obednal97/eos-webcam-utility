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
#   - anything else (wrong version / unexpected bytes) -> abort, change nothing
#
# Usage: patch-binaries.py <path to EOSWebcamUtility.plugin/Contents>
#        patch-binaries.py --check-original DIR
#        patch-binaries.py --check-patched DIR
#
# The --check modes change nothing. They exit 0 only if all three binaries in
# DIR are Canon's originals (or the fork's patched binaries). An original is
# recognised by its full-file SHA-256 (the files in Canon's v1.3.16 package),
# or, if it isn't byte-identical (e.g. re-signed), by holding the original
# bytes at every patch offset and being a complete arm64 Mach-O file (not
# truncated). DIR is either a plug-in's Contents dir or a flat backup dir
# holding the three binaries.
# install.sh and uninstall.sh use --check-original to decide whether a backup
# really holds Canon's originals.
#
# Patch offsets were derived by diffing Canon v1.3.16 (sha256
# 5ad0333bd6a1c66f88c70aac631e5133c5f3dd6fc579e45dd473d1e964c02321) against
# the patched build; applying them to a clean original and re-signing ad-hoc
# reproduces the patched binaries exactly. The offsets are annotated inline below.

import hashlib
import os
import struct
import sys

# rel path under Contents/ -> list of (offset, original_hex, patched_hex)
PATCHES = {
    "MacOS/EOSWebcamUtility": [
        (0x312d9, "a08052694200b9095a", "f08052694200b90987"),  # case 2 width/height 1280x720 -> 1920x1080
        (0x3130c, "c903", "8907"),                              # fps default 30 -> 60
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
        (0x43811, "03", "07"),                                  # default fps 30 -> 60
        (0x43849, "a0", "f0"),                                  # default width
        (0x43855, "5a", "87"),                                  # default height
        (0x43889, "a0", "f0"),                                  # alt-path width
        (0x43895, "5a", "87"),                                  # alt-path height
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


def patch_state(data, patches):
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


def binary_path(root, rel):
    """rel inside a plug-in Contents dir, or its bare name in a flat backup dir."""
    if os.path.isdir(os.path.join(root, "MacOS")) and os.path.isdir(os.path.join(root, "Resources")):
        return os.path.join(root, rel)
    return os.path.join(root, os.path.basename(rel))


def check_dir(root, want):
    """Exit 0 if all three binaries under root are complete and in state want."""
    label = {"orig": "Canon's original", "patched": "the fork's patched"}[want]
    problems = []
    how = []
    for rel, patches in PATCHES.items():
        path = binary_path(root, rel)
        name = os.path.basename(rel)
        if os.path.islink(path) or not os.path.isfile(path):
            problems.append("%s: missing (or not a regular file)" % name)
            continue
        try:
            with open(path, "rb") as f:
                data = f.read()
        except OSError as e:
            problems.append("%s: cannot read (%s)" % (name, e.strerror))
            continue
        if want == "orig" and (hashlib.sha256(data).hexdigest(), len(data)) == CANON_SHA256.get(rel):
            how.append("%s: identical to Canon's v1.3.16 package (SHA-256)" % name)
            continue
        bad = macho_problem(data)
        state = patch_state(data, patches)
        if not bad and state == want:
            how.append("%s: %s bytes at every patch offset, complete Mach-O" % (name, label))
        if bad:
            problems.append("%s: %s" % (name, bad))
        elif state != want:
            problems.append("%s: %s" % (name, "holds the fork's patched bytes" if state == "patched"
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


def check_file(path, patches):
    """Return (state, data): state is 'orig' or 'patched'; exit on unexpected bytes."""
    data = bytearray(open(path, "rb").read())
    state = None
    for off, orig_hex, patched_hex in patches:
        orig = bytes.fromhex(orig_hex)
        patched = bytes.fromhex(patched_hex)
        cur = bytes(data[off:off + len(orig)])
        if cur == orig:
            s = "orig"
        elif cur == patched:
            s = "patched"
        else:
            sys.exit(
                "ERROR: %s @ 0x%x holds unexpected bytes %s\n"
                "       (expected original %s or patched %s).\n"
                "       This is not the supported Canon v1.3.16 build — aborting, nothing changed."
                % (os.path.basename(path), off, cur.hex(), orig_hex, patched_hex)
            )
        if state is None:
            state = s
        elif state != s:
            sys.exit("ERROR: %s is in a mixed patch state — aborting." % os.path.basename(path))
    return state, data


def write_patched(path, patches, data):
    for off, _orig_hex, patched_hex in patches:
        patched = bytes.fromhex(patched_hex)
        data[off:off + len(patched)] = patched
    open(path, "wb").write(bytes(data))


USAGE = ("usage: patch-binaries.py <path to EOSWebcamUtility.plugin/Contents>\n"
         "       patch-binaries.py --check-original DIR | --check-patched DIR")


def main():
    args = sys.argv[1:]
    if len(args) == 2 and args[0] in ("--check-original", "--check-patched"):
        check_dir(args[1], "orig" if args[0] == "--check-original" else "patched")
        return
    if len(args) != 1 or args[0].startswith("-"):
        sys.exit(USAGE)
    contents = args[0]
    # Verify every binary before writing any, so an abort really changes nothing.
    checked = []
    for rel, patches in PATCHES.items():
        path = os.path.join(contents, rel)
        if not os.path.exists(path):
            sys.exit("ERROR: expected binary not found: %s" % path)
        state, data = check_file(path, patches)
        checked.append((rel, path, patches, state, data))
    any_patched = False
    for rel, path, patches, state, data in checked:
        if state == "orig":
            write_patched(path, patches, data)
            any_patched = True
            print("  patched:         %s" % rel)
        else:
            print("  already patched: %s" % rel)
    print("  done — %s" % ("changes applied" if any_patched else "nothing to do (already patched)"))


if __name__ == "__main__":
    main()
