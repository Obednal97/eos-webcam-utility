#!/bin/bash
#
# EOS Webcam Utility Fork v1.4 — Uninstaller
#
# Restores the original EOS Webcam Utility v1.3.16 files from the newest
# backup that verifies as Canon's originals (in ~/Library/Application Support/
# EWCService/backups/, or backups/ in the clone for older installs), then
# removes the camera manager daemon. Backups are kept. If Canon's plug-in is
# gone already (Canon's own uninstaller removes it), there is nothing to
# restore, and only the fork's own pieces are removed.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCHER="$SCRIPT_DIR/patch-binaries.py"
USER_HOME="$HOME"
# The clone this script was run from (repo root). Earlier installers
# kept their backups here, under backups/.
INSTALL_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
LAUNCH_AGENTS="$USER_HOME/Library/LaunchAgents"
AGENT_PLIST="$LAUNCH_AGENTS/com.eos-camera-manager.plist"
if [ ! -f "$SCRIPT_DIR/common.sh" ]; then
    echo "ERROR: common.sh not found next to this script."
    exit 1
fi
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"
# The real plug-in path, unless a test sandbox says otherwise (see common.sh).
eoswc_select_plugin_dir || exit 1
PLUGIN_DIR="$EOSWC_PLUGIN"
# Canon's config dir, which is also where install.sh puts the daemon.
SUPPORT_DIR="$EOSWC_RUNTIME_DIR"
BACKUP_ROOT="$EOSWC_BACKUP_ROOT"
LAUNCH_AGENT_SYS="/Library/LaunchAgents/com.canon.usa.EWCService.plist"
if ! command -v python3 >/dev/null 2>&1 || [ ! -f "$PATCHER" ]; then
    echo "ERROR: python3 and patch-binaries.py (next to this script) are needed to"
    echo "       check the backup. Nothing was changed."
    exit 1
fi

echo "============================================"
echo "  EOS Webcam Utility Fork — Uninstaller"
echo "============================================"
echo ""

# Pick the most recent backup that really holds Canon's originals:
# patch-binaries.py --check-original matches each of the three binaries
# against Canon's v1.3.16 package by SHA-256 or, failing that, checks every
# patch offset and that the file isn't truncated. That rules out empty or partial backups
# (the privacy-protected-folder bug), backups of already-patched or partly
# patched binaries (re-running an older installer over the fork) and cut-off
# copies. This runs before anything is stopped or removed, so a bad backup
# leaves the install exactly as it was.
# Older installers ran the daemon out of the clone they were run from (maybe
# not this one) and kept their backups there; the LaunchAgent says which.
OLD_DAEMON="$(eoswc_agent_daemon_path "$AGENT_PLIST")"
OLD_CLONE="$(eoswc_old_clone_dir "$AGENT_PLIST")"
SEARCHED="$BACKUP_ROOT/ or $INSTALL_DIR/backups/"
[ -n "$OLD_CLONE" ] && SEARCHED="$BACKUP_ROOT/, $INSTALL_DIR/backups/ or $OLD_CLONE/backups/"
BACKUP_DIR=""
SKIPPED=0
while IFS= read -r d; do
    if why="$(python3 "$PATCHER" --check-original "$d" 2>&1)"; then
        BACKUP_DIR="$d"
        break
    fi
    echo "Skipping backup without Canon's original binaries: $d"
    printf '%s\n' "$why" | sed -n 's/^    - /    /p'
    SKIPPED=$((SKIPPED + 1))
done < <(eoswc_backup_candidates "$INSTALL_DIR" "$OLD_CLONE")

# Restore configs. If the backup has none, Canon had never written one and
# the installer created it, so remove it and let Canon recreate its default.
restore_config() {
    local f
    for f in config.plist proconfig.plist; do
        if [ -f "$BACKUP_DIR/$f" ]; then
            mkdir -p "$SUPPORT_DIR"
            cp "$BACKUP_DIR/$f" "$SUPPORT_DIR/$f"
        else
            rm -f "$SUPPORT_DIR/$f"
        fi
    done
}

