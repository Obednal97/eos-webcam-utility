#!/bin/bash
#
# EOS Webcam Utility Fork v1.4 — Installer
#
# This installer does NOT ship Canon's software. It patches the original
# Canon EOS Webcam Utility v1.3.16 binaries already on your Mac (or downloads
# Canon's official package straight from Canon), applying the fork's changes:
#   - 1080p output (upscaled from the camera's native ~1024x576)
#   - Pro features unlocked (no subscription)
#   - Auto-retry camera activation
#   - Custom loading/disconnected screens with optional logo
#
# Binary source, in order of preference:
#   1. An EOS Webcam Utility already installed on this Mac (patched in place)
#   2. Canon's official v1.3.16 package, downloaded from Canon and verified
#   3. A package you supply yourself:  bash install.sh --pkg /path/to/pkg[.zip]
#      It must match the SHA-256 of Canon's v1.3.16 package (the .zip or the
#      .pkg inside it). --allow-unverified-pkg overrides that: don't use it
#      unless you know exactly where the package came from.
#
# Requirements:
#   - macOS on Apple Silicon (M1/M2/M3/M4)
#   - Admin privileges (run WITHOUT sudo; you'll be prompted for your password)
#   - Internet access (only if Canon's package needs to be downloaded)
#
# Usage: bash install.sh [--pkg PATH [--allow-unverified-pkg]] [--agree]
#

set -e

VERSION="1.4.2"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCHER="$SCRIPT_DIR/patch-binaries.py"
# The entitlements the patched helpers are signed with (see that file).
ENTITLEMENTS="$SCRIPT_DIR/fork-entitlements.plist"
if [ ! -f "$SCRIPT_DIR/common.sh" ]; then
    echo "  ERROR: common.sh not found next to this script."
    exit 1
fi
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"
eoswc_refuse_root || exit 1
# The real plug-in path, unless a test sandbox says otherwise (see common.sh).
eoswc_select_plugin_dir || exit 1
PLUGIN_DIR="$EOSWC_PLUGIN"
eoswc_select_canon_app_dir || exit 1
CANON_APPS="$EOSWC_CANON_APPS"
# EOSWC_TEST_PKG_SHA256: one more accepted --pkg checksum, so tests/ can
# install a fake package. Honoured only inside a marked test sandbox.
eoswc_require_sandbox_for EOSWC_TEST_PKG_SHA256 || exit 1
TEST_PKG_SHA256="${EOSWC_TEST_PKG_SHA256:-}"
PLUGIN_RES="$PLUGIN_DIR/Contents/Resources"
PLUGIN_BIN="$PLUGIN_DIR/Contents/MacOS"
LAUNCH_AGENT_SYS="/Library/LaunchAgents/com.canon.usa.EWCService.plist"
USER_HOME="$HOME"
USERNAME="$(whoami)"
SUPPORT_DIR="$USER_HOME/Library/Application Support/EWCService"
LAUNCH_AGENTS="$USER_HOME/Library/LaunchAgents"
# The clone this script was run from. Older installers kept backups (and the
# daemon) here; see EOSWC_BACKUP_ROOT in common.sh for where backups go now.
INSTALL_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
BACKUP_ROOT="$EOSWC_BACKUP_ROOT"
# The daemon and its images must live somewhere launchd can actually read them.
# A LaunchAgent gets no TCC access to ~/Downloads, ~/Desktop, ~/Documents or
# iCloud Drive, so running the daemon out of the clone fails with "Operation not
# permitted"; Application Support is outside TCC's reach.
RUNTIME_DIR="$EOSWC_RUNTIME_DIR"   # same dir as SUPPORT_DIR; see common.sh
LOG_DIR="$USER_HOME/Library/Logs"

# Canon's official EOS Webcam Utility v1.3.16 (still hosted by Canon as of 2026-07).
# The SHA-256 pins the exact build the patch offsets were derived against; a
# different build fails the checksum (download path) or the patcher's own
# byte verification (any path), so patches can never be misapplied.
CANON_PKG_URL="https://downloads.canon.com/webcam/EOSWebcamUtility-MAC1.3.16.pkg.zip"
CANON_PKG_SHA256="5ad0333bd6a1c66f88c70aac631e5133c5f3dd6fc579e45dd473d1e964c02321"
# The .pkg inside that .zip (EOSWebcamUtility-MAC1.3.16.pkg), for a --pkg that
# is the bare .pkg. It is a flat package signed "Developer ID Installer:
# Canon U.S.A., Inc. (NC5A977249)" and notarised.
CANON_INNER_PKG_SHA256="cb368a204db87047fa5e47c8593ac0e654baee39e0c302bed3f7d3cf5364c0eb"
CANON_PKG_SIGNER="Developer ID Installer: Canon U.S.A., Inc. (NC5A977249)"
# CFBundleShortVersionString of the plug-in in that package.
CANON_PLUGIN_VERSIONS="1.3.16.0 1.3.16"

# --- Args ---
USER_PKG=""
ALLOW_UNVERIFIED_PKG=0
AGREED=0
while [ $# -gt 0 ]; do
    case "$1" in
        --pkg)
            [ $# -ge 2 ] && [ -n "$2" ] || { echo "--pkg needs a path"; exit 1; }
            USER_PKG="$2"; shift 2 ;;
        --allow-unverified-pkg) ALLOW_UNVERIFIED_PKG=1; shift ;;
        --agree|--yes|-y) AGREED=1; shift ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -33
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done
if [ "$ALLOW_UNVERIFIED_PKG" = 1 ] && [ -z "$USER_PKG" ]; then
    echo "--allow-unverified-pkg only applies to --pkg"
    exit 1
fi

# --- Failure safety ---
# If the install stops after we've stopped the existing services (an error, a
# cancelled prompt, Ctrl-C, a closed terminal), restart Canon's service and
# the camera manager on exit so the machine isn't left without a camera.
SERVICES_STOPPED=0
INSTALL_COMPLETE=0
WORK=""
STAGE=""
BACKUP_DIR=""
AGENT_PLIST="$LAUNCH_AGENTS/com.eos-camera-manager.plist"

