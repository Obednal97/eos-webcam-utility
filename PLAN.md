# Canon 250D USB Webcam Utility — Project Plan

## Goal

Fork the discontinued Canon EOS Webcam Utility (free, v1.3.16) to unlock 1080p upscaled output and bypass the Pro subscription paywall — delivering the same "Full HD with upscaling" feature Canon charges $5/month for.

## Current State (2026-03-14) — After Patching

### What's Installed & Patched
- **Canon EOS Webcam Utility v1.3.16** (free, standalone — final version, discontinued Aug 2025)
- Native **arm64** DAL plugin at `/Library/CoreMediaIO/Plug-Ins/DAL/EOSWebcamUtility.plugin`
- Intel **x86_64** fallback at `/Library/CoreMediaIO/Plug-Ins/DAL/EOSWebcamUtility_x86_64.plugin` (unmodified)
- Background service: `com.canon.usa.EWCService` (LaunchAgent)
- EDSDK framework: `/Library/Frameworks/EDSDK.framework`

### What's Working
- **1920x1080 output** — confirmed live from Canon 250D via USB (upscaled from ~1024x576 native EVF)
- **isPro bypass** — all Pro feature gates return true
- **Pro subscription check** — bypassed (no Canon account needed)
- **Auto-retry camera activation** — Canon Camera Manager daemon auto-retries when camera fails to connect; typically succeeds within 20-30 seconds without manual intervention (see work-log/007)
- **Camera activation improved** — patched version connects in 1-2 Zoom selections vs 3-5 with original

### What's NOT Working / Not Possible
- **60fps** — **Not possible over USB.** The Canon 250D's firmware generates EVF frames at ~26 unique fps (delivers 30fps with frame duplication). This is a hard hardware/firmware limit. EDSDK provides no frame rate control. See work-log/006.
- **Instant camera activation** — first attempt usually fails (ptpcamerad race condition), auto-retry takes ~20-30 seconds. Not fixable without kernel-level USB device matching overrides.

---

## How The Video Pipeline Works

```
Canon 250D (sensor: 6000x4000)
    ↓ EVF (Electronic Viewfinder) mode
    ↓ Camera internally downscales to ~1024x576
    ↓ Compresses to JPEG
    ↓ Sends over USB via PTP protocol
    ↓
EWCProxy (EDSDK.framework)
    ↓ Receives JPEG frames via EdsDownloadEvfData
    ↓ Decompresses via libjpeg-turbo (tjDecompressToYUVPlanes)
    ↓ Upscales to output resolution (1920x1080)
    ↓ Writes to SharedFrameRing (shared memory)
    ↓
EOSWebcamService
    ↓ Reads from SharedFrameRing
    ↓ Creates CMVideoFormatDescription (1920x1080, 2vuy pixel format)
    ↓ Feeds frames to DAL plugin via CFMessagePort IPC
    ↓
EOSWebcamUtility (DAL Plugin)
    ↓ Registers as CoreMediaIO virtual camera
    ↓ Provides CMSampleBuffers to requesting apps
    ↓
Zoom / FaceTime / ffmpeg
    ↓ Receives 1920x1080 frames
    ↓ Re-encodes for transmission (H.264 at 2-4 Mbps)
```

### Important: What "1080p" Actually Means Here

The Canon 250D's EVF-over-USB stream is natively **~1024x576 pixels**. This is a hardware limitation of the camera's Live View USB output — it does not send full sensor resolution over USB.

The "1080p" output is the result of **upscaling** this ~1024x576 source to 1920x1080 using libjpeg-turbo's DCT-domain scaling (likely the 15/8 = 1.875x factor, which exactly maps 1024→1920 and 576→1080).

**This is exactly what Canon's Pro subscription ($5/month) provides** — their marketing explicitly says "Full HD **with upscaling**." We have replicated this feature for free.

For true native 1080p from the camera, you would need HDMI output + capture card (the sensor sends full resolution over HDMI, but not over USB).

---

## Understanding Upscaling

### How It Works

Upscaling creates new pixel values for a higher-resolution frame from lower-resolution source data. No new real detail is created — the algorithms estimate what the "missing" pixels should look like.

