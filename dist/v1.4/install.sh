#!/bin/bash
#
# EOS Webcam Utility Fork v1.4 — Standalone Installer
#
# Installs a patched EOS Webcam Utility fork that provides:
#   - 1080p output (upscaled from camera's native ~1024x576)
#   - No subscription needed
#   - Auto-retry camera activation
#   - Custom loading/disconnected screens with optional logo
#
# Works on:
#   - Clean Mac (no existing EOS Webcam Utility)
#   - Mac with EOS Webcam Utility v1.3.x installed
#   - Mac with a previous fork version installed
#
# Requirements:
#   - macOS on Apple Silicon (M1/M2/M3/M4)
#   - Admin privileges (will prompt)
#
# Usage: bash install.sh
#

set -e

VERSION="1.4"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_DIR="$SCRIPT_DIR/bundle"
PLUGIN_DIR="/Library/CoreMediaIO/Plug-Ins/DAL/EOSWebcamUtility.plugin"
PLUGIN_X86="/Library/CoreMediaIO/Plug-Ins/DAL/EOSWebcamUtility_x86_64.plugin"
PLUGIN_RES="$PLUGIN_DIR/Contents/Resources"
PLUGIN_BIN="$PLUGIN_DIR/Contents/MacOS"
FRAMEWORK_DIR="/Library/Frameworks/EDSDK.framework"
LAUNCH_AGENT_SYS="/Library/LaunchAgents/com.canon.usa.EWCService.plist"
USER_HOME="$HOME"
USERNAME="$(whoami)"
SUPPORT_DIR="$USER_HOME/Library/Application Support/EWCService"
LAUNCH_AGENTS="$USER_HOME/Library/LaunchAgents"
INSTALL_DIR="$USER_HOME/development/webcam-utility"
LOG_DIR="$USER_HOME/Library/Logs"

echo ""
echo "============================================"
echo "  EOS Webcam Utility Fork v${VERSION}"
echo "  Standalone Installer"
echo "============================================"
echo ""

# --- Pre-flight checks ---
echo "[1/9] Pre-flight checks..."

ARCH=$(uname -m)
if [ "$ARCH" != "arm64" ]; then
    echo "  ERROR: Requires Apple Silicon (arm64). Detected: $ARCH"
    exit 1
fi

if [ ! -d "$BUNDLE_DIR" ]; then
    echo "  ERROR: Bundle directory not found. Ensure full package is extracted."
    exit 1
fi

INSTALL_TYPE="fresh"
if [ -d "$PLUGIN_DIR" ]; then
    EXISTING=$(python3 -c "
with open('$PLUGIN_RES/EOSWebcamService', 'rb') as f:
    d = f.read()
print('fork' if d[0x89b58:0x89b5c] == bytes.fromhex('20008052') else 'original')
" 2>/dev/null || echo "original")
    if [ "$EXISTING" = "fork" ]; then
        INSTALL_TYPE="upgrade_fork"
    else
        INSTALL_TYPE="upgrade_original"
    fi
fi

echo "  Architecture: $ARCH"
echo "  User: $USERNAME"
case "$INSTALL_TYPE" in
    fresh)           echo "  Mode: Fresh install" ;;
    upgrade_original)   echo "  Mode: Upgrade from original v1.3.x" ;;
    upgrade_fork)    echo "  Mode: Update existing fork" ;;
esac
echo ""

# --- Backup ---
echo "[2/9] Creating backups..."
BACKUP_DIR="$INSTALL_DIR/backups/pre-v${VERSION}-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

if [ "$INSTALL_TYPE" != "fresh" ]; then
    cp "$PLUGIN_BIN/EOSWebcamUtility" "$BACKUP_DIR/" 2>/dev/null || true
    cp "$PLUGIN_RES/EOSWebcamService" "$BACKUP_DIR/" 2>/dev/null || true
    cp "$PLUGIN_RES/EWCProxy" "$BACKUP_DIR/" 2>/dev/null || true
    cp "$PLUGIN_RES/EWCPairingService" "$BACKUP_DIR/" 2>/dev/null || true
    cp "$PLUGIN_RES/errorNoDevice.jpg" "$BACKUP_DIR/" 2>/dev/null || true
    cp "$PLUGIN_RES/errorBusy.jpg" "$BACKUP_DIR/" 2>/dev/null || true
    cp "$PLUGIN_RES/default.jpg" "$BACKUP_DIR/" 2>/dev/null || true
    cp "$SUPPORT_DIR/config.plist" "$BACKUP_DIR/" 2>/dev/null || true
    cp "$SUPPORT_DIR/proconfig.plist" "$BACKUP_DIR/" 2>/dev/null || true
    echo "  Backed up to: $BACKUP_DIR"
else
    echo "  Fresh install — nothing to backup"
fi

# --- Stop services ---
echo "[3/9] Stopping existing services..."
launchctl unload "$LAUNCH_AGENTS/com.eos-camera-manager.plist" 2>/dev/null || true
launchctl unload "$LAUNCH_AGENTS/com.eos-camera-manager.plist" 2>/dev/null || true
launchctl unload "$LAUNCH_AGENT_SYS" 2>/dev/null || true
pkill -9 EOSWebcamServic 2>/dev/null || true
pkill -9 EWCProxy 2>/dev/null || true
sleep 1
echo "  Done"

