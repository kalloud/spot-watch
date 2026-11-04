# Spot Watch iOS: build plan

A native iOS port of the Spot Watch web app, for the same iPhone 6s. Decided Nov 3, 2026, at PLAN.md's "Decision point before Phase 4": the web app (`index.html`) reached Phase 3, and the native app replaces the web Phase 4. It adds what Safari can't do: faster detection with Core ML, the battery level and thermal state, and real camera exposure control.

**Behaviour doesn't change.** Spots, states, alerts, hunting, the event log and every rule in PLAN.md carry over as they are, unless this file says otherwise. `index.html` at the repo root is the reference implementation: port its logic function by function rather than re-deriving it. The web app stays live on GitHub Pages as a fallback until N3 passes.

## Target

- iPhone 6s, iOS 15.8.5, A9 chip with no Neural Engine (Core ML runs on the GPU and CPU), 2 GB RAM. Deployment target: iOS 15.0.
- Xcode 27.2 at `/Applications/Xcode.app` (iOS SDK 27.2, lowest deployment target 15.0). `xcode-select` still points to the Command Line Tools, so command-line builds need `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, or Ahmed runs `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` himself (it needs his password).
- **Xcode 27 can't install on the 6s** (found in N0, Nov 3, 2026). It builds for iOS 15, but Apple's support table lists its device support as iOS 17 or later, and the 6s doesn't appear in Xcode 27.2 at all, although macOS is paired with it (usbmuxd sees it and holds its pair record; CoreDevice reports its pairing as "unsupported"). Xcode 26.x is the last to support iOS 15 devices, and Apple lists it for macOS Tahoe 26 only; the Mac runs macOS 27.2. The install route is under "Decisions for Ahmed".
- Swift (5 language mode), SwiftUI for screens, UIKit where SwiftUI on iOS 15 falls short (the camera preview through `UIViewRepresentable`). No third-party packages.
- Layout: `ios/SpotWatch.xcodeproj`, app sources in `ios/SpotWatch/`, the pure logic module's tests in `ios/SpotWatchTests/`, Core ML models in `ios/SpotWatch/Models/`.

## Web → native

| Piece | Web (`index.html`) | Native |
| --- | --- | --- |
| Camera | `getUserMedia`, 4:3, 5–10 fps picker | `AVCaptureSession`, back wide camera, a 4:3 format near 1280×960; frame rate set with `activeVideoMin/MaxFrameDuration` (5 fps default). Lock the interface to the mounted orientation (landscape) so the frame shape never changes; lock focus once spots are drawn. |
| Night | Brightness reading, low frame rate, Night boost (frame averaging) | The same brightness reading, plus real exposure control: auto exposure with low-light boost first; below the low-light threshold, custom exposure (longer duration up to the format's maximum, higher ISO). Keep Night boost as an option. |
| Detector | TF.js YOLO26n 640 from a third-party export | Core ML YOLO26n converted from Ultralytics' **official** `yolo26n.pt` (GitHub release `v8.4.0`), run through `MLModel` or Vision. Export 640 and 320 and pick from device timings. Same output as the web version: [1, 300, 6] boxes (x1, y1, x2, y2, score, class), end-to-end, no NMS step. |
| Views | One view per spot tiled into a 640 mosaic: `spotViews`, `mosaicLayout`, `drawMosaic`, `detectViews`, `dedupe` | The same, with Core Image (crop, scale, composite into a 640×640 pixel buffer). Boxes map back to frame pixels the same way. |
| Spot logic | `readSpot`, `updateSpot` (confirmN, hysteresis, departure check with `spotThumb`/`thumbDiff`), `onSpotFreed`, `onPersonNear` | A pure Swift module with no AVFoundation, UIKit or SwiftUI imports, covered by unit tests. |
| Event log | localStorage JSON, 20,000 rows, CSV | A file in Application Support (JSON lines or SQLite), the same rows and CSV columns; Export CSV through the share sheet (AirDrop, Files). |
| Alerts | `fetch` POST, options in query params | `URLSession` POST with the identical URL format, titles, priorities and tags; retry once after 10 s. |
| Control topic | `EventSource` on `/sse?since=<last id>`, manual reconnect | `URLSession` streaming `/json?since=<last id>` (one JSON object per line), reconnecting with backoff. The same commands: `hunt on` / `hunt off`; keep accepting `power low` / `power high`. |
| Hunting | Saved state, timeout, quiet hours, late hunt-end wording (`startHunt`, `endHunt`, `handleCommand`, `huntTick`) | The same, saved in `UserDefaults`. |
| Eco and battery | Eco interval when not hunting; battery reported by Shortcuts automations | Read the battery directly (`UIDevice` battery monitoring) and `ProcessInfo.thermalState`. Hold 60–70% by switching between full speed and eco, with hysteresis; this only works if the charger supplies less than full-speed draw, so measure it. Throttle at thermal state serious, and alert at critical. |
| Load | Detector busy %, main-thread lag, GPU memory | Real CPU % (from `task_threads`), inference ms, thermal state, battery %, memory footprint. |
| Keeping it running | Auto-Lock Never, Guided Access | `isIdleTimerDisabled = true`. Guided Access is still recommended: iOS never lets an app use the camera in the background. Log and alert when the app leaves the foreground and when it comes back. |
| Watchdog | `cameraWatch` (5 checks without a frame) | Session runtime-error and interruption notifications plus a no-frames timer → "Camera stopped" alert, then restart the session. |
| On screen | Status rows, rolling log, Copy report | The same, with Copy report through `UIPasteboard`. The phone is at a window with no Xcode console attached. |
| Settings | Same keys, localStorage | `UserDefaults` and a Settings screen. Ahmed types or pastes the two ntfy topics once (they're in the web app's Settings on the 6s). |

## Model conversion (in N0)

1. Create a Python virtual environment in the session's scratchpad, not in the repo. If the system Python 3.9 gives trouble, use Homebrew's Python 3.12. Install `ultralytics` and `coremltools`.
2. Download `yolo26n.pt` from the Ultralytics GitHub release `v8.4.0` (`ultralytics/assets`).
3. `yolo export model=yolo26n.pt format=coreml imgsz=640 nms=False`, and again with `imgsz=320`, then both again with `quantize=16` for FP16. `nms=False` matters: in Ultralytics 8.4.202, leaving `nms` unset exports the raw (1, 84, 8400) head, which needs an NMS step. Check each output's input and output spec against the [1, 300, 6] format above.
4. Add the `.mlpackage` files to `ios/SpotWatch/Models/`, and note the model's AGPL-3.0 license in the app's About screen.

Done when both models load on the 6s and return the bus and the people on Ultralytics' `bus.jpg`.

**Converted Nov 3, 2026 (N0).** Homebrew Python 3.13, ultralytics 8.4.202, coremltools 9.0, torch 2.15.0 (newer than coremltools has tested; it worked). Ultralytics pins numpy ≤ 2.3.5 and swaps it in during the first export, which makes that run fail: run it again. `yolo26n.pt` matches the release's SHA-256 (`9b09cc8b…ad4fef`). Four models in `Models/`: `YOLO26n-640-fp32` (9.5 MB), `YOLO26n-320-fp32` (9.4 MB), `YOLO26n-640-fp16` and `YOLO26n-320-fp16` (4.8 MB each). All are spec version 6 (iOS 15), opset CoreML5, with an RGB image input (scale 1/255) and a float32 [1, 300, 6] output named `var_1439`. Xcode compiles them for deployment target 15.0. FP16 is there because the A9's GPU runs half precision at about twice the FP32 rate. The app has a Precision picker so the 6s can settle it.

On `bus.jpg` (Mac, Core ML on the CPU, frame scaled to fit at the top-left): at 640, bus 0.92 and people 0.92, 0.91, 0.85 and 0.56 (the TF.js export in the web app gave bus 92%, people 86–91%); FP16 within 0.01 of FP32; at 320, bus 0.88 and people 0.85–0.55. **The end-to-end head can return one object twice:** at 320 a person came back at 0.37 and 0.33, and in the app (Simulator, GPU, FP16, 640) the edge person came back at 46% and 25%. So N1 should run the same-class IoU > 0.5 dedupe on every run's boxes, not only across views.

## Milestones

Each one ends on the 6s with Ahmed's results. Stop and wait after each, the same rule as the web phases.

**N0 — Feasibility.** Create the Xcode project. First, confirm that Xcode 27.2 can install and run an app on the 6s at iOS 15.8.5 (building for iOS 15 isn't the same as installing on it). Then: camera preview at 4:3 and 5 fps; the model conversion; YOLO26n 640 and 320 running on live frames; on screen, inference ms, CPU %, thermal state, battery %, and boxes over the preview. Exit: runs on the 6s; inference time measured for 640 and 320; cars in all three spots get boxes from the window.
   - Built (Nov 3, 2026, build "N0 · 2026-11-03 · 1"): one landscape screen. The camera preview with boxes and the key numbers on the left (inference ms for 640 and 320, CPU %, thermal state, battery, memory); a scrolling panel on the right with Models (640 / 320 / Both, alternating), Pace (1.5 s / Max), Source (Camera / bus.jpg), Compute (GPU / CPU), Precision (FP16 / FP32), Pause, Copy report, the status rows, the stats, the detections, the log and About. The camera picks the 4:3 format closest to 1280 wide that runs at 5 fps, and lists all 4:3 formats in the log and the report. The frame is scaled to fit the model input at the top-left, as in the web app, with no per-spot views yet (N1). Unit tests cover the output parsing and the timing stats. Ran in the Simulator on bus.jpg. **Installed and running on the 6s** (Nov 3, via Xcode 26.6 and `install.py`). Still to come from the device: the timings, and boxes on cars in all three spots from the window.

**N1 — Spots, logic, log.** Drawing three spots (fractions of the frame, fixed orientation), per-spot views and the mosaic, the spot state machine ported with unit tests, the event log and CSV through the share sheet, Settings. Exit: unit tests pass; states track the street like the web app over 30+ minutes; a CSV reaches the Mac by AirDrop.

**N2 — Alerts and hunting.** ntfy publishing, the control-topic stream with `since` and reconnects, hunting with timeout, quiet hours and late wording, FREE with the departure check, heads-up with arrival grace and cooldowns, Camera stopped, the export reminder, and test previews. Exit: the web Phase 3 exit (every alert type reaches the main phone; nothing fires while hunting is off; the timeout and quiet hours both end a hunt), plus no false FREE in 30 minutes of hunting with cars parked.

**N3 — Battery, heat, night, unattended.** Holding the battery at 60–70% and thermal throttling, night exposure control, the watchdog and session restart, the foreground-loss alert, auto-start on launch. Exit: 3 days unattended, meeting PLAN.md's success criteria, with the battery in range (or, if it can't be, the measured power draw that explains why) and the thermal state no worse than fair.

## Testing

- **Unit tests** (XCTest) for the pure logic:
  - the state machine: confirmN, hysteresis, never FREE from unknown,
  - the departure check, with synthetic thumbnails,
  - the person-near rules,
  - the hunting timeline: timeout, quiet hours across midnight, late hunt ends, replayed commands judged by their sent time,
  - command parsing,
  - CSV quoting,
  - mosaic coordinate mapping.
- **The Simulator has no camera.** Add a file frame source (a looped video or a still image) so detection and the logic also run in the Simulator. Ultralytics' `bus.jpg` is the standard test image; a short recording of the street is better.
- **Never publish to Ahmed's alert or control topics from tests.** Stub `URLSession` or use a throwaway topic.
- **Device results** come back as a Copy report, as with the web app.

## Decisions for Ahmed (ask in N0)

1. **Signing:** a free Apple ID (the app stops working after 7 days until it's reinstalled from Xcode) or the Apple Developer Program ($99/year, 1-year installs). *Decided Nov 3, 2026 (Ahmed): free Apple ID, personal team "Ahmed Belkhir" (`9KKBY2J9SF`), already signed in to Xcode.* Since Xcode 27 can't install on iOS 15, and on a free team only Xcode can register a device, the install route is **Xcode 26.6 next to 27.2** (Ahmed's call, Nov 3). It's unsupported on macOS 27: its icon shows a "not supported" block, and it opens only by launching `Contents/MacOS/Xcode` inside the app. Its command-line tools work, though. *Result, Nov 3: it works.* Setup: `Xcode_26.6_Apple_silicon.xip` unpacked to `/Applications/Xcode-26.6.app`, its license accepted (`sudo …/Xcode-26.6.app/Contents/Developer/usr/bin/xcodebuild -license`), and its iOS 26.5 platform downloaded (`xcodebuild -downloadPlatform iOS -architectureVariant arm64`, 8.5 GB; without it, device builds fail with "iOS 26.5 is not installed"). It doesn't list the 6s in `-showdestinations`, but `-destination id=<UDID>` finds it, registers it on the free team, and signs. Neither Xcode can install from the command line on iOS 15: `devicectl` handles only iOS 17+, and `xcodebuild test` refuses ("Logic Testing on iOS devices is not supported"). So `ios/tools/install.py` installs the signed app through macOS's MobileDevice framework (the calls Xcode's own legacy stack makes), and `ios/tools/deploy.sh` does the build and the install. The first launch needs Settings → General → VPN & Device Management → the Apple Development certificate → Trust. If this route breaks (a macOS update can block Xcode 26.6), the fallback is the Developer Program: register the 6s's UDID on the developer site, build with Xcode 27.2, and install with `install.py` or Apple Configurator 2's `cfgutil`.
2. **The bundle identifier** (a reverse domain he controls). *Decided Nov 3, 2026 (Ahmed): `io.github.kalloud.spotwatch`, from the GitHub Pages domain kalloud.github.io.*
3. **640 or 320, and one mosaic run or one run per view:** decided from the N0 and N1 timings.

## Lessons from the web build

Don't lose these. Each one is described in PLAN.md and implemented in `index.html`:

- Spots sit at the frame's edges, so per-spot views matter more than a single crop.
- `minScore` 0.2 for cars, `personMinScore` 0.4 for people.
- Hysteresis: an occupied spot holds down to half of `occThresh`.
- The departure check against a snapshot: the false FREEs of Nov 3 were the detector missing the same car for 3 checks.
- Arrival grace, and the FREE and heads-up cooldowns.
- The control topic's `since=<last id>` catch-up, with replayed commands judged by when they were sent.
- Late hunt-end wording.
- Eco mode when not hunting.
- A fixed mount orientation makes the frame-shape handling simpler. Keep the check anyway, in case of a rotation.
