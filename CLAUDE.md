# Spot Watch: rules for every session

PLAN.md is the spec and the source of truth. Read it in full before any work.

## Target

- Safari 15 on an iPhone 6s (iOS 15, A9 chip, 2 GB RAM).
- Plain ES2020 in classic `<script>` tags: no modules, no bundler, no framework, no build step.
- One static `index.html` with inline CSS and JS, hosted on GitHub Pages. No backend.
- Libraries load only from jsDelivr: TF.js 4.x and `@tensorflow-models/coco-ssd` with the `lite_mobilenet_v2` base.
- Stay inside what Safari 15 supports. Before using any API or syntax newer than Safari 15, flag it to Ahmed and wait for a decision.

## Alerts

- Publish to ntfy.sh with `POST https://ntfy.sh/<topic>?title=…&priority=…&tags=…` and a `text/plain` body. Options always travel as query params, never as headers, so the request stays CORS-simple with no preflight.

## Workflow

- Work one phase at a time, in PLAN.md's order. At the end of each phase, stop and wait for Ahmed's device test results before starting the next.
- When a decision changes, update PLAN.md in the same commit.