# --- Deploy files ---
echo "[4/9] Deploying files (admin password required)..."

if [ "$INSTALL_TYPE" = "fresh" ]; then
    osascript -e "do shell script \"
mkdir -p '/Library/CoreMediaIO/Plug-Ins/DAL'
mkdir -p '/Library/Frameworks'
mkdir -p '/Library/LaunchAgents'
cp -R '${BUNDLE_DIR}/EOSWebcamUtility.plugin' '/Library/CoreMediaIO/Plug-Ins/DAL/'
cp -R '${BUNDLE_DIR}/EOSWebcamUtility_x86_64.plugin' '/Library/CoreMediaIO/Plug-Ins/DAL/' 2>/dev/null
cp -R '${BUNDLE_DIR}/EDSDK.framework' '/Library/Frameworks/'
cp '${BUNDLE_DIR}/com.canon.usa.EWCService.plist' '/Library/LaunchAgents/'
chmod 600 '/Library/LaunchAgents/com.canon.usa.EWCService.plist'
chown root:wheel '/Library/LaunchAgents/com.canon.usa.EWCService.plist'
chmod 755 '${PLUGIN_BIN}/EOSWebcamUtility'
chmod 755 '${PLUGIN_RES}/EOSWebcamService'
chmod 755 '${PLUGIN_RES}/EWCProxy'
chmod 666 '${PLUGIN_RES}/errorNoDevice.jpg' 2>/dev/null
chmod 666 '${PLUGIN_RES}/errorBusy.jpg' 2>/dev/null
chmod 666 '${PLUGIN_RES}/default.jpg' 2>/dev/null
codesign --force --sign - '${PLUGIN_BIN}/EOSWebcamUtility'
codesign --force --sign - '${PLUGIN_RES}/EOSWebcamService'
codesign --force --sign - '${PLUGIN_RES}/EWCProxy'
codesign --force --deep --sign - '${PLUGIN_DIR}'
\" with administrator privileges"
else
    osascript -e "do shell script \"
cp '${BUNDLE_DIR}/EOSWebcamUtility.plugin/Contents/MacOS/EOSWebcamUtility' '${PLUGIN_BIN}/EOSWebcamUtility'
cp '${BUNDLE_DIR}/EOSWebcamUtility.plugin/Contents/Resources/EOSWebcamService' '${PLUGIN_RES}/EOSWebcamService'
cp '${BUNDLE_DIR}/EOSWebcamUtility.plugin/Contents/Resources/EWCProxy' '${PLUGIN_RES}/EWCProxy'
chmod 755 '${PLUGIN_BIN}/EOSWebcamUtility'
chmod 755 '${PLUGIN_RES}/EOSWebcamService'
chmod 755 '${PLUGIN_RES}/EWCProxy'
chmod 666 '${PLUGIN_RES}/errorNoDevice.jpg' 2>/dev/null
chmod 666 '${PLUGIN_RES}/errorBusy.jpg' 2>/dev/null
chmod 666 '${PLUGIN_RES}/default.jpg' 2>/dev/null
codesign --force --sign - '${PLUGIN_BIN}/EOSWebcamUtility'
codesign --force --sign - '${PLUGIN_RES}/EOSWebcamService'
codesign --force --sign - '${PLUGIN_RES}/EWCProxy'
codesign --force --deep --sign - '${PLUGIN_DIR}'
\" with administrator privileges"
fi
echo "  Files deployed and signed"

# --- Config ---
echo "[5/9] Setting configuration..."
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

# --- Camera manager daemon ---
echo "[6/9] Installing camera manager..."
mkdir -p "$INSTALL_DIR"
cp "$SCRIPT_DIR/eos-camera-manager.sh" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/eos-camera-manager.sh"
echo "  Installed to: $INSTALL_DIR/eos-camera-manager.sh"

# --- Loading screens ---
echo "[7/9] Installing loading screens..."
if [ -d "$SCRIPT_DIR/images" ]; then
    cp "$SCRIPT_DIR/images/"*.jpg "$INSTALL_DIR/" 2>/dev/null || true
    cp "$SCRIPT_DIR/images/generate-images.sh" "$INSTALL_DIR/" 2>/dev/null || true
    chmod +x "$INSTALL_DIR/generate-images.sh" 2>/dev/null || true
    if [ -f "$INSTALL_DIR/errorNoDevice_connecting.jpg" ]; then
        cp "$INSTALL_DIR/errorNoDevice_connecting.jpg" "$PLUGIN_RES/errorNoDevice.jpg" 2>/dev/null || true
    fi
    echo "  Custom screens installed"
else
    echo "  Using default screens"
fi

# --- LaunchAgent ---
echo "[8/9] Setting up auto-start..."
rm -f "$LAUNCH_AGENTS/com.eos-camera-manager.plist" 2>/dev/null
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
echo "[9/9] Starting services..."
launchctl load "$LAUNCH_AGENT_SYS" 2>/dev/null || true
sleep 1
launchctl load "$LAUNCH_AGENTS/com.eos-camera-manager.plist" 2>/dev/null || true

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
