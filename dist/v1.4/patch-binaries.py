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
#
# Patch offsets were derived by diffing Canon v1.3.16 (sha256
# 5ad0333bd6a1c66f88c70aac631e5133c5f3dd6fc579e45dd473d1e964c02321) against
# the patched build; applying them to a clean original and re-signing ad-hoc
# reproduces the patched binaries exactly. See PLAN.md for the annotated table.

import os
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


def patch_file(path, patches):
    """Return 'patched', 'already', or exit on unexpected bytes."""
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

    if state == "patched":
        return "already"

    for off, _orig_hex, patched_hex in patches:
        patched = bytes.fromhex(patched_hex)
        data[off:off + len(patched)] = patched
    open(path, "wb").write(bytes(data))
    return "patched"


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: patch-binaries.py <path to EOSWebcamUtility.plugin/Contents>")
    contents = sys.argv[1]
    any_patched = False
    for rel, patches in PATCHES.items():
        path = os.path.join(contents, rel)
        if not os.path.exists(path):
            sys.exit("ERROR: expected binary not found: %s" % path)
        result = patch_file(path, patches)
        if result == "patched":
            any_patched = True
            print("  patched:         %s" % rel)
        else:
            print("  already patched: %s" % rel)
    print("  done — %s" % ("changes applied" if any_patched else "nothing to do (already patched)"))


if __name__ == "__main__":
    main()
