---
task_id: WATCHER-01B
status: MANUAL_READY
execution: manual_bootstrap_only
base_branch: main
requires_review: true
---

# WATCHER-01B — Read-only Windows Agent Watcher

## Authorization
Human approved proceeding with Stage B. This is a **one-time manual Codex bootstrap** task, not an automatically dispatchable approval. Do not start autonomous Codex execution, register scheduled tasks automatically, or merge into main.

## Read first
- AGENTS.md
- docs/PHASE_0_SPEC.md
- tasks/CURRENT.md
- tasks/WATCHER-01.md

## Goal
Implement and test a Windows 11 Python watcher which polls GitHub task metadata every 15 minutes when explicitly installed, but **never executes Codex, edits task statuses, pushes code, or triggers implementation tasks** in Stage B.

## Deliverables
1. `automation/watcher.py` with CLI subcommands `check`, `status`, and `dry-run`. The `check` operation must be read-only against GitHub and only update local operational state/logs.
2. `automation/watcher_config.yaml` (or a standard-library-only JSON equivalent if dependencies are undesirable), default interval 15 minutes, repo `bandora78/pingplace`, branch `main`, and `dispatch_enabled: false`. Explicitly reject dispatch enablement in this stage.
3. `automation/run_watcher.ps1` for Task Scheduler to invoke a single check, exit, and preserve exit code; never create an infinite polling loop.
4. `automation/install_watcher.ps1` and `automation/uninstall_watcher.ps1` scripts, **not executed by Codex**. Installer must present planned Task Scheduler settings, require explicit user confirmation, use normal-user privileges, 15-minute repetition, avoid overlapping instances, and not wake a sleeping PC. Document logon/missed-run behavior and scheduler limitations.
5. Bounded local logs and durable local state under `%LOCALAPPDATA%\\PingPlaceWatcher`; do not commit operational files. `status` shows last check, next scheduled check (computed from actual schedule or clearly marked estimate), most recent result/error, detected task IDs and dispatch state.
6. Robust fetch/parsing: fetch `origin/main` or GitHub API safely, avoid modifying user's working tree, enforce task filename/path allowlist and valid metadata; reject invalid files without executing them.
7. Explicit locking (including manual double launch), timeout/error handling, offline behavior, redaction of tokens, and graceful recovery from corrupt local state.
8. Automated tests for no tasks, DRAFT, MANUAL_READY, APPROVED without independent proof, invalid metadata, remote error, concurrency, stale state, and restart. No status may trigger dispatch in Stage B.
9. README for prerequisites (Python, Git, optionally gh), dry-run, safe installation, verification of Task Scheduler, and uninstall.

## Safety and workflow
- Work on a dedicated branch such as `agent/watcher-01b`, not main.
- No `codex exec` invocation anywhere in runtime Stage B.
- No app behavior changes and no Flutter build version bump for watcher-only files.
- Do not require administrative rights, store secrets in repo, or use bypass-sandbox flags.
- Run actual tests; report commands/results honestly. Commit and push branch; create PR if credentials support it. No merge.
- If installation or credential prerequisites cannot be verified, report them as manual setup steps; do not guess success.

## Acceptance
- `check` identifies task metadata without side effects on GitHub.
- `dry-run` explains what would be eligible but executes nothing.
- `status` reports accurate local check history and next-check basis.
- No background scheduler installation occurs until user explicitly runs the installer.
- CI/local tests verify dispatch is impossible in Stage B.
- PR contains only watcher Stage B and documentation changes.

## Future stage
Stage C will design independent revision-bound approvals, credential isolation, worktrees and controlled Codex dispatch; those features are not authorized here.
