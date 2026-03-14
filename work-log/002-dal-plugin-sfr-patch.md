# Work Log 002: DAL Plugin Binary Patch

**Date:** 2026-03-14
**Phase:** 2 — DAL Plugin SFR Patch
**Risk Level:** Medium (reversible via backup)
**Status:** In Progress
**Depends on:** Phase 1 (config.plist changes — completed)

## Objective

Patch the DAL plugin binary so that when the EWCService returns `stream_size=2` (the default for non-Pro), the plugin uses 1920x1080 instead of 1280x720. Also patch the FPS fallback to 60fps.

## Key Discovery

The DAL plugin **already contains full 1920x1080@60fps support** in its code. The resolution is determined by a switch on the `stream_size` protobuf enum returned by the EWCService:

| stream_size | Jump target | Width | Height | Resolution |
|---|---|---|---|---|
| 1 | `0x312b4` | 640 | 360 | 640x360 |
| **2 (default)** | **`0x312d8`** | **1280** | **720** | **1280x720** |
| 3 | `0x312e8` | 1920 | 1080 | 1920x1080 |
| 4 | `0x312f8` | custom | custom | Custom |

The service returns `stream_size=2` because the isPro gate prevents it from honoring our config.plist request for 1080p. Rather than patching the service's subscription check, we patch the plugin's case 2 to output 1080p values.

## File Location

```
/Library/CoreMediaIO/Plug-Ins/DAL/EOSWebcamUtility.plugin/Contents/MacOS/EOSWebcamUtility
```

## Backup Location

```
/Library/CoreMediaIO/Plug-Ins/DAL/EOSWebcamUtility.plugin/Contents/MacOS/EOSWebcamUtility.backup-20260314
```

## Patches

### Patch 1: Case 2 width — 1280 → 1920

- **Offset:** `0x312d8`
- **Instruction:** `mov w9, #0x500` → `mov w9, #0x780`
- **Original bytes:** `09 a0 80 52`
- **New bytes:** `09 f0 80 52`
- **Verification:** 1280 = 0x500, 1920 = 0x780

### Patch 2: Case 2 height — 720 → 1080

- **Offset:** `0x312e0`
- **Instruction:** `mov w9, #0x2d0` → `mov w9, #0x438`
- **Original bytes:** `09 5a 80 52`
- **New bytes:** `09 87 80 52`
- **Verification:** 720 = 0x2D0, 1080 = 0x438

### Patch 3: Fallback defaults (when service unreachable) — 1280x720 → 1920x1080

- **Offset:** `0x13bcb0`
- **Original bytes:** `00 05 00 00 d0 02 00 00` (width=1280, height=720, LE 32-bit)
- **New bytes:** `80 07 00 00 38 04 00 00` (width=1920, height=1080, LE 32-bit)

### Patch 4: Default switch case width — 1280 → 1920 (same as case 2, at default jump target)

The default case also jumps to `0x312d8`, so Patch 1 covers this.

### Patch 5: FPS default — 30 → 60

The FPS logic at `0x3130c`-`0x31324`:
```
0x3130c: mov  w9, #0x1e    // 30 (fallback)
0x31310: mov  w10, #0x3c   // 60
0x31314: cmp  w8, #0x2     // if FPS_60
0x31318: csel w10, w10, w9, eq  // select 60 if match, else 30
0x3131c: cmp  w8, #0x1     // if FPS_30
0x31320: csel w8, w9, w10, eq   // select 30 if match, else previous
```

**Approach:** Change the fallback value at `0x3130c` from 30 to 60, so the default path yields 60fps.
- **Offset:** `0x3130c`
- **Instruction:** `mov w9, #0x1e` → `mov w9, #0x3c`
- **Original bytes:** `e9 03 80 52`

Wait — let me verify. `mov w9, #0x1e` encodes as: imm16=0x1e=30, so `0x1e << 5 | 0x09` in the movz encoding.
- movz w9, #0x1e = `0x52800009 | (0x1e << 5)` = ... need to verify exact encoding from binary.

**Simpler approach:** Swap the fallback so both w9 and w10 are 60:
- **Offset:** `0x3130c`
- **Original:** `mov w9, #0x1e` (30)
- **New:** `mov w9, #0x3c` (60)
- This makes the default 60fps. If the service explicitly returns FPS_30 (enum=1), the csel at 0x31320 would still select w9 (now 60) — which is fine for our purposes.

## ARM64 Instruction Encoding Reference

`movz Wd, #imm16` encoding: `0101 0010 100x xxxx xxxx xxxx xxxd dddd`
- Bits [4:0] = register number
- Bits [20:5] = imm16
- For `mov w9, #0x500`: `0x52800009 | (0x500 << 5)` = need to compute

Verified encodings from the binary analysis:
- `mov w9, #0x500` (1280) = `09 a0 80 52`
- `mov w9, #0x2d0` (720) = `09 5a 80 52`
- `mov w9, #0x780` (1920) = `09 f0 80 52`
- `mov w9, #0x438` (1080) = `09 87 80 52`
- `mov w9, #0x1e` (30) = needs verification from binary
- `mov w9, #0x3c` (60) = needs verification from binary

## Execution Steps

1. Back up the original binary
2. Verify original bytes at each offset match expected values
3. Apply Patch 1 (width 1280→1920 at 0x312d8)
4. Apply Patch 2 (height 720→1080 at 0x312e0)
5. Apply Patch 3 (fallback defaults at 0x13bcb0)
6. Apply Patch 5 (fps default 30→60 at 0x3130c)
7. Verify all patches applied correctly
8. Re-sign the binary with ad-hoc signature (required for arm64 macOS)
9. Unload and reload the EWCService LaunchAgent
10. Run validation checks

## Validation Steps

1. **Binary integrity:** `file` and `codesign --verify` on patched binary
2. **Service running:** `launchctl list | grep canon`
3. **Virtual camera visible:** `system_profiler SPCameraDataType`
4. **Resolution probe:** `ffmpeg -f avfoundation -video_size 1920x1080 -framerate 60 -i "0" -t 1 -f null -`
5. **Supported modes:** `ffmpeg -f avfoundation -video_size 9999x9999 -i "0"` (will error and print supported modes)
6. **App test:** Open Zoom → select EOS Webcam Utility → check feed

## Rollback Steps

```bash
cp "/Library/CoreMediaIO/Plug-Ins/DAL/EOSWebcamUtility.plugin/Contents/MacOS/EOSWebcamUtility.backup-20260314" \
   "/Library/CoreMediaIO/Plug-Ins/DAL/EOSWebcamUtility.plugin/Contents/MacOS/EOSWebcamUtility"
codesign --force --sign - "/Library/CoreMediaIO/Plug-Ins/DAL/EOSWebcamUtility.plugin/Contents/MacOS/EOSWebcamUtility"
launchctl unload /Library/LaunchAgents/com.canon.usa.EWCService.plist
sleep 2
launchctl load /Library/LaunchAgents/com.canon.usa.EWCService.plist
```

## Results

*(To be filled in after execution)*

### Patch Application
- [ ] All original bytes match expected values
- [ ] All patches applied successfully
- [ ] Binary re-signed with ad-hoc signature
- [ ] codesign --verify passes

### Service Restart
- [ ] Service restarted successfully
- [ ] No crash / service stays running

### Resolution Change
- [ ] Virtual camera still visible to macOS
- [ ] ffmpeg reports 1920x1080 in supported modes
- [ ] ffmpeg reports 60fps in supported modes
- [ ] Feed visible in Zoom/FaceTime at higher resolution

### Notes
*(To be filled in)*
