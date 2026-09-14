<p align="center"><img src="Resources/MacDuo.png" width="104" alt="MacDuo icon"></p>
<h1 align="center">MacDuo</h1>
<p align="center">A little motion. A different feeling.</p>
<p align="center"><a href="README.md">简体中文</a> · <a href="https://github.com/andyhuo520/MacDuo/releases">Downloads</a> · <a href="LICENSE">MIT</a></p>

![MacDuo concept illustration](docs/images/hero.png)

A native macOS menu bar experiment that turns your MacBook's lid angle into a soft frosted-glass desktop effect. Close the lid gently to advance the frost; open it to reveal the desktop. Mouse or keyboard activity immediately restores the real desktop.

**The images are AI-generated concept illustrations, not screenshots.** MacDuo does not bend the screen hardware or geometrically fold your page. It renders a stationary desktop snapshot with an angle-driven glass veil.

## Attention mode — experimental in 1.1.0

Choose **注视模式 · 使用摄像头** in the controller (switching modes auto-presents the screen picker when nothing is running yet) and allow camera access. Face the screen for about half a second to become ready. While you are away, a liquid-glass card shows your latest continuous screen-attention stretch, time away and a local daily total; a bundled sample companion video loops on the away screen (muted, never keeping the display awake), either fused into the full-screen glass — ambient wash plus a sharp centered hero whose edges melt away, with the card fading in after the first full loop — or as a rounded tile inside the card. Replace `Contents/Resources/AttentionCompanion.mp4` with your own clip (landscape sources span the full width), or delete it to disable.

<img src="docs/images/companion-preview.gif" width="200" alt="Bundled sample companion video preview"> Blurring counts down only while you are both looking away and not touching the keyboard or mouse; either one breaking restarts the countdown, so working at the machine never blurs it. Configure the delay from immediate to 5 minutes. Glass diffuses from a random edge. Looking back restores clarity automatically; enable hold or identity verification to require manual confirmation instead.

This estimates **head orientation, not exact eye gaze**. Eye-only movements may be missed; lighting, glasses, pose and multiple faces affect reliability. It is not a security or privacy lock. Camera interruption clears the overlay and stops monitoring.

Camera frames are processed locally at about 5 Hz using Vision at 640×480. No recording, uploads, identity recognition or microphone use. Pause, switching to lid mode, lock and quit stop capture. The camera stays active while attention mode is enabled so it can detect your return; the lid mode's 90-second standby rule does not apply.

## Features

- About 3° of closing motion triggers a fresh, single desktop snapshot.
- Progressive two-stage blur, subtle refraction and clear uncovered content. No scanning light stripe.
- Non-focusable, click-through overlay that disappears when you interact.
- Menu bar pause, resume and status controls; no floating desktop toolbar.
- After 90 seconds without meaningful lid movement, rendering resources are released. Low-rate monitoring remains ready for the next gesture.
- Pauses during sleep and lock; attempts to resume after unlock. Expired system screen selections must be renewed.
- Optional opening sound using your own WAV file. Audio is disabled by default; no recording is distributed.

## Requirements and installation

**macOS 15.2+, Apple Silicon MacBook and a readable lid-angle sensor.** Used on a MacBook Pro18,3 (M1 Pro) development machine running macOS 26. Other models have not been individually verified. Intel Macs, external displays and devices without the sensor are outside the supported scope.

Download the Apple Silicon DMG from [Releases](https://github.com/andyhuo520/MacDuo/releases), drag MacDuo to Applications and launch it. Click **选择屏幕并开始** (Select screen and start), then choose the built-in display in the system picker. Close the lid gently. Reopen it or move the mouse to restore the desktop. Closing the controller leaves the menu bar app running.

The native UI is currently in Chinese. **Public builds are development-signed and not notarized**, so macOS may block launching them. You can review the source and build locally. Effects are unavailable on the lock/login screen.

### Optional audio

Place a licensed WAV recording at `~/Library/Application Support/MacDuo/HingeCreak.wav`, restart and enable **开盖音效** in the menu. A short, quiet recording of approximately two seconds is recommended. Developers can instead add `Resources/HingeCreak.wav` before building; Git ignores it.

## Scenarios

![Night coding concept](docs/images/coding.png)
![Photography workspace concept](docs/images/creative.png)

AI concept illustrations. Actual visuals depend on desktop content and lid angle. The snapshot does not continuously refresh videos or application content.

## Build and test

Install Xcode or Command Line Tools with a macOS 15.2+ SDK and a working `xcrun swiftc`:

```sh
git clone https://github.com/andyhuo520/MacDuo.git
cd MacDuo
zsh build.sh
zsh scripts/test.sh
```

The output is `MacDuo.app`. Local builds default to ad-hoc signing. Set your own identity for development-signed builds:

```sh
DUOFOLD_SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)" zsh build.sh
```

Quit existing MacDuo instances before replacing an installation. Keep the bundle ID, path and signing identity stable across updates to reduce permission issues.

Tests cover repeated gestures, input handoff, standby, lifecycle recovery, menu actions, audio motion detection and Metal pixel regression. They do not lock or capture your desktop; some briefly start actual sensor subprocesses. A Metal-capable Mac is required. Physical lid motion, screen selection and wake behavior still need manual verification.

## Architecture and privacy

Swift/AppKit manages the app, IOKit reads the lid sensor, ScreenCaptureKit captures a single frame, Core Image prepares blur textures, and Metal renders the stationary cover. Sensor and watchdog workers run as separate processes.

Lid mode does not use the camera. Attention mode uses it only while enabled. No microphone, network access or saved desktop screenshots. Input detection compares event counts without reading typed content. Local lifecycle, angle and error logs live at `~/Library/Logs/DuoFoldDesktop/lifecycle.log`. The watchdog can terminate an unresponsive app, but cannot guarantee recovery from system-level GPU or kernel failures.

See [architecture](docs/ARCHITECTURE.md) and [contributing](CONTRIBUTING.md).

## Credits

By Berryxia · [X](https://x.com/Berryxia) · [andyhuo@me.com](mailto:andyhuo@me.com)

Inspired by duo.grok.me. Angular fitting and portions of historical geometry derive from [Bendable](https://github.com/opensourcevillain/Bendable), with its MIT license preserved. Independent project; not affiliated with Apple.

[MIT](LICENSE) · [Third-party and artwork notices](THIRD_PARTY_NOTICES.md)


## 1.2.0: absence timer, reminder and flowing glass

Choose an absence delay of 1/3/5/10/30 seconds or 1/2/5 minutes. Diffusion automatically starts from a random edge and flows across over about 1.6 seconds with a broad undulating front and gentle refraction. No direction selector or illuminated scan line.

Hold mode keeps the blur when you return; a card shows elapsed absence, a local text reminder and a Welcome back prompt. Restore explicitly, optionally with macOS device-owner authentication (Touch ID/system password); the app never reads the password. Cancelled authentication keeps the cover. Disable Hold for automatic restoration.

Held covers receive mouse and keyboard input; Escape requests restoration. The menu bar can always restore, pause or quit. Pause, quit and system lock clean up the effect and timer. This is a visual break cover, not a security lock: pausing or quitting bypasses it. Real identity-authentication prompts require manual validation.
