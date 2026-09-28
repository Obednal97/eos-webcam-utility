#!/bin/bash
#
# EOS Webcam Utility Fork — frame rate measurement (read-only)
#
# Measures what the "EOS Webcam Utility" camera really delivers: the formats
# and frame rates it advertises to apps, the format ffmpeg negotiates, and
# over a short capture the ACTUAL frame rate, the spacing between frames, and
# how many frames are new pictures rather than repeats of the one before.
#
# It only reads: it installs nothing, changes nothing, needs no admin rights
# and saves no images. Frames are hashed (ffmpeg's framemd5) as they arrive
# and thrown away; only numbers are printed. Other cameras' names are not
# printed. Temp files (ffmpeg's text output) are deleted when it ends.
#
# Needs ffmpeg (e.g. `brew install ffmpeg`; this script won't install it) and
# python3. The first run from a terminal app makes macOS ask whether that
# app may use the camera: allow it, then run this again.
#
# Connect and switch on the camera first, and wait until an app (or Photo
# Booth) shows the live picture: until the camera is connected, the fork
# shows a still loading screen, which measures as 0 new frames per second.
#
# Usage: bash measure-fps.sh [--seconds N] [--warmup N] [--device INDEX]
#   --seconds N     how long to measure (default 10)
#   --warmup N      seconds captured first and not counted (default 3)
#   --device INDEX  measure this AVFoundation video device index instead of
#                   every device called "EOS Webcam Utility"
#

set -euo pipefail

MEASURE=10
WARMUP=3
DEVICE=""
DEVICE_NAME="EOS Webcam Utility"
while [ $# -gt 0 ]; do
    case "$1" in
        --seconds) MEASURE="${2:-}"; shift 2 ;;
        --warmup) WARMUP="${2:-}"; shift 2 ;;
        --device) DEVICE="${2:-}"; shift 2 ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//' | sed -n '3,30p'; exit 0 ;;
        *) echo "Unknown option: $1 (see --help)"; exit 1 ;;
    esac
done
for v in "$MEASURE" "$WARMUP" ${DEVICE:+"$DEVICE"}; do
    case "$v" in ''|*[!0-9]*) echo "--seconds, --warmup and --device take a whole number"; exit 1 ;; esac
done
[ "$MEASURE" -ge 1 ] || { echo "--seconds must be at least 1"; exit 1; }

if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "ffmpeg is needed and isn't installed. Install it yourself (e.g. brew install ffmpeg),"
    echo "then run this again. Nothing was installed or changed."
    exit 2
fi
if ! python3 -c 'import sys' >/dev/null 2>&1; then
    echo "python3 is needed (xcode-select --install). Nothing was installed or changed."
    exit 2
fi

TMP="$(mktemp -d -t eoswc-fps)"
cleanup() {
    rm -f "$TMP/devices.txt" "$TMP/modes.txt" "$TMP/capture.err" "$TMP/frames.txt"
    rmdir "$TMP" 2>/dev/null || true
}
trap cleanup EXIT

