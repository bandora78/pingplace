---
task_id: TASK-08
status: DRAFT
execution: automatic_after_verified_approval
base_branch: main
requires_review: true
---

# TASK-08 — Persistent Diagnostics & Full Log Export

## Background
Physical Android testing on 2026-10-13 confirmed geofence restoration after reboot and at least one real arrival notification on a later pass. An earlier pass did not notify. The debug screen showed `Last notification: duplicate`, but available screenshots cannot establish why the missed pass occurred. Preserve this uncertainty; do not claim a root cause.

## Objective
Make missed arrivals, duplicate suppression, and background events diagnosable without changing arrival detection behavior.

## Scope
1. Add an accessible **COPY FULL LOG** action to the debug UI, with a clear success/failure indication.
2. Persist bounded diagnostic events across app/process restart and device reboot. Define retention limits, timestamps/timezones, ordering, and safe recovery from corrupt storage.
3. Correlate arrival lifecycle events and notification attempts using a stable `visitId` where applicable; record why a notification was sent, suppressed as duplicate, or failed.
4. Record Android background geofence delivery, handling, recovery, and failures with sufficient context to distinguish receipt from downstream processing.
5. Export useful diagnostic history even when UI was not open at event time; avoid leaking sensitive data in normal builds.
6. Preserve Phase 0 battery-first design; do not introduce continuous background GPS or new network services.

## Out of scope
- Changing geofence radii, arrival thresholds, cooldown, rearm rules, or notification policy.
- Assuming the missing first-pass notification was caused by deduplication.
- New product features or backend services.

## Acceptance criteria
- COPY FULL LOG is visible and works on the device.
- Log persists across process restart and reboot and is bounded in size.
- Every notification attempt has a recorded outcome/reason and visit correlation where possible.
- Background event/recovery diagnostics can be exported.
- Existing state transitions, notifications, and geofence behavior remain unchanged.
- Existing and new regression tests pass; physical verification steps are documented.

## Quality gate
Follow `AGENTS.md`: formatting, Flutter analyzer, relevant automated tests, build/CI as appropriate, explicit results and limitations. When installable app code changes, increment the build number from `1.0.0+5` to `1.0.0+6` if still current at implementation time; never decrement or overwrite a newer version. Report commit SHA and build version.

## Delivery
Dedicated branch, pull request, test summary, changed files, limitations, and instructions for a safe physical test. No automatic merge.

## Approval
DRAFT ONLY. No execution until the future Watcher validates a separate, revision-bound approval record.
