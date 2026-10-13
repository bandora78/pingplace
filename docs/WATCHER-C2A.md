# WATCHER-C2A — Secure Executor Boundary Design

Status: design only. This document does not authorize execution, install a
scheduled task, create approval proofs, add signing keys, enable dispatch, or
change the existing Stage B/C1 behavior.

## 1. Security decision

The executor must be a separate Windows security principal and a separate
process boundary from all approval material and publisher credentials. A
same-user Codex process with unrestricted access to the developer profile is
not an acceptable boundary. Until the prerequisites in Section 13 are
demonstrated on Windows 11, the only permitted behavior remains:

- Stage B watcher: read-only GitHub polling, local state/logs, `dispatch_enabled:
  false`, no Codex invocation.
- C1 verifier: read-only proof verification and immutable-source resolution.
- Approval request: blocked; no proof or key creation.
- Reservation library: not wired to the watcher or scheduler.
- No automatic execution, GitHub writes, PR creation, merge, or deployment.

This is intentionally a design for a future manually enabled C2B test task,
not an activation plan for the current workstation.

## 2. Goals and non-goals

### Goals

1. Execute one explicitly reserved, independently approved task in a bounded
   Windows identity and filesystem boundary.
2. Re-verify the exact task bytes and immutable GitHub commit immediately before
   execution.
3. Make approval consumption durable, single-use, crash-visible, and replay
   resistant.
4. Keep the read-only watcher, approval verifier, human signer, executor, and
   publisher independently controllable and auditable.
5. Fail closed on missing identity separation, ACL uncertainty, network/auth
   uncertainty, source changes, crashes, timeouts, unexpected files, or quality
   gate failures.

### Non-goals

- Enabling automatic Codex dispatch or changing the 15-minute Task Scheduler
  installation.
- Creating or provisioning signing keys or approval proofs in C2A.
- Automatic merge, auto-merge, GitHub task-status writes, or deployment.
- Granting Codex access to the approval trust store, private signer material,
  publisher credentials, or the user's normal worktree.
- Replacing C1's RSA verification or weakening its fail-closed decisions.

## 3. Trust model and boundaries

GitHub task files, branches, pull requests, issue comments, local task
worktrees, and Codex output are untrusted data. A YAML `status: APPROVED`, a
plain hash, or a file placed by the executor is never authority.

```text
                    untrusted / read-only source
          +---------------------------------------------+
          | GitHub main, immutable commit, task bytes   |
          +----------------------+----------------------+
                                 | HTTPS read, pinned SHA
                                 v
 +------------------+     +-----+---------------------+
 | Stage B Watcher  |---->| C1 source-bound verifier  |
 | read-only        |     | proof + trust policy      |
 | no dispatch      |     | no execution              |
 +------------------+     +-------------+-------------+
                                       | capability only
                                       | (not a boolean)
                                       v
                         +-------------+--------------+
                         | Reservation Broker        |
                         | protected SQLite journal   |
                         | atomic single-use claim    |
                         +-------------+--------------+
                                       | one reserved run
                                       v
       human-controlled signer          +-----------------------------+
 +-----------------------------+       | Executor Supervisor          |
 | separate identity/device   |       | dedicated non-admin Windows  |
 | holds approval authority   |       | account + restricted token   |
 | cannot be Codex process    |       | private workspace/job object |
 +-------------+---------------+       +---------------+-------------+
               | signed proof                           | no approval store,
               |                                        | no publisher secret
               v                                        v
      protected trust store                    +--------+--------+
      read-only to verifier                    | Codex worker   |
      inaccessible to executor                 | sandboxed      |
                                                 | task only       |
                                                 +--------+--------+
                                                          | proposed diff only
                                                          v
                         +----------------+       +-------+--------+
                         | Human review   |<------+ Publisher     |
                         | / PR review   |       | separate      |
                         +----------------+       | credential    |
                                                  | no merge       |
                                                  +----------------+
```

