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
eoswc_refuse_root || exit 1
# The real plug-in path, unless a test sandbox says otherwise (see common.sh).
eoswc_select_plugin_dir || exit 1
PLUGIN_DIR="$EOSWC_PLUGIN"
eoswc_select_canon_app_dir || exit 1
# Canon's config dir, which is also where install.sh puts the daemon.
SUPPORT_DIR="$EOSWC_RUNTIME_DIR"
BACKUP_ROOT="$EOSWC_BACKUP_ROOT"
LAUNCH_AGENT_SYS="/Library/LaunchAgents/com.canon.usa.EWCService.plist"
# Every tool, and a python3 that really runs, before anything is changed.
eoswc_require_tools || exit 1
if [ ! -f "$PATCHER" ]; then
    echo "ERROR: patch-binaries.py (next to this script) is needed to check the"
    echo "       backup. Nothing was changed."
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
    # The fork's first camera manager (com.canon-camera-manager), if still there.
    eoswc_remove_legacy_agent
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
    # Canon's uninstaller leaves its Camera Extension active.
    eoswc_report_camera_extension uninstaller
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

# If the uninstall stops after the services were stopped (an error, a
# cancelled prompt, Ctrl-C, a closed terminal), restart them so the camera
# keeps working as far as it can, then say what state the plug-in is in.
SERVICES_STOPPED=0
RESTORE_STARTED=0
RESTORED=0
UNINSTALL_COMPLETE=0
STAGE=""
# The admin step writes $STAGE/root.pid and $STAGE/root.exit (see install.sh).
root_step_running() {
    local pid
    [ -n "$STAGE" ] && [ -f "$STAGE/root.pid" ] && [ ! -f "$STAGE/root.exit" ] || return 1
    pid="$(cat "$STAGE/root.pid" 2>/dev/null)" || return 1
    [ -n "$pid" ] && ps -p "$pid" >/dev/null 2>&1
}
wait_for_root_step() {
    local deadline=$((SECONDS + $1))
    while root_step_running && [ "$SECONDS" -lt "$deadline" ]; do
        sleep 1
    done
    ! root_step_running
}
# echo that can't fail: stdout may be a closed pipe by now.
say() { printf '%s\n' "$@" 2>/dev/null || true; }
# The admin step's output ($STAGE/root.log), shown once it is done; on_exit
# keeps it in ~/Library/Logs if it never was.
ROOT_LOG_SHOWN=0
ADMIN_LOG="$USER_HOME/Library/Logs/eos-webcam-utility-admin-step.log"
show_root_log() {
    [ -n "$STAGE" ] && [ -s "$STAGE/root.log" ] || return 0
    cat "$STAGE/root.log" 2>/dev/null || true
    ROOT_LOG_SHOWN=1
}
on_exit() {
    local root_busy=0 reloaded=0 kept_log=0
    trap '' INT TERM HUP PIPE
    set +e
    # Never restart the services under a restore still in progress.
    wait_for_root_step 600 || root_busy=1
    # Reload first, before anything is printed: printing can fail.
    if [ "$SERVICES_STOPPED" = 1 ] && [ "$UNINSTALL_COMPLETE" != 1 ] && [ "$root_busy" = 0 ]; then
        launchctl load "$LAUNCH_AGENT_SYS" 2>/dev/null
        # The camera manager only if the fork's binaries may still be there.
        [ "$RESTORED" != 1 ] && [ -f "$AGENT_PLIST" ] && launchctl load "$AGENT_PLIST" 2>/dev/null
        reloaded=1
    fi
    if [ -n "$STAGE" ] && [ "$root_busy" = 0 ] && [ "$ROOT_LOG_SHOWN" != 1 ] && [ -s "$STAGE/root.log" ]; then
        mkdir -p "$(dirname "$ADMIN_LOG")" 2>/dev/null
        cp "$STAGE/root.log" "$ADMIN_LOG" 2>/dev/null && kept_log=1
    fi
    [ -n "$STAGE" ] && [ "$root_busy" = 0 ] && rm -rf "$STAGE" 2>/dev/null
    if [ "$root_busy" = 1 ]; then
        say "" "  Uninstall interrupted while the admin step was still running. Services" \
            "  were left stopped so it isn't disturbed mid-restore. Wait a minute, then" \
            "  re-run the uninstaller. Your backup is untouched: $BACKUP_DIR"
    elif [ "$reloaded" = 1 ] && [ "$RESTORED" = 1 ]; then
        say "" "  Uninstall did not finish, but Canon's original binaries are back." \
            "  Canon's service was restarted. Re-run the uninstaller to finish cleaning up."
    elif [ "$reloaded" = 1 ]; then
        say "" "  Uninstall did not finish — restarting services."
        if [ "$RESTORE_STARTED" != 1 ] ||
           python3 "$PATCHER" --check-fork "$PLUGIN_DIR/Contents" >/dev/null 2>&1; then
            say "  Nothing was restored: the fork is still installed and working." \
                "  Re-run the uninstaller to try again."
        elif python3 "$PATCHER" --check-original "$PLUGIN_DIR/Contents" >/dev/null 2>&1; then
            say "  Canon's original binaries were copied back, but a later step (signing)" \
                "  failed, so the camera may not work. Re-run the uninstaller."
        else
            say "  The restore stopped part-way: the plug-in now holds a mix of Canon's" \
                "  and the fork's binaries and the camera may not work. Re-run the" \
                "  uninstaller to finish, or reinstall Canon's v1.3.16 package."
        fi
        say "  Your backup is untouched: $BACKUP_DIR"
    fi
    [ "$kept_log" = 1 ] && say "  The admin step's output is in $ADMIN_LOG"
    return 0
}
trap on_exit EXIT
# Leave through on_exit on Ctrl-C, TERM or a closed terminal. Bash runs these
# only once the current foreground command (e.g. the admin step) returns.
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# The elevated shell osascript spawns has no TCC access to user folders
# (~/Downloads, ~/Desktop, ~/Documents, iCloud Drive...), so it cannot read a
# backup that an older installer left in a clone there — "Operation not
# permitted", even as root. Stage the files through the temp dir, which is
# outside TCC's reach, and verify the staged copies: they are what root copies.
# This happens before anything is stopped.
STAGE="$(mktemp -d -t eoswc-restore)"
# Backups made by this version hold Canon's whole signed plug-in bundle
# ($EOSWC_BUNDLE_BACKUP). That is put back byte for byte, so the plug-in has
# Canon's own signature again and nothing is re-signed. Older backups hold
# only the three binaries: those are copied back and the bundle re-signed.
RESTORE_MODE=binaries
STAGED_BUNDLE="$STAGE/$EOSWC_BUNDLE_BACKUP"
if [ -d "$BACKUP_DIR/$EOSWC_BUNDLE_BACKUP" ] && [ ! -L "$BACKUP_DIR/$EOSWC_BUNDLE_BACKUP" ]; then
    if ditto "$BACKUP_DIR/$EOSWC_BUNDLE_BACKUP" "$STAGED_BUNDLE" &&
       python3 "$PATCHER" --check-original "$STAGED_BUNDLE/Contents" >/dev/null 2>&1 &&
       codesign --verify --deep --strict "$STAGED_BUNDLE" >/dev/null 2>&1; then
        RESTORE_MODE=bundle
    else
        echo "Note: the plug-in bundle in this backup doesn't verify (its signature or"
        echo "      Canon's binaries in it), so only the three binaries are restored."
    fi
