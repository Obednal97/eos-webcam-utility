# Work Log 001: Config Plist Experiment

**Date:** 2026-03-14
**Phase:** 1 — Config Plist Modification
**Risk Level:** Low (fully reversible)
**Status:** In Progress

## Objective

Modify the EOS Webcam Utility's persistent config to request 1920x1080 at 60fps instead of 1280x720 at 30fps, then restart the service to see if the change takes effect.

## File Location

```
~/Library/Application Support/EWCService/config.plist
```

## Backup Location

```
~/Library/Application Support/EWCService/config.plist.backup-20260314
```

## Original Values

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>HeadlessStreamHeight</key>
	<string>720</string>
	<key>HeadlessStreamWidth</key>
	<string>1280</string>
	<key>LogLevel</key>
	<string>2</string>
	<key>OptimizationMode</key>
	<string>0</string>
	<key>PreviewFps</key>
	<string>30</string>
	<key>SourceResolution</key>
	<string>1</string>
	<key>StartupSceneId</key>
	<string>0</string>
	<key>StreamFps</key>
	<string>30</string>
	<key>StreamHeight</key>
	<string>720</string>
	<key>StreamWidth</key>
	<string>1280</string>
	<key>SyncCameraTimeOnRecord</key>
	<string>0</string>
	<key>TestEnvironment</key>
	<string>0</string>
	<key>Transition</key>
	<string>0</string>
	<key>TransitionLength</key>
	<string>1000</string>
</dict>
</plist>
```

## New Values (Changes Only)

| Key | Original | New | Reason |
|---|---|---|---|
| `StreamWidth` | `1280` | `1920` | Request 1080p width |
| `StreamHeight` | `720` | `1080` | Request 1080p height |
| `StreamFps` | `30` | `60` | Request 60fps |
| `HeadlessStreamWidth` | `1280` | `1920` | Match headless to stream |
| `HeadlessStreamHeight` | `720` | `1080` | Match headless to stream |
| `PreviewFps` | `30` | `30` | Keep as-is (preview only) |
| `OptimizationMode` | `0` (PICTURE_QUALITY) | `1` (FRAME_RATE) | Prioritize framerate |

## Also Modify: proconfig.plist

```
~/Library/Application Support/EWCService/proconfig.plist
```

**Backup:** `~/Library/Application Support/EWCService/proconfig.plist.backup-20260314`

| Key | Original | New |
|---|---|---|
| `StreamWidth` | `1280` | `1920` |
| `StreamHeight` | `720` | `1080` |
| `StreamFps` | `30` | `60` |

## Execution Steps

1. Create backups of both config files
2. Modify `config.plist` with new values
3. Modify `proconfig.plist` with new values
4. Unload the EWCService LaunchAgent
5. Wait 2 seconds
6. Reload the EWCService LaunchAgent
7. Verify service is running
8. Run validation checks

## Validation Steps

1. **Service running:** `launchctl list | grep canon` — confirm PID exists
2. **Config persisted:** `cat ~/Library/Application\ Support/EWCService/config.plist` — confirm new values
3. **Log check:** `tail -20 ~/Library/Logs/EOS-Webcam-Utility/main.log` — look for errors or resolution mentions
4. **Virtual camera visible:** `system_profiler SPCameraDataType` — confirm EOS Webcam Utility still appears
5. **App test:** Open Zoom or FaceTime → select EOS Webcam Utility → check if feed appears
6. **Resolution test:** Use ffmpeg to probe the virtual camera device and check reported resolution:
   ```
   ffmpeg -f avfoundation -list_devices true -i "" 2>&1
   ffmpeg -f avfoundation -framerate 60 -video_size 1920x1080 -i "<device_index>" -t 1 -f null -
   ```

## Rollback Steps

If anything goes wrong:

```bash
cp ~/Library/Application\ Support/EWCService/config.plist.backup-20260314 ~/Library/Application\ Support/EWCService/config.plist
cp ~/Library/Application\ Support/EWCService/proconfig.plist.backup-20260314 ~/Library/Application\ Support/EWCService/proconfig.plist
launchctl unload /Library/LaunchAgents/com.canon.usa.EWCService.plist
sleep 2
launchctl load /Library/LaunchAgents/com.canon.usa.EWCService.plist
```

## Results

**Executed:** 2026-03-14

### Service Restart
- [x] Service restarted successfully (new PID 50144)
- [x] No new errors in log (log hasn't rotated since Nov 2024 — service may log elsewhere or only on error)

### Resolution Change
- [x] Config values persisted after restart (service did NOT overwrite them back to 720p)
- [x] Virtual camera still visible to macOS (`system_profiler SPCameraDataType` confirms)
- [ ] Feed visible in Zoom/FaceTime — not tested (camera not connected at time of experiment)
- [x] **Resolution NOT changed** — DAL plugin still advertises only 1280x720@30fps

### ffmpeg Probe Output
```
[avfoundation] Selected video size (1920x1080) is not supported by the device.
[avfoundation] Supported modes:
[avfoundation]   1280x720@[30.000000 30.000000]fps
```

### Conclusion

**Config plist alone is insufficient.** The service reads the config, but the DAL plugin (`EOSWebcamUtility.plugin/Contents/MacOS/EOSWebcamUtility`) has hardcoded Stream Format Records (SFRs) that only advertise 1280x720@30fps to macOS via CoreMediaIO. Applications like Zoom and ffmpeg query the DAL plugin for supported formats, not the config file.

The config change is a necessary prerequisite (tells the service what resolution to produce) but the DAL plugin binary must also be patched to advertise the higher resolution/framerate to macOS apps.

**Next step:** Phase 2 — Patch the DAL plugin binary's `InitSFRs` to add 1920x1080@60fps as a supported format. See `work-log/002-dal-plugin-sfr-patch.md`.
