# Work Log 006: 60fps Investigation

**Date:** 2026-03-14
**Phase:** Feasibility Investigation
**Risk Level:** N/A (research only)
**Status:** Complete — Not Feasible

## Objective

Determine whether 60fps output is achievable from the Canon 250D over USB, and if so, what changes would be needed.

## Current State

- Config requests 60fps (`StreamFps: 60`)
- All three binaries patched with fps defaults of 60
- Virtual camera advertises `1920x1080@[15.000000 30.000000]fps` — max 30fps
- Live capture confirms steady 29-30fps

## Investigation Results

### Is 60fps physically possible over USB from the Canon 250D?

**No. 60fps USB live view is a hard hardware/firmware limitation of the Canon 250D.**

Evidence:

1. **Camera firmware generates EVF frames at ~30fps internally.** The DIGIC 8 processor and sensor readout pipeline produce live view at ~30fps. This matches the NTSC video standard the camera targets. Canon does not publish the exact rate but developer testing consistently shows ~30fps ceiling.

2. **EDSDK provides no frame rate control.** The relevant API is a **pull/poll model**:
   - `EdsDownloadEvfData()` downloads the current EVF frame
   - If you poll faster than ~30fps, the camera returns the same frame or blocks
   - If you poll slower, you get fewer frames
   - There is no property or command to request a higher frame rate
   - `kEdsPropID_Evf_Mode` is on/off only, no rate parameter
   - `kEdsPropID_Evf_OutputDevice` selects PC/LCD output, no rate parameter

3. **No Canon DSLR has achieved 60fps USB live view via EDSDK.** The ~30fps ceiling is consistent across all Canon DSLR models tested (Rebel T1i through modern bodies). This is a fundamental characteristic of the EVF-over-USB architecture.

4. **The Canon 250D's EVF resolution is 960x640 pixels at ~30fps.** Each frame is ~50-100KB JPEG. USB 2.0 bandwidth (30 MB/s practical) could theoretically handle 60fps at this data size, but the camera firmware doesn't produce frames that fast.

5. **gphoto2 testing on Canon DSLRs** typically achieves 10-25fps (worse than EDSDK), confirming the camera is the bottleneck, not the software.

### What about Canon's Pro claim of "up to 60fps"?

Canon EOS Webcam Utility Pro advertises "up to 60fps" as a premium feature. However:
- The "up to" qualifier is key — it likely applies to newer mirrorless bodies (R5, R6, etc.) that have faster EVF pipelines
- No public documentation confirms the 250D specifically achieving 60fps through the Pro utility
- The Pro utility uses the same EDSDK + EdsDownloadEvfData path, so it's subject to the same camera firmware limit
- The "60fps" may refer to the **output frame rate** (duplicating frames to hit 60fps delivery) rather than 60 unique frames per second from the camera

### Could frame duplication give us 60fps output?

Yes, technically — the service could duplicate each camera frame to deliver 60 output frames per second. But this provides:
- **Zero quality benefit** — you're seeing each frame twice
- **Increased CPU/memory/bandwidth usage** — double the data for identical content
- **Potential for stuttery/juddery motion** — 30fps content at 60fps delivery looks worse than native 30fps because the duplicate frames create an uneven cadence

### The only path to real 60fps

**HDMI output.** The Canon 250D's HDMI port outputs 1080p60 for external recording. This is a different video pipeline (direct sensor readout → HDMI encoder) that bypasses the EVF system entirely. However, the user has a capture card and prefers USB due to HDMI showing on-screen UI overlays.

## Previous 60fps Test

The user recalled achieving 60fps with ffmpeg previously. Possible explanations:
- The test may have been with **ffmpeg requesting 60fps from the virtual camera** (which would show 60fps output by duplicating frames)
- The test may have been with a **different video source** (FaceTime camera, iPhone Continuity Camera)
- The test may have been with the **capture card** (HDMI path, which does support 60fps)
- Shell history search found no matching commands

## Conclusion

**60fps from the Canon 250D over USB is not achievable.** The camera's firmware produces live view frames at ~30fps, and there is no software mechanism to increase this rate. This is a hard limitation of the camera hardware, not the EOS Webcam Utility.

The current 30fps output is the maximum the camera can deliver over USB. This is perfectly adequate for video conferencing — Zoom, Teams, and Meet all operate at 24-30fps.

## Recommendation

