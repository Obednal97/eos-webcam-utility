"""Fake code signatures for the test suite's FAKE Canon binaries.

The fixture binaries (make-canon-plugin.py) end in a fixed-size "signature
area" that their LC_CODE_SIGNATURE load command points at, the way a real
Mach-O's signature blob sits at the end of the file. Instead of a real
CodeDirectory it holds a small JSON record: who signed it (Canon, with
Canon's Team ID, or ad hoc), the identifier, the flags (runtime), the
entitlements, and a hash of the code before it. A bundle's
Contents/_CodeSignature/CodeResources lists a hash of every resource, and
the main executable's record holds a hash of CodeResources and Info.plist.

tests/stubs/codesign (via fake_codesign.py) signs, displays and verifies
these the way codesign does real ones, so the tests can check which
signature a file ends up with, that re-signing isn't needed after a
byte-identical restore, and that a patched file no longer verifies under
its old signature. Nothing here is Canon code or a real signature.
"""
import hashlib
import json
import os
import plistlib
import struct

SIG_SIZE = 256
LC_CODE_SIGNATURE = 0x1D
CANON_TEAM = "NC5A977249"
CANON_AUTHORITY = "Developer ID Application: Canon U.S.A., Inc. (NC5A977249)"
CAMERA = "com.apple.security.device.camera"
DISABLE_LV = "com.apple.security.cs.disable-library-validation"
MAIN_REL = "MacOS/EOSWebcamUtility"


class NotFake(Exception):
    pass


def _sha(b):
    return hashlib.sha256(b).hexdigest()[:16]


def sig_area(data):
    """(dataoff, datasize) of the file's LC_CODE_SIGNATURE, or raise NotFake."""
    if len(data) < 32 or struct.unpack_from("<I", data, 0)[0] != 0xFEEDFACF:
        raise NotFake("not a Mach-O file")
    ncmds = struct.unpack_from("<I", data, 16)[0]
    off = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<2I", data, off)
        if cmd == LC_CODE_SIGNATURE:
            dataoff, datasize = struct.unpack_from("<2I", data, off + 8)
            if dataoff + datasize > len(data):
                raise NotFake("truncated")
            return dataoff, datasize
        off += size
    raise NotFake("no LC_CODE_SIGNATURE")


def code_hash(data):
    dataoff, _ = sig_area(data)
    return _sha(bytes(data[:dataoff]))


def read_record(data):
    """The signature record, or None if the file is unsigned."""
    dataoff, datasize = sig_area(data)
    raw = bytes(data[dataoff:dataoff + datasize]).rstrip(b"\0")
    if not raw:
        return None
    try:
        return json.loads(raw.decode())
    except ValueError:
        return {"broken": True}


def write_record(data, record):
    """data (bytearray) with record written into its signature area."""
    dataoff, datasize = sig_area(data)
    raw = json.dumps(record, sort_keys=True, separators=(",", ":")).encode()
    if len(raw) > datasize:
        raise ValueError("signature record too long")
    data[dataoff:dataoff + datasize] = raw + b"\0" * (datasize - len(raw))
    return data


def record(data, signer, ident, flags=(), ents=(), seal=None, info=None):
    rec = {
        "signer": signer,
        "team": CANON_TEAM if signer == "canon" else None,
        "id": ident,
        "flags": sorted(flags),
        "ents": sorted(ents),
        "code": code_hash(data),
    }
    if seal is not None:
        rec["seal"] = seal
        rec["info"] = info
    return rec


# --- bundles -----------------------------------------------------------------

def bundle_contents(bundle):
    return os.path.join(bundle, "Contents")


def main_executable(bundle):
    info = os.path.join(bundle_contents(bundle), "Info.plist")
    name = "EOSWebcamUtility"
    try:
        with open(info, "rb") as f:
            name = plistlib.load(f).get("CFBundleExecutable", name)
    except (OSError, ValueError, plistlib.InvalidFileException):
        pass
    return os.path.join(bundle_contents(bundle), "MacOS", name)


