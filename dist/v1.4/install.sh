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
#
# Requirements:
#   - macOS on Apple Silicon (M1/M2/M3/M4)
#   - Admin privileges (run WITHOUT sudo; you'll be prompted for your password)
#   - Internet access (only if Canon's package needs to be downloaded)
#
# Usage: bash install.sh [--pkg PATH] [--agree]
#

set -e

VERSION="1.4.1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCHER="$SCRIPT_DIR/patch-binaries.py"
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

# --- Args ---
USER_PKG=""
AGREED=0
while [ $# -gt 0 ]; do
    case "$1" in
        --pkg) USER_PKG="$2"; shift 2 ;;
        --agree|--yes|-y) AGREED=1; shift ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -30
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# --- Failure safety ---
# If the install is interrupted after we've stopped the existing services,
# restart Canon's service on exit so the machine isn't left without a camera.
SERVICES_STOPPED=0
INSTALL_COMPLETE=0
WORK=""
STAGE=""
BACKUP_DIR=""
# Staging only ever holds copies of things that exist elsewhere (the patcher,
# the Canon .pkg, the root script): Canon's originals go straight from the
# plug-in into BACKUP_DIR, so deleting staging can never lose them.
cleanup() {
    [ -n "$WORK" ] && rm -rf "$WORK" 2>/dev/null || true
    [ -n "$STAGE" ] && rm -rf "$STAGE" 2>/dev/null || true
    if [ "$INSTALL_COMPLETE" != 1 ] && [ "$SERVICES_STOPPED" = 1 ]; then
        echo ""
        echo "  Install did not finish — restarting Canon's service so your existing"
        echo "  camera setup keeps working. Re-run the installer to try again."
        launchctl load "$LAUNCH_AGENT_SYS" 2>/dev/null || true
    fi
}
trap cleanup EXIT

echo ""
echo "============================================"
echo "  EOS Webcam Utility Fork v${VERSION}"
echo "  Installer"
echo "============================================"
echo ""

# --- Pre-flight checks ---
echo "[1/8] Pre-flight checks..."

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

# Decide where Canon's original binaries will come from.
SOURCE=""          # installed | download | userpkg
INSTALL_TYPE="fresh"
if [ -d "$PLUGIN_DIR" ]; then
    SOURCE="installed"
    # Only these two states are safe to go on from: Canon's complete v1.3.16
    # originals (back them up, then patch) or the fork's fully patched
    # binaries (nothing to back up or patch). Anything else (a different
    # build, a half-patched or truncated binary) could not be restored.
    if python3 "$PATCHER" --check-patched "$PLUGIN_DIR/Contents" >/dev/null 2>&1; then
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
    installed) echo "  Canon source:  already installed (patch in place)" ;;
    userpkg)   echo "  Canon source:  $USER_PKG" ;;
    download)  echo "  Canon source:  download from Canon" ;;
esac
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
echo "[2/8] Obtaining Canon base software..."
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
            PKG_FILE=$(/usr/bin/find "$WORK/unz" -name '*.pkg' -maxdepth 3 | head -1) ;;
        *.pkg)
            PKG_FILE="$SRC" ;;
        *)
            echo "  ERROR: --pkg must be a .zip or .pkg"; exit 1 ;;
    esac
    if [ -z "$PKG_FILE" ] || [ ! -e "$PKG_FILE" ]; then
        echo "  ERROR: no .pkg found in the supplied package."
        exit 1
    fi
    NEED_INSTALLER=1
    echo "  Package ready: $(basename "$PKG_FILE")"
fi
echo ""

# --- Acquire admin up front ---
# Prompt now, before anything is torn down, so cancelling aborts cleanly.
echo "[3/8] Requesting admin privileges (needed to install system files)..."
osascript -e 'do shell script "true" with administrator privileges'
echo ""

# --- Back up existing user config (binaries are snapshotted below, as root) ---
echo "[4/8] Creating backups..."
# SNAPSHOT: new = copy Canon's originals into a new backup dir; reuse = an
# existing backup already holds exactly the installed originals; none = the
# installed binaries are already patched, so there are no originals to copy
# (and nothing below changes them). Each install run used to add another
# ~11.5 MB backup, patched or not.
SNAPSHOT=new
[ "$INSTALL_TYPE" = upgrade_fork ] && SNAPSHOT=none
EXISTING_BACKUP=""
# The newest backup that verifies as Canon's originals, in any location.
while IFS= read -r d; do
    if python3 "$PATCHER" --check-original "$d" >/dev/null 2>&1; then
        EXISTING_BACKUP="$d"
        break
    fi
