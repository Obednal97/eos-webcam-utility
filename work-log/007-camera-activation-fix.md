# Work Log 007: Camera Activation Fix — ptpcamerad Manager

**Date:** 2026-03-14
**Phase:** 3 — Camera Activation
**Risk Level:** Low (no binary patching, fully reversible)
**Status:** In Progress

## Problem

macOS `ptpcamerad` (SIP-protected, auto-respawning) claims the Canon 250D USB device before Canon's EDSDK can open a session. This causes:
- EWCProxy never launches
- Camera never activates
- User must toggle cameras in Zoom 2-3 times to trigger activation by luck

## Solution: Canon Camera Manager LaunchAgent

Create a lightweight background daemon that:
1. **Detects** when the Canon 250D is connected via USB
2. **Suppresses** ptpcamerad (kills it in a loop) while the Canon is connected
3. **Restarts** the EOS Webcam Service to trigger fresh camera detection
4. **Monitors** EWCProxy — when it launches, the camera is active
5. **Releases** ptpcamerad when the Canon is disconnected (USB unplugged)

### Why kill ptpcamerad on USB connection (not on stream request)?

The stream request (Zoom opens EOS Webcam Utility) triggers the service to launch EWCProxy, but EWCProxy can't claim the camera because ptpcamerad holds it. By killing ptpcamerad as soon as the Canon is plugged in, EWCProxy can claim the camera immediately when a stream is requested.

**Tradeoff:** You can't use macOS Image Capture / Photos to import photos while the Canon is connected as a webcam. This is acceptable — if the camera is mounted as a webcam, you're not importing photos.

### Architecture

```
[Canon Camera Manager] (LaunchAgent, runs on login)
    |
    |— polls every 2 seconds: is Canon USB device present?
    |
    |— Canon connected:
    |   |— kill ptpcamerad (loop every 0.5s for 5 seconds)
    |   |— restart EOS Webcam Service
    |   |— monitor: is EWCProxy running?
    |   |— keep ptpcamerad suppressed while Canon connected
    |
    |— Canon disconnected:
    |   |— stop suppressing ptpcamerad (it auto-respawns via launchd)
    |   |— log state change
```

## Files To Create

| File | Purpose |
|---|---|
| `~/development/webcam-utility/canon-camera-manager.sh` | Main daemon script |
| `~/Library/LaunchAgents/com.eos-camera-manager.plist` | LaunchAgent to auto-start |

## Backup / Rollback

No existing files are modified. To disable:
```bash
launchctl unload ~/Library/LaunchAgents/com.eos-camera-manager.plist
rm ~/Library/LaunchAgents/com.eos-camera-manager.plist
```

## Validation Steps

1. Disconnect Canon → connect Canon → verify ptpcamerad is killed within 3 seconds
2. Open Zoom → select EOS Webcam Utility → verify camera activates on FIRST try
3. Close Zoom → verify EWCProxy exits
4. Disconnect Canon → verify ptpcamerad respawns
5. Check logs at `~/Library/Logs/canon-camera-manager.log`

## Results

### Camera Manager Daemon — Abandoned
The v1-v4 camera manager scripts caused more problems than they solved:
- Aggressively killing ptpcamerad put the camera's PTP session into a stuck state
- This required full USB cable disconnect + camera power cycle to recover
- The service needs ptpcamerad alive to DETECT the camera, but dead for EWCProxy to CLAIM it — fundamentally incompatible with a simple kill approach
- **Lesson learned:** Don't fight macOS system daemons with brute force

### Key Discovery: Patched Version Is MORE Reliable
After restoring original binaries (camera activation broken), then re-applying all 1080p + isPro patches:
- Camera activated on **first try** in Zoom, two consecutive times
- Previously required 3-5 toggles with original binaries
- The isPro bypass may change the service's initialization flow in a way that reduces the race condition

### Daemon Development History