# Remove the camera manager: its LaunchAgent (already unloaded), and the
# daemon files the installer put in Application Support or, for older
# installs, in a clone.
remove_camera_manager() {
    local f
    rm -f "$AGENT_PLIST"
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
    # Never the whole dir: it is Canon's, and it holds the backups (backups/),
    # which are kept so a restore can be repeated. rmdir only succeeds if empty.
    rmdir "$SUPPORT_DIR" 2>/dev/null || true
    # Installs from before that ran the daemon out of the clone.
    if [ -n "$OLD_DAEMON" ]; then
        eoswc_remove_legacy_runtime "$(dirname "$OLD_DAEMON")"
    fi
    eoswc_remove_legacy_runtime "$INSTALL_DIR"
}

# Canon's plug-in is gone: Canon's own uninstaller (or someone) removed it,
# but that leaves the fork's LaunchAgent and daemon behind, still running.
# There is nothing to restore into, so don't try: stop and remove the fork's
# pieces, keep the backups, and start nothing (Canon's service binary went
# with the plug-in, and the fork's daemon is what is being removed).
if [ ! -e "$PLUGIN_DIR" ]; then
    echo "Canon's EOS Webcam Utility plug-in is not installed:"
    echo "  $PLUGIN_DIR"
    echo "is missing (Canon's own uninstaller removes it). Nothing to restore, so this"
    echo "only removes the fork's camera manager and leaves the backups alone."
    echo ""
    echo "[1/2] Stopping the camera manager..."
    launchctl unload "$AGENT_PLIST" 2>/dev/null || true
    echo "[2/2] Removing camera manager..."
    # Canon's config, if a backup has it; without a backup, leave it be.
    [ -z "$BACKUP_DIR" ] || restore_config
    remove_camera_manager
    echo ""
    echo "============================================"
    echo "  Uninstall complete: the fork's camera manager is removed."
    echo "  Nothing was restored, because Canon's plug-in is not installed."
    if [ -n "$BACKUP_DIR" ]; then
        echo "  Backups kept (delete them yourself once you're happy):"
        echo "    $BACKUP_DIR"
    else
        echo "  No backup of Canon's original binaries was found in $SEARCHED."
    fi
    echo "============================================"
    exit 0
fi

if [ -z "$BACKUP_DIR" ]; then
    if [ "$SKIPPED" -gt 0 ]; then
        echo "ERROR: No backup in $SEARCHED"
        echo "       holds Canon's original binaries."
    else
        echo "ERROR: No backup found in $SEARCHED."
    fi
    echo "Nothing was changed. To get Canon's originals back, reinstall"
    echo "EOS Webcam Utility v1.3.16 from:"
    echo "  https://downloads.canon.com/webcam/EOSWebcamUtility-MAC1.3.16.pkg.zip"
    exit 1
fi

echo "Restoring from backup: $BACKUP_DIR"
echo ""

# If the admin step is cancelled or fails, say what state the plug-in is in
# and restart the services so the camera keeps working as far as it can.
SERVICES_STOPPED=0
RESTORE_STARTED=0
RESTORED=0
STAGE=""
on_exit() {
    [ -n "$STAGE" ] && rm -rf "$STAGE" 2>/dev/null
    if [ "$SERVICES_STOPPED" = 1 ] && [ "$RESTORED" != 1 ]; then
        echo ""
        echo "  Uninstall did not finish — restarting services."
        if [ "$RESTORE_STARTED" != 1 ] ||
           python3 "$PATCHER" --check-patched "$PLUGIN_DIR/Contents" >/dev/null 2>&1; then
            echo "  Nothing was restored: the fork is still installed and working."
            echo "  Re-run the uninstaller to try again."
        elif python3 "$PATCHER" --check-original "$PLUGIN_DIR/Contents" >/dev/null 2>&1; then
            echo "  Canon's original binaries were copied back, but a later step (signing)"
            echo "  failed, so the camera may not work. Re-run the uninstaller."
        else
            echo "  The restore stopped part-way: the plug-in now holds a mix of Canon's"
            echo "  and the fork's binaries and the camera may not work. Re-run the"
            echo "  uninstaller to finish, or reinstall Canon's v1.3.16 package."
        fi
        echo "  Your backup is untouched: $BACKUP_DIR"
        launchctl load "$LAUNCH_AGENT_SYS" 2>/dev/null || true
        launchctl load "$AGENT_PLIST" 2>/dev/null || true
    fi
    return 0
}
trap on_exit EXIT

