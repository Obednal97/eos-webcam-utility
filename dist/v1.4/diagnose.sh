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

# --- Build privacy redaction rules (so the report is safe to paste publicly) ---
# Redacts: the login username, the account holder's real name, and any
# possessive device names like "Ollie's iPhone" (including other people's
# devices that appear via Continuity Camera).
USERNAME="$(whoami)"
FULLNAME="$(id -F 2>/dev/null)"
REDACT=(-E -e "s/${USERNAME}/<username redacted>/g")
# Generic "<Name>'s " device pattern (straight and curly apostrophes).
REDACT+=(-e "s/[[:alpha:]][[:alpha:]]*['’]s /<name redacted>'s /g")
# Each token of the account holder's real name, word-boundary anchored
# (BSD/macOS sed) so it won't mangle unrelated words.
for tok in $FULLNAME; do
    [ "${#tok}" -ge 2 ] && REDACT+=(-e "s/[[:<:]]${tok}[[:>:]]/<name redacted>/g")
done

{
echo "===== EOS Webcam Utility — Diagnostic Report ====="
date -u   # UTC, so the report doesn't reveal your timezone/region

echo; echo "----- macOS / hardware -----"
sw_vers
echo "arch: $(uname -m)"
csrutil status 2>/dev/null || echo "csrutil unavailable"

echo; echo "----- Is the plug-in installed? -----"
ls -la "/Library/CoreMediaIO/Plug-Ins/DAL/" 2>&1

echo; echo "----- Plug-in code signature -----"
echo "(the executable should be present and signed 'adhoc' — the fork's default — or"
echo " with a Developer ID if you installed with --sign-identity)"
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

echo; echo "----- Camera Extension registered? -----"
echo "(Canon's software also ships a modern Camera Extension,"
echo " com.canon.cusa.eoswebcam.cameraExtension. On machines where the virtual"
echo " camera works, enumeration goes through this extension, so its absence"
echo " or a disabled state here is significant — see GitHub issue #3.)"
SYSEXT="$(systemextensionsctl list 2>&1)"
echo "$SYSEXT" | grep -iE "canon|eoswebcam" || echo "no Canon entry in systemextensionsctl list"
pluginkit -m -v -i com.canon.cusa.eoswebcam.cameraExtension 2>/dev/null \
  || echo "no pluginkit registration for com.canon.cusa.eoswebcam.cameraExtension"

echo; echo "----- EDSDK framework present? -----"
ls -la "/Library/Frameworks/EDSDK.framework" 2>&1 | head -5

echo; echo "----- Services loaded? -----"
launchctl list 2>/dev/null | grep -iE "ewc|eos|canon" || echo "no EWC/EOS services loaded"
echo "-- processes --"
pgrep -fl "EOSWebcam|EWCProxy|EWCService" || echo "no service processes running"
echo "-- service detail --"
SVCDETAIL="$(launchctl print "gui/$(id -u)/com.canon.usa.EWCService" 2>/dev/null \
  | grep -E "state|pid|last exit|path|program" | head -8)"
echo "${SVCDETAIL:-launchctl print unavailable for com.canon.usa.EWCService}"

echo; echo "----- Recent crashes? -----"
echo "(rules out / confirms the service or proxy crashing)"
CRASHES="$(ls -lt "$HOME/Library/Logs/DiagnosticReports/" 2>/dev/null \
  | grep -iE "EOSWebcam|EWCProxy|EWCService|EWCPairing" | head -10)"
echo "${CRASHES:-no EWC/EOSWebcam crash reports}"

echo; echo "----- Security management state -----"
spctl --status 2>&1
profiles status -type enrollment 2>/dev/null || echo "profiles status unavailable without admin (fine to skip)"

echo; echo "----- Config present? -----"
ls -la "$HOME/Library/Application Support/EWCService/" 2>&1

echo; echo "----- Canon camera on USB? -----"
system_profiler SPUSBDataType 2>/dev/null | grep -iA3 canon || echo "No Canon device on USB"

echo; echo "----- Cameras macOS can see -----"
echo "(the virtual 'EOS Webcam Utility' camera should appear here if the plug-in loaded)"
CAMS="$(system_profiler SPCameraDataType 2>&1)"
# Show only the camera names (device fingerprints like Model ID / Unique ID
# aren't needed for the diagnostic and are stripped for privacy). Names are
# already run through the redaction filter at the end.
echo "$CAMS" | grep -vE "Model ID:|Unique ID:"

echo; echo "----- Recent plug-in load logs (last 10 min) -----"
LOGS="$(log show --last 10m --predicate \
  'process == "amfid" OR eventMessage CONTAINS[c] "EOSWebcam" OR eventMessage CONTAINS[c] "CoreMediaIO" OR eventMessage CONTAINS[c] "DAL plug" OR eventMessage CONTAINS[c] "library validation" OR eventMessage CONTAINS[c] "code signature"' \
  2>/dev/null | tail -60)"
echo "${LOGS:-no relevant log entries}"

echo; echo "----- Camera manager log (last 30 lines) -----"
tail -30 "$HOME/Library/Logs/eos-camera-manager.log" 2>/dev/null || echo "no manager log found"

echo; echo "===== VERDICT ====="
if echo "$CAMS" | grep -q "EOS Webcam Utility"; then
    echo "[PASS] macOS CAN see the 'EOS Webcam Utility' virtual camera."
    if echo "$LOGS" | grep -q "com.canon.cusa.eoswebcam.cameraExtension"; then
        echo "       Enumeration went through Canon's modern Camera Extension"
        echo "       (com.canon.cusa.eoswebcam.cameraExtension), not the legacy DAL plug-in."
    fi
    echo "       If it still doesn't show in a specific app, that app is likely refusing to load"
    echo "       third-party DAL plug-ins. Try a different app (e.g. Zoom, OBS) to confirm,"
    echo "       and make sure the EWCService process above is running so it sends video."
elif [ ! -d "$PLUGIN" ]; then
    echo "[FAIL] The plug-in is NOT installed (nothing at $PLUGIN)."
    echo "       Fix: run the installer ->  bash dist/v1.4/install.sh"
    echo "       Then reboot and run this diagnostic again."
elif echo "$LOGS" | grep -qiE "AMFI: code signature validation failed|adhoc signed or signed by an unknown certificate chain|library validation failed"; then
    echo "[FAIL] The plug-in IS installed and its files look correct, but macOS refused to"
    echo "       load it: the system log shows code-signature (AMFI) rejections of ad-hoc"
    echo "       signed code around the time the camera list was opened."
    echo "       Re-running the installer will NOT fix this — the files on disk are fine;"
    echo "       it is the OS signing policy that is blocking them."
    echo "       This has been reported starting with macOS 26.5.2 (see GitHub issue #3:"
    echo "       https://github.com/Obednal97/eos-webcam-utility/issues/3). Please add"
    echo "       your macOS version ('sw_vers' output) to that issue so affected"
    echo "       versions can be tracked."
    echo "       If you have an Apple Developer account, re-installing with your own"
    echo "       signing identity should satisfy the OS policy:"
    echo "         bash dist/v1.4/install.sh --sign-identity 'Developer ID Application: <you>'"
    echo "       Please report on issue #3 whether that fixes it for you."
else
    echo "[FAIL] macOS does NOT see the virtual camera — the plug-in is not loading."
    echo "       Check the 'Camera Extension registered?' section above: if Canon's"
    echo "       Camera Extension is missing or disabled, enable it in System Settings"
    echo "       -> General -> Login Items & Extensions -> Camera (or reinstall and"
    echo "       approve the prompt), then reboot and re-run this diagnostic."
    echo "       Otherwise: re-run the installer ->  bash dist/v1.4/install.sh"
    echo "       Then reboot and run this diagnostic again."
fi
echo "===== end of report ====="
} 2>&1 | sed "${REDACT[@]}" > "$OUT"

echo "Report written to: $OUT"
echo "(your username, real name, and device names have been redacted —"
echo " still give it a quick skim before pasting)"
echo "Open it, check there's nothing private, then paste it into the GitHub issue."