The trust boundary is not achieved by Python modules or process names alone.
It requires Windows identities, ACLs, process-token inspection, and a tested
credential boundary. A restricted Codex sandbox is defense in depth, not a
replacement for identity separation.

## 4. Windows 11 execution design

### 4.1 Identities

Use three distinct control roles:

1. **Watcher identity** — the existing normal user Task Scheduler principal.
   It may read public/authenticated GitHub metadata and write its own bounded
   operational state. It cannot invoke Codex, write approvals, or publish.
2. **Human signer identity** — a separate interactive human account or
   externally controlled signer. It owns approval authority and the trust-store
   provisioning path. It is not the Codex account and is not used by the
   watcher.
3. **Executor identity** — a dedicated, non-admin local Windows account with
   no interactive logon, no administrator group membership, no access to the
   human profile, signer material, trust-store write path, watcher credentials,
   or publisher credentials.

The executor account must be created and ACL-provisioned by a human outside
the future executor process. C2B must verify the account SID and group
membership at startup and abort if the identity is missing, interactive, or
privileged.

### 4.2 Filesystem layout and ACLs

Use a dedicated root outside the repository, for example:

```text
C:\ProgramData\PingPlaceExecutor\
  reservation\         SYSTEM + executor service; broker-controlled
  work\                 executor only; one run directory per reservation
  audit\                executor append path; auditor read path
  config\               SYSTEM/admin provisioned; executor read-only
  quarantine\           SYSTEM/admin review; executor write-only if needed

%LOCALAPPDATA%\PingPlaceWatcher\approval\
  trust.json             human signer/admin provisioned; verifier read-only
  proofs\                human signer provisioned; verifier read-only
```

The executor must not have read access to `trust.json`, proof files, signer
profiles, `%LOCALAPPDATA%\PingPlaceWatcher\state.json`, or the developer's
repository. The broker/supervisor must create a fresh empty worktree and set
explicit ACLs before any task bytes are copied. Inheritance must be disabled
where necessary and verified using `icacls` plus an access probe under the
executor identity. Deny ACLs are not the only control; remove unnecessary
allows and verify effective access.

The repository clone used to fetch source is a read-only broker-side staging
area. Codex receives only the exact task specification and the checked-out
source snapshot needed by the C2B allowlist. It does not receive the approval
proof, trust store, reservation secrets, watcher state, or publisher token.

### 4.3 Process and resource controls

The supervisor should launch the executor with `CreateProcessAsUser` or an
equivalent Windows-supported service boundary under the executor SID, using a
restricted token and a Windows Job Object. The job must have:

- a hard wall-clock timeout;
- process-tree termination on timeout/cancellation;
- bounded memory, process count, and output size where practical;
- no access to the interactive desktop or credential UI;
- an explicit current directory under the reservation work root;
- environment variables rebuilt from an allowlist, not inherited wholesale;
- no shell-expanded command string for task-controlled values.

The Codex invocation must use the installed CLI's supported sandbox and
approval flags. Never use `--dangerously-bypass-approvals-and-sandbox` or an
equivalent bypass. C2B must pin the exact CLI executable path/version and
abort if the sandbox contract cannot be inspected or enforced.

## 5. Network and credential boundaries

### Watcher

- GitHub read access only, with the existing configured environment credential
  behavior and redaction rules.
- No GitHub write scopes, no Codex token, no publisher token.
- Network failures and rate limits remain visible and fail closed.

### Verifier/broker

- May resolve the immutable GitHub commit and exact task blob over HTTPS.
- Uses a dedicated read-only credential or anonymous access as policy allows.
- Does not accept credentials from task bytes, proof fields, command-line task
  content, or the Codex environment.

### Codex worker

Default C2B policy is no network access. If a future task genuinely requires
network access, it must be a separately approved capability with an explicit
allowlist, proxy, time limit, and test; it must not inherit the user's proxy,
SSH agent, GitHub token, cloud credentials, or Windows credential manager
access.

### Publisher