# The elevated shell osascript spawns has no TCC access to user folders
# (~/Downloads, ~/Desktop, ~/Documents, iCloud Drive...), so it cannot read a
# backup that an older installer left in a clone there — "Operation not
# permitted", even as root. Stage the files through the temp dir, which is
# outside TCC's reach, and verify the staged copies: they are what root copies.
# This happens before anything is stopped.
STAGE="$(mktemp -d -t eoswc-restore)"
for f in EOSWebcamUtility EOSWebcamService EWCProxy; do
    if ! cp "$BACKUP_DIR/$f" "$STAGE/$f"; then
        echo "ERROR: could not read $f from the backup — nothing was changed."
        exit 1
    fi
done
if ! python3 "$PATCHER" --check-original "$STAGE"; then
    echo "ERROR: the staged copy of the backup failed verification — nothing was changed."
    exit 1
fi
# Root copies the binaries, then the images the backup has, then re-signs.
# set -e: any failed step stops it, and it is reported as a failure below.
RESTORE_SCRIPT="$STAGE/restore.sh"
{
    echo '#!/bin/bash'
    echo 'set -e'
    for f in MacOS/EOSWebcamUtility Resources/EOSWebcamService Resources/EWCProxy; do
        echo "cp $(eoswc_sq "$STAGE/${f#*/}") $(eoswc_sq "$PLUGIN_DIR/Contents/$f")"
    done
    for f in errorNoDevice.jpg errorBusy.jpg default.jpg; do
        if cp "$BACKUP_DIR/$f" "$STAGE/$f" 2>/dev/null; then
            echo "cp $(eoswc_sq "$STAGE/$f") $(eoswc_sq "$PLUGIN_DIR/Contents/Resources/$f")"
        fi
    done
    for f in MacOS/EOSWebcamUtility Resources/EOSWebcamService Resources/EWCProxy; do
        echo "codesign --force --sign - $(eoswc_sq "$PLUGIN_DIR/Contents/$f")"
    done
    echo "codesign --force --deep --sign - $(eoswc_sq "$PLUGIN_DIR")"
} > "$RESTORE_SCRIPT"
chmod 700 "$RESTORE_SCRIPT"

# Stop services
echo "[1/4] Stopping services..."
launchctl unload "$AGENT_PLIST" 2>/dev/null || true
launchctl unload "$LAUNCH_AGENT_SYS" 2>/dev/null || true
SERVICES_STOPPED=1
sleep 1

# Restore binaries
echo "[2/4] Restoring original binaries (admin required)..."
RESTORE_STARTED=1
if ! osascript -e "do shell script \"bash '$RESTORE_SCRIPT'\" with administrator privileges"; then
    echo "ERROR: the admin step was cancelled or failed (see above)."
    exit 1
fi
# Only call it restored once the plug-in itself verifies as Canon's originals.
if ! python3 "$PATCHER" --check-original "$PLUGIN_DIR/Contents"; then
    echo "ERROR: after the restore, the plug-in does not hold Canon's original binaries."
    exit 1
fi
RESTORED=1

rm -rf "$STAGE"
STAGE=""
echo "  Original binaries restored"

echo "[3/4] Restoring original config..."
restore_config

# Remove daemon
echo "[4/4] Removing camera manager..."
remove_camera_manager

# Restart original service
launchctl load "$LAUNCH_AGENT_SYS" 2>/dev/null || true

echo ""
echo "============================================"
echo "  Uninstall complete."
echo "  Original EOS Webcam Utility v1.3.16 restored."
echo "  Backups kept (delete them yourself once you're happy):"
echo "    $BACKUP_DIR"
echo "============================================"
