# Work Log 004: EWCProxy Binary Patch

**Date:** 2026-03-14
**Phase:** 2c — EWCProxy Resolution Defaults
**Risk Level:** Medium (reversible via backup)
**Status:** In Progress
**Depends on:** 001 (config.plist), 003 (isPro bypass + service patch)

## Objective

Patch the EWCProxy binary's default/fallback resolution from 1280x720@30fps to 1920x1080@60fps. EWCProxy is the frame relay process between EOSWebcamService and the DAL plugin.

## Binary Location

```
/Library/CoreMediaIO/Plug-Ins/DAL/EOSWebcamUtility.plugin/Contents/Resources/EWCProxy
```

## Backup Location

```
~/development/webcam-utility/EWCProxy.backup-20260314
```

## Analysis Summary

22 locations with hardcoded 1280/720 values were found. Classification:

| Category | Count | Action |
|---|---|---|
| RESOLUTION defaults/fallbacks | 4 (+1 fps) | **PATCH** |
| EDSDK property IDs (kEdsPropID_Evf_Mode = 0x500) | 5 | DO NOT PATCH |
| Buffer allocation sizes (1280-byte ring slots) | 5 | DO NOT PATCH |
| JPEG color table index offsets | 2 | DO NOT PATCH |
| Protobuf constants (wire format + source line number) | 2 | DO NOT PATCH |
| Resolution switch (already has 1080p case) | 4 | Patch only the 720p case |

Note: The resolution validation function at 0x1000433f0 already accepts 1920x1080 as a valid resolution. The resolution bucketing function at 0x100043488 already has 1920x1080 as a tier. We only need to change the defaults.

## Patches

### Patch 1: Default width 1280 → 1920
- **Offset:** `0x043848`
- **Original:** `08 a0 80 52` (`mov w8, #0x500`)
- **New:** `08 f0 80 52` (`mov w8, #0x780`)

### Patch 2: Default height 720 → 1080
- **Offset:** `0x043854`
- **Original:** `08 5a 80 52` (`mov w8, #0x2d0`)
- **New:** `08 87 80 52` (`mov w8, #0x438`)

### Patch 3: Alt path default width 1280 → 1920
- **Offset:** `0x043888`
- **Original:** `09 a0 80 52` (`mov w9, #0x500`)
- **New:** `09 f0 80 52` (`mov w9, #0x780`)

### Patch 4: Alt path default height 720 → 1080
- **Offset:** `0x043894`
- **Original:** `09 5a 80 52` (`mov w9, #0x2d0`)
- **New:** `09 87 80 52` (`mov w9, #0x438`)

### Patch 5: Default FPS 30 → 60
- **Offset:** `0x043810`
- **Original:** `c8 03 80 52` (`mov w8, #0x1e`)
- **New:** `c8 07 80 52` (`mov w8, #0x3c`)

### Patch 6: Resolution switch case 2 width 1280 → 1920
- **Offset:** `0x0434e4`
- **Original:** `09 a0 80 52` (`mov w9, #0x500`)
- **New:** `09 f0 80 52` (`mov w9, #0x780`)

### Patch 7: Resolution switch case 2 height 720 → 1080
- **Offset:** `0x0434e0`
- **Original:** `08 5a 80 52` (`mov w8, #0x2d0`)
- **New:** `08 87 80 52` (`mov w8, #0x438`)

## NOT Patched (with reasons)

| Offset | Value | Reason |
|---|---|---|
| 0x01e96c | mov w1, #0x500 | EDSDK kEdsPropID_Evf_Mode — camera SDK call |
| 0x024ce8 | mov w1, #0x500 | EDSDK StartEvfCommand — camera SDK call |
| 0x024d50 | mov w1, #0x500 | EDSDK StartEvfCommand — camera SDK call |
| 0x024ea4 | mov w1, #0x500 | EDSDK StopEvfCommand — camera SDK call |
| 0x024ed8 | mov w1, #0x500 | EDSDK StopEvfCommand — camera SDK call |
| 0x04b9c0 | mov w2, #0x500 | Buffer allocation (1280-byte ring slots) |
| 0x04d6f4 | mov w10, #0x500 | JPEG color conversion LUT offset |
| 0x04d794 | mov w7, #0x500 | JPEG color conversion LUT offset |
| 0x04e148 | mov w2, #0x500 | Buffer allocation |
| 0x05e9b4 | mov w2, #0x500 | Buffer allocation |
| 0x05e9c0 | mov w1, #0x500 | Buffer bzero (1280 bytes) |
| 0x060300 | mov w2, #0x500 | Buffer allocation |
| 0x0fc4e8 | mov w9, #0x2d0 | Protobuf varint serialization |
| 0x13a7c4 | mov w3, #0x2d0 | Protobuf source line 720 in map_field.h |