# The admin step writes $STAGE/root.pid when it starts and $STAGE/root.exit
# when it ends. It ignores Ctrl-C and TERM, so once started it always runs to
# the end; osascript itself may still die, though, returning here while root
# is mid-patch. True while it is still running.
root_step_running() {
    local pid
    [ -n "$STAGE" ] && [ -f "$STAGE/root.pid" ] && [ ! -f "$STAGE/root.exit" ] || return 1
    pid="$(cat "$STAGE/root.pid" 2>/dev/null)" || return 1
    [ -n "$pid" ] && ps -p "$pid" >/dev/null 2>&1
}
# Wait up to $1 seconds for the admin step to finish; false if it hasn't.
wait_for_root_step() {
    local deadline=$((SECONDS + $1))
    while root_step_running && [ "$SECONDS" -lt "$deadline" ]; do
        sleep 1
    done
    ! root_step_running
}
# echo that can't fail: stdout may be a closed pipe by now (`install.sh | head`).
say() { printf '%s\n' "$@" 2>/dev/null || true; }
# The admin step writes its output to $STAGE/root.log (see the root script).
# Show it once it is done; cleanup keeps it in ~/Library/Logs if it wasn't.
ROOT_LOG_SHOWN=0
ADMIN_LOG="$LOG_DIR/eos-webcam-utility-admin-step.log"
show_root_log() {
    [ -n "$STAGE" ] && [ -s "$STAGE/root.log" ] || return 0
    cat "$STAGE/root.log" 2>/dev/null || true
    ROOT_LOG_SHOWN=1
}

# True if SHA-256 $1 is a pinned checksum of Canon's v1.3.16 package.
pkg_sha_pinned() {
    [ -n "$1" ] || return 1
    [ "$1" = "$CANON_PKG_SHA256" ] || [ "$1" = "$CANON_INNER_PKG_SHA256" ] ||
        { [ -n "$TEST_PKG_SHA256" ] && [ "$1" = "$TEST_PKG_SHA256" ]; }
}

# Check a --pkg ($USER_PKG, and $PKG_FILE, the .pkg in it) before root ever
# runs it. Exits unless it is pinned or --allow-unverified-pkg was given.
verify_user_pkg() {
    local sha="" inner="" why sig signer
    [ -f "$USER_PKG" ] && sha="$(shasum -a 256 "$USER_PKG" | awk '{print $1}')"
    if pkg_sha_pinned "$sha"; then
        echo "  Verified: SHA-256 matches Canon's v1.3.16 package."
        return 0
    fi
    if [ -f "$PKG_FILE" ] && [ "$PKG_FILE" != "$USER_PKG" ]; then
        inner="$(shasum -a 256 "$PKG_FILE" | awk '{print $1}')"
        if pkg_sha_pinned "$inner"; then
            echo "  Verified: the .pkg inside matches Canon's v1.3.16 package (SHA-256)."
            return 0
        fi
    fi
    if [ -d "$PKG_FILE" ]; then
        why="it is a bundle-style (folder) package, which can't be checked against"
        why="$why the pinned SHA-256"
    else
        why="its SHA-256 (${inner:-$sha}) isn't the one pinned for Canon's v1.3.16 package"
    fi
    sig="$(pkgutil --check-signature "$PKG_FILE" 2>&1)" || true
    if printf '%s\n' "$sig" | grep -qF "$CANON_PKG_SIGNER" &&
       printf '%s\n' "$sig" | grep -qF "Status: signed by a developer certificate issued by Apple"; then
        signer="signed by Canon ($CANON_PKG_SIGNER), but not the v1.3.16 build the patches are for"
    else
        signer="NOT signed by Canon"
    fi
    if [ "$ALLOW_UNVERIFIED_PKG" != 1 ]; then
        echo "  ERROR: refusing to use $USER_PKG:"
        echo "         $why;"
        echo "         it is $signer."
        echo "         Canon's installer runs as root, so only Canon's exact v1.3.16 package"
        echo "         is accepted. Nothing was changed. Get it from Canon:"
        echo "           $CANON_PKG_URL"
        echo "         (or leave out --pkg and the installer downloads and checks it)."
        exit 1
    fi
    echo ""
    echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "  !! WARNING: --allow-unverified-pkg: using a package that FAILED checks. !!"
    echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "  $USER_PKG:"
    echo "    - $why"
    echo "    - it is $signer"
    echo "  It will be run AS ROOT by macOS's installer. If it isn't really Canon's"
    echo "  v1.3.16 package it can do anything to this Mac. Cancel the password prompt"
    echo "  that comes next unless you know exactly where it came from."
    echo ""
}

# Staging only ever holds copies of things that exist elsewhere (the patcher,
# the Canon .pkg, the root script): Canon's originals go straight from the
# plug-in into BACKUP_DIR, so deleting staging can never lose them.
cleanup() {
    local root_busy=0 reloaded=0 kept_log=0
    trap '' INT TERM HUP PIPE
    set +e
    # Never restart Canon's service under a patch still in progress.
    wait_for_root_step 600 || root_busy=1
    # Reload first, before anything is printed: printing can fail.
    if [ "$INSTALL_COMPLETE" != 1 ] && [ "$SERVICES_STOPPED" = 1 ] && [ "$root_busy" = 0 ]; then
        launchctl load "$LAUNCH_AGENT_SYS" 2>/dev/null
        [ -f "$AGENT_PLIST" ] && launchctl load "$AGENT_PLIST" 2>/dev/null
        reloaded=1
    fi
    [ -n "$WORK" ] && rm -rf "$WORK" 2>/dev/null
    # Keep the admin step's output if it was never shown (e.g. Ctrl-C).
    if [ -n "$STAGE" ] && [ "$root_busy" = 0 ] && [ "$ROOT_LOG_SHOWN" != 1 ] && [ -s "$STAGE/root.log" ]; then
        mkdir -p "$LOG_DIR" 2>/dev/null
        cp "$STAGE/root.log" "$ADMIN_LOG" 2>/dev/null && kept_log=1
    fi
    [ -n "$STAGE" ] && [ "$root_busy" = 0 ] && rm -rf "$STAGE" 2>/dev/null
    if [ "$reloaded" = 1 ]; then
        say "" "  Install did not finish — restarting Canon's service and the camera manager" \
            "  so your existing camera setup keeps working. Re-run the installer to try again."
    fi
    if [ "$root_busy" = 1 ]; then
        say "" "  Install interrupted while the admin step was still running. Services were" \
            "  left stopped so it isn't disturbed mid-patch. Wait a minute, then re-run" \
            "  the installer (it checks what state the plug-in is in first)." \
            "  Its output so far: $STAGE/root.log"
    fi
    [ "$kept_log" = 1 ] && say "  The admin step's output is in $ADMIN_LOG"
    return 0
}
trap cleanup EXIT
# Leave through cleanup on Ctrl-C, TERM or a closed terminal. Bash runs these
# only once the current foreground command (e.g. the admin step) returns.
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

echo ""
echo "============================================"
echo "  EOS Webcam Utility Fork v${VERSION}"
echo "  Installer"
echo "============================================"
echo ""

# --- Pre-flight checks ---
echo "[1/7] Pre-flight checks..."

ARCH=$(uname -m)
if [ "$ARCH" != "arm64" ]; then
    echo "  ERROR: Requires Apple Silicon (arm64). Detected: $ARCH"
    exit 1
