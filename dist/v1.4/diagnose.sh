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
#   - Whether the config files exist
#   - Whether your Canon camera is seen on USB
#   - Which cameras macOS itself can see (the virtual cam should appear here
#     if the plug-in loaded correctly)
#   - Recent system logs about the plug-in loading (or failing to load)
#   - The camera manager's own log
#
# Usage:
#   1. Open QuickTime Player -> File -> New Movie Recording, then click the
#      small down-arrow next to the record button to show the camera list.
#      (This forces macOS to try loading the plug-in, so the logs are fresh.)
#   2. Run this script:  bash diagnose.sh
#   3. A report is written to your Desktop. Skim it for anything private,
#      then paste it into the GitHub issue.
#

OUT="$HOME/Desktop/eos-webcam-diagnostics.txt"
PLUGIN="/Library/CoreMediaIO/Plug-Ins/DAL/EOSWebcamUtility.plugin"

{
echo "===== EOS Webcam Utility — Diagnostic Report ====="
date

echo; echo "----- macOS / hardware -----"
sw_vers
echo "arch: $(uname -m)"
csrutil status 2>/dev/null || echo "csrutil unavailable"

echo; echo "----- Is the plug-in installed? -----"
ls -la "/Library/CoreMediaIO/Plug-Ins/DAL/" 2>&1

echo; echo "----- Plug-in code signature -----"
echo "(the executable should be present and signed 'adhoc'; that is expected for this fork)"
codesign -dv --verbose=4 "$PLUGIN/Contents/MacOS/EOSWebcamUtility" 2>&1
echo "-- bundle verify (informational only) --"
echo "NOTE: 'a sealed resource is missing or invalid' here is EXPECTED and harmless —"
echo "the camera-manager swaps the loading-screen image inside the bundle after signing."
echo "It is NOT the cause of the camera failing to appear."
codesign --verify --deep --strict -vv "$PLUGIN" 2>&1

echo; echo "----- Quarantine flags -----"
echo "(a quarantine flag on a .jpg image is harmless; one on the .plugin bundle or its"
echo " executables would block loading — that is the one that matters)"
xattr -lr "$PLUGIN" 2>&1 | grep -i quarantine || echo "no quarantine attribute anywhere (good)"

echo; echo "----- EDSDK framework present? -----"
ls -la "/Library/Frameworks/EDSDK.framework" 2>&1 | head -5

echo; echo "----- Services loaded? -----"
launchctl list 2>/dev/null | grep -iE "ewc|eos|canon" || echo "no EWC/EOS services loaded"
echo "-- processes --"
pgrep -fl "EOSWebcam|EWCProxy|EWCService" || echo "no service processes running"

echo; echo "----- Config present? -----"
ls -la "$HOME/Library/Application Support/EWCService/" 2>&1

echo; echo "----- Canon camera on USB? -----"
system_profiler SPUSBDataType 2>/dev/null | grep -iA3 canon || echo "No Canon device on USB"

echo; echo "----- Cameras macOS can see -----"
echo "(the virtual 'EOS Webcam Utility' camera should appear here if the plug-in loaded)"
CAMS="$(system_profiler SPCameraDataType 2>&1)"
echo "$CAMS"

echo; echo "----- Recent plug-in load logs (last 10 min) -----"
log show --last 10m --predicate \
  'eventMessage CONTAINS[c] "EOSWebcam" OR eventMessage CONTAINS[c] "CoreMediaIO" OR eventMessage CONTAINS[c] "DAL plug" OR eventMessage CONTAINS[c] "library validation" OR eventMessage CONTAINS[c] "code signature"' \
  2>/dev/null | tail -60 || echo "no relevant log entries"

echo; echo "----- Camera manager log (last 30 lines) -----"
tail -30 "$HOME/Library/Logs/eos-camera-manager.log" 2>/dev/null || echo "no manager log found"

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
echo "===== end of report ====="
} > "$OUT" 2>&1

echo "Report written to: $OUT"
echo "Open it, check there's nothing private, then paste it into the GitHub issue."
