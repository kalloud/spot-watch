# Spot Watch: rules for every session

PLAN.md is the spec and the source of truth. Read it in full before any work.

The rules below cover the web app (`index.html`). The native iOS app lives in `ios/`, with its own rules in `ios/CLAUDE.md` and its build plan in `ios/IOS_PLAN.md`; for work there, read those and follow them instead. PLAN.md is the product spec for both.

## Target

- Safari 15 on an iPhone 6s (iOS 15, A9 chip, 2 GB RAM).
- Plain ES2020 in classic `<script>` tags: no modules, no bundler, no framework, no build step.
- One static `index.html` with inline CSS and JS, hosted on GitHub Pages. No backend.
- Libraries and models load only from jsDelivr, pinned to exact versions: TF.js 4.x, `@tensorflow-models/coco-ssd` with the `lite_mobilenet_v2` base, and the YOLOv8n and YOLO26n TF.js models from jsDelivr's GitHub mirror (each pinned to a commit). PLAN.md's tech stack has the exact URLs.
- Stay inside what Safari 15.0 supports (so nothing from 15.4+). Before using any API or syntax newer than that, flag it to Ahmed and wait for a decision.
- The phone has no console: every failure shows on screen, in the error box, a status row and the log.

## Alerts

- Publish to ntfy.sh with `POST https://ntfy.sh/<topic>?title=…&priority=…&tags=…` and a `text/plain` body. Options always travel as query params, never as headers, so the request stays CORS-simple with no preflight.

## Workflow

- Work one phase at a time, in PLAN.md's order. At the end of each phase, stop and wait for Ahmed's device test results before starting the next.
- When a decision changes, update PLAN.md in the same commit.
- Bump `SW_BUILD` in index.html with every change, so a stale GitHub Pages cache is visible on the phone.