- **Close this investigation** — 60fps is not feasible without different hardware
- **Revert fps-related patches** to avoid confusion (config and binary patches that set fps to 60 are harmless but misleading)
- **Document in PLAN.md** that 30fps is the hardware ceiling for USB
- **If 60fps is ever truly needed:** use HDMI output + capture card, and investigate Clean HDMI solutions for the 250D to remove UI overlays

## Definitive Hardware Test (2026-03-14)

Captured 2 seconds of live video from Canon 250D, extracted 61 frames, and MD5-hashed each:

```
Total frames delivered: 61 (at 30fps request)
Unique frames: 52
Duplicate frames: 9
Actual unique fps: 26.0
Consecutive duplicate pairs: 9 (e.g., f_002==f_003, f_009==f_010)
```

**The Canon 250D produces ~26 unique frames per second over USB.** Even when the pipeline delivers 30fps, 9 out of 61 frames are exact duplicates of the previous frame. The camera hardware genuinely cannot produce more than ~26 unique frames per second.

## Frame Interpolation Research

### Could we generate artificial intermediate frames?

| Approach | Speed at 1080p on M2 Pro | Quality | Latency Added | Viable? |
|---|---|---|---|---|
| **Simple frame blending** | ~0ms (trivial) | Poor — ghosting/double-image on motion | 0ms | No — looks worse than 26fps |
| **RIFE (neural network)** | Too slow — M1 only manages 576p real-time | Excellent | 38-60ms | No — can't hit 1080p real-time |
| **IFRNet, FLAVR** | Heavier than RIFE | Good-Excellent | 38-60ms+ | No |
| **Apple VTFrameProcessor** | Hardware-accelerated (Neural Engine) | Good | 38-60ms | **Possible** — macOS 15.4+ only |
| **Frame duplication with timing** | ~0ms | Identical to source | 0ms | Yes — simplest fix |

### Apple's VTLowLatencyFrameInterpolationConfiguration (macOS 15.4+)

Apple introduced a purpose-built real-time frame interpolation API in macOS 15.4:
- Uses Neural Engine + GPU for ML-based interpolation
- Designed for exactly this use case (real-time video on Apple Silicon)
- Would require building a custom CMIOExtension wrapper around the Canon pipeline
- Adds ~38-60ms latency (must buffer next frame to interpolate)

### Is 26fps vs 30fps actually noticeable?

**Almost certainly not in a video call:**
- 26fps exceeds cinema standard (24fps)
- Zoom itself records at 25fps in "Optimize for video" mode
- Conferencing platforms dynamically adjust to 15-25fps based on bandwidth
- Participants rarely notice frame rates above ~24fps for talking heads
- The 4fps difference is a ~13% reduction — perceptually negligible

### Recommendation

**Do nothing.** The 26fps output is more than adequate for video conferencing. Frame interpolation would add complexity, latency (38-60ms), and risk of visual artifacts for an imperceptible improvement. If micro-stutter occurs from frame pacing mismatch (26fps source into 30fps delivery), simple frame duplication with correct timestamps is the better fix — zero latency, zero complexity.

## No Changes Made

This was a research-only investigation. No files were modified.

## Addendum (2026-09-28): what the fps bytes really do, and the fix