fi
# Every tool, and a python3 that really runs, before anything is changed.
NEED_TOOLS=""
[ -d "$PLUGIN_DIR" ] || NEED_TOOLS="installer"
[ -n "$USER_PKG" ] && NEED_TOOLS="$NEED_TOOLS pkgutil"
[ -d "$PLUGIN_DIR" ] || [ -n "$USER_PKG" ] || NEED_TOOLS="$NEED_TOOLS curl"
# shellcheck disable=SC2086  # a list of tool names
eoswc_require_tools $NEED_TOOLS || exit 1
if [ ! -f "$PATCHER" ]; then
    echo "  ERROR: patch-binaries.py not found next to this script."
    exit 1
fi
if [ ! -f "$ENTITLEMENTS" ]; then
    echo "  ERROR: fork-entitlements.plist not found next to this script."
    exit 1
fi

# Decide where Canon's original binaries will come from.
SOURCE=""          # installed | download | userpkg
INSTALL_TYPE="fresh"
if [ -d "$PLUGIN_DIR" ]; then
    SOURCE="installed"
    # The patch offsets are for Canon's v1.3.16 only. Refuse anything that
    # doesn't say it's that version before looking any closer.
    PLUGIN_VERSION="$(eoswc_plist_value "$PLUGIN_DIR/Contents/Info.plist" CFBundleShortVersionString)" || PLUGIN_VERSION=""
    case " $CANON_PLUGIN_VERSIONS " in
        *" $PLUGIN_VERSION "*) ;;
        *)
            echo "  ERROR: the installed EOS Webcam Utility is version ${PLUGIN_VERSION:-unknown (no readable Info.plist)},"
            echo "         not Canon's v1.3.16, the only version this fork can patch."
            echo "         Nothing was changed. Remove it with Canon's uninstaller"
            echo "         ($CANON_APPS/$EOSWC_CANON_UNINSTALLER), then re-run this"
            echo "         to install v1.3.16."
            exit 1 ;;
    esac
    # Only these two states are safe to go on from: Canon's complete v1.3.16
    # originals (back them up, then patch) or the fork's fully patched
    # binaries, this version's or an earlier one's (nothing to back up; an
    # earlier version's are brought up to date). Anything else (a different
    # build, a half-patched or truncated binary) could not be restored.
    if python3 "$PATCHER" --check-fork "$PLUGIN_DIR/Contents" >/dev/null 2>&1; then
        INSTALL_TYPE="upgrade_fork"
    elif python3 "$PATCHER" --check-original "$PLUGIN_DIR/Contents" >/dev/null 2>&1; then
        INSTALL_TYPE="upgrade_original"
    else
        echo "  ERROR: the installed EOS Webcam Utility holds neither Canon's complete"
        echo "         v1.3.16 binaries nor the fork's patched ones:"
        python3 "$PATCHER" --check-original "$PLUGIN_DIR/Contents" 2>&1 | sed -n 's/^    - /           - /p'
        echo "         Nothing was changed. If an earlier install stopped part-way, run"
        echo "         uninstall.sh to restore Canon's originals from its backup; otherwise"
        echo "         reinstall Canon's v1.3.16 package. Then re-run this."
        exit 1
    fi
elif [ -n "$USER_PKG" ]; then
    SOURCE="userpkg"
else
    SOURCE="download"
fi

echo "  Architecture:  $ARCH"
echo "  User:          $USERNAME"
case "$INSTALL_TYPE" in
    fresh)            echo "  Mode:          Fresh install" ;;
    upgrade_original) echo "  Mode:          Patch existing Canon v1.3.x" ;;
    upgrade_fork)     echo "  Mode:          Update existing fork" ;;
esac
case "$SOURCE" in
    installed) echo "  Canon source:  already installed v${PLUGIN_VERSION} (patch in place)" ;;
    userpkg)   echo "  Canon source:  $USER_PKG" ;;
    download)  echo "  Canon source:  download from Canon" ;;
esac
if [ "$SOURCE" = installed ] && [ -n "$USER_PKG" ]; then
    echo ""
    echo "  NOTE: --pkg is NOT used: EOS Webcam Utility is already installed, so the"
    echo "        installed copy is patched in place and $USER_PKG"
    echo "        is left alone. To install from that package instead, remove Canon's"
    echo "        software first (uninstall.sh, then Canon's own uninstaller)."
fi
echo ""

# --- Consent ---
if [ "$AGREED" != 1 ]; then
    echo "--------------------------------------------"
    echo "Please read before continuing:"
    echo ""
    echo "  This tool modifies Canon's EOS Webcam Utility software. Canon's"
    echo "  software remains Canon's; you are solely responsible for complying"
    echo "  with Canon's licence and terms of use. This fork is provided with"
    echo "  NO WARRANTY of any kind and is used entirely at your own risk. The"
    echo "  authors and contributors accept no liability for any consequences."
    echo "--------------------------------------------"
    if [ ! -t 0 ]; then
        echo "  Non-interactive shell: re-run with --agree to accept and proceed."
        exit 1
    fi
    printf 'Type "I AGREE" to continue: '
    read -r ANSWER
    if [ "$ANSWER" != "I AGREE" ]; then
        echo "  Not accepted — nothing was changed."
        exit 1
    fi
    echo ""
fi

# --- Obtain Canon's original package (only if not already installed) ---
NEED_INSTALLER=0
PKG_FILE=""
echo "[2/7] Obtaining Canon base software..."
if [ "$SOURCE" = "installed" ]; then
    echo "  Using the EOS Webcam Utility already installed — no download needed."
else
    WORK="$(mktemp -d -t eoswc)"
    if [ "$SOURCE" = "userpkg" ]; then
        # -e, not -f: a bundle-style .pkg is a directory.
        if [ ! -e "$USER_PKG" ]; then
            echo "  ERROR: --pkg file not found: $USER_PKG"
            exit 1
        fi
        SRC="$USER_PKG"
    else
        echo "  Downloading Canon's official v1.3.16 package..."
        if ! curl -fL --max-time 300 -o "$WORK/canon.zip" "$CANON_PKG_URL"; then
            echo "  ERROR: download failed. If Canon has removed the file, supply your"
            echo "         own copy with:  bash install.sh --pkg /path/to/EOSWebcamUtility-MAC1.3.16.pkg.zip"
            exit 1
        fi
        echo "  Verifying checksum..."
        GOT=$(shasum -a 256 "$WORK/canon.zip" | awk '{print $1}')
        if [ "$GOT" != "$CANON_PKG_SHA256" ]; then
            echo "  ERROR: checksum mismatch (expected $CANON_PKG_SHA256, got $GOT)."
            echo "         Refusing to use an unexpected build."
            exit 1
        fi
        SRC="$WORK/canon.zip"
    fi

    # Accept either a .zip (Canon's distribution) or a bare .pkg.
    case "$SRC" in
        *.zip)
            ditto -x -k "$SRC" "$WORK/unz" 2>/dev/null || { echo "  ERROR: could not unzip package."; exit 1; }
            PKG_FILE=$(/usr/bin/find "$WORK/unz" -maxdepth 3 -name '*.pkg' ! -name '._*' | awk 'NR == 1') ;;
        *.pkg)
            PKG_FILE="$SRC" ;;
        *)
            echo "  ERROR: --pkg must be a .zip or .pkg"; exit 1 ;;
    esac
    if [ -z "$PKG_FILE" ] || [ ! -e "$PKG_FILE" ]; then
        echo "  ERROR: no .pkg found in the supplied package."
        exit 1
    fi
    # A package you supply is run by root with Canon's installer, so it must be
    # exactly Canon's v1.3.16 package: the .zip, or the .pkg inside it, by
    # SHA-256. A valid Canon signature alone is not enough: Canon signs every
    # build, and any other build would replace your Canon software as root
    # before the patcher refused it.
    if [ "$SOURCE" = "userpkg" ]; then
        verify_user_pkg
    fi
    NEED_INSTALLER=1
    echo "  Package ready: $(basename "$PKG_FILE")"
