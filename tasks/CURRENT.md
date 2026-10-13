# PingPlace — Current Task Queue

This file is the entry point for human reviewers and the future Agent Watcher.

## Next manually bootstrapped implementation
- [WATCHER-01B](WATCHER-01B.md) — Read-only Windows watcher (15-minute schedule) — **MANUAL_READY**. Human must invoke Codex once. This is NOT automatic dispatch approval.

## Active work
- [TASK-08](TASK-08.md) — Persistent Diagnostics & Full Log Export — **DRAFT**
- [WATCHER-01](WATCHER-01.md) — Windows Agent Watcher — **DRAFT**

## Execution contract
1. Read `AGENTS.md`, `docs/PHASE_0_SPEC.md`, and the linked task specification before working.
2. The future Watcher MUST NOT execute a task unless its approval is independently verified against the exact approved content revision. A plain `status: APPROVED` field is not sufficient.
3. `DRAFT`, `BLOCKED`, `FAILED`, `IN_PROGRESS`, `REVIEW`, and `DONE` are never dispatchable.
4. No automatic merge to `main`. Use a dedicated branch and pull request for implementation work.
5. Documentation setup is not authorization to start either task. No automation is installed yet.
6. Keep `main` protected from unattended changes once the Watcher is enabled.

## Status
Task tracking scaffold only. WATCHER-01 is not implemented or installed. No automatic polling or dispatch is active.

## Next step
Review and approve this task-management contract; then implement WATCHER-01 incrementally, beginning with read-only dry-run behavior.
