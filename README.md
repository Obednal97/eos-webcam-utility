# EOS Webcam Utility Fork v1.4

A free, open-source community fork of Canon's discontinued EOS Webcam Utility that unlocks 1080p output for Canon EOS cameras used as USB webcams on macOS.

---

## Background

Canon released the EOS Webcam Utility in 2020 as a free tool to let Canon camera owners use their DSLRs and mirrorless cameras as webcams over USB. On **August 20, 2025**, Canon discontinued the free standalone version (v1.3.16 was the final release), leaving users without an actively maintained free option for 1080p webcam output.

This fork takes the final free version (v1.3.16) and unlocks 1080p output, adds automatic camera connection handling, and includes custom loading screens — all completely free and open source.

**This is a personal hobby project, not monetised in any way.** It's my first time doing anything like this. I hope it helps people who own Canon cameras and just want to use them as webcams. Feedback, suggestions, bug reports, and contributions from absolutely anyone are very welcome.

---

## Features

### What This Fork Enables

| Feature | Original (discontinued) | This Fork |
|---|---|---|
| **Resolution** | 720p | **1080p** (upscaled) |
| **Cost** | Free (discontinued) | **Free** (open source) |
| **Auto-retry camera activation** | No | **Yes** |
| **Custom loading screens** | No | **Yes** (with logo support) |
| **Installer size** | 13MB | **14MB** |

### Feature Details

- **1080p Output** — The camera's native USB live view is ~1024x576. This fork upscales it to 1920x1080 using DCT-domain scaling (via libjpeg-turbo at 15/8 factor). This is not native 1080p from the sensor — it's upscaled, the same technique used by professional webcam software. True native 1080p requires HDMI output + capture card.

- **Completely Free** — No accounts, no subscriptions, no registrations. Download, install, use.

- **Auto-Retry Camera Activation** — A lightweight background daemon monitors the camera connection. On macOS, the system `ptpcamerad` service races with Canon's EDSDK for USB device access, causing the camera to fail to connect on the first attempt. The daemon automatically detects failed connections and retries by restarting the service, typically connecting within 20-30 seconds without any manual intervention.

- **Custom Loading Screens** — Instead of Canon's generic error images, the fork shows context-aware screens:
  - **Camera connected but loading:** "Connecting to camera... Please wait" (with optional company/personal logo)
  - **Camera not connected:** "Camera not connected — Please connect your camera or use another camera source"
  - The daemon automatically swaps between these based on whether the camera is detected on USB.

- **Logo Support** — Place a `logo.png` in the install directory and run `generate-images.sh` to overlay your own logo on the loading screens.

---

## How It Works

### The Video Pipeline

```
Canon EOS Camera (e.g. 250D)
    ↓ Electronic Viewfinder (EVF) mode
    ↓ Camera internally downscales sensor to ~1024x576
    ↓ Compresses each frame to JPEG
    ↓ Sends over USB via PTP protocol
    ↓
EWCProxy (Canon's EDSDK framework)
    ↓ Receives JPEG frames
    ↓ Decompresses + upscales via libjpeg-turbo DCT scaling (15/8 = 1.875x)
    ↓ 1024x576 → 1920x1080
    ↓
EOSWebcamService (background service)
    ↓ Creates virtual camera device (CoreMediaIO DAL plugin)
    ↓ Feeds 1080p frames to any app that requests them
    ↓
Zoom / Google Meet / Microsoft Teams / FaceTime
    ↓ Sees "EOS Webcam Utility" as a camera source
    ↓ Receives 1920x1080 @ ~30fps
```

### What Was Patched

Three binary files were patched (ARM64 instruction-level modifications):

1. **EOSWebcamUtility** (DAL plugin) — Resolution defaults changed from 720p to 1080p in the stream format registration
2. **EOSWebcamService** — Resolution values in `CMVideoFormatDescriptionCreate` and resolution clamping changed to 1080p; feature gates unlocked
3. **EWCProxy** — Default resolution and resolution switch cases changed from 720p to 1080p

All patches are to Canon's software only. No macOS system files are modified.

---

## Requirements

- **macOS** on Apple Silicon (M1, M2, M3, M4)
- **Canon EOS camera** with USB connection
- **USB cable** connecting your camera to your Mac
- Admin privileges (the installer will prompt for your password)

### Tested With

