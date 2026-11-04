# Spot Watch iOS: rules for every session

Before any work, read `../PLAN.md` (product behaviour, shared with the web app) and `IOS_PLAN.md` (the native build plan) in full. `../index.html` is the reference implementation to port from.

## Target

- iOS 15.0 deployment target, on an iPhone 6s (A9, no Neural Engine, 2 GB RAM). Use only APIs available in iOS 15.0. Anything newer needs an `if #available` path with an iOS 15 fallback, flagged to Ahmed first.
- Swift 5 language mode; SwiftUI, with UIKit where SwiftUI on iOS 15 falls short. No third-party packages without Ahmed's OK.
- Command-line builds use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, because `xcode-select` points to the Command Line Tools.
- The spot logic stays a pure Swift module (no AVFoundation, UIKit or SwiftUI imports), covered by unit tests.
- The phone sits at a window with no console: every failure shows on screen (the status list and the log) and in Copy report.

## Alerts

- Same ntfy format as the web app: `POST https://ntfy.sh/<topic>?title=…&priority=…&tags=…` with a `text/plain` body, and the same titles, priorities and tags, so Ahmed's ntfy subscriptions and Shortcuts keep working.
- Tests never publish to Ahmed's alert or control topics.

## Workflow

- Work one milestone (N0–N3 in `IOS_PLAN.md`) at a time. At the end of each, stop and wait for Ahmed's device results.
- When behaviour changes, update `../PLAN.md` (and `IOS_PLAN.md` for native specifics) in the same commit.
- Bump the build number shown in the app with every change that goes to the phone.
- Leave `../index.html` alone unless Ahmed asks: it's the live fallback on GitHub Pages.