# The whole analysis, in one place so the tests can feed it recorded output.
#   devices FILE NAME        -> indices of video devices called NAME
#   modes FILE               -> "W H MINFPS MAXFPS" per advertised mode
#   pick FILE                -> "W H FPS": 1920x1080 at its highest rate, else
#                               the biggest mode at its highest rate
#   report IDX MODES REQ ERR FRAMES WARMUP  -> the measurement report
analyse() {
    python3 - "$@" <<'PY'
import re
import statistics
import sys

cmd = sys.argv[1]
PREFIX = re.compile(r"^\[[^\]]*\] ?")


def lines(path):
    with open(path, errors="replace") as f:
        return [PREFIX.sub("", l.rstrip("\n")) for l in f]


def modes(path):
    out = []
    for l in lines(path):
        m = re.match(r"^\s*(\d+)x(\d+)@\[([\d.]+) ([\d.]+)\]fps", l)
        if m:
            out.append((int(m.group(1)), int(m.group(2)), float(m.group(3)), float(m.group(4))))
    return out


if cmd == "devices":
    video = False
    for l in lines(sys.argv[2]):
        if "AVFoundation video devices:" in l:
            video = True
        elif "AVFoundation audio devices:" in l:
            video = False
        elif video:
            m = re.match(r"^\[(\d+)\] (.*)$", l)
            if m and m.group(2).strip() == sys.argv[3]:
                print(m.group(1))
    sys.exit(0)

if cmd == "modes":
    for w, h, lo, hi in modes(sys.argv[2]):
        print(w, h, "%.6f" % lo, "%.6f" % hi)
    sys.exit(0)

if cmd == "pick":
    ms = modes(sys.argv[2])
    if not ms:
        sys.exit(1)
    full = [m for m in ms if (m[0], m[1]) == (1920, 1080)]
    if full:
        w, h, lo, hi = max(full, key=lambda m: m[3])
    else:
        w, h, lo, hi = max(ms, key=lambda m: (m[0] * m[1], m[3]))
    print(w, h, "%.6f" % hi)
    sys.exit(0)

# report
idx, modes_file, req, err_file, frames_file, warmup = sys.argv[2:8]
warmup = float(warmup)
ms = modes(modes_file)
rw, rh, rfps = req.split()
rfps = float(rfps)
print("  advertised modes (what apps are told):")
for w, h, lo, hi in ms:
    print("    %dx%d @ %.2f-%.2f fps" % (w, h, lo, hi))
adv_max = max([m[3] for m in ms if (m[0], m[1]) == (int(rw), int(rh))] or [rfps])
print("  requested: %sx%s @ %.2f fps (the highest this device advertises at that size)" % (rw, rh, rfps))

neg = None
for l in lines(err_file):
    if re.search(r"Stream #\d+:\d+.*: Video: ", l):
        after = l.split(": Video: ", 1)[1]
        fmt = re.match(r"[^,]*, ([a-z0-9_]+)", after)
        size = re.search(r"\b(\d{2,5})x(\d{2,5})\b", after)
        tbr = re.search(r"([\d.]+k?) tbr", after)
        neg = (fmt.group(1) if fmt else "?", size.group(1) if size else "?",
               size.group(2) if size else "?", tbr.group(1) if tbr else "?")
        break
if neg:
    print("  negotiated: %sx%s %s, %s fps (ffmpeg's tbr)" % (neg[1], neg[2], neg[0], neg[3]))
else:
    print("  negotiated: (ffmpeg printed no video stream line)")

tb_num, tb_den = 1, 1000000
frames = []
for l in lines(frames_file):
    if l.startswith("#tb 0:"):
        tb_num, tb_den = (int(x) for x in l.split(":", 1)[1].strip().split("/"))
    elif l and not l.startswith("#"):
        parts = [p.strip() for p in l.split(",")]
        if len(parts) >= 6 and parts[0] == "0":
            frames.append((int(parts[2]), parts[5]))
if len(frames) < 2:
    print("  measured: no frames arrived (see the ffmpeg errors above).")
    print("RESULT device=%s frames=0" % idx)
    sys.exit(3)
tb = tb_num / tb_den
start = frames[0][0] + warmup / tb
kept = [f for f in frames if f[0] >= start] if frames[-1][0] > start else frames
if len(kept) < 2:
    kept = frames
span = (kept[-1][0] - kept[0][0]) * tb
n = len(kept)
intervals = [(b[0] - a[0]) * tb * 1000 for a, b in zip(kept, kept[1:])]
delivered = (n - 1) / span if span > 0 else 0.0
new = 1 + sum(1 for a, b in zip(kept, kept[1:]) if a[1] != b[1])
unique_fps = (new - 1) / span if span > 0 else 0.0
run = longest = 1
for a, b in zip(kept, kept[1:]):
    run = run + 1 if a[1] == b[1] else 1
    longest = max(longest, run)
q = sorted(intervals)
p95 = q[min(len(q) - 1, int(round(0.95 * (len(q) - 1))))]
print("  measured over %.2f s (after %g s warm-up):" % (span, warmup))
print("    frames delivered:     %d" % n)
print("    delivered fps:        %.2f" % delivered)
print("    frame interval (ms):  mean %.2f  min %.2f  max %.2f  stdev %.2f  p95 %.2f"
      % (statistics.mean(intervals), q[0], q[-1], statistics.pstdev(intervals), p95))
print("    new pictures:         %d (%.2f per second)" % (new, unique_fps))
print("    repeated frames:      %d (longest run of one picture: %d frames)" % (n - new, longest))
if unique_fps < 1:
    verdict = ("only one picture the whole time: the camera isn't live yet (the fork's loading "
               "screen). Wait until an app shows the live picture, then run this again.")
else:
    bits = ["apps are told %.0f fps" % adv_max, "frames arrive at %.1f fps" % delivered]
    if unique_fps < 0.9 * delivered:
        bits.append("but only %.1f of them a second are new pictures" % unique_fps)
    else:
        bits.append("and %.1f a second are new pictures" % unique_fps)
    verdict = ", ".join(bits) + "."
    if delivered < 0.9 * adv_max:
        verdict += " Frames arrive slower than advertised."
    if unique_fps >= 0.95 * adv_max:
        verdict += (" New pictures arrive as fast as the advertised rate allows: the camera may"
                    " be able to send more. Please report this in an issue.")
print("  verdict: " + verdict)
print("RESULT device=%s advertised_fps=%.2f requested=%sx%s@%.2f negotiated=%s delivered_fps=%.2f "
      "new_fps=%.2f interval_ms_mean=%.2f interval_ms_max=%.2f frames=%d seconds=%.2f"
      % (idx, adv_max, rw, rh, rfps, ("%sx%s@%s" % (neg[1], neg[2], neg[3])) if neg else "unknown",
         delivered, unique_fps, statistics.mean(intervals), q[-1], n, span))
PY
}

