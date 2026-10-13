---
task_id: WATCHER-02
status: MANUAL_READY
execution: manual_bootstrap_only
base_branch: main
requires_review: true
---

# WATCHER-02 — GitHub API authentication, rate-limit handling and request reduction

## Background
On Windows 11, `python automation/watcher.py check` failed with `HTTP Error 403: rate limit exceeded` when reading `tasks/WATCHER-01B.md`. An unauthenticated `GET https://api.github.com/rate_limit` returned `core.limit=60, core.remaining=0, core.used=60`. The scheduled Stage B watcher runs every 15 minutes and must remain strictly read-only/non-dispatching.

## Objective
Make Stage B polling reliable under GitHub API limits while preserving least privilege and fail-closed behavior. Implement on a separate task branch and open a PR; do not merge or deploy automatically.

## Requirements
1. **Optional authenticated reads**: support a fine-grained GitHub token from a user-controlled environment/secure Windows credential mechanism, not from a committed config or command-line argument. Document the exact minimum permissions (repository Contents: Read-only; Metadata read). No token required for public repo fallback. Do not create, print, log, persist, or expose the token in status, errors, exceptions, process arguments, or tests. Document Task Scheduler environment/credential propagation and how to configure and rotate the token. Prefer an explicitly configured credential source; fail closed on invalid configured credentials instead of silently falling back to unauthenticated reads.
2. **Rate-limit awareness**: recognize primary limit (403/429, `X-RateLimit-Remaining: 0`, `X-RateLimit-Reset`) and secondary limit (`Retry-After` and response hints). Persist a bounded retry-not-before time in local watcher state and avoid outbound calls during cooldown, including manually invoked `check` unless an explicit safe diagnostic command is used. Never busy-loop or hammer API; no token leakage in logs. Honor conservative fallback when headers are absent/malformed. Report `rate_limited` vs other errors distinctly.
3. **Request minimization**: pin one immutable remote main revision per check. If unchanged from last successfully validated revision, reuse bounded cached task metadata/content safely, without weakening validation or confusing errors with success. If changed, fetch and validate fresh files at the pinned SHA. Use conditional requests/ETags where practical, but avoid cache behavior that can authorize stale tasks. Cache is for Stage B display/detection only, never authorization or approval proof.
4. **Safe status and scheduling**: show last check, last successful revision, cooldown/reset UTC, auth mode (not secret), and number of GitHub requests if useful. Preserve current `check`, `status`, `dry-run` interface or document backward-compatible changes. Do not change Task Scheduler cadence (15 min), overlap policy, wake behavior, or permissions.
5. **Failure behavior**: network failure, auth rejection, corrupted cache, unexpected GitHub JSON, inconsistent pinned SHA, and rate-limit responses must be visible and fail closed. Never claim a stale cached result is a new successful remote validation. Ensure status still works offline.

## Security boundaries
- Do not modify `automation/approval_gate.py` or integrate WATCHER-C1 with Stage B.
- Keep `dispatch_enabled: false`, `eligible: false`, and no Codex invocation, GitHub writes, PR creation, or auto-merge from watcher.
- Task files are untrusted data. Authentication grants API read access, not task approval.
- No Flutter app changes or version bump for watcher-only work.

## Tests / acceptance
- Unit tests: authenticated and anonymous requests, missing token, invalid configured token, token redaction in failures/logs, primary and secondary limits, missing/invalid reset headers, cooldown persistence across restart, manual check respecting cooldown, normal resume, unchanged revision cache, changed revision refresh, corrupt cache, offline status, and pinned-SHA consistency.
- Tests verify that the watcher does not dispatch or mutate GitHub and that scheduler config remains unchanged.
- Run Python watcher/security tests, Python compile, PowerShell `-ValidateOnly`, Stage B dry-run if safe and rate limit permits; existing Flutter tests/analyze/format as appropriate. Report exact executed tests, not assumed results.
- No secrets in PR, screenshots, terminal logs or artifacts.
- Open a separate PR from `agent/watcher-02` to `main`; no merge, scheduler installation, or live configuration changes.

## Deployment notes for human reviewer
Provide Windows PowerShell commands to configure secure read-only authentication for the scheduled user (without embedding secrets in task arguments), update local `main` after merge, and validate rate-limit behavior safely. If a secure credential path cannot be verified, leave anonymous mode supported and explicitly document the limitation.
