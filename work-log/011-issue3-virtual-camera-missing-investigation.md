# Work Log 011: Issue #3 — Virtual Camera Missing on macOS 26.5.2

**Date:** 2026-07-27
**Phase:** 6 — Compatibility Investigation
**Risk Level:** None (analysis only; diagnostic-script improvements)
**Status:** In Progress — two live hypotheses, discriminating tests defined

## Problem

[Issue #3](https://github.com/Obednal97/eos-webcam-utility/issues/3): on macOS
26.5.2 (build 25F84) the "EOS Webcam Utility" virtual camera does not appear
in the system camera list at all, despite a fully healthy install (plug-in
present, ad-hoc signed, no quarantine, EWCService running, config written).
The reporter reinstalled at least five times in 30 minutes; reinstalling does
not help.

Reference point: the maintainer's diagnostic from
[issue #1](https://github.com/Obednal97/eos-webcam-utility/issues/1)
(2026-06-19) shows the same fork **passing** on macOS 26.5.1 (build 25F80).

## Confirmed evidence (from the two diagnostic reports)

Failing machine (26.5.2, issue #3):

- Three kernel `AMFI: code signature validation failed.` messages at
  11:01:48, the exact moment QuickTime's camera list was opened (the action
  that forces plug-in loading). The kernel lines do not name the binary.
- `amfid` explicitly rejected the fork's service binary at spawn:
  `Error Code=-423 "The file is adhoc signed or signed by an unknown
  certificate chain"` — yet launchd spawned it anyway and it kept running.
- No `com.canon.cusa.eoswebcam.cameraExtension` lines anywhere in the log
  excerpt, and the log predicate (`CONTAINS[c] "EOSWebcam"`) would have
  matched them.
- The camera-manager log contains **zero** "Attempt N — restarting service"
  lines: EWCProxy never spawned even once, i.e. no camera-open request ever
  reached the service.
- Plug-in bundle CDHash: `c5b27ec3a5340c437b450b2bf3909ddf7de3715b`.

Working machine (26.5.1, maintainer reference report):

- Camera enumeration goes through **Canon's modern Camera Extension**, not
  the legacy DAL plug-in. `system_profiler` and `EOSWebcamService` both log:
  `adding device <CMIOExtensionSessionDevice: ID
  58E340EA-8B2F-467D-AAB0-1E3E44BCE2C8> bundleID
  com.canon.cusa.eoswebcam.cameraExtension`.
- No AMFI/amfid errors in the same log window.
- The camera-manager retry loop fires regularly and reports
  "Connected after N retries" — EWCProxy spawns whenever an app opens the
  camera.
- Plug-in CDHash: `b77b5fbff4899738480ee0cfca7b42b0e11049b3` — differs from
  the reporter's, but this report predates the 2026-07-07 switch from
  shipping pre-patched binaries to patch-in-place (`e953e91`), so the
  difference is explainable and NOT evidence of corruption. Needs
  re-verification with current v1.4.1 (see tests).
- Canon community reports confirm `com.canon.cusa.eoswebcam.cameraExtension`
  is a real Canon component that existed in the Sonoma era:
  https://community.usa.canon.com/t5/EOS-Webcam-Utility-Pro/EOS-Webcam-Utility-not-working-under-Mac-OS-Sonoma-14-5/m-p/485997

## Hypotheses

### H-A: macOS 26.5.2 tightened AMFI against ad-hoc signed DAL plug-ins

The 26.5.2 point update rejects ad-hoc signatures where 26.5.1 accepted
them; the DAL plug-in is refused at load time, so the virtual camera never
registers.

- For: AMFI failures at exactly camera-list-open time; explicit amfid
  ad-hoc rejection of the sibling service binary; pass on 25F80 vs fail on
  25F84 with otherwise identical setups.
- Against: only one machine on each side; the kernel AMFI lines don't name
  the plug-in; and on the working machine the camera is served by the
  Camera Extension anyway (see H-B), so "the DAL plug-in loads fine on
  26.5.1" was never actually demonstrated.
- Fix if true: sign with a real Developer ID (installer now supports
  `--sign-identity`), and migrate to a CMIOExtension long term.

### H-B: The working path is Canon's Camera Extension, and it's missing/disabled on the failing machine

On machines where the fork "works", the virtual camera is provided by
`com.canon.cusa.eoswebcam.cameraExtension` (fed by the patched EWCService);
the ad-hoc DAL plug-in may not be load-bearing at all. The reporter's
machine has no trace of the extension, so nothing serves the camera,
regardless of DAL signing.

- For: the maintainer's own PASS report enumerates the device through the
  extension; the reporter's log has no extension lines; issue #1's reporter
  independently said the utility was "not showing up in Camera Extensions
  either"; extensions can be left unapproved (one-time System Settings
  prompt) or knocked out by OS updates.
- Against: doesn't by itself explain the burst of AMFI failures precisely at
  camera-list-open time on the failing machine (though those could be the
  OS refusing the vestigial DAL plug-in while the real problem is the
  missing extension).
- Fix if true: get Canon's extension registered/approved on the affected
  machine (System Settings -> General -> Login Items & Extensions -> Camera),
  no developer certificate needed. Fork should detect and instruct.

H-A and H-B are not mutually exclusive: 26.5.2 may have both dropped the
extension registration and blocked the ad-hoc DAL fallback.

### Considered and effectively ruled out

- **Bad install / corruption:** signature valid on disk, patcher verifies
  original bytes before writing, five reinstalls made no difference.
- **Quarantine/Gatekeeper:** no quarantine attributes anywhere.
- **Service crashing (the reporter's guess):** service was alive at report
  time (PID 6290, launchctl status 0); 0-byte `logNNN.txt` files also occur
  on the working machine. Crash-report listing added to diagnose.sh to close
  this permanently.
- **Camera not on USB at report time:** likely auto power-off; irrelevant —
  the virtual camera should enumerate with no camera attached.
- **TCC/permissions:** tccd lines show checks, no denials; QuickTime lists
  other cameras fine.
- **BTM disabled:** launch item disposition is `[enabled, allowed, notified]`.
- **x86_64 plug-in interference:** same bundle also present on the working
  machine.

## Discriminating tests

1. **Extension state on both machines** (decisive for H-B):
   `systemextensionsctl list` and
   `pluginkit -m -v -i com.canon.cusa.eoswebcam.cameraExtension`
   on the maintainer's working machine and the reporter's failing one.
   Extension present+enabled on working, absent/disabled on failing => H-B.
   (Both checks are now in diagnose.sh.)
2. **Name the AMFI-rejected binary** (decisive for H-A): reporter runs
   `log stream --predicate 'process == "amfid" OR (processID == 0 AND
   eventMessage CONTAINS "AMFI")' --style compact` while opening QuickTime's
   camera list. If amfid names the DAL plug-in executable => H-A confirmed
   directly.
3. **History question:** did the fork work on the failing machine before the
   26.5.2 update? Worked-then-broke favors an OS-update trigger (either
   hypothesis); never-worked favors H-B.
4. **Developer ID experiment** (tests H-A's fix): on a 26.5.2 machine,
   reinstall with `--sign-identity`. Camera appears => ad-hoc signing was
   the blocker.
5. **CDHash reproducibility:** after reinstalling with current v1.4.1
   ad-hoc, `codesign -dv` on the plug-in executable should show
   `c5b27ec3a5340c437b450b2bf3909ddf7de3715b` on every machine. Match =>
   reporter's binaries are byte-identical to known-good; mismatch => the
   patcher produced different bytes somewhere and that thread needs pulling.
6. **Community data point:** issue #2's user has a working R10 setup —
   their macOS version + extension state adds a second data point on the
   working side.

## Repo changes made during this investigation

- `diagnose.sh`: AMFI-aware verdict (no more blanket "reinstall" advice);
  amfid output captured; new sections for Camera Extension registration,
  service detail, crash reports, Gatekeeper/MDM state; PASS verdict reports
  whether enumeration went through the Camera Extension.
- `install.sh`: `--sign-identity` for signing with a real Developer ID
  (identity validated up front; signing runs unprivileged as the user
  because the identity lives in the login keychain; no hardened runtime
  because EWCService loads Canon's differently-signed EDSDK.framework).
- README: Known Limitations entry for the 26.5.2 report.

## Known gaps / follow-ups

- `uninstall.sh` restores from the **most recent** backup — after an
  upgrade-over-fork install, that backup contains patched fork binaries,
  not Canon originals — and then re-signs whatever it restored **ad-hoc**,
  destroying Canon's valid signature even when the backup was pristine.
  Both behaviours need fixing (restore oldest/verified-pristine backup;
  skip re-signing when the restored files carry Canon's signature).
- If H-B holds, the CMIOExtension migration (work log 009) remains the
  right long-term architecture, and the existing pipeline on working
  machines (patched service feeding Canon's extension) is direct evidence
  the sink-stream approach works.
