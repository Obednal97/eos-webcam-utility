#!/usr/bin/env python3
"""Lay down a FAKE EOSWebcamUtility.plugin for the test suite.

The three binaries are a minimal arm64 Mach-O header (one segment covering
the whole file, so patch-binaries.py's truncation check passes), filler bytes,
and exactly the bytes the real patcher checks for, so the real patcher runs
against them. Nothing here is Canon code.

usage: make-canon-plugin.py PLUGIN_DIR [--patched] [--corrupt] [--truncated]
                             [--version V] [--no-info-plist]
  --patched        write the fork's patched bytes instead of the originals
  --corrupt        put unexpected bytes in EOSWebcamService (patcher must abort)
  --truncated      cut 16 bytes off the end of EWCProxy (after its last patch
                   offset, so only the Mach-O completeness check notices)
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


def load_patches():
    spec = importlib.util.spec_from_file_location("patcher", PATCHER)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.PATCHES


def build(rel, patches, patched):
    size = max(off + len(bytes.fromhex(o)) for off, o, _ in patches) + 64
    tag = ("FAKE:" + rel + ":").encode()
    data = bytearray((tag * (size // len(tag) + 1))[:size])
    # mach_header_64 (arm64, MH_EXECUTE, 1 load command) + one LC_SEGMENT_64
    # spanning the file.
    header = struct.pack("<8I", 0xFEEDFACF, 0x0100000C, 0, 2, 1, 72, 0, 0)
    segment = struct.pack("<2I16s4Q4I", 0x19, 72, b"__TEXT", 0, size, 0, size, 5, 5, 0, 0)
    data[0:len(header) + len(segment)] = header + segment
    for off, orig, new in patches:
        b = bytes.fromhex(new if patched else orig)
        data[off:off + len(b)] = b
    return data


def main():
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)
    plugin = args[0]
    patched = "--patched" in args
    corrupt = "--corrupt" in args
    truncated = "--truncated" in args
    version = "1.3.16.0"
    if "--version" in args:
        version = args[args.index("--version") + 1]
    contents = os.path.join(plugin, "Contents")
    for rel, patches in load_patches().items():
        data = build(rel, patches, patched)
        if corrupt and rel.endswith("EOSWebcamService"):
            off = patches[0][0]
            data[off:off + 2] = b"\xde\xad"
        if truncated and rel.endswith("EWCProxy"):
            data = data[:-16]
        path = os.path.join(contents, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(data)
    if "--no-info-plist" not in args:
        with open(os.path.join(contents, "Info.plist"), "w") as f:
            f.write(INFO_PLIST % version)
    res = os.path.join(contents, "Resources")
    for name in ("EWCPairingService", "errorNoDevice.jpg", "errorBusy.jpg", "default.jpg"):
        with open(os.path.join(res, name), "wb") as f:
            f.write(("FAKE:" + name + "\n").encode())


if __name__ == "__main__":
    main()