fi
echo ""

# --- Back up existing user config (binaries are snapshotted below, as root) ---
echo "[3/7] Creating backups..."
# SNAPSHOT: new = copy Canon's plug-in into a new backup dir; reuse = an
# existing backup already holds the installed originals; none = the
# installed binaries are already patched, so there are no originals to copy
# (and nothing below changes them). Each install run used to add another
# ~11.5 MB backup, patched or not.
SNAPSHOT=new
[ "$INSTALL_TYPE" = upgrade_fork ] && SNAPSHOT=none
EXISTING_BACKUP=""
REUSE_HOW=""
# Older installers ran the daemon out of the clone they were run from, which
# may not be this one, and kept their backups there. The LaunchAgent says
# which clone that was; read it now, before the backup search (the agent is
# rewritten below), so an upgrade from a fresh clone still finds them.
OLD_DAEMON="$(eoswc_agent_daemon_path "$AGENT_PLIST")"
OLD_CLONE="$(eoswc_old_clone_dir "$AGENT_PLIST")"
# The newest backup that verifies as Canon's originals, in any location.
while IFS= read -r d; do
    if python3 "$PATCHER" --check-original "$d" >/dev/null 2>&1; then
        EXISTING_BACKUP="$d"
        break
    fi
done < <(eoswc_backup_candidates "$INSTALL_DIR" "$OLD_CLONE")
if [ "$SNAPSHOT" = new ] && [ "$INSTALL_TYPE" = upgrade_original ] && [ -n "$EXISTING_BACKUP" ]; then
    # Reusable only from Application Support: root can't read an older
    # backup left in a privacy-protected clone, and must re-check it.
    case "$EXISTING_BACKUP" in "$BACKUP_ROOT"/*)
        if cmp -s "$PLUGIN_BIN/EOSWebcamUtility" "$EXISTING_BACKUP/EOSWebcamUtility" &&
           cmp -s "$PLUGIN_RES/EOSWebcamService" "$EXISTING_BACKUP/EOSWebcamService" &&
           cmp -s "$PLUGIN_RES/EWCProxy" "$EXISTING_BACKUP/EWCProxy"; then
            REUSE_HOW=identical
        elif python3 "$PATCHER" --same-code "$EXISTING_BACKUP" "$PLUGIN_DIR/Contents" >/dev/null 2>&1; then
            # Canon's original code, signed differently: older uninstallers
            # re-signed the originals they put back. The backup is the better
            # copy (it has Canon's signatures), so it isn't copied again.
            REUSE_HOW=resigned
        fi
        # A backup from an older installer has only the three binaries. If
        # the installed plug-in is Canon's own signed bundle, take a full
        # backup this once instead, so uninstall can put Canon's signature
        # back exactly; later installs reuse that one.
        if [ -n "$REUSE_HOW" ] && [ ! -d "$EXISTING_BACKUP/$EOSWC_BUNDLE_BACKUP" ] &&
           eoswc_canon_signed "$PLUGIN_DIR"; then
            echo "  $EXISTING_BACKUP has only Canon's three binaries, but the installed"
            echo "  plug-in is Canon's own signed bundle: backing up the whole bundle this once."
            REUSE_HOW=""
        fi
        [ -z "$REUSE_HOW" ] || SNAPSHOT=reuse ;;
    esac
fi
if [ "$SNAPSHOT" = new ]; then
    BACKUP_DIR="$BACKUP_ROOT/pre-v${VERSION}-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    cp "$SUPPORT_DIR/config.plist" "$BACKUP_DIR/" 2>/dev/null || true
    cp "$SUPPORT_DIR/proconfig.plist" "$BACKUP_DIR/" 2>/dev/null || true
    echo "  Backup dir: $BACKUP_DIR"
    echo "  (Canon's plug-in, with its signature, is copied here and verified before"
    echo "  anything is patched.)"
elif [ "$SNAPSHOT" = reuse ]; then
    BACKUP_DIR="$EXISTING_BACKUP"
    echo "  Canon's original binaries are already backed up in $BACKUP_DIR"
    if [ "$REUSE_HOW" = identical ]; then
        echo "  (it holds exactly the installed files; no new copy needed)."
    else
        echo "  (the installed ones are the same code, re-signed by an earlier uninstall;"
        echo "  the backup still has Canon's signatures, so no new copy is needed)."
    fi
else
    echo "  The installed binaries are already patched: no Canon originals to back up."
    case "$EXISTING_BACKUP" in
    ""|"$BACKUP_ROOT"/*) ;;
    *)
        # It is the only copy of Canon's originals, and it sits in a clone that
        # may be moved or deleted. Keep a verified copy in Application Support
        # (the original is left exactly where it is).
        echo "  Found a backup of Canon's originals left by an older installer: $EXISTING_BACKUP"
        if ADOPTED="$(eoswc_adopt_backup "$EXISTING_BACKUP" "$PATCHER")"; then
            echo "  Copied it (verified) to $ADOPTED, so it no longer depends on that clone."
            EXISTING_BACKUP="$ADOPTED"
        else
            echo "  WARNING: could not copy it to $BACKUP_ROOT/. It is still used from"
            echo "           where it is: don't delete that clone before uninstalling."
        fi ;;
    esac
    if [ -n "$EXISTING_BACKUP" ]; then
        echo "  Existing backup of Canon's originals: $EXISTING_BACKUP"
    else
        echo "  WARNING: no backup of Canon's original binaries was found, so uninstall.sh"
        echo "           will not be able to restore them. Reinstalling Canon's v1.3.16"
        echo "           package gets them back."
    fi
fi

# --- Stop services ---
echo "[4/7] Stopping existing services..."
# OLD_DAEMON (read above) is where an older installer ran the daemon from;
# that copy is cleaned up once the new one is in place.
# From here on a closed stdout (e.g. `install.sh | head`) must not kill this
# shell outright, which would skip cleanup and leave the services stopped: with
# SIGPIPE ignored, a failed write is an ordinary error and set -e runs cleanup.
trap '' PIPE
# Set first: reloading a service that wasn't stopped yet is harmless.
SERVICES_STOPPED=1
launchctl unload "$AGENT_PLIST" 2>/dev/null || true
launchctl unload "$LAUNCH_AGENT_SYS" 2>/dev/null || true
pkill -9 EOSWebcamServic 2>/dev/null || true
pkill -9 EWCProxy 2>/dev/null || true
# The fork's first camera manager, if it's still there, would fight this one.
eoswc_remove_legacy_agent
sleep 1
echo "  Done"

# --- Install (if needed), back up originals, patch, sign (single admin step) ---
echo "[5/7] Installing Canon base (if needed), patching, and signing..."
echo "  macOS asks for your admin password now (the only step that needs it). If you"
echo "  cancel, nothing is changed and the services are started again."
# The elevated shell osascript spawns inherits no TCC access to user folders
# (~/Downloads, ~/Desktop, ~/Documents, iCloud Drive...), so reading the patcher
# or the .pkg there fails with "Operation not permitted" even as root. Those are
# staged through a temp dir. The backup goes to BACKUP_DIR in Application
# Support, which root can write, so Canon's originals never sit only in a temp
# dir that macOS may purge.
STAGE="$(mktemp -d -t eoswc-stage)"
cp "$PATCHER" "$STAGE/patch-binaries.py"
cp "$ENTITLEMENTS" "$STAGE/entitlements.plist"
if [ "$NEED_INSTALLER" = 1 ]; then
    # -R: a .pkg is either a flat file or a bundle-style directory.
    cp -R "$PKG_FILE" "$STAGE/canon.pkg"
fi
# On macOS 14+ Canon's postinstall runs its Camera Extension installer last
# and exits 1 unless you approve the extension there and then. By that point
# the DAL plug-in (the part the fork patches), EDSDK and Canon's LaunchAgent
# are all installed; only the optional extension is missing. So that one
# failure is not fatal: root checks that the payload is really there (and the
# backup below verifies it as Canon's v1.3.16) and carries on.
MACOS_VERSION="$(sw_vers -productVersion 2>/dev/null)" || MACOS_VERSION=""
MACOS_MAJOR="${MACOS_VERSION%%.*}"
CAMEXT_EXPECTED=0
if [ "$NEED_INSTALLER" = 1 ] && [ "${MACOS_MAJOR:-0}" -ge 14 ] 2>/dev/null; then
    CAMEXT_EXPECTED=1
    echo "  macOS $MACOS_VERSION: Canon's installer may open \"EOS Webcam Camera Extension"
    echo "  Installer\" and ask you to allow Canon's Camera Extension. That's optional; the"
    echo "  fork patches the DAL plug-in, which works without it. If that window appears,"
    echo "  allow the extension or close the window; the install carries on either way."
fi
ROOT_SCRIPT="$STAGE/deploy.sh"
{
    echo '#!/bin/bash'
    echo 'set -e'
    # Once started, run to the end: Ctrl-C (sent to the whole terminal
    # process group) or TERM must never stop the patcher half-way. root.pid
    # and root.exit let this shell's cleanup see whether it is still running.
    echo "trap '' INT TERM HUP"
    # Every value interpolated into these lines is shell-quoted (eoswc_sq):
    # $HOME and the user name end up in root's command line.
    Q_PATCHER="$(eoswc_sq "$STAGE/patch-binaries.py")"
    Q_BACKUP="$(eoswc_sq "$BACKUP_DIR")"
    Q_PLUGIN="$(eoswc_sq "$PLUGIN_DIR")"
    Q_CONTENTS="$(eoswc_sq "$PLUGIN_DIR/Contents")"
    Q_SVC="$(eoswc_sq "$PLUGIN_RES/EOSWebcamService")"
    Q_PROXY="$(eoswc_sq "$PLUGIN_RES/EWCProxy")"
    Q_BUNDLE_BACKUP="$(eoswc_sq "$BACKUP_DIR/$EOSWC_BUNDLE_BACKUP")"
    # Everything root prints goes to a log in staging, which this shell shows
    # afterwards, never down osascript's pipe: if osascript dies (Ctrl-C
    # reaches it too), that pipe closes, and the next write would kill the
    # patcher or codesign part-way, leaving a patched plug-in with invalid
    # signatures (seen in the VM: BrokenPipeError, then set -e).
    echo "exec > $(eoswc_sq "$STAGE/root.log") 2>&1"
    echo "echo \$\$ > $(eoswc_sq "$STAGE/root.pid")"
    # How the fork signs the patched plug-in: ad hoc (it has no certificate),
    # but keeping what Canon's signature had. Canon signs EOSWebcamService
    # and EWCProxy with the hardened runtime and the camera entitlement, and
    # the plug-in bundle without either. A plain `codesign --force --sign -`
    # (what older versions did) drops all of that. Both helpers load Canon's
    # EDSDK.framework, which under the hardened runtime needs library
    # validation turned off for an ad hoc signature (see
    # fork-entitlements.plist). The identifiers are Canon's (EOSWebcamService
    # signs as EWCService). The bundle is signed last: its seal covers the
    # helpers, which sit in Resources. No --deep: it signs nothing more here.
    Q_ENTS="$(eoswc_sq "$STAGE/entitlements.plist")"
    echo "sign_fork() {"
    echo "    codesign --force --sign - --identifier EWCService --options runtime --entitlements $Q_ENTS $Q_SVC &&"
    echo "    codesign --force --sign - --identifier EWCProxy --options runtime --entitlements $Q_ENTS $Q_PROXY &&"
    echo "    codesign --force --sign - $Q_PLUGIN"
    echo "}"
    # True if helper binary \$1 is validly signed the way sign_fork signs it.
    echo "sig_current() {"
    echo "    codesign --verify --strict \"\$1\" >/dev/null 2>&1 &&"
    echo "    codesign -dv \"\$1\" 2>&1 | grep -q 'flags=0x[0-9a-f]*([^)]*runtime' &&"
    echo "    codesign -d --entitlements - \"\$1\" 2>&1 | grep -q 'com.apple.security.cs.disable-library-validation'"
    echo "}"
    # If a step fails once patching has started, don't leave the plug-in
    # half-patched or unsigned: with a verified backup, put Canon's plug-in
    # back (the whole signed bundle if the backup has it, else the three
    # binaries, which carry Canon's own signatures); with none (the plug-in
    # was already patched), re-sign what is there.
    echo "PATCHING=0"
    echo "PLUGIN_OWNER=\"\$(stat -f '%u:%g' $Q_PLUGIN 2>/dev/null)\" || PLUGIN_OWNER=''"
    echo "root_done() {"
    echo "    rc=\$?"
    echo "    set +e"
    echo "    if [ \"\$rc\" != 0 ] && [ \"\$PATCHING\" = 1 ]; then"
    if [ "$SNAPSHOT" != none ]; then
        echo "        if [ -d $Q_BUNDLE_BACKUP ]; then"
        echo "            ditto $Q_BUNDLE_BACKUP $Q_PLUGIN &&"
        echo "                { [ -z \"\$PLUGIN_OWNER\" ] || chown -R \"\$PLUGIN_OWNER\" $Q_PLUGIN; }"
        echo "        fi"
        ROLLED_BACK_TEST=""
        for f in MacOS/EOSWebcamUtility Resources/EOSWebcamService Resources/EWCProxy; do
            Q_B="$(eoswc_sq "$BACKUP_DIR/${f#*/}")"; Q_P="$(eoswc_sq "$PLUGIN_DIR/Contents/$f")"
            echo "        cmp -s $Q_B $Q_P || cp $Q_B $Q_P"
            ROLLED_BACK_TEST="$ROLLED_BACK_TEST && cmp -s $Q_B $Q_P"
        done
        echo "        if true$ROLLED_BACK_TEST; then"
        echo "            echo 'A step failed after patching started: rolled back, the plug-in holds the Canon originals again (from the verified backup).'"
        echo "            : > $(eoswc_sq "$STAGE/rolled-back")"
        echo "        else"
        echo "            echo 'ERROR: a step failed after patching started, and rolling back from the backup failed too.'"
        echo "        fi"
    else
        echo "        if sign_fork; then"
        echo "            echo 'A step failed after patching started: re-signed the plug-in.'"
        echo "            : > $(eoswc_sq "$STAGE/re-signed")"
        echo "        fi"
    fi
    echo "    fi"
    echo "    echo \"\$rc\" > $(eoswc_sq "$STAGE/root.exit")"
    echo "}"
    echo "trap root_done EXIT"
    if [ "$NEED_INSTALLER" = 1 ]; then
        echo "installer_rc=0"
        echo "installer -pkg $(eoswc_sq "$STAGE/canon.pkg") -target / || installer_rc=\$?"
        echo "if [ \"\$installer_rc\" != 0 ]; then"
        if [ "$CAMEXT_EXPECTED" = 1 ]; then
            echo "  if [ -d $(eoswc_sq "$CANON_APPS/$EOSWC_CAMEXT_HOST") ] &&"
            echo "     [ -s $(eoswc_sq "$PLUGIN_BIN/EOSWebcamUtility") ] && [ -s $(eoswc_sq "$PLUGIN_RES/EOSWebcamService") ] && [ -s $(eoswc_sq "$PLUGIN_RES/EWCProxy") ]; then"
            echo "    echo 'Canon installer: only its Camera Extension step failed (not approved); the plug-in is installed, carrying on.'"
            echo "    : > $(eoswc_sq "$STAGE/camext-not-approved")"
            echo "  else"
            echo "    echo \"ERROR: Canon's installer failed (exit \$installer_rc), and not only at its Camera Extension step; nothing was patched.\" >&2"
            echo "    exit 1"
            echo "  fi"
        else
            echo "  echo \"ERROR: Canon's installer failed (exit \$installer_rc); nothing was patched.\" >&2"
            echo "  exit 1"
        fi
        echo "fi"
        # Canon's installer just wrote the plug-in: its owner now.
        echo "PLUGIN_OWNER=\"\$(stat -f '%u:%g' $Q_PLUGIN 2>/dev/null)\" || PLUGIN_OWNER=''"
    fi
    # If a check below fails because the staged patcher is gone, say so: this
    # shell's EXIT trap deletes staging, so an installer that stopped (e.g.
    # killed) while root ran leaves root without it. That is not a bad backup.
    STAGE_GONE_CHECK="[ -f $Q_PATCHER ] || { echo 'ERROR: the installer staging folder disappeared while the admin step was running (the installer was stopped part-way), so the check could not run; nothing was patched. Re-run the installer.' >&2; exit 1; };"
    # errorNoDevice.jpg is re-owned below (to you); record the owner Canon's
    # file has now (Canon ships it as uid 502:staff) so uninstall can put it
    # back. Only while the plug-in still holds Canon's originals, and never
    # over an existing record.
    Q_NODEV_OWNER="$(eoswc_sq "$BACKUP_DIR/errorNoDevice.owner")"
    RECORD_NODEV_OWNER="[ ! -e $(eoswc_sq "$PLUGIN_RES/errorNoDevice.jpg") ] || [ -s $Q_NODEV_OWNER ] || stat -f '%u:%g' $(eoswc_sq "$PLUGIN_RES/errorNoDevice.jpg") > $Q_NODEV_OWNER || true"
    case "$SNAPSHOT" in
    new)
        # Back up the whole signed plug-in (ditto keeps every byte, the
        # _CodeSignature and Info.plist, modes and times) and verify it before
        # patching: never patch without a restorable copy of Canon's plug-in.
        # The flat copies older uninstallers read are hard links into it (no
        # second ~11 MB), or plain copies where a link can't be made.
        echo "ditto $Q_PLUGIN $Q_BUNDLE_BACKUP || { echo 'ERROR: could not back up the plug-in ($EOSWC_BUNDLE_BACKUP); nothing was patched.' >&2; exit 1; }"
        for f in MacOS/EOSWebcamUtility Resources/EOSWebcamService Resources/EWCProxy; do
            Q_SRC="$(eoswc_sq "$BACKUP_DIR/$EOSWC_BUNDLE_BACKUP/Contents/$f")"
            echo "ln $Q_SRC $Q_BACKUP/ 2>/dev/null || cp $Q_SRC $Q_BACKUP/ || { echo 'ERROR: could not back up ${f#*/}; nothing was patched.' >&2; exit 1; }"
        done
        for f in EWCPairingService errorNoDevice.jpg errorBusy.jpg default.jpg; do
            Q_SRC="$(eoswc_sq "$BACKUP_DIR/$EOSWC_BUNDLE_BACKUP/Contents/Resources/$f")"
            echo "[ ! -e $Q_SRC ] || ln $Q_SRC $Q_BACKUP/ 2>/dev/null || cp $Q_SRC $Q_BACKUP/ 2>/dev/null || true"
        done
        echo "[ -z \"\$PLUGIN_OWNER\" ] || echo \"\$PLUGIN_OWNER\" > $(eoswc_sq "$BACKUP_DIR/plugin.owner")"
        echo "$RECORD_NODEV_OWNER"
        echo "chown -R $(eoswc_sq "$USERNAME") $Q_BACKUP 2>/dev/null || true"
        echo "/usr/bin/python3 $Q_PATCHER --check-original $Q_BACKUP || { $STAGE_GONE_CHECK echo 'ERROR: the backup does not hold complete original Canon v1.3.16 binaries; nothing was patched.' >&2; exit 1; }"
        echo "/usr/bin/python3 $Q_PATCHER --same-code $Q_BACKUP $(eoswc_sq "$BACKUP_DIR/$EOSWC_BUNDLE_BACKUP/Contents") >/dev/null || { echo 'ERROR: the backed-up plug-in does not match the backed-up binaries; nothing was patched.' >&2; exit 1; }" ;;
    reuse)
        # The existing backup must still hold what is installed: the same
        # code (older uninstallers re-signed the originals they put back).
        echo "/usr/bin/python3 $Q_PATCHER --same-code $Q_BACKUP $Q_CONTENTS || { $STAGE_GONE_CHECK echo 'ERROR: the installed binaries no longer match the backup; nothing was patched. Re-run the installer.' >&2; exit 1; }"
        echo "$RECORD_NODEV_OWNER"
        echo "chown $(eoswc_sq "$USERNAME") $(eoswc_sq "$BACKUP_DIR/errorNoDevice.owner") 2>/dev/null || true"
        echo "/usr/bin/python3 $Q_PATCHER --check-original $Q_BACKUP || { $STAGE_GONE_CHECK echo 'ERROR: the backup does not hold complete original Canon v1.3.16 binaries; nothing was patched.' >&2; exit 1; }" ;;
    none)
        # No backup was taken, so only go on if the plug-in holds the fork's
        # patched binaries (this or an earlier version: the patcher brings
        # those up to date by putting Canon's bytes back where this version
        # no longer patches).
        echo "/usr/bin/python3 $Q_PATCHER --check-fork $Q_CONTENTS || { $STAGE_GONE_CHECK echo 'ERROR: the plug-in is not fully patched and no backup was taken; nothing was patched. Re-run the installer.' >&2; exit 1; }" ;;
    esac
    # Nothing to patch and already signed the way sign_fork signs: leave the
    # signatures alone (re-running the installer used to re-sign every time).
    echo "WAS_CURRENT=0"
    echo "/usr/bin/python3 $Q_PATCHER --check-patched $Q_CONTENTS >/dev/null 2>&1 && WAS_CURRENT=1"
    echo "PATCHING=1"
    echo "/usr/bin/python3 $Q_PATCHER $Q_CONTENTS"
    echo "chmod 755 $(eoswc_sq "$PLUGIN_BIN/EOSWebcamUtility") $Q_SVC $Q_PROXY"
    # Canon's loading-screen JPEGs. Older installers made all three
    # world-writable (666), so any process of any user could change what
    # every app shows. errorNoDevice.jpg is the only one the fork writes (the
    # camera manager, running as you, swaps the loading screen into it), so it
    # is yours, 644: writable by your own processes only, the same ones that
    # can already change the daemon in ~/Library. The other two go back to
    # Canon's 644; their owner is left as Canon shipped it.
    Q_NODEV="$(eoswc_sq "$PLUGIN_RES/errorNoDevice.jpg")"
    echo "[ -e $Q_NODEV ] || : > $Q_NODEV"
    echo "chown $(eoswc_sq "$USERNAME:staff") $Q_NODEV"
    echo "chmod 644 $Q_NODEV"
    for f in errorBusy.jpg default.jpg; do
        echo "[ ! -e $(eoswc_sq "$PLUGIN_RES/$f") ] || chmod 644 $(eoswc_sq "$PLUGIN_RES/$f")"
    done
    echo "if [ \"\$WAS_CURRENT\" = 1 ] && sig_current $Q_SVC && sig_current $Q_PROXY; then"
    echo "    echo 'Already patched and signed by this version: not re-signing.'"
    echo "    : > $(eoswc_sq "$STAGE/not-re-signed")"
    echo "else"
    echo "    sign_fork"
    echo "fi"
} > "$ROOT_SCRIPT"
chmod 700 "$ROOT_SCRIPT"
ROOT_OK=1
osascript -e "do shell script \"bash '$ROOT_SCRIPT'\" with administrator privileges" || ROOT_OK=0
show_root_log
if [ "$ROOT_OK" = 0 ]; then
    echo ""
    echo "  ERROR: the admin step failed or was cancelled (see above)."
    if [ -e "$STAGE/rolled-back" ]; then
        echo "  Canon's original binaries are safe in $BACKUP_DIR"
        echo "  (verified), and the half-done patch was rolled back: the plug-in holds"
        echo "  them again. Re-run the installer to try again."
    elif [ -e "$STAGE/re-signed" ]; then
        echo "  The plug-in was re-signed after the failed step. Re-run the installer."
    elif [ "$SNAPSHOT" != none ] && python3 "$PATCHER" --check-original "$BACKUP_DIR" >/dev/null 2>&1; then
        # The backup is verified before the patcher runs, so the patcher may
        # have run and stopped part-way.
        echo "  Canon's original binaries are safe in $BACKUP_DIR"
        echo "  (verified). If the plug-in was left part-patched, run uninstall.sh to"
        echo "  restore them, then re-run the installer."
    else
        # Without a verified backup the root step stops before the patcher.
        echo "  Nothing was patched."
    fi
    exit 1
