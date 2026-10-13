# WATCHER-C1 approval gate

WATCHER-C1 adds a separate, read-only approval verifier. It does not authorize
the Stage B watcher to execute work. `automation/watcher.py` remains
non-dispatching and does not call this module.

## Proof and trust model

An approval proof is a JSON envelope signed with RSA-SHA256. The verifier
accepts only RSA keys of at least 2048 bits with exponent 65537. Its canonical
signed fields bind all of the following:

- repository (`bandora78/pingplace`)
- task ID and allowlisted path (`tasks/<task>.md`)
- immutable 40-character commit SHA
- SHA-256 of the exact UTF-8 task bytes
- approver identity
- UTC approval time
- unique approval ID

The verifier accepts a proof only when the task bytes and all supplied scope
values match, the approver is present and not revoked in the external trust
store, the signature is valid, and the approval is within the configured age.
Direct exact-byte verification is explicitly labelled local-only. A
dispatch-ready result can only come from `verify_from_github`, which first
resolves the commit object and requested file through GitHub's immutable commit
API and then verifies those returned bytes.
It returns explicit denial reasons such as `TASK_BYTES_MISMATCH`,
`COMMIT_SHA_MISMATCH`, `APPROVER_UNAUTHORIZED`, `APPROVAL_REVOKED`,
`APPROVAL_EXPIRED`, or `SIGNATURE_INVALID`.

The trust store and approval proofs belong outside the repository, for example
under `%LOCALAPPDATA%\PingPlaceWatcher\approval\`. They must be provisioned
and ACL-protected by a distinct human-controlled identity. The Codex execution
identity must not be able to write the trust store, replace public keys, issue
proofs, or alter approval files. The public key is not secret, but its
authorization to the verifier is security-sensitive.

This development workstation does not demonstrate that separation: a same-user
Codex process with unrestricted access to the user's files could read or alter
local approval material. Therefore approval issuing is deliberately disabled,
and no future dispatch or reservation path is enabled by C1. A plain hash,
YAML status, proof file, or repository change is never sufficient authority.

## Commands

Verify a proof without executing anything:

```powershell
python automation/approval_gate.py verify `
  --repository bandora78/pingplace `
  --path tasks/WATCHER-X.md `
  --commit-sha <40-hex-commit> `
  --proof-file $env:LOCALAPPDATA\PingPlaceWatcher\approval\proof.json `
  --trust-file $env:LOCALAPPDATA\PingPlaceWatcher\approval\trust.json
```

The interactive request utility displays the exact digest and scope and
requires a typed confirmation, but always exits blocked until an independently
controlled signer/executor boundary is deployed. It writes no proof or key:

```powershell
python automation/approval_gate.py request `
  --task-file .\tasks\WATCHER-X.md `
  --task-id WATCHER-X `
  --repository bandora78/pingplace `
  --path tasks/WATCHER-X.md `
  --commit-sha <40-hex-commit>
```

The module includes an atomic reservation library for a future executor. It is
not called by the verifier, watcher, CLI, or scheduler in C1. It accepts only
the source-bound capability returned by `verify_from_github`, not a caller-built
boolean/result or caller-selected scope. It stores one reservation file per
approval ID outside the repository using exclusive file creation, flushes and
fsyncs the file, and fsyncs the directory where supported. On this Windows
deployment directory fsync cannot be demonstrated, so reservations fail
closed with `RESERVATION_DURABILITY_UNVERIFIED`; no production guarantee is
claimed. A future executor must still run this library only after genuine
approver/executor isolation is deployed.

## Security limitations

- RSA verification is implemented with Python standard-library primitives; a
  vetted cryptographic provider may be preferred for a production deployment.
  Key provisioning, ACL enforcement, secure hardware, and independent identity
  are not established here.
- Direct local-byte verification is intentionally not dispatch-ready. The
  GitHub resolver verifies the commit object identity and fetches the requested
  path with `ref=<immutable commit SHA>`, but its network, TLS, GitHub account,
  and repository policy still require operational hardening.
- No revocation service, timestamp authority, or audit server is present.
  Revocation and expiry are evaluated from the external local trust/policy
  inputs only.
- Windows ACL/identity separation and directory durability are not verified;
  same-user Codex access to external approval material remains an inadequate
  security boundary.
- No Codex invocation, scheduler integration, GitHub write, merge, or automatic
  dispatch exists in C1.
