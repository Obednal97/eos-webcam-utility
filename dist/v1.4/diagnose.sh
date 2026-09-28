#!/bin/bash
#
# EOS Webcam Utility Fork — Diagnostic Report
#
# READ-ONLY. This script does NOT change anything on your system.
# It collects everything needed to debug "the camera doesn't appear in
# QuickTime / Zoom / etc." into a single report you can paste into a
# GitHub issue.
#
# What it checks:
#   - macOS version, architecture, and System Integrity Protection state
#   - Whether the DAL plug-in is actually installed
#   - The plug-in's code signature, Gatekeeper assessment, and quarantine flag
#   - Whether the EDSDK framework is present
#   - Whether the background services/processes are running
#   - Where the camera manager is installed, and whether launchd can run it
#   - Whether the fork's old com.canon-camera-manager agent is still there
#   - Canon's Camera Extension (macOS 14+): installed, approved, or not
#   - Whether the fork's files and Canon's config files exist
#   - Whether a Canon camera is on USB (by Canon's USB vendor ID, 0x04a9)
#   - Which cameras macOS itself can see (the virtual cam should appear here
#     if the plug-in loaded correctly)
#   - Recent log messages from Canon's own processes, and security messages
#     about the plug-in (or failing to load)
#   - The camera manager's own log, and launchd's stderr log for it
#
# Privacy: the report is meant for a public GitHub issue, so it is built
# to leave things out and then redacted before anything is written:
#   - Left out: Canon's own log files and anything else Canon keeps in
#     ~/Library/Application Support/EWCService (they are only counted), USB
#     serial numbers, camera Model/Unique IDs, other USB devices, and log
#     lines that list other apps or extensions.
#   - Redacted (literal text, so any name works): your username, real name,
#     home folder path, computer name and host name, the Mac's serial number
#     and hardware UUID, USB serial numbers; and anywhere in the report, any
#     UUID, IP or MAC address, email address, "serial"/"owner"/"artist"/
#     "copyright" values (a camera can report its owner's name), other
#     people's home folders and possessive device names ("Sam's iPhone").
#   - If redaction fails, or leaves anything it should have removed, or
#     the report comes out empty, no report is written and it exits 1.
#
# Usage:
#   1. Open QuickTime Player -> File -> New Movie Recording, then click the
#      small down-arrow next to the record button to show the camera list.
#      (This forces macOS to try loading the plug-in, so the logs are fresh.)
#   2. Run this script:  bash diagnose.sh
#   3. A report is written to your Desktop (or to --output FILE). Read it
#      before posting, then paste it into the GitHub issue.
#

OUT="$HOME/Desktop/eos-webcam-diagnostics.txt"
while [ $# -gt 0 ]; do
    case "$1" in
        --output|-o)
            [ -n "${2:-}" ] || { echo "ERROR: $1 needs a file name."; exit 1; }
            OUT="$2"; shift 2 ;;
        --output=*) OUT="${1#--output=}"; shift ;;
        -h|--help)
            echo "Usage: bash diagnose.sh [--output FILE]"
            echo "Writes a redacted diagnostic report to FILE (default: $OUT)."
            exit 0 ;;
        *) echo "ERROR: unknown option: $1 (try --help)"; exit 1 ;;
    esac
done
[ -n "$OUT" ] || { echo "ERROR: --output needs a file name."; exit 1; }
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ ! -f "$SCRIPT_DIR/common.sh" ]; then
    echo "ERROR: common.sh not found next to this script."
    exit 1
fi
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"
# The real plug-in path, unless a test sandbox says otherwise (see common.sh).
eoswc_select_plugin_dir || exit 1
PLUGIN="$EOSWC_PLUGIN"
eoswc_select_canon_app_dir || exit 1
CANON_APPS="$EOSWC_CANON_APPS"
AGENT_PLIST="$HOME/Library/LaunchAgents/$EOSWC_AGENT_LABEL.plist"

# Canon's USB vendor ID (0x04a9). Cameras are matched on this, not on the
# product name: the name a body reports varies by model and firmware.
CANON_USB_VENDOR=1193

# One line per launchd job: running (with PID), loaded but not running (the
# PID column is "-", e.g. a crash loop), or not loaded at all.
job_status() {
    local row
    row=$(launchctl list 2>/dev/null | awk -v label="$1" '$3 == label { print $1 " " $2; exit }')
    if eoswc_job_running "$1"; then
        echo "$1: RUNNING (PID ${row%% *})"
    elif [ -n "$row" ]; then
        echo "$1: LOADED BUT NOT RUNNING (last exit status ${row#* })"
    else
        echo "$1: NOT LOADED"
    fi
}

# --- Canon camera on USB -----------------------------------------------------
# macOS 26 has no SPUSBDataType (system_profiler prints nothing for it), so
# the USB tree comes from ioreg, which every macOS version has. Only Canon
# devices are reported, by name and product ID; never serial numbers, and
# never other devices (their names can be personal).

