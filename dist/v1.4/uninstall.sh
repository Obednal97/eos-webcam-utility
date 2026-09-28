#!/bin/bash
#
# EOS Webcam Utility Fork v1.4 — Uninstaller
#
# Restores the original EOS Webcam Utility v1.3.16 files
# and removes the camera manager daemon.
#

set -e

PLUGIN_DIR="/Library/CoreMediaIO/Plug-Ins/DAL/EOSWebcamUtility.plugin"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
USER_HOME="$HOME"
# Match install.sh: the clone this script was run from (repo root).
INSTALL_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
LAUNCH_AGENTS="$USER_HOME/Library/LaunchAgents"
if [ ! -f "$SCRIPT_DIR/common.sh" ]; then
    echo "ERROR: common.sh not found next to this script."
    exit 1
fi
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"
# Canon's config dir, which is also where install.sh puts the daemon.
SUPPORT_DIR="$EOSWC_RUNTIME_DIR"
LAUNCH_AGENT_SYS="/Library/LaunchAgents/com.canon.usa.EWCService.plist"

# A backup is restorable if it holds all three binaries and they are Canon's
# originals. Two things produce backups that aren't: an install that hit the
# privacy-protected-folder bug (empty backup), and re-running the installer
# over the fork (it snapshots the already-patched binaries). The check reads
# the same EOSWebcamService offset install.sh uses to detect a fork install;
# the original bytes there are 00c14339, the fork's are 20008052.
backup_restorable() {
    local d="$1" f marker
    for f in EOSWebcamUtility EOSWebcamService EWCProxy; do
        [ -s "$d/$f" ] || return 1
    done
    marker=$(od -An -tx1 -j $((0x89b58)) -N4 "$d/EOSWebcamService" 2>/dev/null | tr -d ' \n')
    [ "$marker" = "00c14339" ]
}

echo "============================================"
echo "  EOS Webcam Utility Fork — Uninstaller"
echo "============================================"
echo ""

# Pick the most recent restorable backup. This runs before anything is
# stopped or removed, so a bad backup leaves the install exactly as it was.
BACKUP_DIR=""
SKIPPED=0
while IFS= read -r d; do
    if backup_restorable "$d"; then
        BACKUP_DIR="$d"
        break
    fi
    echo "Skipping backup without Canon's original binaries: $d"
    SKIPPED=$((SKIPPED + 1))
done < <(ls -dt "$INSTALL_DIR/backups/pre-v"* 2>/dev/null)

if [ -z "$BACKUP_DIR" ]; then
    if [ "$SKIPPED" -gt 0 ]; then
        echo "ERROR: No backup in $INSTALL_DIR/backups/ holds Canon's original binaries."
    else
        echo "ERROR: No backup found in $INSTALL_DIR/backups/."
    fi
    echo "Nothing was changed. To get Canon's originals back, reinstall"
    echo "EOS Webcam Utility v1.3.16 from:"
    echo "  https://downloads.canon.com/webcam/EOSWebcamUtility-MAC1.3.16.pkg.zip"
    exit 1
fi

echo "Restoring from backup: $BACKUP_DIR"
echo ""

# If the admin step is cancelled or fails, the fork's binaries are still in
# place: restart the services so the camera keeps working.
SERVICES_STOPPED=0
RESTORED=0
STAGE=""
on_exit() {
    [ -n "$STAGE" ] && rm -rf "$STAGE" 2>/dev/null
    if [ "$SERVICES_STOPPED" = 1 ] && [ "$RESTORED" != 1 ]; then
        echo ""
        echo "  Uninstall did not finish — restarting services so the camera keeps"
        echo "  working. Nothing was restored; re-run the uninstaller to try again."
        launchctl load "$LAUNCH_AGENT_SYS" 2>/dev/null || true
        launchctl load "$LAUNCH_AGENTS/com.eos-camera-manager.plist" 2>/dev/null || true
    fi
    return 0
}
trap on_exit EXIT

# Stop services
echo "[1/4] Stopping services..."
launchctl unload "$LAUNCH_AGENTS/com.eos-camera-manager.plist" 2>/dev/null || true
launchctl unload "$LAUNCH_AGENT_SYS" 2>/dev/null || true
SERVICES_STOPPED=1
sleep 1