- Canon EOS 250D (Rebel SL3) on macOS Tahoe (26.3)

This fork has only been tested with the Canon 250D, but the underlying patches modify resolution defaults and feature gates that are shared across all Canon EOS cameras. If your camera was supported by the original EOS Webcam Utility v1.3.16, this fork should work the same way. If you test with a different camera model, please open an issue to let me know how it goes — I'd love to build a community-verified compatibility list.

---

## Installation

### Fresh Install (no Canon software installed)

```bash
git clone https://github.com/Obednal97/eos-webcam-utility.git
cd eos-webcam-utility
bash dist/v1.4/install.sh
```

### Upgrade from Canon's Original v1.3.x

```bash
git clone https://github.com/Obednal97/eos-webcam-utility.git
cd eos-webcam-utility
bash dist/v1.4/install.sh
```

The installer automatically detects existing installations and backs up your current files before upgrading.

### What the Installer Does

1. Detects existing Canon software (fresh / original / previous fork)
2. Creates timestamped backups of all files it will modify
3. Deploys patched binaries and signs them (requires admin password)
4. Sets configuration to 1920x1080 @ 30fps
5. Installs the camera manager daemon (auto-starts on login)
6. Installs custom loading screen images
7. Starts all services

### Uninstall

```bash
bash dist/v1.4/uninstall.sh
```

Restores original Canon files from the backup created during installation.

---

## Usage

1. Connect your Canon EOS camera via USB
2. Turn the camera on
3. Open Zoom, Google Meet, Microsoft Teams, or any video app
4. Select **"EOS Webcam Utility"** as your camera source
5. Wait ~20-30 seconds for the camera to connect (you'll see a loading screen)
6. Live 1080p feed appears

### Custom Logo on Loading Screen

```bash
# Place your logo file in the install directory
cp /path/to/your/logo.png ~/development/webcam-utility/logo.png

# Regenerate loading screen images with your logo
~/development/webcam-utility/generate-images.sh
```

The logo is automatically scaled to fit (never stretched) and placed above the "Connecting to camera..." text. PNG with transparency is supported.

---

## Known Limitations

- **~30fps maximum** — The camera's USB EVF outputs ~26 unique frames per second. This is a hardware/firmware limitation, not software. 60fps is only possible via HDMI output.
- **1080p is upscaled** — The camera sends ~1024x576 natively over USB. The 1080p output is upscaled using DCT-domain scaling. True native 1080p requires HDMI output + capture card.
- **Camera activation takes ~20-30 seconds** — Due to a race condition with macOS's `ptpcamerad` service. The daemon handles this automatically but it takes a few retry cycles.
- **DAL plugin architecture is deprecated** — Apple deprecated CoreMediaIO DAL plugins at WWDC 2022. The plugin still works on current macOS but may break in future versions. A Camera Extension (CMIOExtension) migration is planned.
- **Apple Silicon only** — The patched binaries are ARM64. Intel Macs are not supported by this fork.

---

## Technical Details

Full technical documentation is in [PLAN.md](PLAN.md), including:

- Complete binary patch tables with ARM64 instruction offsets
- Video pipeline architecture
- Upscaling algorithm analysis (DCT-domain scaling at 15/8 factor)
- Camera activation race condition investigation (ptpcamerad)
- 60fps hardware limitation proof (frame hashing: 52 unique out of 61 delivered)
- Competitive analysis of 8 related open-source projects
- PTP liveview size parameter testing results

Detailed work logs for every phase are in the [work-log/](work-log/) directory.


---

## Contributing

This is my first open-source project. I'm learning as I go and welcome any feedback, suggestions, bug reports, or contributions. If you have a Canon EOS camera and want to help test, improve, or extend this project, please open an issue or pull request.

Areas where help would be especially appreciated:
- Testing with different Canon EOS camera models
- Testing on different macOS versions
- Building a Camera Extension (CMIOExtension) to replace the deprecated DAL plugin
- Improving camera activation speed

---

## License

This project is provided as-is for personal use. It modifies Canon's discontinued EOS Webcam Utility v1.3.16. Use at your own risk.

---

## Acknowledgements

Built with the help of reverse engineering, binary analysis, and a lot of trial and error. Thanks to the open-source camera community for their work on gphoto2, libgphoto2, and the various projects listed above that informed this work.