# ioreg -p IOUSB -l -w0 on stdin.
read -r -d '' USB_IOREG_AWK <<'AWK'
function flush() {
    if (!node) return
    if (cls ~ /^IOUSB(Host)?Device$/) ndev++
    if (vid != "" && vid + 0 == canon) {
        name = pname
        if (name == "") name = pstr
        if (name == "") name = nname
        if (pid == "") printf "Canon device on USB: %s (vendor ID 0x%04x, product ID unknown)\n", name, canon
        else printf "Canon device on USB: %s (vendor ID 0x%04x, product ID 0x%04x)\n", name, canon, pid + 0
        ncanon++
    }
    node = 0; vid = ""; pid = ""; pname = ""; pstr = ""; nname = ""; cls = ""
}
function strval(line, key) {
    sub("^.*\"" key "\" = \"", "", line)
    sub(/"[^"]*$/, "", line)
    return line
}
/\+-o / {
    flush()
    node = 1
    line = $0
    sub(/^.*\+-o /, "", line)
    cls = line
    nname = line
    sub(/  <class .*$/, "", nname)
    sub(/@[0-9A-Fa-f]+$/, "", nname)
    if (sub(/^.*<class /, "", cls)) sub(/[,>].*$/, "", cls); else cls = ""
    next
}
/"idVendor" = [0-9]/  { v = $0; sub(/^.*"idVendor" = /, "", v); vid = v + 0 }
/"idProduct" = [0-9]/ { v = $0; sub(/^.*"idProduct" = /, "", v); pid = v + 0 }
/"USB Product Name" = "/  { pname = strval($0, "USB Product Name") }
/"kUSBProductString" = "/ { pstr = strval($0, "kUSBProductString") }
END {
    flush()
    if (ncanon == 0)
        printf "No Canon device on USB (no device with vendor ID 0x%04x among %d USB devices)\n", canon, ndev
    else
        printf "(%d USB devices seen in all; only Canon ones are listed)\n", ndev
}
AWK

# system_profiler SPUSBHostDataType / SPUSBDataType text on stdin.
read -r -d '' USB_SP_AWK <<'AWK'
function flush() {
    if (vid != "") {
        ndev++
        if (tolower(vid) == want) {
            if (pid == "") pid = "unknown"
            printf "Canon device on USB: %s (vendor ID %s, product ID %s)\n", name, want, pid
            ncanon++
        }
    }
    vid = ""; pid = ""
}
/^[ \t]*[^ \t].*:[ \t]*$/ {
    flush()
    name = $0
    sub(/^[ \t]+/, "", name)
    sub(/:[ \t]*$/, "", name)
    next
}
/^[ \t]*Product ID:/ { pid = $0; sub(/^[ \t]*Product ID:[ \t]*/, "", pid); sub(/[ \t].*$/, "", pid) }
/^[ \t]*Vendor ID:/  { vid = $0; sub(/^[ \t]*Vendor ID:[ \t]*/, "", vid); sub(/[ \t].*$/, "", vid) }
END {
    flush()
    if (ncanon == 0)
        printf "No Canon device on USB (no device with vendor ID %s among %d USB devices)\n", want, ndev
    else
        printf "(%d USB devices seen in all; only Canon ones are listed)\n", ndev
}
AWK

canon_usb_report() {
    local out t
    if command -v ioreg >/dev/null 2>&1 &&
       out="$(ioreg -p IOUSB -l -w0 2>/dev/null)" && [ -n "$out" ]; then
        echo "(from the USB tree of ioreg)"
        printf '%s\n' "$out" | awk -v canon="$CANON_USB_VENDOR" "$USB_IOREG_AWK"
        return 0
    fi
    for t in SPUSBHostDataType SPUSBDataType; do
        out="$(system_profiler "$t" 2>/dev/null)"
        if printf '%s\n' "$out" | grep -q "Vendor ID:"; then
            echo "(ioreg gave nothing; from system_profiler $t)"
            printf '%s\n' "$out" | awk -v want="$(printf '0x%04x' "$CANON_USB_VENDOR")" "$USB_SP_AWK"
            return 0
        fi
    done
    echo "USB devices could not be listed (ioreg gave nothing, and system_profiler"
    echo "has no USB data here), so whether a Canon camera is connected is unknown."
}

# --- Logs ----------------------------------------------------------------------
# Only Canon's own processes and subsystems, and the security daemons'
# messages about the plug-in by path. Never a plain substring or bundle-ID
# match on every process: runningboardd, for one, dumps every running app
# with Canon's extension ID among them. From Canon's processes, errors and
# faults, plus messages that name the plug-in or service.
CANON_PROCS='process == "EOSWebcamService" OR process == "EWCService" OR process == "EWCProxy" OR process == "EWCPairingService" OR process == "EWCCameraExtension" OR process == "com.canon.cusa.eoswebcam.cameraExtension"'
LOG_PREDICATE="(($CANON_PROCS) AND (messageType == error OR messageType == fault OR eventMessage CONTAINS[c] \"EOSWebcam\" OR eventMessage CONTAINS[c] \"EWC\"))"
LOG_PREDICATE="$LOG_PREDICATE OR subsystem BEGINSWITH \"com.canon.\""
LOG_PREDICATE="$LOG_PREDICATE OR (eventMessage CONTAINS \"EOSWebcamUtility.plugin\" AND (process == \"amfid\" OR process == \"kernel\" OR process == \"syspolicyd\" OR process == \"tccd\" OR subsystem == \"com.apple.cmio\"))"

