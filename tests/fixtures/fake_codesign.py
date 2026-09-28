#!/usr/bin/env python3
"""What tests/stubs/codesign runs: codesign for the FAKE binaries.

Signs (--sign), displays (-d) and verifies (--verify / -v) the fake
signatures described in fakesig.py, with the options the scripts use:
--force, --identifier, --options runtime, --entitlements, --preserve-metadata,
--deep, --strict, -R / --test-requirement. Output follows real codesign's
wording closely enough for the scripts' greps. Refuses any path outside the
test sandbox.
"""
import os
import plistlib
import subprocess
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fakesig  # noqa: E402

VALUE_OPTS = {"-s": "sign", "--sign": "sign", "-i": "identifier", "--identifier": "identifier",
              "-o": "options", "--options": "options", "--entitlements": "entitlements",
              "-R": "requirement", "--test-requirement": "requirement", "--timestamp": None}


def staging_dir(real):
    """True if real is inside a staging dir the scripts made with mktemp -t
    (macOS puts those in the per-user temp dir, outside the sandbox)."""
    try:
        out = subprocess.run(["/usr/bin/getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True,
                             text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return False
    if not out:
        return False
    tmp = os.path.realpath(out)
    rel = os.path.relpath(real, tmp)
    first = rel.split(os.sep)[0]
    return not rel.startswith("..") and (first.startswith("eoswc-restore.") or first.startswith("eoswc-stage."))


def forbid(path, writes):
    """Exit unless path is in the test sandbox (or, only for reading, in a
    staging dir the script under test made)."""
    sandbox = os.environ.get("EOSWC_TEST_SANDBOX", "")
    real = os.path.realpath(path)
    root = os.path.realpath(sandbox) if sandbox else ""
    inside = bool(root) and (real == root or real.startswith(root + os.sep))
    if not inside and not (not writes and staging_dir(real)):
        log = os.environ.get("STUB_LOG")
        if log:
            with open(log, "a") as f:
                f.write("FORBIDDEN codesign on %s (outside the test sandbox)\n" % path)
        sys.stderr.write("codesign stub: %s is outside the test sandbox; refusing\n" % path)
        sys.exit(99)


def parse(argv):
    opts = {"force": False, "display": False, "verify": False, "verbose": 0, "deep": False,
            "strict": False, "preserve": [], "requirements": [], "paths": []}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a.startswith("--"):
            name, eq, val = a.partition("=")
            if name in VALUE_OPTS:
                if not eq:
                    if name == "--timestamp":
                        i += 1
                        continue
                    i += 1
                    val = argv[i]
                key = VALUE_OPTS[name]
                if key == "requirement":
                    opts["requirements"].append(val)
                elif key:
                    opts[key] = val
            elif name == "--force":
                opts["force"] = True
            elif name == "--display":
                opts["display"] = True
            elif name == "--verify":
                opts["verify"] = True
            elif name == "--verbose":
                opts["verbose"] += int(val or 1)
            elif name == "--deep":
                opts["deep"] = True
            elif name == "--strict":
                opts["strict"] = True
            elif name == "--preserve-metadata":
                opts["preserve"] = [p for p in val.split(",") if p]
            # --xml, --no-strict, ...: accepted and ignored
        elif a.startswith("-") and a != "-" and len(a) > 1:
            j = 1
            while j < len(a):
                c = a[j]
                if c in "sioR":
                    val = a[j + 1:]
                    if val.startswith("="):
                        val = val[1:]
                    if not val:
                        i += 1
                        val = argv[i]
                    key = VALUE_OPTS["-" + c]
                    if key == "requirement":
                        opts["requirements"].append(val)
                    else:
                        opts[key] = val
                    break
                if c == "d":
                    opts["display"] = True
                elif c == "v":
                    opts["verbose"] += 1
                elif c == "f":
                    opts["force"] = True
                elif c == "r":
                    opts["show_req"] = True
                    break
                j += 1
        else:
            opts["paths"].append(a)
        i += 1
    if "sign" not in opts and not opts["display"] and opts["verbose"]:
        opts["verify"] = True
    return opts


def entitlement_keys(path):
    with open(path, "rb") as f:
        return sorted(k for k, v in plistlib.load(f).items() if v)


def meets(rec, req):
    """Evaluate the requirement forms the scripts use."""
    req = req.lstrip("=").strip()
    ok = True
    if "anchor apple generic" in req:
        ok = ok and rec.get("signer") == "canon"
    if "subject.OU" in req:
        want = req.split("subject.OU", 1)[1].split("=", 1)[1].strip().strip('"').split()[0]
        ok = ok and rec.get("team") == want
    return ok


def do_sign(o, path):
    identity = o["sign"]
    signer = "adhoc" if identity == "-" else "identity:" + identity
    if os.path.isdir(path):
        main = fakesig.main_executable(path)
        with open(main, "rb") as f:
            old = fakesig.read_record(f.read()) or {}
        flags = old.get("flags", []) if "flags" in o["preserve"] else []
        ents = old.get("ents", []) if "entitlements" in o["preserve"] else []
        fakesig.seal_bundle(path, signer, flags, ents)
        return 0
    with open(path, "rb") as f:
        data = f.read()
    try:
        old = fakesig.read_record(data) or {}
    except fakesig.NotFake:
        sys.stderr.write("%s: unsupported format for signature\n" % path)
        return 1
    ident = o.get("identifier") or (old.get("id") if "identifier" in o["preserve"] else None) \
        or old.get("id") or os.path.basename(path)
    flags = old.get("flags", []) if "flags" in o["preserve"] else []
    if "options" in o:
        flags = sorted(set(flags) | {x for x in o["options"].split(",") if x})
    ents = old.get("ents", []) if "entitlements" in o["preserve"] else []
    if "entitlements" in o:
        ents = entitlement_keys(o["entitlements"])
    fakesig.sign_file(path, signer, ident, flags, ents)
    return 0


def flag_text(rec):
    bits, names = 0, []
    if rec.get("signer") == "adhoc":
        bits |= 0x2
        names.append("adhoc")
    if "runtime" in rec.get("flags", []):
        bits |= 0x10000
        names.append("runtime")
    return "0x%x(%s)" % (bits, ",".join(names) or "none")


def do_display(o, path):
    try:
        target, rec = fakesig.signature_of(path)
    except (OSError, fakesig.NotFake):
        rec, target = None, path
    if rec is None:
        sys.stderr.write("%s: code object is not signed at all\n" % path)
        return 1
    sys.stderr.write("Executable=%s\n" % os.path.abspath(target))
    if "entitlements" in o:
        if rec.get("ents"):
            sys.stdout.write("[Dict]\n")
            for k in rec["ents"]:
                sys.stdout.write("\t[Key] %s\n\t[Value]\n\t\t[Bool] true\n" % k)
        return 0
    if o["verbose"]:
        bundle = os.path.isdir(path)
        lines = ["Identifier=%s" % rec.get("id"),
                 "Format=%sMach-O thin (arm64)" % ("bundle with " if bundle else ""),
                 "CodeDirectory v=20500 size=0 flags=%s hashes=0+0 location=embedded" % flag_text(rec)]
        if rec.get("signer") == "canon":
            lines += ["Authority=" + fakesig.CANON_AUTHORITY, "Authority=Developer ID Certification Authority",
                      "Authority=Apple Root CA"]
        elif rec.get("signer") == "adhoc":
            lines.append("Signature=adhoc")
        else:
            lines.append("Authority=" + rec.get("signer", "").replace("identity:", ""))
        lines.append("TeamIdentifier=%s" % (rec.get("team") or "not set"))
        if "runtime" in rec.get("flags", []):
            lines.append("Runtime Version=13.1.0")
        lines.append("Sealed Resources=%s" % ("version=2 rules=13 files=6" if bundle else "none"))
        sys.stderr.write("\n".join(lines) + "\n")
    return 0


def do_verify(o, path):
    if not os.path.exists(path):
        sys.stderr.write("%s: No such file or directory\n" % path)
        return 1
    if os.path.isdir(path):
        ok, msgs = fakesig.verify_bundle(path)
    else:
        ok, msg = fakesig.verify_file(path)
        msgs = [msg] if msg else []
    if not ok:
        sys.stderr.write("\n".join(msgs) + "\n")
        return 1
    _target, rec = fakesig.signature_of(path)
    if o["verbose"]:
        sys.stderr.write("%s: valid on disk\n%s: satisfies its Designated Requirement\n" % (path, path))
    for req in o["requirements"]:
        if not meets(rec, req):
            sys.stderr.write("test-requirement: code failed to satisfy specified code requirement(s)\n")
            return 3
    if o["requirements"] and o["verbose"]:
        sys.stderr.write("%s: explicit requirement satisfied\n" % path)
    return 0


def main():
    o = parse(sys.argv[1:])
    if not o["paths"]:
        sys.stderr.write("Usage: codesign ...\n")
        return 2
    rc = 0
    for p in o["paths"]:
        forbid(p, "sign" in o)
        if "sign" in o:
            r = do_sign(o, p)
        elif o["display"]:
            r = do_display(o, p)
        elif o["verify"]:
            r = do_verify(o, p)
        else:
            r = 0
        rc = rc or r
    return rc


if __name__ == "__main__":
    sys.exit(main())