fi
if [ "$RESTORE_MODE" = bundle ]; then
    if eoswc_canon_signed "$STAGED_BUNDLE"; then
        echo "The backup holds Canon's signed plug-in: it goes back byte for byte, with"
        echo "Canon's own signature (Team ID $EOSWC_CANON_TEAM). Nothing is re-signed."
    else
        echo "The backup holds the whole plug-in as it was before the install: it goes"
        echo "back byte for byte, with the signature it had then. Nothing is re-signed."
    fi
else
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
    cp "$SCRIPT_DIR/fork-entitlements.plist" "$STAGE/entitlements.plist" 2>/dev/null || true
    echo "This backup was made by an older installer and holds Canon's three binaries,"
    echo "not the plug-in's signature files. EOSWebcamService and EWCProxy keep the"
    echo "signatures they have in the backup (Canon's); the plug-in bundle itself is"
    echo "re-signed ad hoc. To get Canon's signed plug-in back exactly, reinstall"
    echo "Canon's v1.3.16 package afterwards:"
    echo "  https://downloads.canon.com/webcam/EOSWebcamUtility-MAC1.3.16.pkg.zip"
fi
echo ""
# Root copies the plug-in (or the binaries and images) back, puts the owners
# back and, for an older backup only, re-signs. set -e: any failed step stops
# it, and it is reported as a failure below.
RESTORE_SCRIPT="$STAGE/restore.sh"
{
    echo '#!/bin/bash'
    echo 'set -e'
    # Once started, run to the end (see install.sh): never a half restore.
    echo "trap '' INT TERM HUP"
    # Output to a log, never down osascript's pipe (see install.sh): codesign
    # reports on stderr, and a closed pipe would kill it mid-restore.
    echo "exec > $(eoswc_sq "$STAGE/root.log") 2>&1"
    echo "echo \$\$ > $(eoswc_sq "$STAGE/root.pid")"
    echo "root_done() { echo \"\$?\" > $(eoswc_sq "$STAGE/root.exit"); }"
    echo "trap root_done EXIT"
    if [ "$RESTORE_MODE" = bundle ]; then
        echo "ditto $(eoswc_sq "$STAGED_BUNDLE") $(eoswc_sq "$PLUGIN_DIR")"
        # ditto gave every file the staged copy's owner (you). Put back the
        # owner the plug-in had when it was backed up, on exactly the files
        # the backup has. The record is only a uid:gid pair, checked here,
        # since root runs the chown.
        PLUGIN_OWNER="$(head -1 "$BACKUP_DIR/plugin.owner" 2>/dev/null)" || PLUGIN_OWNER=""
        if printf '%s\n' "$PLUGIN_OWNER" | grep -qE '^[0-9]{1,10}:[0-9]{1,10}$'; then
            while IFS= read -r -d '' rel; do
                rel="${rel#.}"
                echo "chown -h $(eoswc_sq "$PLUGIN_OWNER") $(eoswc_sq "$PLUGIN_DIR$rel")"
            done < <(cd "$STAGED_BUNDLE" && find . -print0)
        elif [ -n "$PLUGIN_OWNER" ]; then
            echo "Note: $BACKUP_DIR/plugin.owner isn't a uid:gid pair;" >&2
            echo "      not restoring the plug-in's owner." >&2
        fi
    else
        for f in MacOS/EOSWebcamUtility Resources/EOSWebcamService Resources/EWCProxy; do
            echo "cp $(eoswc_sq "$STAGE/${f#*/}") $(eoswc_sq "$PLUGIN_DIR/Contents/$f")"
        done
    fi
    for f in errorNoDevice.jpg errorBusy.jpg default.jpg; do
        if [ "$RESTORE_MODE" != bundle ] && cp "$BACKUP_DIR/$f" "$STAGE/$f" 2>/dev/null; then
            echo "cp $(eoswc_sq "$STAGE/$f") $(eoswc_sq "$PLUGIN_DIR/Contents/Resources/$f")"
        fi
        # The installer gave errorNoDevice.jpg to you; give it back to the
        # owner it had before (recorded in the backup). The record is only a
        # uid:gid pair, checked here, since root runs the chown.
        if [ "$RESTORE_MODE" != bundle ] && [ "$f" = errorNoDevice.jpg ] && [ -f "$BACKUP_DIR/errorNoDevice.owner" ]; then
            NODEV_OWNER="$(head -1 "$BACKUP_DIR/errorNoDevice.owner" 2>/dev/null)" || NODEV_OWNER=""
            if printf '%s\n' "$NODEV_OWNER" | grep -qE '^[0-9]{1,10}:[0-9]{1,10}$'; then
                echo "[ ! -e $(eoswc_sq "$PLUGIN_DIR/Contents/Resources/$f") ] || chown $(eoswc_sq "$NODEV_OWNER") $(eoswc_sq "$PLUGIN_DIR/Contents/Resources/$f")"
            else
                echo "Note: $BACKUP_DIR/errorNoDevice.owner isn't a uid:gid pair;" >&2
                echo "      not restoring the owner of errorNoDevice.jpg." >&2
            fi
        fi
        # Older installers left these world-writable (666); cp keeps that.
        # (A mode isn't part of the signature.)
        echo "[ ! -e $(eoswc_sq "$PLUGIN_DIR/Contents/Resources/$f") ] || chmod 644 $(eoswc_sq "$PLUGIN_DIR/Contents/Resources/$f")"
    done
    if [ "$RESTORE_MODE" != bundle ]; then
        # The helpers keep the signature they have in the backup (Canon's, or
        # whatever an older uninstall gave them); only one that doesn't verify
        # is re-signed, the way install.sh signs. The bundle's own signature
        # files weren't backed up, so it is re-signed ad hoc: its seal has to
        # cover Canon's binaries again.
        Q_ENTS="$(eoswc_sq "$STAGE/entitlements.plist")"
        for pair in EOSWebcamService:EWCService EWCProxy:EWCProxy; do
            Q_H="$(eoswc_sq "$PLUGIN_DIR/Contents/Resources/${pair%%:*}")"
            echo "codesign --verify --strict $Q_H >/dev/null 2>&1 || codesign --force --sign - --identifier ${pair#*:} --options runtime --entitlements $Q_ENTS $Q_H"
        done
        echo "codesign --force --sign - $(eoswc_sq "$PLUGIN_DIR")"
    fi
} > "$RESTORE_SCRIPT"
chmod 700 "$RESTORE_SCRIPT"

# Stop services
echo "[1/4] Stopping services..."
# A closed stdout must not kill this shell outright (skipping on_exit): with
# SIGPIPE ignored, a failed write is an ordinary error and set -e runs on_exit.
trap '' PIPE
# Set first: reloading a service that wasn't stopped yet is harmless.
SERVICES_STOPPED=1
launchctl unload "$AGENT_PLIST" 2>/dev/null || true
launchctl unload "$LAUNCH_AGENT_SYS" 2>/dev/null || true
sleep 1

# Restore binaries
echo "[2/4] Restoring Canon's plug-in (macOS asks for your admin password)..."
RESTORE_STARTED=1
ROOT_OK=1
osascript -e "do shell script \"bash '$RESTORE_SCRIPT'\" with administrator privileges" || ROOT_OK=0
show_root_log
if [ "$ROOT_OK" = 0 ]; then
    echo "ERROR: the admin step was cancelled or failed (see above)."
    exit 1
fi
# Only call it restored once the plug-in itself verifies as Canon's originals.
if ! python3 "$PATCHER" --check-original "$PLUGIN_DIR/Contents"; then
    echo "ERROR: after the restore, the plug-in does not hold Canon's original binaries."
    exit 1
fi
RESTORED=1
SIGNATURE_NOTE=""
if [ "$RESTORE_MODE" = bundle ]; then
    if eoswc_canon_signed "$PLUGIN_DIR"; then
        SIGNATURE_NOTE="Canon's signature is back (Team ID $EOSWC_CANON_TEAM); nothing was re-signed."
    elif codesign --verify --deep --strict "$PLUGIN_DIR" >/dev/null 2>&1; then
        SIGNATURE_NOTE="The plug-in is back exactly as it was before the install; nothing was re-signed."
    else
        echo "  WARNING: the restored plug-in doesn't pass codesign --verify --deep --strict:"
        codesign --verify --deep --strict "$PLUGIN_DIR" 2>&1 | sed 's/^/    /' | head -12 || true
        # Anything in the plug-in that isn't in the backup was left alone.
        EXTRA="$(comm -13 <(cd "$STAGED_BUNDLE" && find . | LC_ALL=C sort)                          <(cd "$PLUGIN_DIR" && find . | LC_ALL=C sort) 2>/dev/null)" || EXTRA=""
        if [ -n "$EXTRA" ]; then
            echo "  These aren't part of the backed-up plug-in (something else put them there;"
            echo "  they were left alone):"
            printf '%s\n' "$EXTRA" | sed "s|^\\.|    $PLUGIN_DIR|" | head -20
        fi
        SIGNATURE_NOTE="The binaries are Canon's, but the plug-in's signature doesn't verify (see above)."
    fi
else
    SIGNATURE_NOTE="The plug-in bundle is signed ad hoc (restored from an older backup, see above)."
fi

rm -rf "$STAGE"
STAGE=""
echo "  Original binaries restored"
echo "  $SIGNATURE_NOTE"

echo "[3/4] Restoring original config..."
restore_config

# Remove daemon
echo "[4/4] Removing camera manager..."
remove_camera_manager

# Restart original service
launchctl load "$LAUNCH_AGENT_SYS" 2>/dev/null || true
UNINSTALL_COMPLETE=1

echo ""
echo "============================================"
echo "  Uninstall complete."
echo "  Original EOS Webcam Utility v1.3.16 restored."
echo "  $SIGNATURE_NOTE"
echo "  Backups kept (delete them yourself once you're happy):"
echo "    $BACKUP_DIR"
# This restores Canon's software; it doesn't remove it. That includes Canon's
# Camera Extension (macOS 14+), which a fresh install may have added.
eoswc_report_camera_extension uninstaller
echo "============================================"