Publishing is a separate, human-reviewed step. If C2B prepares a PR artifact,
the publisher helper runs outside the Codex token boundary with a narrowly
scoped GitHub credential. It may create a branch/PR only after allowlist and
quality checks, never merge, close, approve, change task status, or enable
dispatch. The token is injected only into the publisher process and is never
available to Codex or written to the worktree/logs.

## 6. Exact source and task verification

The C1 `verify_from_github` path remains the source of truth for a dispatchable
capability. C2B must perform the following sequence again immediately before
reservation/execution:

1. Validate repository, allowlisted `tasks/<name>.md` path, task ID, and
   40-hex immutable commit SHA.
2. Resolve the commit object through the GitHub commit API and require the
   returned commit SHA to equal the requested SHA.
3. Resolve the task path from that commit/tree/blob, not from a branch or a
   mutable local checkout. Reject symlink/submodule/tree ambiguity and any
   path traversal.
4. Decode the exact UTF-8 bytes returned by GitHub. Do not normalize line
   endings, Unicode, BOMs, whitespace, YAML, or Markdown.
5. Compute SHA-256 over those exact bytes and require equality with both the
   proof's `task_sha256` and the verifier's source result.
6. Require the proof's repository, path, task ID, commit SHA, approver ID,
   approval time, and unique approval ID to match the verified source and
   policy. C1 must still reject unauthorized, revoked, expired, malformed, or
   invalidly signed proofs.
7. Pass a non-forgeable `VerifiedApproval` capability to the reservation
   broker. Do not pass a caller-created `VerificationResult(allowed=True)` or
   a boolean.
8. Re-resolve or compare the same immutable source immediately before the
   worker starts. Any mismatch aborts and leaves the approval unusable.

The local worktree is an execution substrate, never the authority for task
identity or approval. A task edit after approval, a branch movement, a changed
blob, or a different repository/path must require a new approval.

## 7. Durable reservation, single use, and crash recovery

C1's current reservation helper is deliberately not activated because Windows
directory durability and identity separation are not demonstrated. C2B should
introduce a protected reservation journal rather than silently relying on a
file-existence flag.

### 7.1 Journal record

Use a standard-library SQLite database under the protected `reservation`
directory, with `PRAGMA journal_mode=DELETE` and `PRAGMA synchronous=FULL`.
The journal schema should have a unique primary key on `approval_id` and bind:

- repository, task ID, path, immutable commit SHA, exact task SHA-256;
- approver ID and approval time;
- reservation ID, executor SID, created/started/finished timestamps;
- state: `RESERVED`, `RUNNING`, `SUCCEEDED`, `FAILED`, `ABANDONED`;
- process/job identity and bounded diagnostic reason;
- result commit/diff digest when a run produces one.

### 7.2 Atomic claim

Within `BEGIN IMMEDIATE`, verify the source-bound capability and insert the
approval ID if absent. A duplicate approval ID, even with matching content,
returns `ALREADY_RESERVED` and cannot be reused. Commit with FULL durability,
close the connection, and only then launch the job. A caller cannot choose a
different task scope for an existing approval ID.

### 7.3 Crash behavior

- Crash before commit: no reservation exists; no executor may have been
  launched.
- Crash after commit before launch: the journal remains `RESERVED`; startup
  reports an orphan and does not auto-run it.
- Crash during launch or execution: transition to `RUNNING` is durable; a
  supervisor heartbeat/job check records `ABANDONED` after a human-reviewed
  recovery decision. It is never silently retried.
- Crash after success but before reporting: the durable terminal state and
  result digest remain authoritative; repeated callbacks return the stored
  result and cannot rerun the approval.
- Any recovery action that wants another attempt requires a new approval ID,
  new approval time, and new exact source verification.

This is conservative recovery: it may require manual cleanup after a power
loss, but it prevents replay. No lease expiry may turn a previously consumed
approval back into an executable approval.

### 7.4 Concurrency

