#!/bin/bash
# EOS Camera Manager v11
#
# Features:
# 1. Auto-retry camera connection when EWCProxy fails
# 2. Swap placeholder image based on camera USB state:
#    - Camera on USB → "Connecting to camera..." image
#    - Camera NOT on USB → "Camera not connected" image

LOG_FILE="$HOME/Library/Logs/eos-camera-manager.log"
PLUGIN_RES="/Library/CoreMediaIO/Plug-Ins/DAL/EOSWebcamUtility.plugin/Contents/Resources"
IMG_CONNECTING="$HOME/development/webcam-utility/errorNoDevice_connecting.jpg"
IMG_DISCONNECTED="$HOME/development/webcam-utility/errorNoDevice_disconnected.jpg"
PROXY_PID=""
PROXY_START_TIME=0
RETRY_COUNT=0
MAX_RETRIES=8
CURRENT_IMAGE=""
CAMERA_WAS_CONNECTED=""

log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

is_camera_connected() {
    ioreg -p IOUSB 2>/dev/null | grep -q "Canon Digital Camera"
}

swap_image() {
    local target="$1"
    if [ "$CURRENT_IMAGE" != "$target" ]; then
        cp "$target" "$PLUGIN_RES/errorNoDevice.jpg" 2>/dev/null
        CURRENT_IMAGE="$target"
    fi
}

log_msg "EOS Camera Manager v11 started (PID $$)"

# Set initial image based on current USB state
if is_camera_connected; then
    swap_image "$IMG_CONNECTING"
    CAMERA_WAS_CONNECTED=true
    log_msg "Camera on USB — showing connecting image"
else
    swap_image "$IMG_DISCONNECTED"
    CAMERA_WAS_CONNECTED=false
    log_msg "Camera not on USB — showing disconnected image"
fi

while true; do
    current_pid=$(pgrep EWCProxy 2>/dev/null)
    now=$(date +%s)
    camera_connected=$(is_camera_connected && echo true || echo false)

    # Update image based on USB state changes
    if [ "$camera_connected" = true ] && [ "$CAMERA_WAS_CONNECTED" != "true" ]; then
        swap_image "$IMG_CONNECTING"
        CAMERA_WAS_CONNECTED=true
        log_msg "Camera connected — showing connecting image"
    elif [ "$camera_connected" = false ] && [ "$CAMERA_WAS_CONNECTED" != "false" ]; then
        swap_image "$IMG_DISCONNECTED"
        CAMERA_WAS_CONNECTED=false
        log_msg "Camera disconnected — showing disconnected image"
    fi

    # Auto-retry logic
    if [ -n "$current_pid" ]; then
        if [ "$current_pid" != "$PROXY_PID" ]; then
            PROXY_PID="$current_pid"
            PROXY_START_TIME=$now
            # Camera is attempting to connect — ensure connecting image
            if [ "$camera_connected" = true ]; then
                swap_image "$IMG_CONNECTING"
            fi
        fi

        elapsed=$((now - PROXY_START_TIME))
        if [ $elapsed -ge 15 ] && [ $RETRY_COUNT -gt 0 ]; then
            log_msg "Connected after $RETRY_COUNT retries"
            RETRY_COUNT=0
        fi
    else
        if [ -n "$PROXY_PID" ]; then
            elapsed=$((now - PROXY_START_TIME))
            PROXY_PID=""

            if [ $elapsed -lt 15 ]; then
                RETRY_COUNT=$((RETRY_COUNT + 1))
                if [ $RETRY_COUNT -le $MAX_RETRIES ]; then
                    log_msg "Attempt $RETRY_COUNT (${elapsed}s) — restarting service"
                    launchctl unload /Library/LaunchAgents/com.canon.usa.EWCService.plist 2>/dev/null
                    sleep 0.5
                    launchctl load /Library/LaunchAgents/com.canon.usa.EWCService.plist 2>/dev/null
                else
                    log_msg "Max retries — cooling down 30s"
                    RETRY_COUNT=0
                    sleep 30
                fi
            else
                RETRY_COUNT=0
            fi
        fi
    fi

    sleep 0.5
done