**v1-v4 (ptpcamerad killing approach) — FAILED**
- Concept: kill ptpcamerad so EDSDK can claim the camera
- v1: Kill on Canon USB detection → caused constant ptpcamerad killing, USB state corruption
- v2: State machine → overcomplicated, same fundamental problem
- v3: Reactive (detect EWCProxy crash, then kill ptpcamerad) → service didn't retry after ptpcamerad was killed
- v4: Kill ptpcamerad + restart service → EWCProxy still crashed (EDSDK SEGFAULT in CIccMan::OpenRequest)
- **Root cause:** Aggressively killing ptpcamerad corrupts the camera's PTP session. The camera stops responding to ALL PTP commands. Recovery requires: camera OFF → battery removal → USB unplug → wait 10s → replug to DIFFERENT USB port → camera ON
- **Lesson:** Never brute-force kill ptpcamerad

**v5-v6 (service restart approach) — PARTIALLY WORKED**
- Concept: don't kill ptpcamerad; when EWCProxy fails, restart Canon service so Zoom auto-reconnects
- v5: Had increasing delays (2s, 3s, 4s...) between retries → too slow
- v6: Threshold too low (5s) → treated successful 5-second EWCProxy runs as "normal exit"

**v7 (faster service restart) — WORKED (27s)**
- Fixed: 0.5s service restart sleep, 1s retry delay, 0.5s poll interval
- Result: 3 retries, camera connected after 27 seconds total
- Timing: first attempt 6s fail → 5s restart → 2s fail → 5s restart → 2s fail → 5s restart → success

**v8 (kill stuck proxy) — FAILED**
- Concept: kill EWCProxy after 4s if it hasn't connected, avoid service restart
- Result: service didn't relaunch EWCProxy without restart — Zoom's DAL plugin needs the service restart to re-trigger STREAM_REQUEST_ACTIVATED

**v9 (hybrid kill + restart) — CAUSED LOOP**
- Concept: kill stuck proxy early + fast service restart
- Result: killing EWCProxy after 4s was too aggressive — successful connections take 5-15s for EDSDK setup. Created infinite kill loop.

**v10 (clean v7 with fast restart) — WORKS (20-30s)**
- Same as v7 but cleaner code, 0.5s service restart, 15s threshold
- Result: camera connects in ~20-30 seconds, 2-3 retries
- Confirmed working across multiple disconnect/reconnect cycles
- **DEPLOYED AS FINAL SOLUTION**

### Final State (2026-03-14)

**Deployed configuration:**
- All 1080p patches applied (DAL plugin + EOSWebcamService + EWCProxy)
- isPro bypassed
- Config set to 1920x1080@30fps
- Canon Camera Manager v10 installed as LaunchAgent
- Camera connects automatically within ~20-30 seconds of selecting EOS Webcam Utility in Zoom

**Files installed:**
- `~/Library/LaunchAgents/com.eos-camera-manager.plist` — auto-starts on login
- `~/development/webcam-utility/canon-camera-manager.sh` — the daemon script

**What the user sees during connection:**
1. Select EOS Webcam Utility in Zoom
2. ~6 seconds of grey screen (`default.jpg` — "EOS WEBCAM UTILITY" text)
3. Briefly shows disconnection image (`errorNoDevice.jpg` — USB cable with red X)
4. Manager restarts service, Zoom reconnects
5. Another brief grey/disconnection cycle
6. After 2-3 retries (~20-30s total), live camera feed appears at 1920x1080

**Timing breakdown per retry cycle (~8-9s):**
| Step | Duration | What happens |
|---|---|---|
| EWCProxy EDSDK attempt | 2-6s | Tries to open camera session, fails (ptpcamerad race) |
| Manager detects failure | 0.5s | Polls at 0.5s interval |
| Retry delay | 0.5s | Minimal wait |
| Service restart (launchctl) | ~5s | Unload + load — the main bottleneck |
| Zoom DAL plugin reconnects | ~1s | Auto-reconnects to restarted service |

### Rollback
```bash
launchctl unload ~/Library/LaunchAgents/com.eos-camera-manager.plist
rm ~/Library/LaunchAgents/com.eos-camera-manager.plist
```