# `log show --style compact` on stdin. Even Canon's processes log lists of
# every camera extension, so a second line of defence: entries from
# processes that dump app lists are dropped whole, and any line that names
# another app, process or extension is dropped. Long multi-line entries are
# cut to their first few lines. The last line says what was left out.
read -r -d '' LOG_FILTER_AWK <<'AWK'
BEGIN {
    split("runningboardd launchservicesd lsd backgroundtaskmanagementd WindowServer loginwindow Dock ControlCenter SystemUIServer coreduetd", d, " ")
    for (i in d) deny[d[i]] = 1
    maxcont = 3
}
function lists_apps(s,   id) {
    if (s ~ /(app|xpcservice|osservice|daemon|anon|application|extension)</) return 1
    if (s ~ /application\.[A-Za-z0-9-]+\./) return 1
    if (s ~ /RBSProcessIdentity|RBConnectionClient|RBSAssertion|processStates:|assertionCount:/) return 1
    if (match(s, /CMIOExtensionInfo: ID [^ >]+/)) {
        id = substr(s, RSTART + 22, RLENGTH - 22)
        if (id !~ /^com\.canon\./) return 1
    }
    return 0
}
/^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] / {
    proc = $4
    sub(/\[.*$/, "", proc)
    cont = 0
    dropentry = (proc in deny) || lists_apps($0)
    if (dropentry) { apps++; next }
    print
    next
}
/^Timestamp[ \t]/ { next }
{
    if (dropentry) { apps++; next }
    if (lists_apps($0)) { apps++; next }
    if (++cont > maxcont) { long++; next }
    print
}
END {
    if (apps + long > 0)
        printf "(left out: %d line(s) that list other apps, processes or extensions; %d more line(s) of long multi-line entries)\n", apps, long
}
AWK

recent_logs() {
    local logs
    # Timestamps in UTC, like the report's date.
    logs="$(log show --last 10m --timezone UTC --style compact --predicate "$LOG_PREDICATE" 2>/dev/null)" ||
        logs="$(log show --last 10m --style compact --predicate "$LOG_PREDICATE" 2>/dev/null)" ||
        logs=""
    logs="$(printf '%s\n' "$logs" | awk "$LOG_FILTER_AWK" | tail -60)"
    if [ -n "$logs" ]; then printf '%s\n' "$logs"; else echo "no relevant log entries"; fi
}

# --- Runtime dir -----------------------------------------------------------------
# ~/Library/Application Support/EWCService is Canon's folder too: its logs
# (log*.txt) and its Camera/ and Device/ folders can hold camera serial
# numbers and names. Only the fork's own files and Canon's two config files
# are listed (mode and size); everything else is only counted.
runtime_files_report() {
    local dir="$EOSWC_RUNTIME_DIR" f known=" backups " entry name other=0 b nb=0 nbo=0
    if [ ! -d "$dir" ]; then
        echo "$dir: not found"
        return 0
    fi
    echo "$dir:"
    for f in $EOSWC_RUNTIME_FILES config.plist proconfig.plist $EOSWC_LOGO_FILES; do
        known="$known$f "
        if [ -e "$dir/$f" ] || [ -L "$dir/$f" ]; then
            printf '  %s %8s bytes  %s\n' "$(stat -f '%Sp' "$dir/$f")" "$(stat -f '%z' "$dir/$f")" "$f"
        else
            case " $EOSWC_LOGO_FILES " in
                *" $f "*) ;;
                *) printf '  missing                    %s\n' "$f" ;;
            esac
        fi
    done
    if [ -d "$dir/backups" ]; then
        for b in "$dir/backups"/*; do
            [ -e "$b" ] || continue
            case "${b##*/}" in
                pre-v[0-9]*) nb=$((nb + 1)); echo "  backup: ${b##*/}" ;;
                *) nbo=$((nbo + 1)) ;;
            esac
        done
        echo "  backups/: $nb backup(s)$([ "$nbo" = 0 ] || echo ", $nbo other item(s) not listed")"
    fi
    for entry in "$dir"/* "$dir"/.[!.]*; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        name="${entry##*/}"
        case "$known" in *" $name "*) continue ;; esac
        other=$((other + 1))
    done
    echo "  other files and folders (Canon's logs and data; not listed): $other"
}

# --- Privacy redaction ---------------------------------------------------------
# Everything identifying that this Mac knows about itself, one
# "<label><TAB><text>" per line: the text is replaced by the label, as
# literal text (never a regex), case-insensitively, and only as a whole word
# where it starts or ends with a letter or digit (a username "can" leaves
# "Canon" alone). Values shorter than two characters are skipped.
redaction_terms() {
    local v t home_p user name q="'" cq="’" words=()
    home_p="$(cd "$HOME" 2>/dev/null && pwd -P)"
    for v in "$HOME" "$home_p"; do
        [ -n "$v" ] && [ "$v" != / ] && printf '~\t%s\n' "${v%/}"
    done
    for user in "$(id -un 2>/dev/null)" "$(whoami 2>/dev/null)" "${USER:-}" "${LOGNAME:-}"; do
        [ -n "$user" ] && printf '<user>\t%s\n' "$user"
    done
    name="$(id -F 2>/dev/null)"
    if [ -n "$name" ]; then
        printf '<name>\t%s\n' "$name"
        # Each word of it too, e.g. a first name in a device name. (read -a:
        # no glob expansion, so a name like "a*b" stays as it is.)
        read -r -a words <<< "$name"
        for t in "${words[@]+"${words[@]}"}"; do
            printf '<name>\t%s\n' "$t"
        done
    fi
    # With both kinds of apostrophe: "Sam’s MacBook" is also "Sam's MacBook".
    for t in ComputerName LocalHostName HostName; do
        v="$(scutil --get "$t" 2>/dev/null)" || continue
        printf '<computer name>\t%s\n' "$v" "${v//$cq/$q}" "${v//$q/$cq}"
    done
    v="$(hostname 2>/dev/null)"
    [ -n "$v" ] && printf '<computer name>\t%s\n' "$v" "${v%%.*}"
    # The Mac's serial number and hardware UUID, and every USB serial number.
    ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | awk -F'"' '
        $2 == "IOPlatformSerialNumber" && $4 != "" { print "<serial>\t" $4 }
        $2 == "IOPlatformUUID" && $4 != ""         { print "<uuid>\t" $4 }'
    ioreg -p IOUSB -l -w0 2>/dev/null | awk -F'"' '
        ($2 == "USB Serial Number" || $2 == "kUSBSerialNumberString") && $4 != "" { print "<serial>\t" $4 }'
}

