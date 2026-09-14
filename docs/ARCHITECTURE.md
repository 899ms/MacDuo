# Architecture

`App.swift` owns screen selection, lifecycle and a cancellable single-snapshot task. `Session.swift` defines the idle → armed → capturing → folding → finished → armed cycle. A generation identifier prevents late captures from restoring an obsolete overlay.

`Workers.swift` isolates HID reads in a 20 Hz worker and heartbeat supervision in a second process. The watchdog terminates the parent after four seconds without a heartbeat, not after a fixed session duration. `AngleMailbox.swift` transfers the latest sample; `AngularFit.swift` smooths quantized lid readings.

`MonitoringLifecycle.swift` tracks lock, sleep, display sleep and inactive-user blockers independently. All must clear before resumption. No locked desktop is captured. `CaptureStandby.swift` releases rendering after 90 seconds without meaningful lid changes, lowering main-thread polling from 30 Hz to 10 Hz. HID monitoring remains active.

`InputActivity.swift` compares input event counters. Input yields the desktop, invalidates pending capture, and re-arms from the current angle. `DesktopPanel` cannot become key or main and ignores mouse events.

`Engine.swift` prepares sharp, 4 px blur and 16 px blur textures off the main thread. `Resources/Fold.metal` uses mode 0 for the product: one stationary surface, angle-driven frost coverage reaching up to 92% height, and local optical refraction. Historical geometry modes remain internal. Fully open and uncovered pixels remain unchanged. At most two GPU frames are in flight.

`HingeSound.swift` detects cumulative opening of 2° and plays once per gesture. Meaningful closing re-arms it. Optional audio is loaded from Application Support first, then the bundle. No recording is shipped publicly.

## Manual validation

Use a supported MacBook: select its built-in display, close/open repeatedly, interrupt a gesture with input, remain at a fixed angle, wait 90 seconds and retrigger, sleep/lock/unlock and repeat. Check pause remains paused after wake. If system screen sharing expires, verify the app requests a new selection. Never infer these results from synthetic tests alone.

## Attention mode

`AttentionMonitor.swift` serializes AVFoundation capture and Vision face-rectangle requests on a utility queue. Only the built-in camera is selected. The largest sufficiently confident face supplies yaw/pitch; thresholds are 0.38/0.32 radians. Frame analysis is capped at 5 Hz and late video frames are dropped. No identity model or frame persistence is used.

`AttentionGate` requires 0.5 seconds facing forward before activation, 1 second away before obscuring, and 0.2 seconds facing forward before revealing. `AttentionMode.swift` owns permission handling with generation tokens, input suppression and gradual full-screen blur via Metal mode 6. Unchanging blur frames are not redrawn. Snapshot capture remains single-frame, background-prepared and cancellable. An 8-second sample timeout fails clear and stops monitoring. Lock/sleep and explicit pause invalidate pending callbacks and stop the camera. The default mode is still lid mode and selecting attention mode while stopped never starts the camera.