| Algorithm | Samples | Speed | Quality | Artifacts |
|---|---|---|---|---|
| Nearest Neighbor | 1 pixel | Fastest | Blocky, pixelated | Jagged edges |
| Bilinear | 4 pixels (2x2) | Fast | Smooth but blurry | Soft edges |
| Bicubic | 16 pixels (4x4) | Medium | Good sharpness | Minor ringing |
| Lanczos | 32+ pixels | Slower | Sharpest traditional | Halo/ringing artifacts |
| DCT-domain (libjpeg-turbo) | Frequency domain | Efficient for JPEG | Similar to bicubic | Block boundary artifacts |

Canon's utility likely uses **libjpeg-turbo's DCT-domain scaling** during JPEG decompression — the 15/8 factor is an exact match for 1024x576 → 1920x1080, and the library supports it natively.

### Quality At Different Scale Factors (from ~1024x576 source)

| Target | Scale Factor | Quality | Verdict |
|---|---|---|---|
| 1280x720 | 1.25x | Excellent — nearly indistinguishable from native | Best efficiency for most video calls |
| **1920x1080** | **1.875x** | **Good — moderate softening, fine for talking-head** | **What we've enabled; matches Canon Pro** |
| 3840x2160 (4K) | 3.75x | Poor — visibly soft/mushy, 14x more pixels than source | Harmful, not beneficial |

### Should We Push To 4K?

**No.** Reasons:

1. **3.75x upscale from 1024x576 produces obviously soft output** — no algorithm can conjure 7.7M pixels of real detail from 0.6M source pixels
2. **No video conferencing app transmits 4K** — Zoom maxes at 1080p (Business plans only), Teams/Meet max at 720p-1080p. The 4K frame would be immediately downscaled back
3. **Compression destroys upscaled detail** — Zoom uses 2-4 Mbps; at 4K that's catastrophically low bits-per-pixel, producing worse quality than 720p at the same bitrate
4. **libjpeg-turbo can't do it in one pass** — max DCT upscale is 2x (1024→2048), so 4K would need a second scaling pass
5. **4x the memory/bandwidth for zero quality gain** — pure waste of CPU, memory, and USB bandwidth

### The Honest Reality of 1080p Upscaling for Video Calls

For Zoom/Teams at typical bitrates (2-4 Mbps), research shows that **720p can actually look better than 1080p** because the encoder has more bits per pixel. The upscaled "detail" from 1080p is the first thing the encoder discards.

**Where 1080p upscaling helps:**
- Zoom Business/Enterprise plans with 1080p enabled (~3.8 Mbps allocation)
- Local recording (no compression)
- OBS streaming at higher bitrates (8+ Mbps)
- Apps that display the uncompressed local preview

**Where it doesn't help:**
- Zoom Free/Pro plans (capped to 720p output regardless)
- Virtual backgrounds enabled (caps to 720p)
- Google Meet (720p max)

---

## All Changes Made

### Backups (all reversible)

| File | Backup Location |
|---|---|
| `config.plist` | `~/Library/Application Support/EWCService/config.plist.backup-20260314` |
| `proconfig.plist` | `~/Library/Application Support/EWCService/proconfig.plist.backup-20260314` |
| `EOSWebcamUtility` (DAL plugin) | `~/development/webcam-utility/EOSWebcamUtility.backup-20260314` |
| `EOSWebcamService` | `~/development/webcam-utility/EOSWebcamService.backup-20260314` |
| `EWCProxy` | `~/development/webcam-utility/EWCProxy.backup-20260314` |

Original installer also available: `~/Downloads/EOSWebcamUtility-MAC1.3.16.pkg` and on Canon's server.

### Phase 1: Config Plist (work-log/001)

