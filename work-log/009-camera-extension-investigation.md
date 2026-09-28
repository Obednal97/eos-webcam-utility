# Work Log 009: Camera Extension (CMIOExtension) Investigation

**Date:** 2026-03-14
**Phase:** 5 — Future-Proofing
**Risk Level:** High (new architecture, significant development effort)
**Status:** Research Complete — Blocked by Requirements

## Objective

Replace the deprecated CoreMediaIO DAL plugin with a modern Camera Extension (CMIOExtension) to future-proof the webcam utility against macOS updates.

## Research Findings

### What a CMIOExtension Requires

A Camera Extension is fundamentally different from a DAL plugin:

| Aspect | DAL Plugin (current) | Camera Extension (target) |
|---|---|---|
| Architecture | Plugin loaded into app process | Sandboxed system extension (own process) |
| Host requirement | None (just a .plugin bundle) | **Requires a host .app in /Applications** |
| Signing | Ad-hoc works | **Requires Apple Developer certificate ($99/year)** OR SIP disabled |
| User approval | None | **User must approve in System Settings** |
| Update workflow | Replace file, restart service | **Reboot required between extension updates** |
| IPC | Direct shared memory / CFMessagePort | Sink streams via CoreMediaIO C API |
| Sandbox | None (runs in app's process) | Heavily sandboxed (no fork/exec, no XPC to arbitrary daemons) |
| Min macOS | 10.15 | 12.3 |

### Architecture Required

```
EOSWebcamService (existing daemon, captures from Canon 250D)
         |
         | (IPC: shared memory / Unix socket)
         v
Host App (NEW — must live in /Applications, acts as bridge)
         |
         | (CoreMediaIO C API - sink stream)
         v
CMIOExtension (NEW — sandboxed system extension)
  - Sink stream: receives CMSampleBuffers from host app
  - Source stream: provides frames to Zoom/Meet/Teams
```

### Blockers

1. **Apple Developer Certificate Required ($99/year)** — With SIP enabled (production), system extensions must be signed with a valid Apple Developer certificate. Ad-hoc signing does NOT work. Disabling SIP is a development-only workaround, not viable for distribution.

2. **Requires Xcode Project** — Cannot be built with command-line tools alone. Needs proper `.systemextension` bundle inside a `.app` bundle, with specific entitlements and Info.plist entries.

3. **Reboot Required Between Updates** — During development, every change to the extension requires uninstalling the old version, rebooting, then installing the new one. This makes iteration extremely slow.

4. **Sandboxing Prevents Direct Camera Access** — The extension cannot communicate with EOSWebcamService directly (sandbox restrictions). A host app must act as a bridge, receiving frames from the service and forwarding them via sink streams.

5. **Significant Development Effort** — This is not a patch or configuration change. It's a full Swift/Objective-C application with two targets (host app + extension), proper IPC, entitlements, and signing infrastructure.

### What We Would Need to Build

1. **Host App (Swift)**
   - Registers/unregisters the system extension
   - Receives frames from EOSWebcamService (via shared memory or IPC)
   - Forwards frames to the extension via CoreMediaIO C API sink streams
   - Lives in /Applications

2. **Camera Extension (Swift)**
   - Implements CMIOExtensionProviderSource, DeviceSource, StreamSource
   - Provides source stream (video output to apps)
   - Provides sink stream (video input from host app)
   - Configures format: 1920x1080 @ 30fps, 2vuy pixel format

3. **Build Infrastructure**
   - Xcode project with two targets
   - Apple Developer certificate for signing
   - Entitlements files for both targets
   - Info.plist with NSCMIOExtensionMachServiceName

### Key Reference Projects

- [ldenoue/cameraextension](https://github.com/ldenoue/cameraextension) — Best minimal example, MIT licensed, shows sink+source stream pattern
- [Apple WWDC22 Session 10022](https://developer.apple.com/videos/play/wwdc2022/10022/) — Official introduction

### Migration Path from DAL Plugin

If we build the extension, we can set `legacyDeviceID` to match our current DAL plugin's device UUID (`8A9AA3FD-9C04-4325-BCD1-EA469F34633C`). This means apps that have the old "EOS Webcam Utility" saved as their camera would automatically find the new extension without reconfiguration.

## Assessment

### Is This Worth Doing Now?

**No, not yet.** Here's why:

1. **The DAL plugin still works** — Despite being "deprecated," our patched DAL plugin works on macOS 26.3 (Tahoe). Apple hasn't actually removed DAL plugin support yet.

2. **The $99/year developer certificate** is a barrier for an open-source hobby project. Without it, the extension only works with SIP disabled, which is not acceptable for distribution.

3. **Development iteration is painful** — Reboots between every extension update make development extremely slow.

4. **The current solution works** — 1080p output, auto-retry, custom screens — all functional today.

### When Should We Do This?

- When Apple actually removes DAL plugin support (not just deprecates it)
- When we have an Apple Developer certificate
- When we're prepared for the Xcode project infrastructure
- When we want to distribute via the Mac App Store

### What We Can Do Now

1. **Monitor macOS releases** for DAL plugin removal
2. **Set up the Xcode project structure** as a skeleton (doesn't need to work yet)
3. **Get an Apple Developer certificate** if this becomes a priority
4. **Use the `legacyDeviceID` migration path** when we eventually build it

## Decision

**Parked for now.** The DAL plugin approach continues to work. The Camera Extension is the correct long-term solution but requires infrastructure (developer certificate, Xcode project) that's beyond the scope of the current hobby project.

## No Changes Made

This was a research-only investigation. No files were modified.

## Addendum (2026-09-28): Canon already ships a signed Camera Extension

This log reads as if a Camera Extension would have to be built from scratch.
It missed that Canon's own v1.3.16 package already contains one. Expanding
`EOSWebcamUtility-MAC1.3.16.pkg` (the one inside the pinned
`EOSWebcamUtility-MAC1.3.16.pkg.zip`, sha256 5ad0333b...02321) shows:

- `/Applications/EOS Webcam Utility/EOS Webcam Camera Extension Installer.app`
  (bundle id `com.canon.cusa.eoswebcam.cameraExtension.installer`), the host
  app, with `Contents/Library/SystemExtensions/com.canon.cusa.eoswebcam.cameraExtension.systemextension`
  (CFBundlePackageType `SYSX`, a `CMIOExtension` with
  `LSMinimumSystemVersion` 14.0). The strings in its binary list 720p and
  1080p device sources at 30 and 60 fps.
- The package is signed "Developer ID Installer: Canon U.S.A., Inc.
  (NC5A977249)" and notarised (`pkgutil --check-signature`), so the extension
  is signed by Canon and needs no developer certificate from us. That removes
  blocker 1 above for *Canon's* extension; it doesn't help with building our
  own.
- Canon's `postinstall` runs the host app with `--args install` on macOS 14+
  and exits 1 unless it returns 100 ("activated by the user"). It runs after
  the payload (DAL plug-in, EDSDK, apps) and Canon's LaunchAgent are in place,
  so a non-approval leaves everything installed except the extension, but
  makes `installer` report failure. `install.sh` now treats exactly that case
  as non-fatal (see the H4 fix in the installer-safety PR).
- `/Applications/EOS Webcam Utility/EOS Webcam Utility Uninstaller.app`
  references the host app, which suggested it deactivates the extension. It
  doesn't: in a VM test (macOS 26, v1.3.16) it removed only the DAL plug-in
  and `~/Library/Application Support/EOS-Webcam-Utility/temp`, and the
  extension stayed active. The ways to remove the extension are to turn it
  off in System Settings > General > Login Items & Extensions > Camera
  Extensions, or to move its host app to the Trash in Finder.

Once approved, the extension shows up as a second "EOS Webcam Utility" camera
next to the fork's patched DAL plug-in. The fork doesn't patch the extension.
Work log 011 (issue #3 branch) saw a working machine enumerate the camera
through this extension, so whether it carries the fork's 1080p frames (it
presumably talks to the patched EOSWebcamService) still needs checking on a
real Mac.

The decision above stands for building the fork's *own* extension. What
changes is that the migration path may be "patch or feed Canon's signed
extension" rather than "write and sign a new one".
