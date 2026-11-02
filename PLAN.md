# Spot Watch — Build Plan

Nov 2, 2026 · @Ahmed

## Goal

An old iPhone 6s in the front window watches the two parking spots in front of the triplex. It pushes an alert to Ahmed's main phone before a spot opens, not only after.

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
| Detector | TensorFlow.js 4.22.0 + COCO-SSD 2.2.3, `lite_mobilenet_v2` base, from jsDelivr (exact versions pinned). The model weights load from `storage.googleapis.com`, COCO-SSD's default; copying them into the repo is a Phase 4 option. | Runs in the browser and detects both cars and people. It is the smallest variant, so it suits the A9. |
| Backend | TF.js WebGL (default) | Faster than CPU; fall back to CPU if WebGL fails on the device |
| Push | ntfy.sh, published with a plain POST from the page | No server or account needed; the ntfy app on the main iPhone subscribes to the topic |
| Storage | localStorage | Keeps the spot boxes, topic and settings across page reloads |
| Language | Plain ES2020 JS, no modules or bundler | Safe on Safari 15; avoid syntax and APIs newer than that |

**Key decisions**

- Use the phone-only version (Option A); a home computer running Python/YOLO is the fallback if detection quality is too weak.
- Detect on a crop around the two spots plus a margin, not the full frame. Distant cars are bigger to the model, and it does less work.
- Mark spots by hand by dragging two boxes on the live view. No automatic spot detection.
- Send ntfy options as query parameters (`?title=…&priority=…&tags=…`) with a `text/plain` body. This keeps the request "simple" and avoids a CORS preflight. Confirmed in Phase 0.

## Detection and state logic

Each check decides, per spot, whether a vehicle covers it and whether a person is near it. A spot only changes state after several checks in a row agree.

**Each check (every `interval` ms, waiting for the previous one to finish)**