fi
CAMEXT_PENDING=0
[ -e "$STAGE/camext-not-approved" ] && CAMEXT_PENDING=1
RESIGNED=1
[ -e "$STAGE/not-re-signed" ] && RESIGNED=0
rm -rf "$STAGE"
STAGE=""
if [ "$RESIGNED" = 1 ]; then
    echo "  Patched and signed (ad hoc, with Canon's hardened runtime and camera entitlement)"
else
    echo "  Already patched and signed: nothing changed"
fi

# --- Config ---
echo "[6/7] Writing config, daemon, screens, and auto-start..."
mkdir -p "$SUPPORT_DIR"

cat > "$SUPPORT_DIR/config.plist" << 'CFGEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>HeadlessStreamHeight</key><string>1080</string>
	<key>HeadlessStreamWidth</key><string>1920</string>
	<key>LogLevel</key><string>2</string>
	<key>OptimizationMode</key><string>1</string>
	<key>PreviewFps</key><string>30</string>
	<key>SourceResolution</key><string>1</string>
	<key>StartupSceneId</key><string>0</string>
	<key>StreamFps</key><string>30</string>
	<key>StreamHeight</key><string>1080</string>
	<key>StreamWidth</key><string>1920</string>
	<key>SyncCameraTimeOnRecord</key><string>0</string>
	<key>TestEnvironment</key><string>0</string>
	<key>Transition</key><string>0</string>
	<key>TransitionLength</key><string>1000</string>
