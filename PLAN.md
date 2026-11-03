# Spot Watch — Build Plan

Nov 2, 2026 · @Ahmed

## Goal

An old iPhone 6s in the front window watches the three parking spots in front of the triplex (two at first; a third was added during Phase 2). It pushes an alert to Ahmed's main phone before a spot opens, not only after.

The core problem is timing. A free spot gets taken within seconds by someone already circling. An alert that fires only once the spot is empty is too late. The real value is the early warning: someone walks up to a parked car, so it may leave soon.

**Success criteria**

- While hunting, a "heads up" alert arrives as soon as someone is at a parked car in one of the spots, early enough to win slow departures (loading, kids, warming up the engine, clearing snow).
- A "spot free" alert arrives within about 5 s of the spot actually emptying.
- False alerts are tolerable while hunting (Ahmed checks the window first), and the sensitivity can be lowered if they get annoying.
- It runs unattended for days on the 6s and tells Ahmed when it stops working.
- No video leaves the phone. Only short text alerts are sent.

## Trigger strategy (decided)

The app targets **slow departures**. Wins are a bonus, not a guarantee. Ahmed's response time is 2–4 minutes, but a driver at their car usually leaves within about 10 seconds to 2 minutes ([Ruback & Juieng, 1997](https://www.eurekalert.org/news-releases/1012563)), so a quick departure can't be beaten.

| Decision | Choice |
| --- | --- |
| What the app is built around | Slow departures (loading, kids, engine warm-up, snow clearing) + the FREE alert |
| On nights the spot really matters | Ahmed re-parks as close as possible himself; the app tells him when to pull forward |
| Sensitivity | Sensitive by default while hunting; he confirms by looking out the window and lowers the sensitivity if it gets noisy |
| When alerts fire | Only in **hunting mode**, switched on and off from the main iPhone |
| What ends hunting | Manual off, a safety timeout (default 3 h), or quiet hours (default 9 pm–7 am) |
| Logging | Every state change logged from day one, even when not hunting and during quiet hours |
| Later | Use the log to judge whether predicting departures from patterns is worth building |

## Constraints

Everything runs as one web page in Safari on the 6s. These limits shape the design:

| Constraint | What it means for the build |
| --- | --- |
| iPhone 6s tops out at iOS 15 | Safari 15 only, with 15.0 as the baseline: nothing added in 15.4+ (e.g. `Array.at`, `structuredClone`, `requestVideoFrameCallback`) and no iOS 16+ features. Test every API on the real device. |
| A9 chip, 2 GB RAM (2015) | Small detector only, one check every 1–2 s. Run detection on a crop of the spots, not the full frame. |
| Camera access needs HTTPS | The page must be hosted (GitHub Pages or similar), not opened as a local file. |
| No Screen Wake Lock API in iOS 15 Safari (believed added in 16.4 — verify) | Keep the screen on with Settings: Auto-Lock = Never, plus Guided Access to pin Safari. |
| Safari pauses timers when the tab is hidden | The page must stay in the foreground. Detect pauses and report them. |
| No backend | Alerts go straight from the page to ntfy.sh. Config lives in localStorage. |
| Plugged in around the clock | Watch the old battery for swelling and keep the phone away from window heat. |

## Architecture

The pipeline is a straight line from camera to alert, and every step up to the push runs inside one Safari page on the 6s.

&#91;embedded content: Spot Watch pipeline · on-device detection, push out\]

Once per interval, a frame is cropped to the spots, run through the detector, and scored per spot. The state machine decides whether to alert. ntfy.sh is the only outside service, and it only receives short text.

## Tech stack and decisions

The app is one static HTML file with inline JS. There is no build step and no framework, so it loads fast on Safari 15 and is easy to debug on the device.

