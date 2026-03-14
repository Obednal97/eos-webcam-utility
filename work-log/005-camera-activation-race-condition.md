# Work Log 005: Camera Activation Race Condition

**Date:** 2026-03-14
**Phase:** 3 — Camera Activation Fix
**Risk Level:** Low-Medium
**Status:** In Progress

## Problem

The Canon EOS 250D is detected by the service but never activates. The camera goes through an add/remove cycle every ~2-14 seconds because macOS `ptpcamerad` keeps reclaiming the USB device before Canon's EDSDK can open a session.

### Symptoms
- `Dev Browser | Added: Canon EOS 250D` appears in logs
- 2-14 seconds later: `removeDeviceContext` / `Removed: Canon EOS 250D`
- EWCProxy never launches
- ffmpeg captures show placeholder image, not live feed
- User reports: toggling cameras in Zoom (EOS ↔ FaceTime, back and forth) eventually triggers activation

### Root Cause

1. Camera is plugged in via USB
2. macOS `ptpcamerad` (PID 782, SIP-protected, auto-respawns) claims the device via PTPCamera.app
3. Canon service detects camera via ImageCapture framework → delegates to `EdsIccHandler`
4. Service uses **lazy activation** — only launches EWCProxy when an app requests a stream
5. When stream is requested, EWCProxy tries to open EDSDK session but ptpcamerad holds the USB claim
6. EDSDK fails → proxy fails → camera never activates
7. Toggling in Zoom creates rapid activate/deactivate cycles, occasionally creating a timing window where EDSDK wins the race

### Architecture

```
Zoom/App → DAL Plugin (STREAM_REQUEST_ACTIVATED) → EOSWebcamService
    → ProxyManager::CreateProxy → EWCProxy (EDSDK) → USB → Canon 250D
                                                       ↑
                                            ptpcamerad (PTPCamera.app) blocks here
```

### Key Mach Ports
- `com.canon.usa.EOSWebcamUtility.Command` — DAL plugin ↔ Service
- `com.canon.usa.EOSWebcamUtility.ProxyCommand` — Service ↔ EWCProxy
- `com.canon.usa.EOSWebcamUtility.CameraProxy` — EWCProxy camera IPC

## Approaches Tried

| Approach | Result |
|---|---|
| Kill ptpcamerad once | Respawns immediately (launchd) |
| launchctl bootout ptpcamerad | Blocked by SIP |
| launchctl unload ptpcamerad plist | Blocked by SIP |
| Kill ptpcamerad in tight loop + restart service | Didn't create long enough window |
| Race: restart service during kill loop | EWCProxy still never launched |

## Potential Solutions

### A: Disable PTPCamera claim for Canon devices (requires SIP modification)
- Modify `/System/Library/Image Capture/Devices/PTPCamera.app` USB matching rules
- **Not viable** without disabling SIP

### B: Use IOKit USB device override
- Create a codeless kext or IOKit matching override that prevents PTPCamera from matching Canon devices
- Place in `/Library/Extensions/` — doesn't require SIP
- This is the approach gphoto2 documentation recommends for similar issues

### C: Modify EDSDK session opening to retry with backoff
- Patch EWCProxy or EOSWebcamService to retry `EdsOpenSession` multiple times
- Combined with killing ptpcamerad, could eventually succeed

### D: Pre-launch EWCProxy on camera detection
- Patch service to launch EWCProxy immediately when camera is detected (not lazy)
- EWCProxy claims the device before ptpcamerad can

### E: Use IOUSBHostDevice exclusive access
- Patch EWCProxy to request exclusive USB access via IOKit before calling EDSDK
- Would block ptpcamerad from reclaiming

## Results

**Executed:** 2026-03-14

### Camera Activation
- [x] Camera activated via Zoom toggle approach (select EOS Webcam → FaceTime → EOS Webcam, 3rd attempt)
- [x] EWCProxy launched (PID 56717) once camera activated
- [x] **Live 1080p feed confirmed from Canon 250D:**
  ```
  1920x1080@[30.000000 30.000000]fps
  frame=147 fps=29-30, sustained 5 seconds
  ```
- [x] Test capture saved: `~/development/webcam-utility/test-live-canon-1080p.jpg`

### Conclusion
The 1080p resolution patch is **fully working**. The camera activation race condition is a pre-existing issue (not caused by our patches) that needs separate investigation. The Zoom toggle workaround remains necessary for now.

### Remaining Work
- [ ] Investigate reliable camera activation (eliminate need for Zoom toggling)
- [ ] 60fps investigation (currently capped at 30fps in advertised modes)