# The redaction filter (EOSWC_REDACT_MODE=redact), and the check run on its
# output (=check), which exits 1 if anything it should have removed is still
# there. Terms come in EOSWC_REDACT_TERMS (not awk -v, which would eat
# backslashes). Byte-wise (LC_ALL=C), so non-ASCII names match exactly.
read -r -d '' REDACT_AWK <<'AWK'
BEGIN {
    for (i = 1; i < 256; i++) CH[i] = sprintf("%c", i)
    HIGH = ""
    for (i = 128; i < 256; i++) HIGH = HIGH CH[i]
    M1 = CH[1]; M2 = CH[2]
    mode = ENVIRON["EOSWC_REDACT_MODE"]
    if (mode != "redact" && mode != "check") {
        print "redact: EOSWC_REDACT_MODE must be redact or check" > "/dev/stderr"
        failed = 1
        exit 2
    }
    n = split(ENVIRON["EOSWC_REDACT_TERMS"], raw, "\n")
    nt = 0
    for (i = 1; i <= n; i++) {
        p = index(raw[i], "\t")
        if (p == 0) continue
        lab = substr(raw[i], 1, p - 1)
        term = substr(raw[i], p + 1)
        if (length(term) < 2 || term ~ /[\001-\037]/) continue
        key = tolower(term)
        if (key in seen) continue
        seen[key] = 1
        nt++; T[nt] = term; TL[nt] = key; TC[nt] = code(lab)
    }
    # Longest first: the full name before its words, the home path before
    # the username.
    for (i = 2; i <= nt; i++)
        for (j = i; j > 1 && length(TL[j]) > length(TL[j - 1]); j--) {
            t = T[j]; T[j] = T[j - 1]; T[j - 1] = t
            t = TL[j]; TL[j] = TL[j - 1]; TL[j - 1] = t
            t = TC[j]; TC[j] = TC[j - 1]; TC[j - 1] = t
        }
    for (i = 1; i <= nt; i++) {
        WF[i] = isword(substr(T[i], 1, 1))
        WL[i] = isword(substr(T[i], length(T[i]), 1))
    }
    hx = "[0-9A-Fa-f]"
    h2 = hx hx; h4 = h2 h2; h8 = h4 h4; h12 = h8 h4
    UUID_RE = h8 "-" h4 "-" h4 "-" h4 "-" h12
    MAC_RE = "(" h2 ":" h2 ":" h2 ":" h2 ":" h2 ":" h2 "|" h2 "-" h2 "-" h2 "-" h2 "-" h2 "-" h2 ")"
    EMAIL_RE = "[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+([.][A-Za-z0-9-]+)*[.][A-Za-z][A-Za-z]+"
    d3 = "[0-9]([0-9]([0-9])?)?"
    IPV4_RE = d3 "[.]" d3 "[.]" d3 "[.]" d3
    KEY_RE = "(serial( ?(number|no[.]?|#))?|owner( ?name)?|artist|author|copyright|nickname|body ?id)[\" \t]*[:=]"
    split("it that what there here who let he she where canon apple", sw, " ")
    for (i in sw) stop[sw[i]] = 1
    C_UUID = code("<uuid>"); C_EMAIL = code("<email>"); C_IP = code("<ip>")
    C_MAC = code("<mac>"); C_RED = code("<redacted>"); C_USER = code("<user>")
    C_NAME = code("<name>")
    APOS2 = CH[226] CH[128] CH[153]
}
# One placeholder (\001, a letter, \002) per label, swapped for the label
# text only at the very end, so no later rule can match inside a label.
function code(lab) {
    if (!(lab in LID)) {
        nl++
        LID[lab] = nl; LAB[nl] = lab; LC[nl] = M1 CH[64 + nl] M2
    }
    return LC[LID[lab]]
}
function isword(c) {
    if (c == "") return 0
    if (c ~ /[A-Za-z0-9_]/) return 1
    return index(HIGH, c) > 0
}
function before(s, i, out) {
    return (i > 1) ? substr(s, i - 1, 1) : substr(out, length(out), 1)
}
# Term k, literally, whole-word at the ends that are word characters.
function lit(s, k,   out, i, n, b, a) {
    n = length(TL[k]); out = ""
    while ((i = index(tolower(s), TL[k])) > 0) {
        b = before(s, i, out)
        a = substr(s, i + n, 1)
        if ((!WF[k] || !isword(b)) && (!WL[k] || !isword(a))) {
            out = out substr(s, 1, i - 1) TC[k]
            s = substr(s, i + n)
            hits++
        } else {
            out = out substr(s, 1, i)
            s = substr(s, i + 1)
        }
    }
    return out s
}
# Regex re; bnd (if set) is a class the characters on either side must
# not be in.
function rx(s, re, c, bnd,   out, b, a) {
    out = ""
    while (match(s, re)) {
        b = before(s, RSTART, out)
        a = substr(s, RSTART + RLENGTH, 1)
        if (bnd == "" || (b !~ bnd && a !~ bnd)) {
            out = out substr(s, 1, RSTART - 1) c
            s = substr(s, RSTART + RLENGTH)
            hits++
        } else {
            out = out substr(s, 1, RSTART)
            s = substr(s, RSTART + 1)
        }
    }
    return out s
}
# IPv6: a run of hex digits and colons with "::" or seven colons, groups of
# at most four digits, not part of a word (C++'s Foo::Bar is left alone).
function v6(s,   out, run, b, a, g, ng, i, ok, colons) {
    out = ""
    while (match(s, /[0-9A-Fa-f:]*:[0-9A-Fa-f:]*/)) {
        run = substr(s, RSTART, RLENGTH)
        b = before(s, RSTART, out)
        a = substr(s, RSTART + RLENGTH, 1)
        colons = gsub(/:/, ":", run)
        ok = (index(run, "::") > 0 || colons >= 7) && run ~ /[0-9A-Fa-f]/ &&
             b !~ /[A-Za-z0-9_]/ && a !~ /[A-Za-z0-9_]/
        if (ok) {
            ng = split(run, g, ":")
            for (i = 1; i <= ng; i++) if (length(g[i]) > 4) ok = 0
        }
        if (ok) {
            out = out substr(s, 1, RSTART - 1) C_IP
            hits++
        } else {
            out = out substr(s, 1, RSTART + RLENGTH - 1)
        }
        s = substr(s, RSTART + RLENGTH)
    }
    return out s
}
# Someone else's home folder: /Users/<name> (not /Users/Shared).
function users(s,   out, u) {
    out = ""
    while (match(s, /\/Users\/[^\/ \t"'<>:;,()\001\002]+/)) {
        u = substr(s, RSTART + 7, RLENGTH - 7)
        if (u == "Shared") {
            out = out substr(s, 1, RSTART + RLENGTH - 1)
        } else {
            out = out substr(s, 1, RSTART + 6) C_USER
            hits++
        }
        s = substr(s, RSTART + RLENGTH)
    }
    return out s
}
# "serial: X", "Owner name = X", ...: the value, to the end of the line.
# A value that is empty or already just a label is left alone.
function keyed(s,   low, b, rest) {
    low = tolower(s)
    while (match(low, KEY_RE)) {
        b = (RSTART > 1) ? substr(low, RSTART - 1, 1) : ""
        if (b !~ /[a-z0-9_]/) {
            rest = substr(s, RSTART + RLENGTH)
            gsub(/^[ \t"]+|[ \t"]+$/, "", rest)
            if (rest == "" || rest == M1 || rest ~ /^\001.\002$/) return s
            hits++
            return substr(s, 1, RSTART + RLENGTH - 1) " " C_RED
        }
        low = substr(low, 1, RSTART - 1) "#" substr(low, RSTART + 1)
    }
    return s
}
# Possessive device names ("Sam's iPhone", curly apostrophe too). This hits
# any "<word>'s ", so text the report prints says "the X of Y" instead
# (only "Canon's", "it's" and a few more are left alone).
function possessive(s, ap,   out, i, j, w) {
    out = ""
    while ((i = index(s, ap "s ")) > 0) {
        j = i
        while (j > 1 && (substr(s, j - 1, 1) ~ /[A-Za-z]/ || index(HIGH, substr(s, j - 1, 1)) > 0)) j--
        w = substr(s, j, i - j)
        if (w != "" && !(tolower(w) in stop) && !isword(before(s, j, out))) {
            out = out substr(s, 1, j - 1) C_NAME
            hits++
        } else {
            out = out substr(s, 1, i - 1)
        }
        out = out ap "s "
        s = substr(s, i + length(ap) + 2)
    }
    return out s
}
function redact(s,   k) {
    for (k = 1; k <= nt; k++) s = lit(s, k)
    s = rx(s, UUID_RE, C_UUID, "")
    s = rx(s, EMAIL_RE, C_EMAIL, "")
    s = v6(s)
    s = rx(s, MAC_RE, C_MAC, "[0-9A-Fa-f:-]")
    s = rx(s, IPV4_RE, C_IP, "[0-9A-Za-z_.]")
    s = users(s)
    s = keyed(s)
    s = possessive(s, "'")
    s = possessive(s, APOS2)
    return s
}
function expand(s,   k, i, out) {
    for (k = 1; k <= nl; k++) {
        out = ""
        while ((i = index(s, LC[k])) > 0) {
            out = out substr(s, 1, i - 1) LAB[k]
            s = substr(s, i + length(LC[k]))
        }
        s = out s
    }
    return s
}
function strip_labels(s,   k, i, out) {
    for (k = 1; k <= nl; k++) {
        out = ""
        while ((i = index(s, LAB[k])) > 0) {
            out = out substr(s, 1, i - 1) M1
            s = substr(s, i + length(LAB[k]))
        }
        s = out s
    }
    return s
}
{
    line = $0
    gsub(/[\001\002]/, "", line)
    if (mode == "redact") {
        print expand(redact(line))
        next
    }
    # check: what is left once the labels are taken out must redact to
    # itself. Only the kind is reported, never the text.
    hits = 0
    redact(strip_labels(line))
    if (hits) leftover++
}
END {
    if (failed) exit 2
    if (mode == "check" && leftover) {
        printf "redaction check: %d line(s) still hold something that should have been redacted\n", leftover > "/dev/stderr"
        exit 1
    }
}
AWK

# Redact the report in RAW into REPORT, then check the result. Fails (1),
# saying why on stderr, if the filter errors, if its output is empty, not
# the same number of lines, or much shorter than the input, or if the check
# still finds something to redact.
redact_report() {
    local terms raw_lines out_lines v ids
    terms="$(redaction_terms)"
    if ! REPORT="$(printf '%s\n' "$RAW" | EOSWC_REDACT_MODE=redact EOSWC_REDACT_TERMS="$terms" LC_ALL=C awk "$REDACT_AWK")"; then
        echo "the redaction filter failed" >&2
        return 1
    fi
    raw_lines="$(printf '%s\n' "$RAW" | wc -l | tr -d ' ')"
    out_lines="$(printf '%s\n' "$REPORT" | wc -l | tr -d ' ')"
    if [ -z "$REPORT" ] || [ "$out_lines" != "$raw_lines" ] ||
       [ "${#REPORT}" -lt $((${#RAW} / 3)) ] ||
       ! printf '%s\n' "$REPORT" | grep -qF "===== end of report ====="; then
        echo "the redacted report came out empty or cut short ($out_lines of $raw_lines lines)" >&2
        return 1
    fi
    if ! printf '%s\n' "$REPORT" | EOSWC_REDACT_MODE=check EOSWC_REDACT_TERMS="$terms" LC_ALL=C awk "$REDACT_AWK"; then
        return 1
    fi
    # Belt and braces, without awk: the home path and the Mac's serial and
    # hardware UUID must be gone.
    ids="$(printf '%s\n' "$HOME"
           ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null |
               awk -F'"' '$2 == "IOPlatformSerialNumber" || $2 == "IOPlatformUUID" { print $4 }')"
    while IFS= read -r v; do
        [ "${#v}" -ge 5 ] || continue
        if printf '%s\n' "$REPORT" | grep -qiF -- "$v"; then
            echo "redaction check: the home path, serial number or hardware UUID is still in the report" >&2
            return 1
        fi
    done <<< "$ids"
    return 0
}

# The whole report, unredacted. Only ever captured into RAW (memory).
build_report() {
echo "===== EOS Webcam Utility — Diagnostic Report ====="
date -u   # UTC, so the report doesn't reveal your timezone/region
echo "(Redacted automatically: username, real name, home folder, computer name,"
echo " serial numbers, UUIDs, IP/MAC/email addresses. Read it before posting.)"

echo; echo "----- macOS / hardware -----"
sw_vers
echo "arch: $(uname -m)"
csrutil status 2>/dev/null || echo "csrutil unavailable"

# ls -n: numeric owners. Names would show other accounts on this Mac (the
# EDSDK framework is owned by whoever ran Canon's installer).
echo; echo "----- Is the plug-in installed? -----"
ls -lan "$(dirname "$PLUGIN")/" 2>&1

echo; echo "----- Plug-in code signature -----"
echo "(with the fork installed the executable is signed 'adhoc'; after an uninstall from a"
echo " full backup (installers after v1.4.2) it is Canon's again, TeamIdentifier=$EOSWC_CANON_TEAM)"
codesign -dv --verbose=4 "$PLUGIN/Contents/MacOS/EOSWebcamUtility" 2>&1
echo "-- bundle verify (informational only) --"
echo "NOTE: 'a sealed resource is missing or invalid' here is EXPECTED and harmless —"
echo "the camera-manager swaps the loading-screen image inside the bundle after signing."
echo "It is NOT the cause of the camera failing to appear."
codesign --verify --deep --strict -vv "$PLUGIN" 2>&1

echo; echo "----- Service and EWCProxy signatures -----"
echo "(installed by the fork: ad hoc, flags=0x10002(adhoc,runtime), with Canon's camera"
echo " entitlement and disable-library-validation, which lets them load Canon's EDSDK;"
echo " Canon's own, e.g. after uninstall: flags=0x10000(runtime), team=$EOSWC_CANON_TEAM)"
for h in EOSWebcamService EWCProxy; do
    info="$(codesign -dv "$PLUGIN/Contents/Resources/$h" 2>&1)" || true
    flags="$(printf '%s\n' "$info" | sed -n 's/^CodeDirectory .*flags=\([^ ]*\).*/\1/p' | head -1)"
    team="$(printf '%s\n' "$info" | sed -n 's/^TeamIdentifier=//p' | head -1)"
    ents="$(codesign -d --entitlements - "$PLUGIN/Contents/Resources/$h" 2>&1 |
            grep -oE 'com\.apple\.security\.[a-z.-]+' | sort -u | tr '\n' ' ')" || true
    echo "$h: flags=${flags:-unsigned or missing} team=${team:-none} entitlements: ${ents:-none}"
done
# Only counts: crash reports hold paths and names. A helper that can't load
# EDSDK (library validation) dies at launch, before it logs anything itself.
CRASH_DIR="$HOME/Library/Logs/DiagnosticReports"
CRASHES=0
SIGN_CRASHES=0
if [ -d "$CRASH_DIR" ]; then
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        CRASHES=$((CRASHES + 1))
        if grep -qiE 'Team IDs|library validation|not valid for use in process|CODESIGNING|Library missing' "$f" 2>/dev/null; then
            SIGN_CRASHES=$((SIGN_CRASHES + 1))
        fi
    done < <(find "$CRASH_DIR" -maxdepth 1 -type f \( -name 'EOSWebcamService*' -o -name 'EWCService*' -o -name 'EWCProxy*' \) -mtime -7 2>/dev/null)
fi
echo "crash reports of the service or EWCProxy in the last 7 days: $CRASHES ($SIGN_CRASHES about code signing or library loading)"

echo; echo "----- Quarantine flags -----"
echo "(a quarantine flag on a .jpg image is harmless; one on the .plugin bundle or its"
echo " executables would block loading — that is the one that matters)"
xattr -lr "$PLUGIN" 2>&1 | grep -i quarantine || echo "no quarantine attribute anywhere (good)"

echo; echo "----- EDSDK framework present? -----"
ls -lan "/Library/Frameworks/EDSDK.framework" 2>&1 | head -5

echo; echo "----- Services loaded? -----"
# Matched on the label column only ("eos" alone also matches com.apple.videos...).
EWC_JOBS="$(launchctl list 2>/dev/null | awk 'tolower($3) ~ /canon|ewc|eos-camera|eoswebcam/')"
if [ -n "$EWC_JOBS" ]; then printf '%s\n' "$EWC_JOBS"; else echo "no EWC/EOS services loaded"; fi
echo "-- running? (from the PID column of launchctl list) --"
job_status "$EOSWC_CANON_LABEL"
job_status "$EOSWC_AGENT_LABEL"
echo "-- processes --"
pgrep -fl "EOSWebcam|EWCProxy|EWCService|eos-camera-manager" 2>/dev/null |
    grep -E '(^[0-9]+ |/)(EOSWebcamService|EWCProxy|EWCPairingService|EWCService|EWCCameraExtension)( |$)|eos-camera-manager\.sh' ||
    echo "no service processes running"

echo; echo "----- Camera manager install -----"
echo "expected daemon: $EOSWC_RUNTIME_DIR/eos-camera-manager.sh"
if [ -f "$AGENT_PLIST" ]; then
    DAEMON="$(eoswc_agent_daemon_path "$AGENT_PLIST")"
    echo "LaunchAgent runs: ${DAEMON:-<no eos-camera-manager.sh in LaunchAgent>}"
    if [ -n "$DAEMON" ] && [ ! -f "$DAEMON" ]; then
        echo "[WARN] that daemon file does not exist — re-run the installer."
    fi
    if [ -n "$DAEMON" ] && [ "$DAEMON" != "$EOSWC_RUNTIME_DIR/eos-camera-manager.sh" ]; then
        echo "[WARN] LaunchAgent points at an old install location — re-run the installer."
    fi
    case "$DAEMON" in
        "$HOME/Downloads/"*|"$HOME/Desktop/"*|"$HOME/Documents/"*|"$HOME/Library/Mobile Documents/"*)
            echo "[WARN] that is a privacy-protected folder: launchd can't run it (exit 126)." ;;
    esac
else
    echo "LaunchAgent: not installed ($AGENT_PLIST missing)"
fi

echo; echo "----- Old camera manager ($EOSWC_LEGACY_LABEL) -----"
if [ -e "$EOSWC_LEGACY_PLIST" ]; then
    if LEGACY_PROG="$(eoswc_legacy_agent_matches "$EOSWC_LEGACY_PLIST")"; then
        echo "[WARN] the old camera manager LaunchAgent of the fork is still installed:"
        echo "       $EOSWC_LEGACY_PLIST runs $LEGACY_PROG"
        echo "       It fights the current camera manager. Re-run the installer (or"
        echo "       uninstall.sh), which removes it."
    else
        echo "$EOSWC_LEGACY_PLIST exists but does not run the old fork"
        echo "canon-camera-manager.sh, so it is not from the fork (left alone)."
    fi
    job_status "$EOSWC_LEGACY_LABEL"
else
    echo "not installed (good)"
fi

# (No "X's " possessives in this section: the name redaction mangles them.)
echo; echo "----- Canon Camera Extension -----"
echo "(The Canon v1.3.16 package also ships a Camera Extension, $EOSWC_CAMEXT_ID."
echo " On macOS 14+ the Canon installer asks you to approve it; once approved, apps"
echo " list a second 'EOS Webcam Utility' camera, which the fork does not patch.)"
if [ -d "$CANON_APPS/$EOSWC_CAMEXT_HOST" ]; then
    echo "host app: $CANON_APPS/$EOSWC_CAMEXT_HOST (installed)"
else
    echo "host app: not installed"
fi
CAMEXT_STATE="$(eoswc_camera_extension_state)"
echo "state (systemextensionsctl): $CAMEXT_STATE"
case "$CAMEXT_STATE" in
    *"waiting for user"*)
        echo "[INFO] installed but not approved: no second camera. Approving it is optional." ;;
    *enabled*)
        echo "[INFO] approved: expect two 'EOS Webcam Utility' cameras in apps." ;;
esac
if [ "$CAMEXT_STATE" != "not registered" ] && [ "$CAMEXT_STATE" != unknown ]; then
    eoswc_camera_extension_removal_help ""
fi

echo; echo "----- Camera manager files and Canon config -----"
echo "(the files of the fork and Canon's config files only: Canon's logs and data in this"
echo " folder can hold camera serial numbers and names, so they are only counted)"
runtime_files_report

echo; echo "----- Canon camera on USB? -----"
canon_usb_report

echo; echo "----- Cameras macOS can see -----"
echo "(the virtual 'EOS Webcam Utility' camera should appear here if the plug-in loaded)"
CAMS="$(system_profiler SPCameraDataType 2>&1)"
# Camera names only: Model ID / Unique ID are device fingerprints.
CAM_NAMES="$(printf '%s\n' "$CAMS" | awk '/^    [^ ].*:[ \t]*$/ { sub(/^ +/, ""); sub(/:[ \t]*$/, ""); print "  " $0 }')"
if [ -n "$CAM_NAMES" ]; then printf '%s\n' "$CAM_NAMES"; else echo "  (none listed)"; fi

echo; echo "----- Recent log messages from Canon's software (last 10 min, UTC) -----"
echo "(Canon's own processes, and security messages about the plug-in)"
recent_logs

echo; echo "----- Camera manager log (last 30 lines) -----"
tail -30 "$HOME/Library/Logs/eos-camera-manager.log" 2>/dev/null || echo "no manager log found"
echo "-- launchd stderr for the camera manager (last 10 lines) --"
echo "(\"Operation not permitted\" here means launchd can't read the folder the daemon is in)"
tail -10 "$HOME/Library/Logs/eos-camera-manager-stderr.log" 2>/dev/null || echo "no stderr log found"

echo; echo "===== VERDICT ====="
if echo "$CAMS" | grep -q "EOS Webcam Utility"; then
    echo "[PASS] macOS CAN see the 'EOS Webcam Utility' virtual camera — the plug-in IS loading."
    echo "       If it still doesn't show in a specific app, that app is likely refusing to load"
    echo "       third-party DAL plug-ins. Try a different app (e.g. Zoom, OBS) to confirm,"
    echo "       and make sure the EWCService process above is running so it sends video."
else
    echo "[FAIL] macOS does NOT see the virtual camera — the plug-in is not loading."
    echo "       Most likely: it isn't installed, or wasn't (re)installed after a macOS upgrade."
    echo "       Fix: re-run the installer ->  bash dist/v1.4/install.sh"
    echo "       Then reboot and run this diagnostic again."
fi
if [ "$SIGN_CRASHES" -gt 0 ]; then
    echo "[WARN] EOSWebcamService or EWCProxy crashed with a code-signing or library-loading"
    echo "       error ($SIGN_CRASHES crash report(s), see 'Service and EWCProxy signatures')."
    echo "       Please open an issue with this report. uninstall.sh puts Canon's signed"
    echo "       plug-in back."
fi
if ! eoswc_job_running "$EOSWC_AGENT_LABEL"; then
    echo "[WARN] The camera manager isn't running, so auto-retry and the loading screens"
    echo "       won't work. See 'Camera manager install' above; re-running the installer"
    echo "       puts it in $EOSWC_RUNTIME_DIR/."
fi
echo "===== end of report ====="
}

RAW="$(build_report 2>&1)"

# Nothing unredacted is ever written to disk: the report is redacted in
# memory, checked, written to a temp file next to the report, and only then
# moved into place.
REPORT=""
if ! redact_report; then
    RAW=""; REPORT=""
    rm -f "$OUT"
    echo "ERROR: the report could not be redacted safely, so no report was written"
    echo "       (and any older one at $OUT was removed)."
    echo "       Please open a GitHub issue saying that diagnose.sh failed to redact,"
    echo "       with your macOS version, but without the report."
    exit 1
fi
RAW=""
TMP_OUT=""
cleanup() { [ -z "$TMP_OUT" ] || rm -f "$TMP_OUT"; }
trap cleanup EXIT
if ! TMP_OUT="$(mktemp "$OUT.XXXXXX")" ||
   ! printf '%s\n' "$REPORT" > "$TMP_OUT" ||
   ! mv -f "$TMP_OUT" "$OUT"; then
    echo "ERROR: could not write the report to $OUT"
    exit 1
fi
TMP_OUT=""

echo "Report written to: $OUT"
echo ""
echo "Redacted automatically: your username, real name, home folder path, computer"
echo "and host name, serial numbers, hardware UUIDs, IP and MAC addresses and email"
echo "addresses. Canon's own log files and your other USB devices are left out."
echo ""
echo "REVIEW BEFORE POSTING: GitHub issues are public. Read the whole report first:"
echo "redaction is automatic and can miss something (a nickname in a camera or"
echo "network name, say). Replace anything private with <redacted>, then paste it"
echo "into the GitHub issue."
