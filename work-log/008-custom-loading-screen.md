# Work Log 008: Custom Loading Screen

**Date:** 2026-03-14
**Phase:** 4 — UX Polish
**Risk Level:** Low (image file swaps only)
**Status:** Complete

## Objective

Replace the generic Canon "USB disconnected" error image with context-aware placeholder images:
- **Camera on USB:** "Connecting to camera... Please wait" with company logo
- **Camera not on USB:** "Camera not connected" with instructions

## Implementation

### Image Generation
- Script: `~/development/webcam-utility/generate-images.sh`
- Uses ImageMagick (`magick`) to generate 1980x1080 JPEGs matching Canon's dark angular background style
- Supports optional logo overlay: place `logo.png` or `logo.svg` in the same directory
- Logo is auto-scaled to fit within 500x250 box, never stretched, transparency preserved
- Title: "Connecting to camera..." (Helvetica Bold, 72pt, white)
- Subtitle: "Please wait" (48pt, blue #4a9eff)

### Dynamic Image Swapping
The Canon Camera Manager daemon (v11) swaps `errorNoDevice.jpg` in the plugin Resources based on USB state:
- Detects Canon USB connection via `ioreg -p IOUSB`
- Copies the appropriate image to the plugin's `errorNoDevice.jpg`
- Swaps happen on USB connect/disconnect events

### Files Created
| File | Purpose |
|---|---|
| `~/development/webcam-utility/generate-images.sh` | Image generation script |
| `~/development/webcam-utility/errorNoDevice_connecting.jpg` | "Connecting..." image (with logo) |
| `~/development/webcam-utility/errorNoDevice_disconnected.jpg` | "Not connected" image |
| `~/development/webcam-utility/logo.png` | Company logo for overlay |
| `~/development/webcam-utility/original-images/` | Backup of Canon's original images |

### Files Modified
| File | Change |
|---|---|
| `canon-camera-manager.sh` | Updated to v11 with image swapping logic |
| `.../Resources/errorNoDevice.jpg` | Dynamically swapped by daemon |

## Known Issue: Mirrored Text

Zoom (and some other apps) mirror the video feed, causing the loading screen text to appear backwards:
- This affects **both** the local preview and what other participants see
- The mirroring is applied at the app/source level, not just as a UI transform
- **No fix implemented** — would require pre-mirroring the image, which would look wrong in apps that don't mirror
- Low priority since the loading screen is only visible for ~20-30 seconds during camera connection

## To Regenerate Images

```bash
# Replace logo if needed
cp /path/to/new/logo.png ~/development/webcam-utility/logo.png

# Regenerate
~/development/webcam-utility/generate-images.sh

# Restart daemon to pick up new images
launchctl unload ~/Library/LaunchAgents/com.eos-camera-manager.plist
launchctl load ~/Library/LaunchAgents/com.eos-camera-manager.plist
```

## Rollback

```bash
# Restore Canon's original image
cp ~/development/webcam-utility/original-images/errorNoDevice.jpg \
   "/Library/CoreMediaIO/Plug-Ins/DAL/EOSWebcamUtility.plugin/Contents/Resources/errorNoDevice.jpg"
```
