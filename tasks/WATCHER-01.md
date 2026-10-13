---
task_id: WATCHER-01
status: DRAFT
execution: automatic_after_verified_approval
base_branch: main
requires_review: true
---

# WATCHER-01 — Windows 11 PingPlace Agent Watcher

## Objective
Build a local Windows 11 Task Scheduler + Python watcher that polls the GitHub `main` task queue every **15 minutes** and automatically dispatches only independently verified, revision-approved tasks to Codex CLI. No automatic merge.

## Architecture
- Source of task specs: `tasks/CURRENT.md` and referenced `tasks/*.md` on `origin/main`.
- Scheduler: Windows Task Scheduler, 15-minute repeat, no overlapping instances, no wake from sleep, resume checking after user logon/missed schedule.
- Worker: Python watcher with read-only `dry-run`, locking, durable state, structured logs and status CLI.
- Executor: Codex CLI in isolated Git worktree and dedicated task branch.
- Publisher: validated commit/push and GitHub pull request, with CI and human review before merge.
- Local operational state under `%LOCALAPPDATA%\\PingPlaceWatcher`, not tracked by Git.

## Critical trust boundary
Task files are untrusted instructions, not proof of approval. Design a separate approval mechanism with verifiable authority and content digest (SHA-256), inaccessible to the executing Codex process. Verify exact task bytes/revision, identity and authorization before dispatch. Reapproval required after edits. Define threat model and validate it in tests before enabling automatic execution.

## Execution rules
1. Fetch remote `main` without changing the user's worktree; reject invalid task metadata and stale approval.
2. Allow only `APPROVED` tasks with valid independent approval and `execution: automatic_after_verified_approval`.
3. Acquire exclusive lock and durable task/revision execution record to prevent duplicate runs across restarts.
4. Use an isolated worktree, least privilege, and restricted filesystem/network access as supported by the installed Codex CLI. Do not use `--dangerously-bypass-approvals-and-sandbox`.
5. Run required quality gates; inspect diff against an explicit allowlist; fail closed on unexpected changes or test failures.
6. Publisher credentials must be separated from the Codex process; Codex cannot merge to `main` or approve its own tasks.
7. Produce a PR, execution report, commit SHA and CI status. Transition to `REVIEW`; no automatic merge.
8. On timeout, power loss, network failure, or crash, record `FAILED`/`BLOCKED` and require human recovery decision; do not blindly retry.
9. Provide `status` output: last check, next scheduled check, active task, last outcome, latest PR, and errors. Countdown can be calculated from schedule; no always-on process is required.

## Phased implementation
A. GitHub task-tracking documentation (this scaffold).
B. Read-only polling, validation, local logs, status and dry-run; no Codex dispatch.
C. Controlled Codex execution on a safe test task, isolated branch and PR.
D. Enable automatic execution of independently approved tasks after all safety tests.

## Acceptance tests
No task; DRAFT; valid approval; changed content after approval; unauthorized approval; duplicate scheduling; concurrent invocation; offline/network failure; missing Codex CLI; timeout; failed quality gate; unexpected diff; interrupted run; reboot/logon recovery; successful PR; prohibition of automatic merge.

## Versioning
Documentation-only and watcher-only changes do not require a Flutter app build bump. If installable app code changes, follow `AGENTS.md` and increment the build number.

## Approval
DRAFT ONLY. The watcher is not implemented, installed, scheduled, or authorized to run Codex yet.
