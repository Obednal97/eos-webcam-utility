#!/usr/bin/env python3
"""Lay down a FAKE EOSWebcamUtility.plugin for the test suite.

The three binaries are a minimal arm64 Mach-O header (one segment covering
the whole file, so patch-binaries.py's truncation check passes, and an
LC_CODE_SIGNATURE pointing at a signature area at the end), filler bytes, and
exactly the bytes the real patcher checks for, so the real patcher runs
against them. The bundle is "signed" with fakesig.py's fake signatures (see
there), which tests/stubs/codesign understands. Nothing here is Canon code.

usage: make-canon-plugin.py PLUGIN_DIR [--patched | --old-patched] [--sig S]
                             [--corrupt] [--truncated] [--version V]
                             [--no-info-plist]
  --patched        write this version's patched bytes, signed the way this
                   version's install.sh signs them
  --old-patched    write an earlier fork version's patched bytes (v1.4.1 and
                   v1.4.2: the fps bytes in REVERTS still patched), signed the
                   way those versions did (ad hoc, no runtime, no entitlements)
  --sig S          canon | fork | old-fork | none: sign that way instead
                   (default: canon for originals, fork for --patched,
                   old-fork for --old-patched)
  --corrupt        put unexpected bytes in EOSWebcamService (patcher must
                   abort); done after signing, so its signature breaks too
  --truncated      cut 16 bytes off the end of EWCProxy (its signature area,
                   after its last patch offset, so only the Mach-O
                   completeness check notices)
  --version V      CFBundleShortVersionString in Contents/Info.plist
                   (default 1.3.16.0, what Canon's v1.3.16 package ships)
  --no-info-plist  write no Contents/Info.plist
"""
import importlib.util
import os
import struct
import sys

sys.dont_write_bytecode = True  # importing the patcher must not litter dist/ with __pycache__

HERE = os.path.dirname(os.path.abspath(__file__))
PATCHER = os.path.join(HERE, "..", "..", "dist", "v1.4", "patch-binaries.py")
sys.path.insert(0, HERE)
import fakesig  # noqa: E402

INFO_PLIST = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>EOSWebcamUtility</string>
	<key>CFBundleIdentifier</key><string>EOSWebcamUtility</string>
	<key>CFBundleShortVersionString</key><string>%s</string>
</dict>
</plist>
"""

# Identifiers Canon's signatures carry (EOSWebcamService signs as EWCService).
IDENT = {"MacOS/EOSWebcamUtility": "EOSWebcamUtility",
         "Resources/EOSWebcamService": "EWCService",
         "Resources/EWCProxy": "EWCProxy"}


def load_patcher():
    spec = importlib.util.spec_from_file_location("patcher", PATCHER)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def build(rel, patches, reverts, mode):
    offsets = [off + len(bytes.fromhex(o)) for off, o, _ in patches + reverts]
    size = max(offsets) + 64 + fakesig.SIG_SIZE
    tag = ("FAKE:" + rel + ":").encode()
    data = bytearray((tag * (size // len(tag) + 1))[:size])
    # mach_header_64 (arm64, MH_EXECUTE, 2 load commands), one LC_SEGMENT_64
    # spanning the file, and an LC_CODE_SIGNATURE for the last SIG_SIZE bytes.
    sizeofcmds = 72 + 16
    header = struct.pack("<8I", 0xFEEDFACF, 0x0100000C, 0, 2, 2, sizeofcmds, 0, 0)
    segment = struct.pack("<2I16s4Q4I", 0x19, 72, b"__TEXT", 0, size, 0, size, 5, 5, 0, 0)
    codesig = struct.pack("<4I", fakesig.LC_CODE_SIGNATURE, 16, size - fakesig.SIG_SIZE, fakesig.SIG_SIZE)
    data[0:32 + sizeofcmds] = header + segment + codesig
    data[size - fakesig.SIG_SIZE:] = b"\0" * fakesig.SIG_SIZE
    for off, orig, new in patches:
        b = bytes.fromhex(orig if mode == "orig" else new)
        data[off:off + len(b)] = b
    for off, canon, old in reverts:
        b = bytes.fromhex(old if mode == "old" else canon)
        data[off:off + len(b)] = b
    return data


def sign(plugin, how):
    """Sign the bundle's binaries the way `how` says."""
    if how == "none":
        return
    contents = os.path.join(plugin, "Contents")
    helpers = ("Resources/EOSWebcamService", "Resources/EWCProxy")
    for rel in helpers:
        path = os.path.join(contents, rel)
        if how == "canon":
            fakesig.sign_file(path, "canon", IDENT[rel], ["runtime"], [fakesig.CAMERA])
        elif how == "fork":
            fakesig.sign_file(path, "adhoc", IDENT[rel], ["runtime"], [fakesig.CAMERA, fakesig.DISABLE_LV])
        else:  # old-fork: codesign --force --sign - dropped the runtime and entitlements
            fakesig.sign_file(path, "adhoc", IDENT[rel] if rel.endswith("Service") else "EWCProxy-5555", [], [])
    fakesig.seal_bundle(plugin, "canon" if how == "canon" else "adhoc")


def main():
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)
    plugin = args[0]
    mode = "patched" if "--patched" in args else "old" if "--old-patched" in args else "orig"
    how = {"orig": "canon", "patched": "fork", "old": "old-fork"}[mode]
    if "--sig" in args:
        how = args[args.index("--sig") + 1]
    corrupt = "--corrupt" in args
    truncated = "--truncated" in args
    version = "1.3.16.0"
    if "--version" in args:
        version = args[args.index("--version") + 1]
    patcher = load_patcher()
    contents = os.path.join(plugin, "Contents")
    for rel, patches in patcher.PATCHES.items():
        data = build(rel, patches, patcher.REVERTS.get(rel, []), mode)
        path = os.path.join(contents, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(data)
    with_info = "--no-info-plist" not in args
    if with_info:
        with open(os.path.join(contents, "Info.plist"), "w") as f:
            f.write(INFO_PLIST % version)
    res = os.path.join(contents, "Resources")
    for name in ("EWCPairingService", "errorNoDevice.jpg", "errorBusy.jpg", "default.jpg"):
        with open(os.path.join(res, name), "wb") as f:
            f.write(("FAKE:" + name + "\n").encode())
    sign(plugin, how)
    for rel, patches in patcher.PATCHES.items():
        path = os.path.join(contents, rel)
        if corrupt and rel.endswith("EOSWebcamService"):
            with open(path, "r+b") as f:
                f.seek(patches[0][0])
                f.write(b"\xde\xad")
        if truncated and rel.endswith("EWCProxy"):
            os.truncate(path, os.path.getsize(path) - 16)


if __name__ == "__main__":
    main()
