---
task_id: WATCHER-C2B
status: DRAFT
execution: manual_bootstrap_only
base_branch: main
requires_review: true
---

# WATCHER-C2B — Isolated executor preflight and durable reservation library

## Status and authorization

This is a proposed follow-up task from WATCHER-C2A. It is DRAFT only. It does
not authorize automatic execution, scheduler changes, Codex dispatch, GitHub
writes, PR creation, merge, deployment, signing-key generation, or approval
proof creation.

## Objective

Implement the preflight and reservation boundary described in
`docs/WATCHER-C2A.md` without invoking Codex or wiring the Stage B watcher to
dispatch. Prove that a future executor can receive only a verified,
immutable-source capability under a dedicated Windows identity and cannot
reuse it after a crash or restart.

## Scope

- Standard-library Python reservation journal using SQLite transactions with
  explicit NTFS/ACL/integrity preflight and conservative ambiguous-commit
  handling; do not claim hardware power-loss durability.
- Broker IPC/capability handoff that accepts only a broker-reverified C1
  `VerifiedApproval` and never trusts a caller-supplied boolean or Python type.
- Windows 11 executor identity, ACL, environment, work-root, and network
  preflight checks with explicit `EXECUTOR_NOT_ACTIVATED` failure by default.
- Bounded structured audit records with no tokens, signatures, or task full
  text.
- Exact task-byte, commit-reachability, and complete source-tree manifest
  revalidation at reservation and handoff time.
- Crash, restart, duplicate, replay, concurrency, tampering, and permission
  tests using disposable fixtures/accounts where available.
- Documentation of all observed Windows evidence and limitations.

## Explicit exclusions

- No call to `codex`, no Codex installation, and no automatic or scheduled
  executor.
- No modification to `automation/watcher.py`, `automation/approval_gate.py`,
  Task Scheduler scripts, `tasks/CURRENT.md`, or dispatch configuration.
- No approval request/signing implementation, key generation, trust-store
  provisioning, GitHub write, publisher token, PR, merge, or deployment. The
  approval authority must be outside the watcher profile; C2B may only verify
  read-only broker access to its public trust metadata.
- No Flutter code, app version bump, or product behavior change.

## Required acceptance tests

1. Missing or weak Windows identity/ACL/network/sandbox preflight blocks before
   reservation.
2. Broker named-pipe ACL/SID authentication rejects unapproved callers; the
   broker re-verifies the proof and source rather than trusting IPC fields.
3. A valid C1 capability reserves once; a second process receives a durable
   duplicate denial.
4. Changed repository/path/task ID/commit SHA/exact bytes/tree/manifest cannot
   reserve; a moved `main` is accepted only while the approved commit remains
   reachable under the explicit policy.
5. Malformed or caller-forged approval values cannot enter the reservation API.
6. Process termination before/after journal commit leaves a visible state and
   never silently replays the approval.
7. SQLite integrity, ACL, lock, disk-full, failed-commit, and ambiguous-commit
   cases block execution and require human recovery.
8. Restart with `RESERVED` or `RUNNING` requires human recovery and a new
   approval for another attempt.
9. Executor identity cannot read trust material, watcher credentials, or
   publisher credentials and cannot escape the work root.
10. Codex network and sandbox preflight failures block; no bypass flag is
    accepted.
11. Audit output is bounded and contains no secret, signature, proof, or task
    full text.
12. C2B performs no GitHub write or PR creation; existing watcher and C1
    security tests remain green.

## Delivery gate

Dedicated branch and PR only. Report exact Windows identity/ACL/durability
evidence, tests, unresolved risks, and why execution remains disabled. Any
future Codex invocation requires a separate explicit task after this library
is reviewed.
