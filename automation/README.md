# PingPlace Watcher — Stage B

The Stage B watcher is deliberately read-only. It polls the public GitHub task
queue, validates task links and front matter, records local state/logs, and
explains dispatch eligibility. It cannot execute Codex, edit GitHub task
statuses, push code, create a PR, or dispatch implementation work.

## Prerequisites

- Windows 11
- Python 3.11+ on `PATH`
- Network access to GitHub; an optional `GITHUB_TOKEN` or `GH_TOKEN` may reduce
  API rate-limit pressure. Tokens are read from the environment and redacted
  from errors; do not put them in this repository.
- PowerShell for the optional Task Scheduler scripts

Run a single read-only check from the repository root:

```powershell
python automation/watcher.py check
python automation/watcher.py dry-run
python automation/watcher.py status
```

State and bounded logs are stored under
`%LOCALAPPDATA%\PingPlaceWatcher` on Windows. `status` computes the next check
as an estimate from the last completed check plus the configured 15-minute
interval; it is not a guarantee of Task Scheduler execution.

`dry-run` performs the same read-only GitHub validation but does not create or
update `state.json`. It intentionally appends one bounded diagnostic log entry
so a manual dry run is visible in local diagnostics.

## Optional safe installation

Review `install_watcher.ps1` before use. It prints the planned task settings
and requires typing `INSTALL`. It creates a normal-user task named
`PingPlaceWatcher`, invokes one check through `run_watcher.ps1`, repeats every
15 minutes, ignores overlapping instances, does not wake a sleeping PC, and
uses `StartWhenAvailable` so a missed run can occur after logon. It never runs
an infinite loop. Codex has not run the installer.

Validate the Task Scheduler parameters without installing anything:

```powershell
powershell -ExecutionPolicy Bypass -File .\automation\install_watcher.ps1 -ValidateOnly
```

```powershell
powershell -ExecutionPolicy Bypass -File .\automation\install_watcher.ps1
Get-ScheduledTask -TaskName PingPlaceWatcher
Get-ScheduledTaskInfo -TaskName PingPlaceWatcher
```

To remove it, explicitly run `uninstall_watcher.ps1` and type `UNINSTALL`.
Uninstalling does not delete local logs/state, so the last error and check
history remain available for diagnosis.

## Stage B safety boundary

Even an `APPROVED` status is reported as ineligible because independent,
revision-bound approval proof is not implemented in Stage B. This is
intentional. No watcher command has a dispatch path.

Each check first resolves one immutable commit SHA for `main`, then reads
`CURRENT.md` and all linked task files at that same SHA. Concurrent checks use
an OS-backed lock (`msvcrt` on Windows, `flock` elsewhere); a stale PID is never
used to delete an active lock. If the lock, log, or remote read cannot be
handled safely, the operation fails visibly.

WATCHER-C1's separate approval verifier is documented in
[APPROVAL_GATE.md](APPROVAL_GATE.md). It is read-only and disabled for approval
creation; Stage B polling never invokes it and never dispatches Codex.
