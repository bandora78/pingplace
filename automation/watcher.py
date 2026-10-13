#!/usr/bin/env python3
"""Read-only Stage B watcher for the PingPlace task queue.

This module deliberately has no process execution or GitHub write capability.
It reads task metadata, records local operational state, and explains why a
task is or is not eligible for a future stage. Stage B cannot dispatch tasks.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import sys
import tempfile
import time
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable, Iterable
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen


DEFAULT_CONFIG = Path(__file__).with_name("watcher_config.json")
CURRENT_PATH = "tasks/CURRENT.md"
TASK_PATH_RE = re.compile(r"^tasks/[A-Za-z0-9][A-Za-z0-9._-]*\.md$")
TASK_LINK_RE = re.compile(r"\[([A-Za-z0-9][A-Za-z0-9_-]*)\]\(([^)]+)\)")
FRONT_MATTER_RE = re.compile(r"^---\r?\n(.*?)\r?\n---(?:\r?\n|$)", re.DOTALL)
ALLOWED_STATUSES = {"DRAFT", "MANUAL_READY", "APPROVED", "BLOCKED", "FAILED", "IN_PROGRESS", "REVIEW", "DONE"}
ALLOWED_EXECUTION = {"manual_bootstrap_only", "automatic_after_verified_approval"}
MAX_LOG_BYTES = 512 * 1024
MAX_LOG_LINES = 500
LOCK_MAX_AGE_SECONDS = 2 * 60 * 60


class WatcherError(Exception):
    """Expected operational or validation failure."""


class LockBusy(WatcherError):
    """Another watcher operation owns the local lock."""


@dataclass(frozen=True)
class RemoteFile:
    path: str
    sha: str
    text: str


@dataclass(frozen=True)
class TaskRecord:
    task_id: str
    path: str
    status: str
    execution: str
    sha: str
    eligible: bool
    reason: str

    def as_dict(self) -> dict[str, Any]:
        return {
            "task_id": self.task_id,
            "path": self.path,
            "status": self.status,
            "execution": self.execution,
            "sha": self.sha,
            "eligible": self.eligible,
            "reason": self.reason,
        }


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def iso_timestamp(value: datetime | None = None) -> str:
    return (value or utc_now()).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_timestamp(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def redacted_error(error: BaseException) -> str:
    message = str(error)
    for secret_name in ("GITHUB_TOKEN", "GH_TOKEN"):
        secret = os.environ.get(secret_name)
        if secret:
            message = message.replace(secret, "<redacted>")
    message = re.sub(r"(?i)(authorization|token|password)=?[^\s,;]+", r"\1=<redacted>", message)
    return message[:500]


def state_directory() -> Path:
    local_app_data = os.environ.get("LOCALAPPDATA")
    if local_app_data:
        return Path(local_app_data) / "PingPlaceWatcher"
    return Path.home() / ".local" / "share" / "PingPlaceWatcher"


def load_config(path: Path) -> dict[str, Any]:
    try:
        config = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise WatcherError(f"Cannot read config: {redacted_error(error)}") from error
    if not isinstance(config, dict):
        raise WatcherError("Config must be a JSON object")
    repo = config.get("repo")
    branch = config.get("branch")
    interval = config.get("interval_minutes")
    if not isinstance(repo, str) or not re.fullmatch(r"[^/\s]+/[^/\s]+", repo):
        raise WatcherError("Config repo must be owner/name")
    if not isinstance(branch, str) or not branch:
        raise WatcherError("Config branch is required")
    if not isinstance(interval, int) or interval < 1:
        raise WatcherError("Config interval_minutes must be a positive integer")
    if config.get("dispatch_enabled") is not False:
        raise WatcherError("Stage B requires dispatch_enabled: false")
    return config


class LocalStore:
    def __init__(self, directory: Path):
        self.directory = directory
        self.state_path = directory / "state.json"
        self.log_path = directory / "watcher.log"
        self.lock_path = directory / "watcher.lock"

    def ensure_directory(self) -> None:
        self.directory.mkdir(parents=True, exist_ok=True)

    def read_state(self) -> dict[str, Any]:
        if not self.state_path.exists():
            return {"state_version": 1, "detected_tasks": []}
        try:
            value = json.loads(self.state_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            corrupt = self.state_path.with_name(f"state.corrupt.{int(time.time())}.json")
            try:
                self.state_path.replace(corrupt)
            except OSError:
                pass
            self.log("state_corrupt", {"error": redacted_error(error)})
            return {"state_version": 1, "detected_tasks": [], "last_error": "Local state was corrupt and was reset"}
        return value if isinstance(value, dict) else {"state_version": 1, "detected_tasks": []}

    def write_state(self, state: dict[str, Any]) -> None:
        self.ensure_directory()
        temporary = self.state_path.with_suffix(".tmp")
        temporary.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        os.replace(temporary, self.state_path)

    def log(self, event: str, details: dict[str, Any] | None = None) -> None:
        self.ensure_directory()
        record = {"timestamp": iso_timestamp(), "event": event}
        if details:
            record.update(details)
        with self.log_path.open("a", encoding="utf-8") as stream:
            stream.write(json.dumps(record, sort_keys=True) + "\n")
        self._bound_log()

    def _bound_log(self) -> None:
        try:
            if self.log_path.stat().st_size <= MAX_LOG_BYTES:
                return
            lines = self.log_path.read_text(encoding="utf-8").splitlines()[-MAX_LOG_LINES:]
            temporary = self.log_path.with_suffix(".tmp")
            temporary.write_text("\n".join(lines) + "\n", encoding="utf-8")
            os.replace(temporary, self.log_path)
        except OSError:
            pass

    def acquire(self) -> "FileLock":
        self.ensure_directory()
        return FileLock(self.lock_path)


class FileLock:
    def __init__(self, path: Path):
        self.path = path
        self.owned = False

    def __enter__(self) -> "FileLock":
        payload = {"pid": os.getpid(), "started_at": iso_timestamp()}
        for attempt in range(2):
            try:
                descriptor = os.open(self.path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
                with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                    json.dump(payload, stream)
                self.owned = True
                return self
            except FileExistsError:
                if attempt == 0 and self._stale():
                    try:
                        self.path.unlink()
                    except OSError:
                        pass
                    continue
                raise LockBusy("Another watcher operation is already running")
        raise LockBusy("Another watcher operation is already running")

    def _stale(self) -> bool:
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
            pid = int(data.get("pid", 0))
            started = parse_timestamp(data.get("started_at"))
            if started and (utc_now() - started).total_seconds() > LOCK_MAX_AGE_SECONDS:
                return True
            if pid <= 0:
                return True
            try:
                os.kill(pid, 0)
            except OSError:
                return True
            return False
        except (OSError, ValueError, TypeError, json.JSONDecodeError):
            return True

    def __exit__(self, *_: object) -> None:
        if self.owned:
            try:
                self.path.unlink()
            except FileNotFoundError:
                pass
            self.owned = False


class GitHubFetcher:
    def __init__(self, repo: str, branch: str, timeout: float = 20.0):
        self.repo = repo
        self.branch = branch
        self.timeout = timeout
        self.api_root = f"https://api.github.com/repos/{repo}/contents"

    def fetch(self, path: str) -> RemoteFile:
        if not valid_task_path(path) and path != CURRENT_PATH:
            raise WatcherError(f"Rejected remote path: {path}")
        url = f"{self.api_root}/{quote(path, safe='/')}?ref={quote(self.branch, safe='') }"
        request = Request(url, headers={"Accept": "application/vnd.github+json", "User-Agent": "PingPlaceWatcher/StageB"})
        token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
        if token:
            request.add_header("Authorization", f"Bearer {token}")
        try:
            with urlopen(request, timeout=self.timeout) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except (HTTPError, URLError, TimeoutError, OSError, json.JSONDecodeError) as error:
            raise WatcherError(f"GitHub read failed for {path}: {redacted_error(error)}") from error
        if not isinstance(payload, dict) or payload.get("type") != "file":
            raise WatcherError(f"GitHub response for {path} was not a file")
        try:
            text = base64.b64decode(payload["content"], validate=False).decode("utf-8")
            sha = str(payload["sha"])
        except (KeyError, TypeError, ValueError, UnicodeDecodeError) as error:
            raise WatcherError(f"Invalid GitHub file response for {path}: {redacted_error(error)}") from error
        return RemoteFile(path=path, sha=sha, text=text)


def valid_task_path(path: str) -> bool:
    return bool(TASK_PATH_RE.fullmatch(path)) and ".." not in Path(path).parts


def parse_front_matter(task: RemoteFile) -> dict[str, str]:
    match = FRONT_MATTER_RE.match(task.text)
    if not match:
        raise WatcherError(f"{task.path}: missing YAML front matter")
    values: dict[str, str] = {}
    for line in match.group(1).splitlines():
        if not line.strip():
            continue
        key, separator, raw_value = line.partition(":")
        if not separator or not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]*", key.strip()):
            raise WatcherError(f"{task.path}: invalid metadata line")
        value = raw_value.strip().strip("'\"")
        if key.strip() in values:
            raise WatcherError(f"{task.path}: duplicate metadata field {key.strip()}")
        values[key.strip()] = value
    for required in ("task_id", "status", "execution"):
        if not values.get(required):
            raise WatcherError(f"{task.path}: missing metadata field {required}")
    expected_id = Path(task.path).stem
    if values["task_id"] != expected_id:
        raise WatcherError(f"{task.path}: task_id does not match filename")
    if values["status"] not in ALLOWED_STATUSES:
        raise WatcherError(f"{task.path}: unsupported status {values['status']}")
    if values["execution"] not in ALLOWED_EXECUTION:
        raise WatcherError(f"{task.path}: unsupported execution mode {values['execution']}")
    return values


def referenced_tasks(current: RemoteFile) -> list[tuple[str, str]]:
    references: list[tuple[str, str]] = []
    for match in TASK_LINK_RE.finditer(current.text):
        task_id, path = match.groups()
        # CURRENT.md is stored in tasks/, so ordinary Markdown links are
        # relative to that directory (for example WATCHER-01B.md).
        if "/" not in path and "\\" not in path and not path.startswith("."):
            path = f"tasks/{path}"
        if not valid_task_path(path):
            raise WatcherError(f"CURRENT.md: rejected task path {path}")
        references.append((task_id, path))
    return references


def classify_task(metadata: dict[str, str], sha: str, path: str) -> TaskRecord:
    status = metadata["status"]
    execution = metadata["execution"]
    if status != "APPROVED":
        eligible = False
        reason = f"status {status} is not dispatchable"
    elif execution != "automatic_after_verified_approval":
        eligible = False
        reason = f"execution mode {execution} is not automatic"
    else:
        eligible = False
        reason = "Stage B has no independently verifiable approval proof and cannot dispatch"
    return TaskRecord(metadata["task_id"], path, status, execution, sha, eligible, reason)


class Watcher:
    def __init__(self, config: dict[str, Any], store: LocalStore, fetcher: Any):
        self.config = config
        self.store = store
        self.fetcher = fetcher

    def check(self, dry_run: bool = False) -> list[TaskRecord]:
        with self.store.acquire():
            started = iso_timestamp()
            try:
                current = self.fetcher.fetch(CURRENT_PATH)
                records: list[TaskRecord] = []
                for linked_id, path in referenced_tasks(current):
                    remote_task = self.fetcher.fetch(path)
                    metadata = parse_front_matter(remote_task)
                    if metadata["task_id"] != linked_id:
                        raise WatcherError(f"{path}: link ID does not match task metadata")
                    records.append(classify_task(metadata, remote_task.sha, path))
                state = self.store.read_state()
                state.update({
                    "state_version": 1,
                    "last_check_started": started,
                    "last_check_finished": iso_timestamp(),
                    "last_result": "dry_run" if dry_run else "ok",
                    "last_error": None,
                    "remote_revision": current.sha,
                    "detected_tasks": [record.as_dict() for record in records],
                    "dispatch_enabled": False,
                    "next_check_basis": "estimate_from_last_check_plus_interval",
                })
                if not dry_run:
                    self.store.write_state(state)
                self.store.log("dry_run_completed" if dry_run else "check_completed", {"task_count": len(records), "eligible_count": 0})
                return records
            except Exception as error:
                message = redacted_error(error)
                state = self.store.read_state()
                state.update({
                    "state_version": 1,
                    "last_check_started": started,
                    "last_check_finished": iso_timestamp(),
                    "last_result": "error",
                    "last_error": message,
                    "dispatch_enabled": False,
                })
                if not dry_run:
                    self.store.write_state(state)
                self.store.log("dry_run_failed" if dry_run else "check_failed", {"error": message})
                raise WatcherError(message) from error

    def status(self) -> dict[str, Any]:
        state = self.store.read_state()
        finished = parse_timestamp(state.get("last_check_finished"))
        next_check = finished + timedelta(minutes=self.config["interval_minutes"]) if finished else None
        state["next_scheduled_check"] = iso_timestamp(next_check) if next_check else None
        state["next_check_basis"] = "estimate_from_last_check_plus_interval" if finished else "unavailable"
        state["dispatch_enabled"] = False
        return state


def print_records(records: Iterable[TaskRecord], prefix: str = "") -> None:
    records = list(records)
    if not records:
        print(f"{prefix}No referenced tasks found.")
        return
    for record in records:
        print(f"{prefix}{record.task_id}: status={record.status}, eligible=NO, reason={record.reason}")


def print_status(value: dict[str, Any]) -> None:
    for key in (
        "last_check_finished", "next_scheduled_check", "next_check_basis",
        "last_result", "last_error", "remote_revision", "dispatch_enabled",
    ):
        print(f"{key}: {value.get(key)}")
    tasks = value.get("detected_tasks") or []
    print(f"detected_tasks: {len(tasks)}")
    for task in tasks:
        print(f"  {task.get('task_id')}: {task.get('status')} ({task.get('reason')})")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Read-only PingPlace Stage B watcher")
    parser.add_argument("command", choices=("check", "status", "dry-run"))
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--state-dir", type=Path, default=None)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        config = load_config(args.config)
        store = LocalStore(args.state_dir or state_directory())
        if args.command == "status":
            print_status(Watcher(config, store, None).status())
            return 0
        fetcher = GitHubFetcher(config["repo"], config["branch"])
        watcher = Watcher(config, store, fetcher)
        records = watcher.check(dry_run=args.command == "dry-run")
        print_records(records, prefix="DRY RUN: " if args.command == "dry-run" else "")
        print("Dispatch: disabled (Stage B read-only watcher)")
        return 0
    except LockBusy as error:
        print(f"watcher busy: {error}", file=sys.stderr)
        return 3
    except WatcherError as error:
        print(f"watcher error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