| Piece | Choice | Why |
| --- | --- | --- |
| Hosting | GitHub Pages (HTTPS) | Free, gives the HTTPS that camera access requires, and deploys with a push |
| Detector | TensorFlow.js 4.22.0, plus a model picked on the page: **COCO-SSD 2.2.3** (`lite_mobilenet_v2` base, from jsDelivr; its 18 MB of weights load from `storage.googleapis.com`) or **YOLOv8n 640** (Ultralytics, GPL-3.0; a 12.8 MB TF.js export served by jsDelivr from the `Hyuto/yolov8-tfjs` GitHub repo, pinned to commit `b6a8bc6`). All versions are pinned. YOLOv8n is far more accurate on the COCO benchmark (mAP ~37 vs ~22) but needs about 10× the work per check; YOLOv8n is the default since Phase 3, after it held all three spots steady with per-spot views; COCO-SSD stays selectable. Copying weights into the repo is a Phase 4 option. | Runs in the browser and detects both cars and people. It is the smallest variant, so it suits the A9. |
| Backend | TF.js WebGL (default) | Faster than CPU; fall back to CPU if WebGL fails on the device |
| Push | ntfy.sh, published with a plain POST from the page | No server or account needed; the ntfy app on the main iPhone subscribes to the topic |
| Storage | localStorage | Keeps the spot boxes, topic and settings across page reloads |
| Language | Plain ES2020 JS, no modules or bundler | Safe on Safari 15; avoid syntax and APIs newer than that |

**Key decisions**

- Use the phone-only version (Option A); a home computer running Python/YOLO is the fallback if detection quality is too weak.
- Detect on zoomed views of the spots, not the full frame: each spot gets its own view (the spot plus a margin), and the views are tiled into one detector input. Distant cars are much bigger to the model. (A single crop around all spots was tried first, but with spots at both edges of the frame it was the whole frame, and a small distant car in spot 3 kept being missed.)
- Mark spots by hand by dragging three boxes on the live view. No automatic spot detection.
- Send ntfy options as query parameters (`?title=…&priority=…&tags=…`) with a `text/plain` body. This keeps the request "simple" and avoids a CORS preflight. Confirmed in Phase 0.

## Detection and state logic

Each check decides, per spot, whether a vehicle covers it and whether a person is near it. A spot only changes state after several checks in a row agree.

**Each check (every `interval` ms, waiting for the previous one to finish)**