def bundle_identifier(bundle):
    try:
        with open(os.path.join(bundle_contents(bundle), "Info.plist"), "rb") as f:
            return plistlib.load(f).get("CFBundleIdentifier", "EOSWebcamUtility")
    except (OSError, ValueError, plistlib.InvalidFileException):
        return "EOSWebcamUtility"


def resource_hashes(bundle):
    """{path relative to Contents: hash} of what the bundle seal covers."""
    contents = bundle_contents(bundle)
    main = os.path.relpath(main_executable(bundle), contents)
    out = {}
    for d, dirs, files in os.walk(contents):
        dirs.sort()
        for n in sorted(files):
            p = os.path.join(d, n)
            rel = os.path.relpath(p, contents)
            if rel == main or rel.startswith("_CodeSignature" + os.sep) or rel == "Info.plist":
                continue
            with open(p, "rb") as f:
                out[rel] = _sha(f.read())
    return out


def _file_sha(path):
    try:
        with open(path, "rb") as f:
            return _sha(f.read())
    except OSError:
        return None


def seal_bundle(bundle, signer, main_flags=(), main_ents=()):
    """Write CodeResources and sign the main executable over it."""
    contents = bundle_contents(bundle)
    os.makedirs(os.path.join(contents, "_CodeSignature"), exist_ok=True)
    cr = os.path.join(contents, "_CodeSignature", "CodeResources")
    with open(cr, "w") as f:
        json.dump({"signer": signer, "files": resource_hashes(bundle)}, f, sort_keys=True, indent=1)
        f.write("\n")
    main = main_executable(bundle)
    with open(main, "rb") as f:
        data = bytearray(f.read())
    rec = record(data, signer, bundle_identifier(bundle), main_flags, main_ents,
                 seal=_file_sha(cr), info=_file_sha(os.path.join(contents, "Info.plist")))
    with open(main, "wb") as f:
        f.write(write_record(data, rec))


def sign_file(path, signer, ident, flags=(), ents=()):
    with open(path, "rb") as f:
        data = bytearray(f.read())
    rec = record(data, signer, ident, flags, ents)
    with open(path, "wb") as f:
        f.write(write_record(data, rec))


# --- verification ------------------------------------------------------------

def verify_file(path):
    """(ok, message). message is what codesign would say when not ok."""
    try:
        with open(path, "rb") as f:
            data = f.read()
        rec = read_record(data)
    except OSError as e:
        return False, "%s: %s" % (path, e.strerror)
    except NotFake:
        return False, "%s: code object is not signed at all" % path
    if rec is None:
        return False, "%s: code object is not signed at all" % path
    if rec.get("broken") or rec.get("code") != code_hash(data):
        return False, "%s: invalid signature (code or signature have been modified)" % path
    return True, ""


def verify_bundle(bundle):
    main = main_executable(bundle)
    ok, msg = verify_file(main)
    if not ok:
        return False, [msg.replace(main, bundle)]
    with open(main, "rb") as f:
        rec = read_record(f.read())
    contents = bundle_contents(bundle)
    cr = os.path.join(contents, "_CodeSignature", "CodeResources")
    if rec.get("info") != _file_sha(os.path.join(contents, "Info.plist")):
        return False, ["%s: invalid Info.plist (plist or signature have been modified)" % bundle]
    if rec.get("seal") is None or rec.get("seal") != _file_sha(cr):
        return False, ["%s: invalid resource directory (directory or signature have been modified)" % bundle]
    with open(cr) as f:
        sealed = json.load(f).get("files", {})
    now = resource_hashes(bundle)
    problems = []
    for rel in sorted(set(sealed) | set(now)):
        if rel not in now:
            problems.append("file missing: %s" % os.path.join(contents, rel))
        elif rel not in sealed:
            problems.append("file added: %s" % os.path.join(contents, rel))
        elif sealed[rel] != now[rel]:
            problems.append("file modified: %s" % os.path.join(contents, rel))
    if problems:
        return False, ["%s: a sealed resource is missing or invalid" % bundle] + problems
    return True, []


def signature_of(path):
    """The record of path (a file, or a bundle's main executable)."""
    target = main_executable(path) if os.path.isdir(path) else path
    with open(target, "rb") as f:
        return target, read_record(f.read())