The SQLite unique constraint and `BEGIN IMMEDIATE` transaction are the primary
cross-process control. A named Windows mutex or existing OS file lock may
reduce contention, but correctness must not depend on a best-effort PID file.
Tests must run two independent processes against the same journal and prove
one winner, one durable denial, and no duplicate Codex launch.

## 8. Audit logging and failure handling

Write bounded structured audit records outside the repository. Records contain
IDs, digests, immutable SHAs, actor/SID labels, state transitions, and reason
codes—not tokens, approval signatures, private paths, task full text, or
location data. Suggested events:

`SOURCE_RESOLVED`, `PROOF_VERIFIED`, `PROOF_DENIED`, `RESERVATION_CREATED`,
`RESERVATION_DUPLICATE`, `EXECUTOR_STARTED`, `EXECUTOR_BLOCKED`,
`EXECUTOR_TIMEOUT`, `EXECUTOR_CRASHED`, `EXECUTOR_EXITED`, `DIFF_REJECTED`,
`QUALITY_GATE_FAILED`, `PUBLISH_PREPARED`, `PUBLISH_BLOCKED`, `RECOVERY_REQUIRED`.

Use a monotonically increasing sequence and hash-chain fields for operator
diagnostics, but do not claim tamper-proof audit without protected storage and
an independent reader. Rotate by byte count/record count and preserve the
terminal record for every reservation. Audit write failure is a hard failure
for execution and must not be hidden.

Failure policy is fail closed:

| Condition | Action |
|---|---|
| Missing/weak identity or ACL proof | Block before reservation |
| Missing/invalid/revoked/expired proof | Deny; no worker |
| GitHub network/auth/source mismatch | Deny; preserve evidence; no worker |
| Duplicate approval ID | Deny; no retry |
| Reservation durability uncertainty | Deny; no worker |
| Codex CLI/sandbox mismatch | Deny; no worker |
| Timeout, crash, power loss | Mark orphan/abandoned; require new human approval |
| Unexpected file/diff or quality failure | Quarantine; no publish/merge |
| Audit write failure or secret-leak detection | Terminate run; block publish |

## 9. Diff and publisher controls

After Codex exits, a broker outside the worker identity must inspect the
worktree. It must reject changes outside the approved task's explicit file
allowlist and repository policy, generated credentials, symlinks/reparse
points, executable artifacts, keystores, private keys, or changes to watcher
security boundaries unless separately approved. It must run the required
quality gates in a clean process and record their exact exit codes.

The result is a reviewable branch/PR artifact only. Human review remains
required. There is no automatic merge, auto-approval, task-status update,
scheduled-task update, or dispatch enablement.

## 10. Negative security test matrix

| Area | Test | Expected result |
|---|---|---|
| Source | branch moves after proof | commit mismatch; deny |
| Source | one-byte task edit, CRLF/LF change, BOM/Unicode change | digest mismatch; deny |
| Source | changed repo, path, task ID, tree type, symlink, submodule | explicit deny |
| Proof | bad signature, wrong key, revoked/unknown approver, expired/future proof | deny; no reservation |
| Proof | proof file altered, duplicated approval ID, forged allowed boolean | deny |
| Identity | executor can read/write trust store or proof | preflight blocks; no worker |
| Identity | executor is admin, interactive, or shares signer SID | preflight blocks |
| Filesystem | repository/worktree escape, `..`, junction/reparse-point escape | deny and quarantine |
| Credentials | Codex sees watcher/GitHub/publisher token or inherited env secret | preflight/test fails closed |
| Network | Codex attempts network, proxy, localhost credential endpoint | blocked and audited |
| Reservation | two processes reserve same approval concurrently | exactly one winner |
| Reservation | crash before/after commit, during launch, after success | durable state; no replay |
| Reservation | restart sees `RESERVED`/`RUNNING` orphan | recovery required; no auto-retry |
| Executor | missing CLI, changed CLI hash, sandbox bypass, timeout, crash | no execution or terminal failure; no publish |
| Output | unexpected file, private key, symlink, disallowed diff | reject/quarantine |
| Audit | oversized log, audit write failure, token in exception/output | bounded/blocked; secret absent |
| Publisher | missing scope, attempted merge/status/dispatch write | blocked; no GitHub write |