1. Grab the current video frame. Crop it to the union of the two spot boxes plus a margin (50% of the union's size on each side, at least 5% of the frame), and scale the crop down to 640 px max.
2. Run COCO-SSD on the crop and map the boxes back to full-frame coordinates.
3. For each spot:
   - **coverage** = the largest intersection of any vehicle box (`car`, `truck`, `bus`, `motorcycle`) with the spot box, divided by the spot box's area.
   - **occupied reading** = coverage ≥ `occThresh`.
   - **person near** = any `person` box overlaps the spot box expanded by 35% (35% of its width added on the left and right, 35% of its height on the top and bottom).
   - **lights (experimental, off by default)** = the spot's mean brightness jumps above its slow-moving baseline by more than a set amount.
4. Update that spot's state machine and send any alerts.

**States per spot:** `unknown` → `occupied` ↔ `vacant`

- Becomes `occupied` after `confirmN` occupied readings in a row.
- Becomes `vacant` after `confirmN` vacant readings in a row.
- A failed check, a paused loop or a stopped camera gives no reading; it never counts as vacant.
- A spot resets to `unknown`, without a log row, when it is redrawn or the frame orientation changes, so neither can look like a departure.
- The **FREE** alert fires only on `occupied → vacant`, never on the first reading from `unknown`.
- The **heads-up** alert fires when the spot is `occupied` and "person near" (or lights) holds for `hintN` readings in a row. It has a cooldown per spot.

Spot boxes are stored as fractions (0–1) of the frame, so they survive changes in camera resolution. Each spot also records whether the frame was portrait or landscape when it was drawn. iOS rotates the camera picture with the phone (confirmed in Phase 1: 1280×720 in landscape, 720×1280 in portrait), so a spot is only shown and used while the frame has that orientation; otherwise the Spots status row asks to rotate back or redraw.

**Starting parameters (tune on real footage)**

| Parameter | Default | Effect |
| --- | --- | --- |
| `interval` | 1500 ms | Time between checks; raise it if the 6s runs hot |
| `minScore` | 0.35 | Lowest detector confidence that counts |
| `occThresh` | 0.35 | Spot coverage needed to call it occupied; raise it if a car in the next spot over bleeds in |
| `confirmN` | 3 | Readings in a row before a state changes (about 4.5 s); filters out passing cars |
| `hintN` | 2 | Readings in a row of "person near" before a heads-up |
| Heads-up cooldown | 3 min per spot | Stops repeat alerts while someone loads a trunk |
| Person margin | 35% of the spot box | How close a person must be to count as "at the car" |

**Low light (experimental, added during Phase 2)**

Safari 15 is believed to offer no exposure-time or ISO control; Copy report lists the camera's capabilities to confirm it on the 6s. What the page can do:

- **Brightness:** each check measures the crop's mean brightness (0–255). Below 45 the page shows "low light", and it returns to normal above 60.
- **Frame rate:** a 30 / 15 / 10 / 5 fps choice (saved). At a lower rate, iOS may expose each frame for longer at night; parked cars don't move, so the extra blur doesn't matter.
- **Night boost (off by default):** averages 4 frames of the crop to cut sensor noise, then stretches the levels so the 1st–99th brightness percentiles fill 0–255, with the gain capped at ×6. With debug on, the page shows the model's input under the video.
- Whether night mode switches on automatically (from the brightness reading) is decided after the night test.

**Event log (always on)**

Every state change and alert is appended to a log in localStorage, whether or not hunting is on and including quiet hours. Each row records: ISO timestamp, spot, event (`start`, `occupied`, `vacant`, `person_near`, `alert_free`, `alert_headsup`, `hunt_on`, `hunt_off`, `camera_stopped`), coverage %, and hunting on/off (0/1 in the CSV).

- `start` is written each time the camera starts, so gaps after a reload are explainable.
- `person_near` is written only while the spot is occupied, once per visit: a visit starts after `hintN` readings in a row with a person near and ends after `hintN` readings without one.

- An **Export CSV** button downloads the full log.
- Cap the log at about 20,000 rows and drop the oldest first, so localStorage never fills up.
- A low-priority weekly ntfy reminder prompts the export, so a wiped phone loses at most a week of data.

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
- **Catch-up.** If the 6s misses a command, it catches up on reconnect using ntfy's `since=` parameter; ntfy.sh keeps messages for 12 hours by default.
- **What ends hunting:** manual off, a safety timeout (default 3 h after hunt on), or the start of quiet hours (default 9 pm–7 am). A hunt-on command during quiet hours is refused, with a reply saying so.
- **No auto-detect of "got it".** Guessing that Ahmed took the spot fails silently if a stranger takes it, so hunting never ends on a guess.
- **Cooldowns.** Heads-up: 3 min per spot. Camera stopped: once per outage.

**Topic name.** Make it long and random (e.g. `spotwatch-k3x9q2m7`). Anyone who knows a public ntfy.sh topic can read it.

## UI and configuration

One screen, built to work in both portrait and landscape: the live camera with an overlay, plus a control panel. It is set up once and then left alone.

**Camera view**

- The live video fills the width, but never takes more than about 85% of the window height, so a whole spot can be drawn without scrolling (this matters in landscape). A transparent canvas on top draws the spot boxes, colored by state: green = vacant, red = occupied, grey = unknown.
- Each box is labeled with its spot number and current coverage %.
- An optional debug mode draws the raw detection boxes (vehicles and people) for tuning. It is on by default during setup and saved in localStorage.
- To draw a spot, tap "Draw spot 1/2", then drag on the video. The overlay accepts touches only while drawing, so the page still scrolls normally.

**Panel**

- Buttons: Start, Pause/Resume, Draw spot 1, Draw spot 2, Test alert, Export CSV, Hunt on/off (a local override for testing).
- Hunting status: on/off, when it ends (timeout or quiet hours), and the last command received.
- Per spot: state, coverage %, person near (yes/no).
- Settings: alert topic and control topic (each with a subscribe link), interval, `minScore`, `occThresh`, `confirmN`, `hintN`, person margin, hunting timeout, quiet-hours start and end, lights hint on/off, debug boxes on/off.
- Status line: TF.js backend, ms per check, last check time, log row count.
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
- No plate reading or identification; the frame is aimed tightly at the two spots.

**Physical setup checklist**

- [ ] Pick the window with the clearest view of both spots, ideally slightly elevated (2nd/3rd floor helps).
- [ ] Mount the phone so it can't shift (a suction or clamp mount); a moved camera breaks the spot boxes.
- [ ] Use the rear camera, with the lens close to the glass to cut reflections.
- [ ] Route a charger to the mount.
- [ ] Note what the street lighting is like at night at that spot.

## Scope: MVP vs later

The MVP proves the core loop: two spots, a FREE alert, a person-based heads-up, and a page that keeps running unattended.

| In the MVP | Later, if the MVP works |
| --- | --- |
| Two hand-drawn spots | Any number of spots |
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
| Snow removal day | Both spots empty and refill | Expect a burst of alerts; that's useful |
| Camera unplugged / Safari crash | Camera-stopped alert arrives | Watchdog thresholds |

**What to log during tuning:** time of each real departure, time of the heads-up, time of the FREE alert, and any false alerts. Lead time = the time from heads-up to departure, which is the number that matters most.

## Open questions and things to verify

These need an answer before or during Phase 0. Most are checked on the real device, not from documentation.

- [ ] Does the front window give a clear view of both spots? Which floor, and at what angle?
- [x] Exact iOS version on the 6s (Settings → General → About); update to the latest 15.x if it's not already there. *iOS 15.8.5, Safari 15.6.7 (Phase 1).*
- [x] Does TF.js 4.x with the WebGL backend run in Safari 15 on the A9? What is the real ms per check? *Yes: 373 ms average, 200 ms min (Phase 0).*
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
