#!/bin/bash
#
# EOS Webcam Utility Fork v1.4 — Uninstaller
#
# Restores the original EOS Webcam Utility v1.3.16 files
# and removes the camera manager daemon.
#

set -e

PLUGIN_DIR="/Library/CoreMediaIO/Plug-Ins/DAL/EOSWebcamUtility.plugin"
USER_HOME="$HOME"
INSTALL_DIR="$USER_HOME/development/webcam-utility"
LAUNCH_AGENTS="$USER_HOME/Library/LaunchAgents"

echo "============================================"
echo "  EOS Webcam Utility Fork — Uninstaller"
echo "============================================"
echo ""

# Find most recent backup
BACKUP_DIR=$(ls -dt "$INSTALL_DIR/backups/pre-v"* 2>/dev/null | head -1)

if [ -z "$BACKUP_DIR" ]; then
    echo "ERROR: No backup found. Cannot restore original files."
    echo "You may need to reinstall EOS Webcam Utility v1.3.16 from:"
    echo "  https://downloads.canon.com/webcam/EOSWebcamUtility-MAC1.3.16.pkg.zip"
    exit 1
fi

echo "Restoring from backup: $BACKUP_DIR"
echo ""

# Stop services
echo "[1/4] Stopping services..."
launchctl unload "$LAUNCH_AGENTS/com.eos-camera-manager.plist" 2>/dev/null || true
launchctl unload /Library/LaunchAgents/com.canon.usa.EWCService.plist 2>/dev/null || true
sleep 1

# Restore binaries
echo "[2/4] Restoring original binaries (admin required)..."
osascript -e "do shell script \"
cp '$BACKUP_DIR/EOSWebcamUtility' '$PLUGIN_DIR/Contents/MacOS/EOSWebcamUtility'
cp '$BACKUP_DIR/EOSWebcamService' '$PLUGIN_DIR/Contents/Resources/EOSWebcamService'
cp '$BACKUP_DIR/EWCProxy' '$PLUGIN_DIR/Contents/Resources/EWCProxy'
cp '$BACKUP_DIR/errorNoDevice.jpg' '$PLUGIN_DIR/Contents/Resources/errorNoDevice.jpg' 2>/dev/null
cp '$BACKUP_DIR/errorBusy.jpg' '$PLUGIN_DIR/Contents/Resources/errorBusy.jpg' 2>/dev/null
cp '$BACKUP_DIR/default.jpg' '$PLUGIN_DIR/Contents/Resources/default.jpg' 2>/dev/null
codesign --force --sign - '$PLUGIN_DIR/Contents/MacOS/EOSWebcamUtility'
codesign --force --sign - '$PLUGIN_DIR/Contents/Resources/EOSWebcamService'
codesign --force --sign - '$PLUGIN_DIR/Contents/Resources/EWCProxy'
codesign --force --deep --sign - '$PLUGIN_DIR'
\" with administrator privileges"

echo "  Original binaries restored"

# Restore configs
echo "[3/4] Restoring original config..."
cp "$BACKUP_DIR/config.plist" "$USER_HOME/Library/Application Support/EWCService/config.plist" 2>/dev/null || true
cp "$BACKUP_DIR/proconfig.plist" "$USER_HOME/Library/Application Support/EWCService/proconfig.plist" 2>/dev/null || true

# Remove daemon
echo "[4/4] Removing camera manager..."
rm -f "$LAUNCH_AGENTS/com.eos-camera-manager.plist"

# Restart original service
launchctl load /Library/LaunchAgents/com.canon.usa.EWCService.plist 2>/dev/null || true

echo ""
echo "============================================"
echo "  Uninstall complete."
echo "  Original EOS Webcam Utility v1.3.16 restored."
echo "  Backups preserved at: $INSTALL_DIR/backups/"
echo "============================================"