1. Grab the current video frame. Cut one view per spot: the spot plus a margin of 50% of its size on each side (at least 5% of the frame), clipped to the frame. Tile the views into a 640×640 mosaic: one view fills it, two to four share a 2×2 grid (320 px tiles). Each view is scaled to fit its tile, keeping its shape, so small spots are enlarged. With no spot drawn for the current frame shape, the whole frame is the only view.
2. Run the detector and map the boxes back to full-frame coordinates. YOLOv8n takes the whole mosaic in one run; COCO-SSD shrinks its input to 300 px, so it gets one run per view. A box belongs to the view its centre falls in and is clipped to it; the same object found in two overlapping views (IoU > 0.5, same class) is kept once.
3. For each spot:
   - **coverage** = the largest intersection of any vehicle box (`car`, `truck`, `bus`, `motorcycle`) with the spot box, divided by the spot box's area.
   - **occupied reading** = coverage ≥ `occThresh`; once the spot is occupied, coverage ≥ half of `occThresh` (hysteresis, so coverage hovering at the line can't flip it). A complete miss still reads as vacant; `confirmN` handles those.
   - **person near** = any `person` box overlaps the spot box expanded by 35% (35% of its width added on the left and right, 35% of its height on the top and bottom).
   - **lights (experimental, off by default)** = the spot's mean brightness jumps above its slow-moving baseline by more than a set amount.
4. Update that spot's state machine and send any alerts.

**States per spot:** `unknown` → `occupied` ↔ `vacant`

- Becomes `occupied` after `confirmN` occupied readings in a row.
- Becomes `vacant` after `confirmN` vacant readings in a row.
- A failed check, a paused loop or a stopped camera gives no reading; it never counts as vacant.
- A spot resets to `unknown`, without a log row, when it is redrawn or the frame orientation changes, so neither can look like a departure.
- The **FREE** alert fires only on `occupied → vacant`, never on the first reading from `unknown`, and at most once per spot per FREE cooldown (2 min), so a flapping spot can't send a burst.
- The **heads-up** alert fires when the spot is `occupied` and "person near" (or lights) holds for `hintN` readings in a row. It has a cooldown per spot, and doesn't fire during the arrival grace (the first 2 min after the spot became occupied), which is the driver who just parked getting out. For person near, a person needs `personMinScore` (0.4), higher than the `minScore` cars need, because low-score people were the main source of false person-near readings at night.

Spot boxes are stored as fractions (0–1) of the frame, so they survive changes in camera resolution. Each spot also records the frame shape it was drawn on: orientation plus aspect, e.g. "landscape 16:9". iOS rotates the camera picture with the phone (confirmed in Phase 1: 1280×720 in landscape, 720×1280 in portrait), and a 4:3 frame shows more above and below than 16:9, so the same fractions point elsewhere on another shape. A spot is only shown and used while the frame has its shape; otherwise the Spots status row asks to rotate back, switch the shape back, or redraw. Spots saved before the 4:3 option count as 16:9.

**Starting parameters (tune on real footage)**

| Parameter | Default | Effect |
| --- | --- | --- |
| `interval` | 1500 ms | Time between checks; raise it if the 6s runs hot |
| `minScore` | 0.2 (was 0.35; 0.2 kept spots steady on YOLOv8n in Phase 2) | Lowest detector confidence that counts |
| `personMinScore` | 0.4 | Lowest confidence for a person to count as near a car |
| `occThresh` | 0.35 | Spot coverage needed to call it occupied; raise it if a car in the next spot over bleeds in |
| `confirmN` | 3 | Readings in a row before a state changes (about 4.5 s); filters out passing cars |
| `hintN` | 2 | Readings in a row of "person near" before a heads-up |
| Heads-up cooldown | 3 min per spot | Stops repeat alerts while someone loads a trunk |
| Arrival grace | 2 min | No heads-up this soon after a spot becomes occupied |
| FREE cooldown | 2 min per spot | Caps FREE alerts if a spot flaps |
| Person margin | 35% of the spot box | How close a person must be to count as "at the car" |

**Low light (experimental, added during Phase 2)**

Safari 15 offers no exposure-time, ISO, zoom or torch control. Confirmed on the 6s: the camera's capabilities list only width and height (up to 4032×3024), aspect ratio, frame rate (1–30) and facing mode. What the page can do:

- **Brightness:** each check measures the crop's mean brightness (0–255). Below 45 the page shows "low light", and it returns to normal above 60.
- **Frame rate:** a 30 / 15 / 10 / 5 fps choice (saved). At a lower rate, iOS may expose each frame for longer at night; parked cars don't move, so the extra blur doesn't matter.
- **Night boost (off by default):** averages 4 frames of the crop to cut sensor noise, then stretches the levels so the 1st–99th brightness percentiles fill 0–255, with the gain capped at ×6. With debug on, the page shows the model's input under the video.
- Whether night mode switches on automatically (from the brightness reading) is decided after the night test.

**Event log (always on)**

Every state change and alert is appended to a log in localStorage, whether or not hunting is on and including quiet hours. Each row records: ISO timestamp, spot, event (`start`, `occupied`, `vacant`, `person_near`, `alert_free`, `alert_headsup`, `hunt_on`, `hunt_off`, `camera_stopped`), coverage %, hunting on/off (0/1 in the CSV), and a free-text detail (why a hunt ended, a person's score and why no heads-up went out, whether an alert was sent). The CSV columns are `time,spot,event,coverage_pct,hunting,detail`; rows from before Phase 3 have an empty detail.

- `start` is written each time the camera starts, so gaps after a reload are explainable.
- `person_near` is written only while the spot is occupied, once per visit: a visit starts after `hintN` readings in a row with a person near and ends after `hintN` readings without one.

- An **Export CSV** button downloads the full log.
- Cap the log at about 20,000 rows and drop the oldest first, so localStorage never fills up.
- A low-priority weekly ntfy reminder prompts the export, so a wiped phone loses at most a week of data. It goes out when 7 days have passed since the last export (or since the first log row), between 10:00 and 20:00, at most once a week.

## Alerts

All alerts go to one ntfy topic, which the ntfy app on Ahmed's main iPhone subscribes to. ntfy priorities run from 1 (min) to 5 (max/urgent).

| Alert | When it fires | ntfy priority | Tag |
| --- | --- | --- | --- |
| Spot N is FREE | Hunting is on and a spot goes from occupied to vacant | 5 | `rotating_light` |
| Heads up: spot N | Hunting is on and someone is at the car (or its lights came on) for `hintN` checks | 4 | `eyes` |
| Camera stopped | No usable frames for about 5 checks, or the camera track ended (sent even when not hunting) | 3 | `warning` |
| Hunting on / off | Confirms each hunt command, and says why hunting ended (manual, timeout, quiet hours) | 2 | `white_check_mark` |
| Export the log | Weekly reminder | 1 | `floppy_disk` |

**Hunting mode**

- **Alerts fire only while hunting.** This replaces the "my car" toggle from the first draft.
- **Switch.** An iOS Shortcut on the main iPhone POSTs `hunt on` or `hunt off` to a second ntfy topic (the control topic). The 6s listens on that topic. Put the Shortcut on the home screen, Back Tap or Siri.
- **Catch-up.** If the 6s misses a command, it catches up on reconnect using ntfy's `since=` parameter; ntfy.sh keeps messages for 12 hours by default. The page saves the id of the last control message it handled and always reconnects with `since=<that id>`, handling drops itself rather than relying on the browser's reconnect. A replayed command is judged by when it was sent: a `hunt on` whose timeout has already passed is ignored, and a newer one hunts until its own sent time plus the timeout.
- **What ends hunting:** manual off, a safety timeout (default 3 h after hunt on), or the start of quiet hours (default 9 pm–7 am). A hunt-on command during quiet hours is refused, with a reply saying so. Hunting is saved, so a reload keeps it; if the page was down past the end, it ends as soon as the page is back.
- **Replies** go to the alert topic at priority 2: "Hunting on until HH:MM" (the timeout or the start of quiet hours, whichever is first), "Hunting off (manual / timeout / quiet hours)", "Hunt on refused: quiet hours until HH:MM", "Hunting was already off".
- **Sending.** An alert ntfy doesn't accept is tried once more after 10 s; a failure shows in the Alerts status row and the log. The page's "Send test" button previews any alert type with its real priority and tag and a "[test]" title, and a "Hunt on/off" button acts like the commands.
- **No auto-detect of "got it".** Guessing that Ahmed took the spot fails silently if a stranger takes it, so hunting never ends on a guess.
- **Cooldowns.** Heads-up: 3 min per spot, plus the 2 min arrival grace. FREE: 2 min per spot. Camera stopped: once per outage. Cooldowns survive redrawing a spot.

**Topic name.** Make it long and random (e.g. `spotwatch-k3x9q2m7`). Anyone who knows a public ntfy.sh topic can read it.

## UI and configuration

One screen, built to work in both portrait and landscape: the live camera with an overlay, plus a control panel. It is set up once and then left alone.

**Camera view**

- The camera frame is 16:9 (1280×720) by default, or 4:3 (1280×960, picked on the page), which keeps the sensor's full height: more picture above and below at the same width.
- The live video fills the width, but never takes more than about 85% of the window height, so a whole spot can be drawn without scrolling (this matters in landscape). A transparent canvas on top draws the spot boxes, colored by state: green = vacant, red = occupied, grey = unknown.
- Each box is labeled with its spot number and current coverage %.
- An optional debug mode draws the raw detection boxes (vehicles and people) for tuning. It is on by default during setup and saved in localStorage.
- To draw a spot, tap "Draw spot 1/2/3", then drag on the video. The overlay accepts touches only while drawing, so the page still scrolls normally.

**Panel**

- Buttons: Start, Pause/Resume, Draw spot 1, Draw spot 2, Draw spot 3, Test alert, Export CSV, Hunt on/off (a local override for testing).
- Hunting status: on/off, when it ends (timeout or quiet hours), and the last command received.
- Per spot: state, coverage %, person near (yes/no).
- Settings: alert topic and control topic (each with a subscribe link), interval, `minScore`, `personMinScore`, `occThresh`, `confirmN`, `hintN`, person margin, hunting timeout, quiet-hours start and end (decimal hours, e.g. 7.5 = 07:30), heads-up cooldown, FREE cooldown, arrival grace, lights hint on/off, debug boxes on/off.
- Status line: model, TF.js backend, ms per check, last check time, log row count.
- Load: Safari gives pages no CPU or GPU %, so the page shows stand-ins: detector busy % (share of time spent inside checks over the last 20), main-thread load % (how late a 100 ms timer fires, over ~10 s) and GPU memory used by TF.js.
- A rolling on-screen view of the last \~50 events; the full history is in the event log.

All settings are saved to localStorage on change. On load, if spots are already set, the page tries to start on its own.

## Reliability, privacy and setup

**Reliability**

- **Watchdog.** If the video isn't ready or the camera track has ended for about 5 checks in a row, send "Camera stopped" once, then try to restart the camera.
- **Error handling.** A failed detection is logged and the loop continues; one bad frame never stops it.
- **Visibility.** Log when the page is hidden or shown again. On resume, send a low-priority "running" ping.
- **Reloads.** Config lives in localStorage and the page auto-starts, so a reload by Safari recovers without setup.
- **Device settings.** Auto-Lock = Never, Guided Access on, charger connected, low screen brightness.

**Privacy**

- All detection runs on the phone. No frames or images are stored or sent anywhere.
- Only short text alerts leave the device.
- No plate reading or identification; the frame is aimed tightly at the spots.

**Physical setup checklist**

- [ ] Pick the window with the clearest view of all three spots, ideally slightly elevated (2nd/3rd floor helps).
- [ ] Mount the phone so it can't shift (a suction or clamp mount); a moved camera breaks the spot boxes.
- [ ] Use the rear camera, with the lens close to the glass to cut reflections.
- [ ] Route a charger to the mount.
- [ ] Note what the street lighting is like at night at that spot.

## Scope: MVP vs later

The MVP proves the core loop: three spots, a FREE alert, a person-based heads-up, and a page that keeps running unattended.

| In the MVP | Later, if the MVP works |
| --- | --- |
| Three hand-drawn spots | Any number of spots |
| FREE + heads-up (person near) alerts | Lights and door-open signals, tuned on night footage |
| Hunting mode via iOS Shortcut + ntfy control topic, with timeout and quiet hours | Smarter auto-start of hunting (e.g. when the main phone arrives home) |
| Event log in localStorage + Export CSV + weekly reminder | Predict departures from the log's patterns |
| Watchdog + camera-stopped alert | A daily health ping and a log of uptime |
| On-device detection only | Fallback: phone streams to a home computer running Python/YOLO |
| Single user | Shared block version: one camera, alerts to opted-in neighbours |

## Build phases

Build in five phases, and test each one on the real 6s before starting the next. Phase 0 is the riskiest, so it comes first.

1. **Phase 0 — Feasibility spike (on device).** A bare page on GitHub Pages: open the camera, load COCO-SSD, log detections and ms per check, send one ntfy test alert, and receive one message from a control topic. It also draws the raw detection boxes on the video (so it's clear which car was found), has a WebGL/CPU switch, and has a Copy report button for sending results back.
   - Exit: TF.js runs in Safari 15 on the 6s; one check takes under \~1.5 s; the push arrives on the main phone; a control-topic message reaches the 6s; cars are detected from the real window.
   - Result (Nov 2, 2026): passed, except the window check, which moved to Phase 1. WebGL averaged 373 ms per check over 272 checks (min 200 ms) on the full frame scaled to 640 px; CPU was slower. Test alerts and control-topic messages both arrived.
2. **Phase 1 — Spot setup.** Live view with overlay, drawing two spot boxes, saving them as fractions in localStorage, and drawing debug boxes.
   - Exit: boxes survive reloads and line up with the video in portrait and landscape; with the phone at the real window, parked cars in both spots get vehicle boxes (carried over from Phase 0).
   - Result (Nov 2, 2026): passed. Spots survive reloads; rotating hides them with the warning and rotating back restores them. Cars were detected from the window by day, though the car count varies from check to check on the full frame. Checks averaged 303 ms (266–639 ms) over 139 checks.
3. **Phase 2 — Detection loop, state machine, event log.** Crop-to-spots, coverage, person-near, debounce, per-spot states shown live, every change written to the log, Export CSV.
   - Exit: states track reality for an hour of daytime watching, with no false flips from passing cars; the exported CSV matches what happened.
   - Result (Nov 2, 2026): closed by Ahmed without the full daytime hour. At night, on YOLOv8n with per-spot views, 4:3 frames, 5 fps and minScore 0.2, all three spots held their state for 18 minutes with no flips (before per-spot views, spot 3 flipped about 50 times in 22 minutes). Spot 3's coverage sat at 24–26%, held occupied by hysteresis. Checks averaged 1025 ms (969–1780 ms), detector busy 69%. Not yet verified on the device: Export CSV downloading, and a daytime run.
4. **Phase 3 — Hunting mode + alerts.** Control topic, iOS Shortcuts for hunt on/off, timeout, quiet hours, FREE and heads-up alerts, camera-stopped, cooldowns, weekly export reminder.
   - Exit: every alert type is seen at least once on the main phone; no FREE or heads-up fires while hunting is off; timeout and quiet hours both end a hunt.
5. **Phase 4 — Hardening + tuning.** Watchdog, auto-start, visibility handling, then a multi-day soak test.
   - Exit: runs 3 days unattended and meets the success criteria in the Goal section.

## Test plan and tuning

Test against what actually happens on the street, writing down each departure by hand at first. Then tune one parameter at a time.

| Scenario | What to check | Likely fix if it fails |
| --- | --- | --- |
| Car parks in a spot | Turns occupied within \~5 s | Lower `occThresh` or `minScore` |
| Car drives off | FREE within \~5 s, exactly once | Lower `confirmN` |
| Driver walks up, then leaves | Heads-up arrives before the car moves | Bigger person margin, lower `hintN` |
| Someone walks past on the sidewalk | No heads-up | Smaller person margin, higher `hintN` |
| Cars pass on the street | No state change | Raise `confirmN` |
| Car in the neighboring spot | Doesn't count as occupied | Raise `occThresh`, tighten the box |
| Night, under street lighting | Parked cars are still detected | Lower frame rate, Night boost, block window reflections; then consider the Option B fallback |
| Rain, snow on cars, fogged glass | Track the false FREE rate | Raise `confirmN` at night |
| Snow removal day | All spots empty and refill | Expect a burst of alerts; that's useful |
| Camera unplugged / Safari crash | Camera-stopped alert arrives | Watchdog thresholds |

**What to log during tuning:** time of each real departure, time of the heads-up, time of the FREE alert, and any false alerts. Lead time = the time from heads-up to departure, which is the number that matters most.

## Open questions and things to verify

These need an answer before or during Phase 0. Most are checked on the real device, not from documentation.

- [ ] Does the front window give a clear view of all three spots? Which floor, and at what angle?
- [x] Exact iOS version on the 6s (Settings → General → About); update to the latest 15.x if it's not already there. *iOS 15.8.5, Safari 15.6.7 (Phase 1).*
- [x] Does TF.js 4.x with the WebGL backend run in Safari 15 on the A9? What is the real ms per check? *Yes: 373 ms average, 200 ms min (Phase 0). YOLOv8n 640: 1.0 s average (0.95–3.2 s) over 884 checks, first check 16 s, detector busy 76%, main thread 66% (Phase 2, at night, 5 fps, minScore 0.2).*
- [ ] Which model stays, COCO-SSD lite or YOLOv8n? *YOLOv8n with minScore 0.2 held spots 1 and 2 steady for 22 minutes, but spot 3's small, distant car was found only in some checks and flipped about 50 times; per-spot views were added to fix that. With per-spot views, YOLOv8n held all three spots for 18 minutes with no flips (Phase 2 result). COCO-SSD hasn't been re-tested with per-spot views.*
- [ ] Can COCO-SSD `lite_mobilenet_v2` detect the cars from that distance and angle, by day and by night? *By day, yes, with a car count that varies between checks on the full frame (Phase 1). Night still to test.*
- [x] Does ntfy accept the query-parameter publish from Safari without CORS issues, and does the ntfy iOS app deliver priority-5 alerts promptly? *Yes (Phase 0).*
- [ ] Can the 6s hold a live subscription to the control topic (EventSource or polling) for hours, and how fast do hunt commands arrive? *EventSource receives messages (Phase 0); hours-long hold still to test.*
- [ ] Build and test the two iOS Shortcuts (hunt on / hunt off) on the main iPhone.
- [ ] Does Safari remember the camera permission for the site, or ask on every reload? (Settings → Safari → Camera.)
- [ ] Does the video keep playing for hours with Guided Access on and Auto-Lock off, and how hot does the phone get?
- [ ] Confirm Screen Wake Lock is truly unavailable on iOS 15 Safari, to rule it out.
- [ ] Do neighbours need to know there's a camera aimed at the street? It's worth a courtesy word even if nothing is recorded.

## Claude Code kickoff prompt

Export this doc as Markdown, save it in the repo as `PLAN.md`, and start Claude Code with:

```markdown
Read PLAN.md. We're building "Spot Watch": a single static index.html (inline CSS + JS, no build step, no framework) that runs in Safari 15 on an iPhone 6s, watches two parking spots through the camera, and pushes alerts via ntfy.sh.

Hard constraints:
- Must run on iOS 15 Safari: plain ES2020, no modules, no APIs newer than Safari 15. Flag anything you're unsure about.
- TF.js 4.x + @tensorflow-models/coco-ssd (lite_mobilenet_v2) loaded from jsDelivr.
- No backend. Config and the event log in localStorage. Hosted on GitHub Pages.
- Video must use playsinline + muted; camera via getUserMedia with facingMode environment.
- Detection on a crop around the spots, not the full frame.
- ntfy publish: POST text/plain body, options as query params (title, priority, tags) to avoid a CORS preflight.
- Alerts (FREE, heads-up) fire only in hunting mode. Hunting is switched by "hunt on" / "hunt off" messages on a separate ntfy control topic, and ends on manual off, a timeout (default 3 h), or quiet hours (default 9 pm–7 am).
- Every state change is logged (even when not hunting), with an Export CSV button.

Work phase by phase as PLAN.md describes. Start with Phase 0 only: a minimal page that opens the camera, loads the model, logs detections + ms per check on screen, has a "Test alert" button, and shows messages received on the control topic. Also set up the GitHub Pages deploy. Stop after Phase 0 so I can test on the device and report results before Phase 1.
```

After each phase, report the device results back to Claude Code (ms per check, what was detected, any Safari errors) before moving on.