</dict>
</plist>
CFGEOF

cat > "$SUPPORT_DIR/proconfig.plist" << 'PROEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>StartupSceneId</key><string>0</string>
	<key>StreamFps</key><string>30</string>
	<key>StreamHeight</key><string>1080</string>
	<key>StreamWidth</key><string>1920</string>
	<key>SyncCameraTimeOnRecord</key><string>0</string>
	<key>Transition</key><string>0</string>
	<key>TransitionLength</key><string>1000</string>
</dict>
</plist>
PROEOF
echo "  Config: 1920x1080 @ 30fps"

# Camera manager daemon
mkdir -p "$RUNTIME_DIR"
cp "$SCRIPT_DIR/eos-camera-manager.sh" "$RUNTIME_DIR/"
chmod +x "$RUNTIME_DIR/eos-camera-manager.sh"
echo "  Daemon: $RUNTIME_DIR/eos-camera-manager.sh"

# Loading screens. The daemon and the generator both resolve images relative to
# themselves, so all three live together in the runtime dir — regenerating with
# your own logo there is picked up without another copy step.
if [ -d "$SCRIPT_DIR/images" ]; then
    # Only the files uninstall.sh knows to remove (EOSWC_RUNTIME_FILES).
    cp "$SCRIPT_DIR/images/errorNoDevice_connecting.jpg" \
       "$SCRIPT_DIR/images/errorNoDevice_disconnected.jpg" "$RUNTIME_DIR/" 2>/dev/null || true
    cp "$SCRIPT_DIR/images/generate-images.sh" "$RUNTIME_DIR/" 2>/dev/null || true
    chmod +x "$RUNTIME_DIR/generate-images.sh" 2>/dev/null || true
    if [ -f "$RUNTIME_DIR/errorNoDevice_connecting.jpg" ]; then
        cp "$RUNTIME_DIR/errorNoDevice_connecting.jpg" "$PLUGIN_RES/errorNoDevice.jpg" 2>/dev/null || true
    fi
    echo "  Custom loading screens installed"