# Restore binaries
echo "[2/4] Restoring original binaries (admin required)..."
# The elevated shell osascript spawns has no TCC access to user folders
# (~/Downloads, ~/Desktop, ~/Documents, iCloud Drive...), so it cannot read the
# backup where it sits — "Operation not permitted", even as root. Stage the
# files through the temp dir, which is outside TCC's reach.
STAGE="$(mktemp -d -t eoswc-restore)"
for f in EOSWebcamUtility EOSWebcamService EWCProxy errorNoDevice.jpg errorBusy.jpg default.jpg; do
    cp "$BACKUP_DIR/$f" "$STAGE/$f" 2>/dev/null || true
done
for f in EOSWebcamUtility EOSWebcamService EWCProxy; do
    if [ ! -s "$STAGE/$f" ]; then
        echo "ERROR: backup is missing $f — cannot restore."
        exit 1
    fi
done
osascript -e "do shell script \"
cp '$STAGE/EOSWebcamUtility' '$PLUGIN_DIR/Contents/MacOS/EOSWebcamUtility'
cp '$STAGE/EOSWebcamService' '$PLUGIN_DIR/Contents/Resources/EOSWebcamService'
cp '$STAGE/EWCProxy' '$PLUGIN_DIR/Contents/Resources/EWCProxy'
cp '$STAGE/errorNoDevice.jpg' '$PLUGIN_DIR/Contents/Resources/errorNoDevice.jpg' 2>/dev/null
cp '$STAGE/errorBusy.jpg' '$PLUGIN_DIR/Contents/Resources/errorBusy.jpg' 2>/dev/null
cp '$STAGE/default.jpg' '$PLUGIN_DIR/Contents/Resources/default.jpg' 2>/dev/null
codesign --force --sign - '$PLUGIN_DIR/Contents/MacOS/EOSWebcamUtility'
codesign --force --sign - '$PLUGIN_DIR/Contents/Resources/EOSWebcamService'
codesign --force --sign - '$PLUGIN_DIR/Contents/Resources/EWCProxy'
codesign --force --deep --sign - '$PLUGIN_DIR'
\" with administrator privileges"
RESTORED=1

rm -rf "$STAGE"
STAGE=""
echo "  Original binaries restored"

# Restore configs. If the backup has none, Canon had never written one and
# the installer created it, so remove it and let Canon recreate its default.
echo "[3/4] Restoring original config..."
for f in config.plist proconfig.plist; do
    if [ -f "$BACKUP_DIR/$f" ]; then
        mkdir -p "$SUPPORT_DIR"
        cp "$BACKUP_DIR/$f" "$SUPPORT_DIR/$f"
    else
        rm -f "$SUPPORT_DIR/$f"
    fi
done

# Remove daemon
echo "[4/4] Removing camera manager..."
OLD_DAEMON="$(eoswc_agent_daemon_path "$LAUNCH_AGENTS/com.eos-camera-manager.plist")"
rm -f "$LAUNCH_AGENTS/com.eos-camera-manager.plist"
# The daemon, its images and generate-images.sh live in Application Support
# (see install.sh: launchd can't read the clone if it sits in ~/Downloads and
# friends), next to Canon's config. Remove only what the installer put there,
# plus the logo the README says to add; leave anything else alone.
for f in $EOSWC_RUNTIME_FILES $EOSWC_LOGO_FILES; do
    if [ -f "$SUPPORT_DIR/$f" ]; then
        rm -f "$SUPPORT_DIR/$f"
        echo "  Removed $SUPPORT_DIR/$f"
    fi
done
rmdir "$SUPPORT_DIR" 2>/dev/null || true
# Installs from before that ran the daemon out of the clone.
if [ -n "$OLD_DAEMON" ]; then
    eoswc_remove_legacy_runtime "$(dirname "$OLD_DAEMON")"
fi
eoswc_remove_legacy_runtime "$INSTALL_DIR"

# Restart original service
launchctl load "$LAUNCH_AGENT_SYS" 2>/dev/null || true

echo ""
echo "============================================"
echo "  Uninstall complete."
echo "  Original EOS Webcam Utility v1.3.16 restored."
echo "  Backups preserved at: $INSTALL_DIR/backups/"
echo "============================================"
