# Work Log 003: isPro Bypass + EOSWebcamService Resolution Patch

**Date:** 2026-03-14
**Phase:** 2b — isPro Bypass + Service Binary Patch
**Risk Level:** Medium (reversible via backup)
**Status:** In Progress
**Depends on:** Phase 1 (config.plist — completed), Phase 2a (DAL plugin — partial, SFRs still from service)

## Key Discovery

The DAL plugin (patched in 002) gets its format from EOSWebcamService via IPC. The resolution is controlled by:
1. **isPro getter** (`0x100089b54` in EOSWebcamService) — called 30+ times to gate all pro features
2. **SetIsPro** (`0x100089b60`) — clamps resolution to 1280x720 when isPro=false
3. **CMVideoFormatDescriptionCreate** call (`0x0d8ae4`) — hardcoded to 1280x720
4. **GetGlobalStreamSettings** switch case 2 (`0x0062ac`) — maps stream_size=2 to 1280x720

## Binary Location

```
/Library/CoreMediaIO/Plug-Ins/DAL/EOSWebcamUtility.plugin/Contents/Resources/EOSWebcamService
```

## Backup Location

```
~/development/webcam-utility/EOSWebcamService.backup-20260314
```

## Patches

### Patch A: isPro Getter — Always Return True

**Function at `0x100089b54`** (file offset `0x89b54`):
```asm
; Original:
adrp  x8, 0x1004fd000       ; (8 bytes - adrp + ldrb)
ldrb  w0, [x8, #0xf0]       ; load isPro from memory
ret

; Patched:
mov   w0, #1                 ; always return true
ret
nop                          ; pad unused instruction
```

- **Offset `0x89b58`** (the ldrb instruction): change to `mov w0, #1`
  - Original bytes: need to verify from binary
  - New bytes: `20 00 80 52` (`mov w0, #1`)
- The `adrp` at `0x89b54` and `ret` at `0x89b5c` can stay as-is (adrp is harmless, ret stays)

Wait — simpler: just patch the `ldrb` to `mov w0, #1`. The adrp loads x8 but we never use it. ret stays.

### Patch B: CMVideoFormatDescriptionCreate — 1280x720 → 1920x1080

At file offset `0xd8ae4`:
```asm
mov  w26, #0x500    ; width=1280 → change to #0x780 (1920)
mov  w28, #0x2d0    ; height=720 → change to #0x438 (1080)
```
At file offset `0xd8af8`:
```asm
mov  w2, #0x500     ; width=1280 → change to #0x780 (1920)
```
At file offset `0xd8b00`:
```asm
mov  w3, #0x2d0     ; height=720 → change to #0x438 (1080)
```

### Patch C: GetGlobalStreamSettings case 2 — 1280x720 → 1920x1080

At file offset `0x62ac`:
```asm
mov  w9, #0x500     ; width=1280 → change to #0x780 (1920)
```
At file offset `0x62b4`:
```asm
mov  w9, #0x2d0     ; height=720 → change to #0x438 (1080)
```

### Patch D: SetIsPro Resolution Clamping — Neutralize

When SetIsPro is called with false, it writes 1280x720 to global vars. Patch the clamping values:
- Width `mov w8, #0x500` → `mov w8, #0x780` (1920)
- Height `mov w8, #0x2d0` → `mov w8, #0x438` (1080)
(Exact offsets to be verified from binary)

## Execution Steps

1. Back up EOSWebcamService binary
2. Verify original bytes at each offset
3. Apply all patches
4. Re-sign the plugin bundle
5. Restart service
6. Validate

## Validation Steps

1. `launchctl list | grep canon` — service running
2. `system_profiler SPCameraDataType` — virtual camera visible
3. `ffmpeg -f avfoundation -video_size 1920x1080 -framerate 60 -i "0" -t 1 -f null -` — test 1080p60
4. `ffmpeg -f avfoundation -video_size 9999x9999 -i "0"` — list supported modes
5. Open Zoom → select EOS Webcam Utility → verify feed

## Rollback

```bash
cp ~/development/webcam-utility/EOSWebcamService.backup-20260314 \
   "/Library/CoreMediaIO/Plug-Ins/DAL/EOSWebcamUtility.plugin/Contents/Resources/EOSWebcamService"
codesign --force --deep --sign - "/Library/CoreMediaIO/Plug-Ins/DAL/EOSWebcamUtility.plugin"
launchctl unload /Library/LaunchAgents/com.canon.usa.EWCService.plist
sleep 2
launchctl load /Library/LaunchAgents/com.canon.usa.EWCService.plist
```

## Results

**Executed:** 2026-03-14

### Patch Application
- [x] All original bytes verified
- [x] All 9 patches applied to EOSWebcamService
- [x] First deploy: service crashed — `CODE SIGNING: rejecting invalid page` — ad-hoc `--deep` signing didn't re-hash the inner binary
- [x] **Fix:** Sign the service binary directly first (`codesign --force --sign - EOSWebcamService`), THEN sign the bundle
- [x] Both signatures verified valid
- [x] Service restarted successfully (PID 53428)

### Resolution Change
- [x] Service running — no crash
- [x] Virtual camera visible to macOS
- [ ] **Resolution still 1280x720@30fps** — format unchanged

### Root Cause Analysis

The format is being set by **EWCProxy** (`/Library/CoreMediaIO/Plug-Ins/DAL/EOSWebcamUtility.plugin/Contents/Resources/EWCProxy`), which sits between EOSWebcamService and the DAL plugin. EWCProxy has **22+ hardcoded references** to 1280/720 values that control frame delivery and format negotiation. Key locations:

- `0x0434e0-0x04351c`: Resolution switch (has both 720p and 1080p cases)
- `0x043848-0x043894`: Fallback/default resolution (1280x720)
- `0x04b9c0`, `0x04d6f4`, `0x04d794`, `0x04e148`: Various width=1280 references
- `0x05e9b4-0x05e9c0`: More width references
- `0x060300`: Width reference
- `0x01e96c`, `0x024ce8-0x024ed8`: Width references (possibly EDSDK-related)

### Pivot Decision
EWCProxy needs patching too, but it has many more hardcoded values — need careful analysis to determine which are resolution-related and which are other constants (EDSDK property IDs, buffer sizes, etc.).

**Next step:** Work log 004 — EWCProxy binary analysis and patch.

### Code Signing Lesson Learned
On macOS arm64, after patching any binary in a plugin bundle:
1. Sign the **individual binary** first: `codesign --force --sign - <binary_path>`
2. Then sign the **bundle**: `codesign --force --deep --sign - <bundle_path>`
3. Verify both: `codesign --verify -vv <path>`
Failure to sign the inner binary causes `CODE SIGNING: rejecting invalid page` kernel errors and SIGKILL.