| File | Key | Original | New |
|---|---|---|---|
| config.plist | StreamWidth | 1280 | 1920 |
| config.plist | StreamHeight | 720 | 1080 |
| config.plist | StreamFps | 30 | 30 (60 not possible — hardware limit) |
| config.plist | HeadlessStreamWidth | 1280 | 1920 |
| config.plist | HeadlessStreamHeight | 720 | 1080 |
| config.plist | OptimizationMode | 0 (PICTURE_QUALITY) | 1 (FRAME_RATE) |
| proconfig.plist | StreamWidth | 1280 | 1920 |
| proconfig.plist | StreamHeight | 720 | 1080 |
| proconfig.plist | StreamFps | 30 | 30 |

**Result:** Values persisted (service didn't overwrite), but format still advertised as 720p — config alone insufficient.

### Phase 2a: DAL Plugin Binary (work-log/002)

File: `EOSWebcamUtility.plugin/Contents/MacOS/EOSWebcamUtility`

| Offset | Original | Patched | Purpose |
|---|---|---|---|
| `0x312d8` | `mov w9, #0x500` (1280) | `mov w9, #0x780` (1920) | Case 2 width |
| `0x312e0` | `mov w9, #0x2d0` (720) | `mov w9, #0x438` (1080) | Case 2 height |
| `0x13bcb0` | `00 05 00 00 d0 02 00 00` | `80 07 00 00 38 04 00 00` | Fallback defaults |
| `0x3130c` | `mov w9, #0x1e` (30) | `mov w9, #0x3c` (60) | FPS default |

**Result:** DAL plugin now maps stream_size=2 to 1080p. But format still set by service via IPC.

### Phase 2b: EOSWebcamService Binary — isPro Bypass (work-log/003)

File: `EOSWebcamUtility.plugin/Contents/Resources/EOSWebcamService`

| Offset | Original | Patched | Purpose |
|---|---|---|---|
| `0x89b58` | `ldrb w0, [x8, #0xf0]` | `mov w0, #1` | **isPro getter → always true** |
| `0xd8ae4` | `mov w26, #0x500` (1280) | `mov w26, #0x780` (1920) | CMVideoFormat width |
| `0xd8ae8` | `mov w28, #0x2d0` (720) | `mov w28, #0x438` (1080) | CMVideoFormat height |
| `0xd8af8` | `mov w2, #0x500` (1280) | `mov w2, #0x780` (1920) | CMVideoFormat arg width |
| `0xd8b00` | `mov w3, #0x2d0` (720) | `mov w3, #0x438` (1080) | CMVideoFormat arg height |
| `0x62ac` | `mov w9, #0x500` (1280) | `mov w9, #0x780` (1920) | Case 2 width |
| `0x62b4` | `mov w9, #0x2d0` (720) | `mov w9, #0x438` (1080) | Case 2 height |
| `0x89bfc` | `mov w8, #0x500` (1280) | `mov w8, #0x780` (1920) | SetIsPro clamp width |
| `0x89c08` | `mov w8, #0x2d0` (720) | `mov w8, #0x438` (1080) | SetIsPro clamp height |

**Result:** All Pro features unlocked. Service creates 1080p format descriptions. First deploy crashed due to code signing — learned to sign each binary individually before bundle.

### Phase 2c: EWCProxy Binary (work-log/004)

File: `EOSWebcamUtility.plugin/Contents/Resources/EWCProxy`

| Offset | Original | Patched | Purpose |
|---|---|---|---|
| `0x434e0` | `mov w8, #0x2d0` (720) | `mov w8, #0x438` (1080) | Case 2 height |
| `0x434e4` | `mov w9, #0x500` (1280) | `mov w9, #0x780` (1920) | Case 2 width |
| `0x43810` | `mov w8, #0x1e` (30) | `mov w8, #0x3c` (60) | Default FPS |
| `0x43848` | `mov w8, #0x500` (1280) | `mov w8, #0x780` (1920) | Default width |
| `0x43854` | `mov w8, #0x2d0` (720) | `mov w8, #0x438` (1080) | Default height |
| `0x43888` | `mov w9, #0x500` (1280) | `mov w9, #0x780` (1920) | Alt path width |
| `0x43894` | `mov w9, #0x2d0` (720) | `mov w9, #0x438` (1080) | Alt path height |

**14 other 1280/720 values intentionally NOT patched** — they are EDSDK property IDs (kEdsPropID_Evf_Mode), buffer allocation sizes, JPEG color LUT offsets, and protobuf constants.

**Result:** Virtual camera advertises 1920x1080 as primary mode. Live feed confirmed at 1080p from Canon 250D.

### Phase 3: Camera Activation Auto-Retry (work-log/007)

File: `~/development/webcam-utility/canon-camera-manager.sh`
Installed as: `~/Library/LaunchAgents/com.eos-camera-manager.plist`

A background daemon that monitors EWCProxy and auto-retries when camera connection fails. When EWCProxy exits within 15 seconds (indicating failed EDSDK session), the daemon restarts the Canon service, which triggers Zoom's DAL plugin to reconnect and send a fresh stream request.

**Does NOT kill ptpcamerad** — that was found to cause USB state corruption.

### Upscaling Algorithm: DCT-Domain Scaling

Confirmed via binary analysis: the utility uses **libjpeg-turbo's DCT-domain scaling** at 15/8 (1.875x). `tjGetScalingFactors()` and `tjDecompress2()` are present in both EWCProxy and EOSWebcamService. No spatial-domain scaling (no vImage, no Accelerate, no CoreImage, no Lanczos). The upscaling happens during JPEG decompression in a single pass.

### Code Signing Lesson

On macOS arm64, after patching binaries in a plugin bundle:
1. Sign **each binary individually** first: `codesign --force --sign - <binary>`
2. Then sign the **bundle**: `codesign --force --deep --sign - <bundle>`
3. Verify: `codesign --verify -vv <path>`

Failure to sign inner binaries causes `CODE SIGNING: rejecting invalid page` kernel errors and SIGKILL.

### USB State Corruption Lesson

Aggressively killing ptpcamerad in a loop can corrupt the camera's PTP session state. Symptoms: `PTP Timeout` on all gphoto2/EDSDK commands, camera shows "connected" on USB but won't respond. Recovery requires: unplug USB cable, remove camera battery for 10+ seconds, reconnect to a different USB port. **Never brute-force kill ptpcamerad — it causes more problems than it solves.**

---

## Rollback Procedure

To fully restore the original v1.3.16 installation:

```bash
# Stop service
launchctl unload /Library/LaunchAgents/com.canon.usa.EWCService.plist

# Restore configs
cp ~/Library/Application\ Support/EWCService/config.plist.backup-20260314 \
   ~/Library/Application\ Support/EWCService/config.plist
cp ~/Library/Application\ Support/EWCService/proconfig.plist.backup-20260314 \
   ~/Library/Application\ Support/EWCService/proconfig.plist

# Restore binaries (needs admin)
osascript -e 'do shell script "
cp ~/development/webcam-utility/EOSWebcamUtility.backup-20260314 \
   \"/Library/CoreMediaIO/Plug-Ins/DAL/EOSWebcamUtility.plugin/Contents/MacOS/EOSWebcamUtility\"
cp ~/development/webcam-utility/EOSWebcamService.backup-20260314 \
   \"/Library/CoreMediaIO/Plug-Ins/DAL/EOSWebcamUtility.plugin/Contents/Resources/EOSWebcamService\"
cp ~/development/webcam-utility/EWCProxy.backup-20260314 \
   \"/Library/CoreMediaIO/Plug-Ins/DAL/EOSWebcamUtility.plugin/Contents/Resources/EWCProxy\"
codesign --force --sign - \"/Library/CoreMediaIO/Plug-Ins/DAL/EOSWebcamUtility.plugin/Contents/MacOS/EOSWebcamUtility\"
codesign --force --sign - \"/Library/CoreMediaIO/Plug-Ins/DAL/EOSWebcamUtility.plugin/Contents/Resources/EOSWebcamService\"
codesign --force --sign - \"/Library/CoreMediaIO/Plug-Ins/DAL/EOSWebcamUtility.plugin/Contents/Resources/EWCProxy\"
codesign --force --deep --sign - \"/Library/CoreMediaIO/Plug-Ins/DAL/EOSWebcamUtility.plugin\"
" with administrator privileges'

# Restart service
launchctl load /Library/LaunchAgents/com.canon.usa.EWCService.plist
```

Or simply reinstall from `~/Downloads/EOSWebcamUtility-MAC1.3.16.pkg`.

---

## Canon Download Server Reference

All publicly accessible at `https://downloads.canon.com/webcam/` (Akamai CDN, no auth, CORS open).

### Free Utility (Discontinued)
| Version | Filename | Date |
|---|---|---|
| 1.0 | `EOSWebcamUtility-MAC1.0.pkg.zip` | Nov 2020 |
| 1.1 | `EOSWebcamUtility-MAC1.1.pkg.zip` | Sep 2022 |
| **1.3.16** | `EOSWebcamUtility-MAC1.3.16.pkg.zip` | Jan 2024 |

### Pro Utility (Active)
| Version | Filename | Date |
|---|---|---|
| 2.0 | `EOSWebcamUtilityPro-MAC2.0.pkg.zip` | Nov 2022 |
| 2.3 | `EOSWebcamUtilityPro-MAC2.3.pkg.zip` | Nov 2024 |
| 2.3c–2.3g | `EOSWebcamUtilityPro-MAC2.3{c-g}.pkg.zip` | Mar–Sep 2025 |
| **2.3h** | `EOSWebcamUtilityPro-MAC2.3h.pkg.zip` | Mar 2026 (latest) |

**CUSA redirect:** `/webcam/EOSWebcamUtilityPro-MAC/CUSA` → latest version

---

## Key Files Reference

| File | Purpose |
|---|---|
| `~/Library/Application Support/EWCService/config.plist` | Main persistent settings |
| `~/Library/Application Support/EWCService/proconfig.plist` | Pro-tier settings |
| `~/Library/Logs/EOS-Webcam-Utility/main.log` | Service log (stopped writing Oct 2025) |
| `/Library/LaunchAgents/com.canon.usa.EWCService.plist` | LaunchAgent (root-owned) |
| `/Library/Frameworks/EDSDK.framework/` | Canon's camera SDK |
| `.../EOSWebcamUtility.plugin/Contents/MacOS/EOSWebcamUtility` | DAL plugin binary |
| `.../EOSWebcamUtility.plugin/Contents/Resources/EOSWebcamService` | Background service |
| `.../EOSWebcamUtility.plugin/Contents/Resources/EWCProxy` | Camera proxy (EDSDK) |
| `.../EOSWebcamUtility.plugin/Contents/Resources/EWCPairingService` | WiFi pairing helper |

### IPC Mach Ports
| Port | Communication |
|---|---|
| `com.canon.usa.EOSWebcamUtility.Command` | DAL plugin ↔ Service |
| `com.canon.usa.EOSWebcamUtility.ProxyCommand` | Service ↔ EWCProxy |
| `com.canon.usa.EOSWebcamUtility.CameraProxy` | EWCProxy camera IPC |

---

## Competitive Analysis (8 projects reviewed, 2026-03-14)

### Our fork is the only working 1080p USB webcam solution for Canon DSLRs on macOS Apple Silicon.

No other project delivers 1080p output from the 250D over USB, handles ptpcamerad gracefully, or works natively on Apple Silicon without Rosetta 2.

### Relevant Projects

| Project | Platform | Approach | Status | Key Finding |
|---|---|---|---|---|
| [webcamize](https://github.com/cowtoolz/webcamize) | Linux | gphoto2 + v4l2loopback | Active (1,600+ stars) | Confirms ~1024x576 native EVF is hardware limit; PTP liveview size parameter may allow higher native resolution |
| [poly-canon-cam](https://github.com/princepspolycap/poly-canon-cam) | macOS | EDSDK via Python | Low activity (2 stars) | Validates `EdsGetEvent()` warmup for macOS 13+ camera detection; aggressive retry with exponential backoff |
| [webcamit](https://github.com/petabyt/webcamit) | Linux | C + libjpeg-turbo | WIP (5 stars) | Most efficient frame decode pipeline; USB hotplug monitoring; has libpict PTP library alternative |
| [eos-webcam-live](https://github.com/marcelogm/eos-webcam-live) | Linux | gphoto2 + face detect | New (0 stars) | Face-detection autofocus — novel feature (not pursuing for now) |
| [ptpwebcam](https://github.com/dognotdog/ptpwebcam) | macOS | PTP + DAL plugin | Broken on macOS 14+ | Camera controls (exposure/aperture/focus) via PTP; **critically: DAL plugins are deprecated** |
| [EOS-M100-Clean-HDMI](https://github.com/FloppySoft/EOS-M100-Clean-HDMI) | Camera firmware | EOSCard scripting | Dormant | M100 only; CHDK/Magic Lantern don't support 250D |

### Not Relevant

| Project | Why |
|---|---|
| [vb-c10-network-camera](https://github.com/davidbrenner/vb-c10-network-camera-js-client) | IP network camera with HTTP API — different product category entirely |
| [canonball](https://github.com/soldair/canonball) | Controls a pirate cannon, not a Canon camera |

### Key Strategic Findings

1. **PTP liveview size parameter** — webcamize issue #18 suggests some cameras support requesting higher preview resolution via PTP config. If the 250D supports this, we could get native 1280x720 or higher before upscaling. **High priority to test.**

2. **DAL plugins are deprecated** — Apple deprecated CoreMediaIO DAL plugins (WWDC 2022, sunset macOS 14). Our patched plugin still works but is fragile. **Camera Extensions (CMIOExtension, macOS 12.3+) is the future-proof replacement.** No open-source project has built a DSLR webcam Camera Extension — completely unoccupied space. Reference: [coremediaio-dal-minimal-example](https://github.com/johnboiles/coremediaio-dal-minimal-example).

3. **EDSDK has no native ARM64 support** — must run under Rosetta 2. Our binary patching approach avoids this dependency entirely, which is a significant advantage over EDSDK-based projects.

4. **Our ptpcamerad handling is unique** — every other project recommends aggressive kill loops. Our gentle service-restart retry is documented nowhere else and avoids the USB state corruption we discovered.

5. **Magic Lantern / CHDK don't support the 250D** — firmware-level approaches (resolution override, overlay suppression) are not available for this camera.

### Tools Available on System
| Tool | Version | Path |
|---|---|---|
| gphoto2 | 2.5.32 | `/opt/homebrew/bin/gphoto2` |
| ffmpeg | 8.0.1 | `/opt/homebrew/bin/ffmpeg` |
| libgphoto2 | (dep) | via Homebrew |

---

## Outstanding Work

### ~~Priority 1: Camera Activation Race Condition~~ — SOLVED (work-log/005, 007)
- **Solution:** Canon Camera Manager daemon (v10) auto-retries by restarting the service when EWCProxy fails
- **Result:** Camera connects automatically within ~20-30 seconds, no manual toggling needed
- **Installed as:** `~/Library/LaunchAgents/com.eos-camera-manager.plist`
- **Remaining:** Could be faster (currently ~20-30s due to EDSDK session timeout + service restart overhead)

### ~~Priority 2: 60fps Investigation~~ — CLOSED (Not Feasible, work-log/006)
- **Finding:** Camera hardware produces ~26 unique frames/second (confirmed by frame hashing: 52 unique out of 61 delivered in 2 seconds)
- **EDSDK is a pull/poll model** — polling faster than ~30fps returns duplicate frames
- **AI frame interpolation investigated** — RIFE can't run 1080p real-time on M2 Pro; Apple VTFrameProcessor (macOS 15.4+) could work but adds 38-60ms latency; not worth it for 26→30fps
- **30fps is adequate** for Zoom/Teams/Meet (all operate at 24-30fps)

### ~~Priority 3: Custom Loading Screen~~ — DONE (work-log/008)
- **Solution:** Canon Camera Manager daemon dynamically swaps `errorNoDevice.jpg` based on USB state
- **Camera connected:** Shows company logo + "Connecting to camera... Please wait"
- **Camera disconnected:** Shows "Camera not connected" in red
- **Logo support:** Place `logo.png` in `~/development/webcam-utility/`, run `generate-images.sh`
- **Known issue:** Text appears mirrored in Zoom (mirrors video at source level) — low priority, only visible during 20-30s connection period

### ~~Priority 4: PTP Liveview Size Parameter~~ — CLOSED (No Effect)
- **Tested:** Canon 250D has Large/Medium/Small liveview size settings via PTP (`/main/capturesettings/liveviewsize`)
- **Result:** All three output **identical 1024x576 resolution**. The setting does not change output dimensions on this camera.
- **Tested via:** gphoto2 `--set-config liveviewsize=Large/Medium/Small` + `--capture-preview` — all produced 1024x576 JPEGs (~180-195KB)
- **Conclusion:** The 250D's USB EVF resolution is hardware-locked at 1024x576. No PTP configuration can increase it. Our DCT upscaling to 1080p remains the best available approach.

### Priority 5: Camera Extension (Future-Proofing)
- **Problem:** CoreMediaIO DAL plugins deprecated (WWDC 2022, sunset macOS 14). Our patched plugin works but is fragile.
- **Solution:** Build an open-source Camera Extension (CMIOExtension) — Apple's modern virtual camera API
- **Opportunity:** No open-source DSLR webcam Camera Extension exists. First-mover advantage.
- **Reference:** [coremediaio-dal-minimal-example](https://github.com/johnboiles/coremediaio-dal-minimal-example)
- **Impact:** Future-proof, would survive macOS updates

### Priority 6: Code Signing Hardening
- **Problem:** Patched binaries use ad-hoc signatures; could break on macOS updates
- **Impact:** Low — works currently, but fragile

### Placeholder Images Reference
| Image | File | Dimensions | When Shown |
|---|---|---|---|
| "EOS WEBCAM UTILITY" (text only) | `default.jpg` | 1980x1080 | DAL plugin loaded, no frames yet (~6s grey period) |
| USB cable with red X | `errorNoDevice.jpg` | 1980x1080 | Camera not detected / EWCProxy failed |
| Camera with warning triangle | `errorBusy.jpg` | 1980x1080 | Camera busy / claimed by another process |

---

## Key Discoveries & Lessons Learned

### Camera Hardware
- The Canon 250D's USB EVF outputs ~1024x576 natively at ~26 unique fps
- True native 1080p requires HDMI output + capture card
- 60fps is not possible over USB — hard firmware limit
- The camera's PTP session can get stuck if USB interactions are too aggressive — requires battery removal + USB replug to different port to recover

### Upscaling
- The 1080p output is DCT-domain upscaled at 15/8 (1.875x) via libjpeg-turbo — identical to Canon Pro
- 4K upscaling would be harmful (3.75x scale, no app supports it, compression destroys it)
- AI upscaling (RIFE, etc.) can't run 1080p real-time on Apple Silicon; not worth the latency for webcam use
- For Zoom Free/Pro plans (capped at 720p output), 1080p upscaling provides no benefit over 720p

### Camera Activation
- macOS `ptpcamerad` (SIP-protected) claims Canon USB device, blocking EDSDK
- Killing ptpcamerad aggressively corrupts the USB/PTP state — DO NOT brute-force kill
- The service uses lazy activation — only launches EWCProxy when an app requests a stream
- The service needs ptpcamerad ALIVE to detect the camera, but EWCProxy needs ptpcamerad NOT BLOCKING to claim it — fundamental race condition
- Solution: auto-retry via service restart (Canon Camera Manager daemon), not ptpcamerad killing
- The isPro bypass may have improved activation reliability as a side effect (1-2 attempts vs 3-5 originally)

### Code Signing
- macOS arm64 validates page hashes at runtime — must sign each binary individually before signing the bundle
- Ad-hoc signatures work but could break on macOS updates
- `codesign --force --deep --sign -` on the bundle alone is NOT sufficient for inner binaries

### General
- Avoid building fully custom camera software from scratch — previous attempts caused camera/laptop issues
- The user has a capture card but prefers direct USB: the capture card shows on-screen UI overlays
- All changes are to Canon's software only — no macOS system files were modified
- Arc browser (Chromium) can claim USB devices via IOUSBLib — potential interference source
