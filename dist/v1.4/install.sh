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
#   - Admin privileges (will prompt)
#   - Internet access (only if Canon's package needs to be downloaded)
#
# Usage: bash install.sh [--pkg PATH] [--agree]
#

set -e

VERSION="1.4.1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCHER="$SCRIPT_DIR/patch-binaries.py"
PLUGIN_DIR="/Library/CoreMediaIO/Plug-Ins/DAL/EOSWebcamUtility.plugin"
PLUGIN_RES="$PLUGIN_DIR/Contents/Resources"
PLUGIN_BIN="$PLUGIN_DIR/Contents/MacOS"
LAUNCH_AGENT_SYS="/Library/LaunchAgents/com.canon.usa.EWCService.plist"
USER_HOME="$HOME"
USERNAME="$(whoami)"
SUPPORT_DIR="$USER_HOME/Library/Application Support/EWCService"
LAUNCH_AGENTS="$USER_HOME/Library/LaunchAgents"
# Install the daemon/images into the clone this script was run from.
INSTALL_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
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
cleanup() {
    [ -n "$WORK" ] && rm -rf "$WORK" 2>/dev/null || true
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
if ! command -v python3 >/dev/null 2>&1; then
    echo "  ERROR: python3 is required (ships with macOS developer tools). Run 'xcode-select --install'."
    exit 1
fi
if [ ! -f "$PATCHER" ]; then
    echo "  ERROR: patch-binaries.py not found next to this script."
    exit 1
fi

# Decide where Canon's original binaries will come from.
SOURCE=""          # installed | download | userpkg
INSTALL_TYPE="fresh"
if [ -d "$PLUGIN_DIR" ]; then
    SOURCE="installed"
    EXISTING=$(python3 -c "
try:
    with open('$PLUGIN_RES/EOSWebcamService', 'rb') as f:
        d = f.read()
    print('fork' if d[0x89b58:0x89b5c] == bytes.fromhex('20008052') else 'original')
except Exception:
    print('original')
" 2>/dev/null || echo "original")
    [ "$EXISTING" = "fork" ] && INSTALL_TYPE="upgrade_fork" || INSTALL_TYPE="upgrade_original"
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
        if [ ! -f "$USER_PKG" ]; then
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
BACKUP_DIR="$INSTALL_DIR/backups/pre-v${VERSION}-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp "$SUPPORT_DIR/config.plist" "$BACKUP_DIR/" 2>/dev/null || true
cp "$SUPPORT_DIR/proconfig.plist" "$BACKUP_DIR/" 2>/dev/null || true
echo "  Backup dir: $BACKUP_DIR"

# --- Stop services ---
echo "[5/8] Stopping existing services..."
launchctl unload "$LAUNCH_AGENTS/com.eos-camera-manager.plist" 2>/dev/null || true
launchctl unload "$LAUNCH_AGENT_SYS" 2>/dev/null || true
pkill -9 EOSWebcamServic 2>/dev/null || true
pkill -9 EWCProxy 2>/dev/null || true
SERVICES_STOPPED=1
sleep 1
echo "  Done"

# --- Install (if needed), snapshot originals, patch, sign (single admin step) ---
echo "[6/8] Installing Canon base (if needed), patching, and signing..."
ROOT_SCRIPT="$(mktemp -t eoswc-deploy)"
{
    echo '#!/bin/bash'
    echo 'set -e'
    [ "$NEED_INSTALLER" = 1 ] && echo "installer -pkg '$PKG_FILE' -target /"
    # Snapshot the pristine originals before patching so uninstall can restore them.
    echo "mkdir -p '$BACKUP_DIR'"
    echo "for f in '$PLUGIN_BIN/EOSWebcamUtility' '$PLUGIN_RES/EOSWebcamService' '$PLUGIN_RES/EWCProxy' '$PLUGIN_RES/EWCPairingService' '$PLUGIN_RES/errorNoDevice.jpg' '$PLUGIN_RES/errorBusy.jpg' '$PLUGIN_RES/default.jpg'; do [ -e \"\$f\" ] && cp \"\$f\" '$BACKUP_DIR/' 2>/dev/null || true; done"
    echo "/usr/bin/python3 '$PATCHER' '$PLUGIN_DIR/Contents'"
    echo "chmod 755 '$PLUGIN_BIN/EOSWebcamUtility' '$PLUGIN_RES/EOSWebcamService' '$PLUGIN_RES/EWCProxy'"
    echo "chmod 666 '$PLUGIN_RES/errorNoDevice.jpg' 2>/dev/null || true"
    echo "chmod 666 '$PLUGIN_RES/errorBusy.jpg' 2>/dev/null || true"
    echo "chmod 666 '$PLUGIN_RES/default.jpg' 2>/dev/null || true"
    echo "codesign --force --sign - '$PLUGIN_BIN/EOSWebcamUtility'"
    echo "codesign --force --sign - '$PLUGIN_RES/EOSWebcamService'"
    echo "codesign --force --sign - '$PLUGIN_RES/EWCProxy'"
    echo "codesign --force --deep --sign - '$PLUGIN_DIR'"
    echo "chown -R '$USERNAME' '$BACKUP_DIR' 2>/dev/null || true"
} > "$ROOT_SCRIPT"
chmod 700 "$ROOT_SCRIPT"
osascript -e "do shell script \"bash '$ROOT_SCRIPT'\" with administrator privileges"
rm -f "$ROOT_SCRIPT"
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
mkdir -p "$INSTALL_DIR"
cp "$SCRIPT_DIR/eos-camera-manager.sh" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/eos-camera-manager.sh"
echo "  Daemon: $INSTALL_DIR/eos-camera-manager.sh"

# Loading screens
if [ -d "$SCRIPT_DIR/images" ]; then
    cp "$SCRIPT_DIR/images/"*.jpg "$INSTALL_DIR/" 2>/dev/null || true
    cp "$SCRIPT_DIR/images/generate-images.sh" "$INSTALL_DIR/" 2>/dev/null || true
    chmod +x "$INSTALL_DIR/generate-images.sh" 2>/dev/null || true
    if [ -f "$INSTALL_DIR/errorNoDevice_connecting.jpg" ]; then
        cp "$INSTALL_DIR/errorNoDevice_connecting.jpg" "$PLUGIN_RES/errorNoDevice.jpg" 2>/dev/null || true
    fi
    echo "  Custom loading screens installed"
fi

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
		<string>${INSTALL_DIR}/eos-camera-manager.sh</string>
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

SVC=$(launchctl list 2>/dev/null | grep -c "com.canon.usa.EWCService" || true)
MGR=$(launchctl list 2>/dev/null | grep -c "com.eos-camera-manager" || true)

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
echo "  Backups:        $BACKUP_DIR"
echo ""
echo "  Usage:"
echo "    1. Connect your EOS camera via USB"
echo "    2. Open Zoom/Meet/Teams"
echo "    3. Select 'EOS Webcam Utility' as camera"
echo "    4. Camera connects automatically (~20-30s)"
echo ""
echo "  Custom logo (optional):"
echo "    1. Place logo.png in $INSTALL_DIR/"
echo "    2. Run: $INSTALL_DIR/generate-images.sh"
echo ""
echo "  Uninstall: bash $SCRIPT_DIR/uninstall.sh"
echo "============================================"