Review finding M2: the fork's EWCProxy "fps 30 -> 60" patch changed `03` to
`07` at 0x43811, which encodes `mov w8,#62`, not 60, while the README and
the installer said 30fps. The disassembly below (`otool -tV` on the three
binaries from Canon's pinned v1.3.16 package, expanded read-only with
`pkgutil --expand-full`) shows where the frame rate comes from and why none
of the three "30 -> 60" patches did what their comments said. Addresses are
vmaddrs (file offset + 0x100000000 for EOSWebcamService and EWCProxy; the
DAL plug-in's are the file offsets).

### Canon's pipeline has two frame rates: 30 and 60

- **EOSWebcamService.** The protobuf enum `APIGlobalSettings.StreamFps` has
  `FPS_UNSPECIFIED`, `FPS_30`, `FPS_60` (strings in the binary; "GetGlobalSettings:
  unexpected fps setting" for anything else). The StreamFps setter at
  0x10008992c stores the value only if it is `#0x3c` (60) or `#0x1e` (30).
  `SetIsPro(false)` at 0x100089b60 (called on the licence paths, e.g.
  0x1000155fc with `w0 = 0`) resets StreamFps to 30 (`mov w8,#0x1e` at
  0x100089bc4) along with the 1280x720 clamp the fork patches to 1080p.
- **EWCProxy.** Reads `StreamFps` from config.plist (CFString at
  0x100172658) through the setter at 0x100043584, which also accepts only 60
  or 30. The initial value in `__DATA` (0x100174fb4) is 30. The getter
  (0x100043578) feeds the frame pacing: waits of `1000 / fps` ms
  (0x10001b638, 0x10001d224), and 0x100022cb4 returns
  `min(1000 / measured camera frame interval, StreamFps)`, clamped to 1 when
  no frame came for a second. So EWCProxy already follows the camera's real
  rate, up to StreamFps.
- **The patched `mov w8,#30` at 0x100043810** is in EWCProxy's own
  "Pro turned off" reset (0x1000437b8: stores the flag, then resets fps,
  1280x720 and a 1000 ms value). Nothing calls it: no `bl`/`b` to it, no
  pointer to it in the data, no `adrp` to its page. The `#62` it was patched
  to was dead code, and a value the setter would refuse anyway. (The four
  EWCProxy width/height patches at 0x43849-0x43895 are in the same dead
  function; they are harmless and left as they are.)
- **The DAL plug-in** decides what apps are told.
  `StreamClient::GetGlobalStreamSettings` (symbols are present) asks the
  service for its settings and maps StreamFps at 0x3130c:

  ```
  3130c  mov  w9, #0x1e        ; 30
  31310  mov  w10, #0x3c       ; 60
  31314  cmp  w8, #0x2         ; FPS_60?
  31318  csel w10, w10, w9, eq
  3131c  cmp  w8, #0x1         ; FPS_30?
  31320  csel w8, w9, w10, eq
  31324  str  w8, [x19, #0x48] ; StreamClient::GetFps() returns this
  ```

  (30 if the service can't be reached, 0x312d0.) `GetFps()` is the stream's
  `kCMIOStreamPropertyFrameRate` ('nfrt'), `FrameRates` ('nfr#'),
  `MinimumFrameRate` ('mfrt') and `FrameRateRanges` ('frrg', min = max =
  fps), and it sets the plug-in's frame timer (`dispatch_source_set_timer`
  every 1e9/fps ns, 0x34d2c), queue depth (0x34f70) and sample times
  (0x35530). The old patch `c903` -> `8907` made the first instruction
  `mov w9,#60`, so **every** setting advertised 60 fps and the timer ran at
  60 Hz, handing apps each camera frame two or three times.

### Can a static patch give "the camera's maximum"?

No. What apps are told is one number, fixed when the stream is set up, from
the service's StreamFps (30 or 60). The camera's actual rate is only known
while frames arrive, and EWCProxy already paces to it (up to StreamFps). The
highest value the pipeline and the camera can really serve is therefore the
smallest StreamFps at or above what the camera delivers. The one body
measured, the 250D, sends 26 new frames a second over USB (above), and EDSDK
live view (`EdsDownloadEvfData`) is generally about 30 fps at most. That is
30.

### Fix (PR C)

- patch-binaries.py no longer patches either fps byte, and puts Canon's
  bytes back on installs of fork v1.4.1/v1.4.2 (`REVERTS`). The whole chain
  now follows config.plist's `StreamFps`, which the installer writes as 30:
  the service reports FPS_30, the DAL plug-in advertises 30 and paces at
  30 Hz, EWCProxy caps at 30 and follows the camera below that.
- The README and the installer's "1920x1080 @ 30fps" are now true.
- `dist/v1.4/measure-fps.sh` measures, read-only, what the camera really
  delivers: the advertised modes, the negotiated format, the delivered
  frame rate and spacing, and how many frames are new pictures.

### Still to measure on a real Mac

- The earlier note above that the plug-in advertised `[15 30]` doesn't match
  this disassembly (min = max = GetFps). On the v1.4.2 install on this Mac
  (read-only check), 0x3130c holds `mov w9,#60`, so the prediction is that
  apps are told 60 fps and get ~26 new pictures a second; after the fix, 30
  fps with ~26 new. measure-fps.sh before and after settles it.
- Whether any EOS body delivers more than ~30 new frames a second over USB.
  60 would need StreamFps 60 *and* the service's `SetIsPro(false)` reset
  (0x100089bc4) changed, since that sets 30 back; untested, so not done.
  measure-fps.sh says so if new pictures come as fast as the cap allows.