echo "EOS Webcam Utility frame rate measurement (read-only: nothing is saved or changed)"
echo ""
ffmpeg -hide_banner -nostdin -f avfoundation -list_devices true -i "" > /dev/null 2> "$TMP/devices.txt" || true
if [ -n "$DEVICE" ]; then
    INDICES="$DEVICE"
else
    INDICES="$(analyse devices "$TMP/devices.txt" "$DEVICE_NAME")"
fi
if [ -z "$INDICES" ]; then
    echo "No video device called \"$DEVICE_NAME\" was found. Is the fork installed, and"
    echo "does it show up in an app? (--device INDEX measures another index.)"
    exit 1
fi
COUNT="$(printf '%s\n' "$INDICES" | wc -l | tr -d ' ')"
if [ "$COUNT" -gt 1 ]; then
    echo "$COUNT devices are called \"$DEVICE_NAME\" (the fork's DAL plug-in and Canon's"
    echo "Camera Extension, if approved). Measuring each."
    echo ""
fi

STATUS=0
for idx in $INDICES; do
    echo "device [$idx] $DEVICE_NAME"
    # Asking for an impossible size makes ffmpeg list the supported modes
    # and stop before capturing anything.
    ffmpeg -hide_banner -nostdin -f avfoundation -video_size 9999x9999 -i "$idx:none" \
        > /dev/null 2> "$TMP/modes.txt" || true
    if ! REQ="$(analyse pick "$TMP/modes.txt")"; then
        echo "  ffmpeg listed no modes for it:"
        grep -iE 'error|fail|denied|not ' "$TMP/modes.txt" | sed 's/^/    /' | head -5 || true
        STATUS=1
        continue
    fi
    read -r W H FPS <<< "$REQ"
    TOTAL=$((WARMUP + MEASURE))
    echo "  capturing $TOTAL s at ${W}x$H..."
    # -c copy: no decoding or re-timing, so the timestamps are the device's
    # own and repeated pictures hash the same. framemd5 prints one line per
    # frame: its timestamp and a hash of its pixels, nothing else.
    ffmpeg -hide_banner -nostdin -f avfoundation -video_size "${W}x$H" -framerate "$FPS" \
        -i "$idx:none" -t "$TOTAL" -map 0:v:0 -c copy -f framemd5 - \
        > "$TMP/frames.txt" 2> "$TMP/capture.err" || {
            echo "  ffmpeg stopped with an error:"
            grep -iE 'error|fail|denied|not ' "$TMP/capture.err" | sed 's/^/    /' | head -5 || true
        }
    analyse report "$idx" "$TMP/modes.txt" "$REQ" "$TMP/capture.err" "$TMP/frames.txt" "$WARMUP" || STATUS=1
    echo ""
done
exit "$STATUS"