## Execution Steps

1. Backup EWCProxy binary
2. Verify original bytes at all 7 patch offsets
3. Apply all patches to a copy
4. Stop service
5. Deploy patched binary with admin privileges
6. Sign individual binary, then sign bundle
7. Restart service
8. Validate

## Validation Steps

1. `launchctl list | grep canon` — service running with PID
2. `system_profiler SPCameraDataType` — virtual camera visible
3. `ffmpeg -f avfoundation -video_size 9999x9999 -i "0"` — check supported modes
4. `ffmpeg -f avfoundation -video_size 1920x1080 -framerate 60 -i "0" -t 1 -f null -` — test capture
5. Open Zoom → select EOS Webcam Utility → verify feed

## Rollback

```bash
cp ~/development/webcam-utility/EWCProxy.backup-20260314 \
   "/Library/CoreMediaIO/Plug-Ins/DAL/EOSWebcamUtility.plugin/Contents/Resources/EWCProxy"
# Also restore service and DAL plugin if needed:
cp ~/development/webcam-utility/EOSWebcamService.backup-20260314 \
   "/Library/CoreMediaIO/Plug-Ins/DAL/EOSWebcamUtility.plugin/Contents/Resources/EOSWebcamService"
cp ~/development/webcam-utility/EOSWebcamUtility.backup-20260314 \
   "/Library/CoreMediaIO/Plug-Ins/DAL/EOSWebcamUtility.plugin/Contents/MacOS/EOSWebcamUtility"
# Re-sign and restart
codesign --force --sign - <each binary>
codesign --force --deep --sign - <bundle>
launchctl unload /Library/LaunchAgents/com.canon.usa.EWCService.plist
sleep 2
launchctl load /Library/LaunchAgents/com.canon.usa.EWCService.plist
```

## Results

**Executed:** 2026-03-14

### Patch Application
- [x] Backup saved to `~/development/webcam-utility/EWCProxy.backup-20260314`
- [x] All 7 original bytes verified
- [x] All patches applied successfully
- [x] All 3 binaries + bundle signed (lesson from 003: sign each binary individually first)
- [x] `codesign --verify` passes

### Service Restart
- [x] Service running — PID 54574, exit code 0, no crash

### Resolution Change — SUCCESS!
- [x] Virtual camera visible to macOS
- [x] **Supported modes now include 1920x1080** (listed FIRST = default):
  ```
  1920x1080@[15.000000 30.000000]fps  ← NEW DEFAULT
  1280x720@[15.000000 30.000000]fps
  1080x1920@[15.000000 30.000000]fps
  1760x1328@[15.000000 30.000000]fps
  640x480@[15.000000 30.000000]fps
  ```
- [x] **ffmpeg 1080p capture confirmed:**
  ```
  Stream #0:0: Video: rawvideo (UYVY), uyvy422, 1920x1080
  frame=60 fps=30
  ```
- [ ] 60fps not yet verified (camera not physically connected; placeholder runs at 30fps)
- [ ] Zoom/FaceTime test pending (need camera connected)

### Live Camera Activation — NOT WORKING RELIABLY
- [x] Camera detected on USB: `Canon EOS 250D` at `usb:001,004`
- [x] Service detected camera: `Dev Browser | Added: Canon EOS 250D`
- [ ] **EWCProxy never auto-launched** — service detects camera but doesn't spawn EWCProxy
- [ ] All ffmpeg captures were the placeholder image, not live feed
- **Known pre-existing issue:** User has always had to toggle between cameras in Zoom (EOS ↔ FaceTime, back and forth) to trigger camera activation. Suggests a race condition or device claim timing issue.

### Known Issue: Camera Activation Race Condition
The camera detection flow appears to have a race condition:
1. Service detects Canon EOS 250D via ImageCapture/PTP
2. macOS PTPCamera.app claims the device first (`modulePath = /System/Library/Image Capture/Devices/PTPCamera.app`)
3. EDSDK (Canon's SDK) can't open the camera because PTPCamera holds the USB claim
4. Toggling cameras in Zoom causes repeated open/close cycles, eventually creating a window where EDSDK can claim the device before PTPCamera
5. This is a pre-existing issue (not caused by our patches) — needs investigation in work-log/005

### Notes
- The format change to 1920x1080 is confirmed working — the virtual camera advertises it and ffmpeg accepts it
- Multiple format modes now available (1080p, 720p, portrait, 1760x1328, 480p)
- Once camera activation is solved, the 1080p feed should work
- 60fps still capped at 30fps in advertised modes — separate investigation needed