done < <(eoswc_backup_candidates "$INSTALL_DIR")
if [ "$SNAPSHOT" = new ] && [ "$INSTALL_TYPE" = upgrade_original ] && [ -n "$EXISTING_BACKUP" ]; then
    # Reusable only from Application Support: root can't read an older
    # backup left in a privacy-protected clone, and must re-check it.
    case "$EXISTING_BACKUP" in "$BACKUP_ROOT"/*)
        if cmp -s "$PLUGIN_BIN/EOSWebcamUtility" "$EXISTING_BACKUP/EOSWebcamUtility" &&
           cmp -s "$PLUGIN_RES/EOSWebcamService" "$EXISTING_BACKUP/EOSWebcamService" &&
           cmp -s "$PLUGIN_RES/EWCProxy" "$EXISTING_BACKUP/EWCProxy"; then
            SNAPSHOT=reuse
        fi ;;
    esac
fi
if [ "$SNAPSHOT" = new ]; then
    BACKUP_DIR="$BACKUP_ROOT/pre-v${VERSION}-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    cp "$SUPPORT_DIR/config.plist" "$BACKUP_DIR/" 2>/dev/null || true
    cp "$SUPPORT_DIR/proconfig.plist" "$BACKUP_DIR/" 2>/dev/null || true
    echo "  Backup dir: $BACKUP_DIR"
    echo "  (Canon's original binaries are copied here and verified before anything is patched.)"
elif [ "$SNAPSHOT" = reuse ]; then
    BACKUP_DIR="$EXISTING_BACKUP"
    echo "  Canon's original binaries are already backed up in $BACKUP_DIR"
    echo "  (it holds exactly the installed files; no new copy needed)."
else
    echo "  The installed binaries are already patched: no Canon originals to back up."
    if [ -n "$EXISTING_BACKUP" ]; then
        echo "  Existing backup of Canon's originals: $EXISTING_BACKUP"
    else
        echo "  WARNING: no backup of Canon's original binaries was found, so uninstall.sh"
        echo "           will not be able to restore them. Reinstalling Canon's v1.3.16"
        echo "           package gets them back."
    fi
fi

# --- Stop services ---
echo "[5/8] Stopping existing services..."
# Older installers ran the daemon out of the clone; note where, so that copy
# can be cleaned up once the new one is in place.
OLD_DAEMON="$(eoswc_agent_daemon_path "$LAUNCH_AGENTS/com.eos-camera-manager.plist")"
launchctl unload "$LAUNCH_AGENTS/com.eos-camera-manager.plist" 2>/dev/null || true
launchctl unload "$LAUNCH_AGENT_SYS" 2>/dev/null || true
pkill -9 EOSWebcamServic 2>/dev/null || true
pkill -9 EWCProxy 2>/dev/null || true
SERVICES_STOPPED=1
sleep 1
echo "  Done"

# --- Install (if needed), back up originals, patch, sign (single admin step) ---
echo "[6/8] Installing Canon base (if needed), patching, and signing..."
# The elevated shell osascript spawns inherits no TCC access to user folders
# (~/Downloads, ~/Desktop, ~/Documents, iCloud Drive...), so reading the patcher
# or the .pkg there fails with "Operation not permitted" even as root. Those are
# staged through a temp dir. The backup goes to BACKUP_DIR in Application
# Support, which root can write, so Canon's originals never sit only in a temp
# dir that macOS may purge.
STAGE="$(mktemp -d -t eoswc-stage)"
cp "$PATCHER" "$STAGE/patch-binaries.py"
if [ "$NEED_INSTALLER" = 1 ]; then
    # -R: a .pkg is either a flat file or a bundle-style directory.
    cp -R "$PKG_FILE" "$STAGE/canon.pkg"
fi
ROOT_SCRIPT="$STAGE/deploy.sh"
{
    echo '#!/bin/bash'
    echo 'set -e'
    [ "$NEED_INSTALLER" = 1 ] && echo "installer -pkg '$STAGE/canon.pkg' -target /"
    # Every value interpolated into these lines is shell-quoted (eoswc_sq):
    # $HOME and the user name end up in root's command line.
    Q_PATCHER="$(eoswc_sq "$STAGE/patch-binaries.py")"
    Q_BACKUP="$(eoswc_sq "$BACKUP_DIR")"
    case "$SNAPSHOT" in
    new)
        # Back up the pristine originals and verify the backup before patching:
        # never patch without a restorable copy of the three patched binaries.
        for f in "$PLUGIN_BIN/EOSWebcamUtility" "$PLUGIN_RES/EOSWebcamService" "$PLUGIN_RES/EWCProxy"; do
            echo "cp $(eoswc_sq "$f") $Q_BACKUP/ || { echo 'ERROR: could not back up $(basename "$f"); nothing was patched.' >&2; exit 1; }"
        done
        for f in EWCPairingService errorNoDevice.jpg errorBusy.jpg default.jpg; do
            echo "[ ! -e $(eoswc_sq "$PLUGIN_RES/$f") ] || cp $(eoswc_sq "$PLUGIN_RES/$f") $Q_BACKUP/ 2>/dev/null || true"
        done
        echo "chown -R $(eoswc_sq "$USERNAME") $Q_BACKUP 2>/dev/null || true"
        echo "/usr/bin/python3 $Q_PATCHER --check-original $Q_BACKUP || { echo 'ERROR: the backup does not hold complete original Canon v1.3.16 binaries; nothing was patched.' >&2; exit 1; }" ;;
    reuse)
        # The existing backup must still hold exactly what is installed.
        for f in "$PLUGIN_BIN/EOSWebcamUtility" "$PLUGIN_RES/EOSWebcamService" "$PLUGIN_RES/EWCProxy"; do
            echo "cmp -s $(eoswc_sq "$f") $(eoswc_sq "$BACKUP_DIR/$(basename "$f")") || { echo 'ERROR: $(basename "$f") no longer matches the backup; nothing was patched. Re-run the installer.' >&2; exit 1; }"
        done
        echo "/usr/bin/python3 $Q_PATCHER --check-original $Q_BACKUP || { echo 'ERROR: the backup does not hold complete original Canon v1.3.16 binaries; nothing was patched.' >&2; exit 1; }" ;;
    none)
        # No backup was taken, so only go on if there is nothing left to patch.
        echo "/usr/bin/python3 $Q_PATCHER --check-patched $(eoswc_sq "$PLUGIN_DIR/Contents") || { echo 'ERROR: the plug-in is not fully patched and no backup was taken; nothing was patched. Re-run the installer.' >&2; exit 1; }" ;;
    esac
    echo "/usr/bin/python3 $Q_PATCHER $(eoswc_sq "$PLUGIN_DIR/Contents")"
    echo "chmod 755 '$PLUGIN_BIN/EOSWebcamUtility' '$PLUGIN_RES/EOSWebcamService' '$PLUGIN_RES/EWCProxy'"
    echo "chmod 666 '$PLUGIN_RES/errorNoDevice.jpg' 2>/dev/null || true"
    echo "chmod 666 '$PLUGIN_RES/errorBusy.jpg' 2>/dev/null || true"
    echo "chmod 666 '$PLUGIN_RES/default.jpg' 2>/dev/null || true"
    echo "codesign --force --sign - '$PLUGIN_BIN/EOSWebcamUtility'"
    echo "codesign --force --sign - '$PLUGIN_RES/EOSWebcamService'"
    echo "codesign --force --sign - '$PLUGIN_RES/EWCProxy'"
    echo "codesign --force --deep --sign - '$PLUGIN_DIR'"
} > "$ROOT_SCRIPT"
chmod 700 "$ROOT_SCRIPT"
if ! osascript -e "do shell script \"bash '$ROOT_SCRIPT'\" with administrator privileges"; then
    echo ""
    echo "  ERROR: the admin step failed (see above)."
    if [ "$SNAPSHOT" != none ] && python3 "$PATCHER" --check-original "$BACKUP_DIR" >/dev/null 2>&1; then
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
rm -rf "$STAGE"
STAGE=""
echo "  Patched and signed"

# --- Config ---
echo "[7/8] Writing config, daemon, screens, and auto-start..."
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
echo "[8/8] Starting services..."
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