fi

# Upgrade from an in-clone install: carry a custom logo over, then remove the
# old daemon copy and its images (the LaunchAgent is rewritten below). The
# logo itself is left where it was.
migrate_legacy_dir() {
    local dir="$1" logo
    [ -n "$dir" ] && [ -d "$dir" ] || return 0
    [ "$dir" -ef "$RUNTIME_DIR" ] && return 0
    for logo in $EOSWC_LOGO_FILES; do
        if [ -f "$dir/$logo" ] && [ ! -e "$RUNTIME_DIR/$logo" ]; then
            cp "$dir/$logo" "$RUNTIME_DIR/$logo"
            echo "  Copied your $logo to $RUNTIME_DIR/"
            echo "  (re-run generate-images.sh there to put it back on the loading screen)"
        fi
    done
    eoswc_remove_legacy_runtime "$dir"
}
if [ -n "$OLD_DAEMON" ]; then
    migrate_legacy_dir "$(dirname "$OLD_DAEMON")"
fi
migrate_legacy_dir "$INSTALL_DIR"

# Auto-start
rm -f "$LAUNCH_AGENTS/com.eos-camera-manager.plist" 2>/dev/null
mkdir -p "$LAUNCH_AGENTS"
cat > "$LAUNCH_AGENTS/com.eos-camera-manager.plist" << LAEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.eos-camera-manager</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>${RUNTIME_DIR}/eos-camera-manager.sh</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>StandardOutPath</key>
	<string>${LOG_DIR}/eos-camera-manager-stdout.log</string>
	<key>StandardErrorPath</key>
	<string>${LOG_DIR}/eos-camera-manager-stderr.log</string>
