#!/usr/bin/env python3
"""Lay down a FAKE EOSWebcamUtility.plugin for the test suite.

The three binaries are filler bytes plus exactly the bytes the real
patch-binaries.py checks for, so the real patcher runs against them. Nothing
here is Canon code.

usage: make-canon-plugin.py PLUGIN_DIR [--patched] [--corrupt]
  --patched  write the fork's patched bytes instead of the originals
  --corrupt  put unexpected bytes in EOSWebcamService (patcher must abort)
"""
import importlib.util
import os
import sys

sys.dont_write_bytecode = True  # importing the patcher must not litter dist/ with __pycache__

HERE = os.path.dirname(os.path.abspath(__file__))
PATCHER = os.path.join(HERE, "..", "..", "dist", "v1.4", "patch-binaries.py")


def load_patches():
    spec = importlib.util.spec_from_file_location("patcher", PATCHER)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.PATCHES


def build(rel, patches, patched):
    size = max(off + len(bytes.fromhex(o)) for off, o, _ in patches) + 64
    tag = ("FAKE:" + rel + ":").encode()
    data = bytearray((tag * (size // len(tag) + 1))[:size])
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
    contents = os.path.join(plugin, "Contents")
    for rel, patches in load_patches().items():
        data = build(rel, patches, patched)
        if corrupt and rel.endswith("EOSWebcamService"):
            off = patches[0][0]
            data[off:off + 2] = b"\xde\xad"
        path = os.path.join(contents, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(data)
    res = os.path.join(contents, "Resources")
    for name in ("EWCPairingService", "errorNoDevice.jpg", "errorBusy.jpg", "default.jpg"):
        with open(os.path.join(res, name), "wb") as f:
            f.write(("FAKE:" + name + "\n").encode())


if __name__ == "__main__":
    main()
