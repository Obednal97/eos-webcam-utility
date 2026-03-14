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