</dict>
</plist>
LAEOF
echo "  Auto-start configured"

# --- Start ---
echo "[7/7] Starting services..."
launchctl load "$LAUNCH_AGENT_SYS" 2>/dev/null || true
sleep 1
launchctl load "$LAUNCH_AGENTS/com.eos-camera-manager.plist" 2>/dev/null || true
INSTALL_COMPLETE=1

# Give a job that can't start (e.g. exit 126) time to fall over before
# checking; eoswc_job_running reads the PID column, not mere presence.
sleep 2
SVC=0; eoswc_job_running "$EOSWC_CANON_LABEL" && SVC=1
MGR=0; eoswc_job_running "$EOSWC_AGENT_LABEL" && MGR=1

echo ""
echo "============================================"
echo "  Installation complete!"
echo "============================================"
echo ""
echo "  Version:        v${VERSION}"
echo "  Mode:           ${INSTALL_TYPE}"
echo "  Resolution:     1920x1080 @ 30fps"
echo "  EOS Service:    $([ "$SVC" -gt 0 ] && echo "RUNNING" || echo "NOT RUNNING")"
echo "  Camera Manager: $([ "$MGR" -gt 0 ] && echo "RUNNING" || echo "NOT RUNNING")"
echo "  Backups:        ${BACKUP_DIR:-${EXISTING_BACKUP:-none (see the warning above)}}"
if [ "$SVC" = 0 ] || [ "$MGR" = 0 ]; then
    echo ""
    echo "  Something isn't running. Check $LOG_DIR/eos-camera-manager-stderr.log"
    echo "  and run: bash '$SCRIPT_DIR/diagnose.sh'"
fi
# Canon's Camera Extension (macOS 14+): not the fork's, not patched by it.
CAMEXT_STATE="$(eoswc_camera_extension_state)"
if [ "$CAMEXT_PENDING" = 1 ] || [ -d "$CANON_APPS/$EOSWC_CAMEXT_HOST" ] ||
   { [ "$CAMEXT_STATE" != "not registered" ] && [ "$CAMEXT_STATE" != unknown ]; }; then
    echo ""
    echo "  Canon's Camera Extension: $CAMEXT_STATE"
    if [ "$CAMEXT_PENDING" = 1 ]; then
        echo "    Canon's installer reported an error only because this extension"
        echo "    wasn't approved. That is expected: the fork doesn't need it."
    fi
    echo "    Canon's package also includes a Camera Extension. If it is (or you later"
    echo "    get it) approved in System Settings, apps list a SECOND camera called"
    echo "    'EOS Webcam Utility'. The fork doesn't patch that one."
    eoswc_camera_extension_removal_help "    "
fi
echo ""
echo "  Usage:"
echo "    1. Connect your EOS camera via USB"
echo "    2. Open Zoom/Meet/Teams"
echo "    3. Select 'EOS Webcam Utility' as camera"
echo "    4. Camera connects automatically (~20-30s)"
echo ""
echo "  Custom logo (optional):"
echo "    1. Place logo.png in $RUNTIME_DIR/"
echo "    2. Run: '$RUNTIME_DIR/generate-images.sh'"
echo ""
echo "  Uninstall: bash $SCRIPT_DIR/uninstall.sh"
echo "============================================"