Positive tests must also prove that a valid, independently provisioned
source-bound capability can reserve once, execute only inside the intended
root, produce an allowlisted diff, and remain review-only. These tests must
run in a disposable Windows environment with test identities; they must not
use production credentials or enable the scheduler.

## 11. Phased implementation plan

### Phase C2A — design and prerequisites (this task)

- Publish this architecture, trust boundaries, threat model, test matrix, and
  C2B task.
- Keep C1 approval creation, reservation activation, and Stage B dispatch
  disabled.
- Acceptance: documentation reviewed; no code/config/scheduler changes; open
  decisions recorded.

### Phase C2B — preflight and durable reservation library

- Implement the isolated preflight, SQLite reservation state machine, audit
  journal, and exact-source handoff API.
- Add Windows identity/ACL/access-probe tests using disposable accounts.
- Do not invoke Codex or publisher and do not wire the watcher.
- Acceptance: negative matrix passes; crash/concurrency tests demonstrate one
  durable winner and no replay; C1 tests remain unchanged and green.

### Phase C2C — manual isolated executor proof

- Human explicitly starts one fixed test task under the executor identity.
- Run Codex with no publisher credential and no network, in a disposable
  worktree/job object.
- Produce only a local report and rejected/accepted diff artifact for review.
- Acceptance: physical Windows evidence for SID/ACL/token/network/job limits,
  timeout/crash recovery, and secret absence; no GitHub writes.

### Phase C2D — separately reviewed publisher preparation

- Add a human-invoked publisher helper with a separate narrowly scoped token.
- It may prepare a PR but cannot merge, approve, update task status, or enable
  dispatch.
- Acceptance: GitHub audit confirms no unauthorized writes and human review
  remains required.

Automatic scheduling/dispatch is intentionally not a C2A/C2B deliverable.
Any future activation requires a new explicit task and independent security
review.

## 12. Acceptance criteria for the C2A design

- All six requested boundaries are documented with Windows-specific controls.
- Exact bytes, immutable revision, approval identity, and source re-check are
  explicit.
- Reservation crash/replay/concurrency behavior is deterministic and fail
  closed.
- C1 remains the verifier authority; no proof/key generation is introduced.
- Negative tests cover tampering, crashes, concurrency, replay, permissions,
  credentials, network, and audit failures.
- Open prerequisites and risks are explicit.
- Only documentation/planning files are changed in the C2A branch.

## 13. Unresolved security decisions and activation prerequisites

The following are open and block any executor activation:

1. **Independent signer identity:** choose and demonstrate a signer account or
   external device that the executor cannot control.
2. **Windows ACL evidence:** provision the executor account and attach
   `icacls`/effective-access evidence for trust store, proofs, watcher state,
   repository, publisher secret, and work root.
3. **Codex sandbox contract:** record the installed CLI version, supported
   Windows sandbox controls, and proof that bypass flags are rejected.
4. **Network enforcement:** choose Windows Firewall/AppContainer/proxy policy
   and demonstrate that Codex cannot reach GitHub, localhost credential
   endpoints, or inherited proxy services.
5. **Publisher credential custody:** define the separate process/account and
   exact GitHub scopes for PR preparation; no merge or task-status scope.
6. **Durability evidence:** demonstrate SQLite FULL transactions and recovery
   across process kill and power-loss simulation on the target filesystem.
7. **Audit custody/retention:** define the protected reader, rotation, and
   retention period without storing secrets or task full text.
8. **Human recovery policy:** define who may mark an orphan `ABANDONED` and how
   a new approval is obtained; no automatic replay.
9. **Operational consent:** explicitly approve a future C2B test task and
   install nothing as part of C2A.

Until all applicable decisions are resolved and independently reviewed, the
system must report `EXECUTOR_NOT_ACTIVATED` and remain read-only.
