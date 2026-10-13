---
task_id: WATCHER-C1
status: MANUAL_READY
execution: manual_bootstrap_only
base_branch: main
requires_review: true
---

# WATCHER-C1 — Independent revision-bound approval gate

## Authorization and boundaries
This task authorizes **manual, one-time Codex implementation on a dedicated branch and PR only**. Do not merge, install/update the scheduled watcher, enable dispatch, invoke Codex from the watcher, or mark any existing task APPROVED. Stage B must continue to run read-only unchanged until an explicit human deployment decision.

## Read first
- AGENTS.md
- docs/PHASE_0_SPEC.md
- tasks/WATCHER-01.md
- tasks/WATCHER-01B.md
- automation/watcher.py
- automation/README.md
- automation/test_watcher.py

## Goal
Implement a separately controlled, verifiable approval gate for future automated task execution. Approval is tied to exact UTF-8 bytes of one task file at a known immutable GitHub revision and cannot be granted merely by changing a task's YAML status.

## Threat model and trust boundary
- Treat GitHub task Markdown, PRs, branches, and the Codex worktree as **untrusted input**, not authorization.
- The task author/agent must not be able to approve its own work.
- An approval must be created only by a distinct human-controlled local action, not by task content or by an agent-run command.
- A plain hash, status field, or approval JSON inside the repository is not sufficient proof.
- Design for edited task bytes, stale SHA, copied/replayed approval, changed repo/path/task ID, duplicate approvals, missing proof, malformed data, and restart.
- Approval storage and private signing keys, if any, must be outside the repository and inaccessible to the Codex execution identity. Document that same-user local Codex with unrestricted filesystem access is **not** an adequate security boundary; do not claim isolation until enforced and tested.
- Fail closed on any uncertainty. Approval never grants permission to merge, modify main, or bypass sandbox controls.

## Deliverables
1. A documented approval architecture and threat model, including the chosen trust anchor, approver identity, file permissions and executor separation on Windows 11.
2. A read-only verifier module/API which accepts the exact task bytes, repository, path, immutable commit SHA, and proof, and returns explicit allow/deny reasons. Bind the proof to at least repo, task ID, path, SHA-256 of exact bytes, immutable commit SHA, approval identity, approval time, and a unique approval ID.
3. A separate, **interactive human-only** approval utility with an explicit confirmation of task ID, digest and scope. It must not be invoked by watcher polling or by Codex. If a secure trust boundary cannot be established on the development machine, implement verifier/tests and a clearly disabled approval-creation path instead of a weak substitute.
4. Replay and concurrency protection design: an approval is single-use per task revision; durable execution reservation must be atomic and survive restart. Implement the verification/reservation library only if it can be safely isolated; do not dispatch.
5. Clear separation of approval state from `tasks/*.md` and the agent's worktree; no credentials or approval secrets in Git, logs, CLI args, PR descriptions, or diagnostic output.
6. Automated negative and positive tests for correct proof, altered task bytes, altered commit/path/repo/task ID, unauthorized signer, expired/revoked approval if applicable, duplicate/replayed approval, malformed proof, offline verifier, corrupt local state, concurrency, and restart.
7. Documentation for a safe manual review/approval flow and the limits of the trust boundary, plus a dry-run verifier demo that performs **no execution**.

## Implementation constraints
- Stage B `check`, `status`, `dry-run` and 15-minute Task Scheduler configuration must remain operational and non-dispatching.
- Never add a `codex exec` call, GitHub write action, or auto-merge capability to watcher runtime in C1.
- Never interpret `status: APPROVED` alone as sufficient.
- No Flutter application behavior change or version bump for watcher-only changes.
- Prefer standard-library Python and Windows-supported security primitives; explicitly document external dependencies if unavoidable.
- Work in branch `agent/watcher-c1`; run watcher tests and existing Flutter gates; commit/push and open PR; do not merge.
- Report which tests were actually run, including Windows-specific security checks, and any security boundary not yet demonstrated.

## Acceptance criteria
- An unapproved task cannot pass verification regardless of task YAML.
- Any edit to task bytes or revision invalidates its prior approval.
- A forged proof or agent-authored file cannot grant approval.
- The verifier never triggers work; the active scheduler remains Stage B.
- Concurrent/restarted checks cannot consume the same approval twice if reservation is implemented.
- If genuine approver/executor isolation is not available, approval issuing and future dispatch stay disabled with an explicit BLOCKED reason.

## Next stage
C2 will separately authorize a single controlled Codex test-task execution with isolation, quality gates and PR creation. C1 completion is not authorization for C2 or automatic dispatch.
