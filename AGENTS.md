# PingPlace Engineering Contract

## Mission
Build PingPlace as a reliable, privacy-first location reminder application. The current implementation scope is Phase 0 only.

## Source of truth
Read all files in /docs before changing product behavior. For current implementation scope, docs/PHASE_0_SPEC.md is authoritative. TECH_SPEC.md governs architecture unless Phase 0 intentionally narrows it.

## Working rules
- Work incrementally. Do not build the full MVP during Phase 0.
- Keep domain/detection logic pure Dart wherever possible.
- Keep Android/iOS APIs and Flutter plugins behind interfaces.
- Prefer small reversible decisions over speculative abstractions.
- Do not silently invent ambiguous product behavior; document the ambiguity.
- Do not introduce backend, authentication, cloud sync, maps, voice, LLM features, LEAVE reminders, or continuous GPS tracking in Phase 0.
- Preserve battery-first design: OS geofence wakes the app; precise location is temporary.
- Never hide failures. Diagnostics must make field-test failures explainable.

## Required quality gate
Before finishing any implementation task:
1. Compare the result with the relevant specification.
2. Run formatter.
3. Run Flutter/Dart analyzer.
4. Run all relevant automated tests.
5. Fix regressions introduced by the task.
6. Self-review state transitions, lifecycle/background behavior, duplicate notifications, persistence, and error handling when relevant.
7. Report what changed, tests run/results, limitations, ambiguities, and recommended next task.

Do not claim a check passed unless it was actually executed.

## Phase 0 implementation order
1. Flutter skeleton and platform-independent architecture.
2. Pure Dart Smart Arrival Detection Engine.
3. Development Simulation Mode using the same engine.
4. Unit tests.
5. Android geofence integration.
6. Temporary precise-location verification.
7. Local notifications.
8. Persistence/background/reboot behavior.
9. Debug dashboard and diagnostic event log.
10. Physical field testing and tuning.

Real Android geofencing should not be implemented until the pure engine and simulation tests are working.
