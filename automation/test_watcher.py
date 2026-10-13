from __future__ import annotations

import json
import os
import tempfile
import threading
import time
import unittest
from pathlib import Path

from watcher import (
    CURRENT_PATH,
    FileLock,
    LocalStore,
    RemoteFile,
    Watcher,
    WatcherError,
    classify_task,
    load_config,
    parse_front_matter,
    referenced_tasks,
)


CURRENT = """# Queue\n- [WATCHER-01B](WATCHER-01B.md)\n"""


def task(task_id: str = "WATCHER-01B", status: str = "MANUAL_READY", execution: str = "manual_bootstrap_only") -> str:
    return f"---\ntask_id: {task_id}\nstatus: {status}\nexecution: {execution}\n---\n\n# Task\n"


class MappingFetcher:
    def __init__(self, files: dict[str, str | tuple[str, str]]):
        self.files = files

    def fetch(self, path: str) -> RemoteFile:
        value = self.files[path]
        if isinstance(value, tuple):
            sha, text = value
        else:
            sha, text = f"sha-{path}", value
        return RemoteFile(path, sha, text)


class WatcherTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.store = LocalStore(Path(self.temp.name))
        self.config = {"repo": "bandora78/pingplace", "branch": "main", "interval_minutes": 15, "dispatch_enabled": False}

    def tearDown(self) -> None:
        self.temp.cleanup()

    def watcher(self, files: dict[str, str | tuple[str, str]]) -> Watcher:
        return Watcher(self.config, self.store, MappingFetcher(files))

    def test_no_tasks(self) -> None:
        records = self.watcher({CURRENT_PATH: "# Queue\n"}).check()
        self.assertEqual(records, [])
        self.assertEqual(self.store.read_state()["last_result"], "ok")

    def test_draft_and_manual_ready_are_not_eligible(self) -> None:
        records = self.watcher({CURRENT_PATH: CURRENT, "tasks/WATCHER-01B.md": task()}).check(dry_run=True)
        self.assertFalse(records[0].eligible)
        self.assertIn("MANUAL_READY", records[0].reason)
        self.assertFalse(self.store.state_path.exists())

    def test_approved_without_independent_proof_is_not_eligible(self) -> None:
        records = self.watcher({CURRENT_PATH: CURRENT, "tasks/WATCHER-01B.md": task(status="APPROVED", execution="automatic_after_verified_approval")}).check()
        self.assertFalse(records[0].eligible)
        self.assertIn("independently verifiable", records[0].reason)

    def test_invalid_metadata_is_rejected(self) -> None:
        with self.assertRaises(WatcherError):
            self.watcher({CURRENT_PATH: CURRENT, "tasks/WATCHER-01B.md": "# no front matter"}).check()

    def test_invalid_path_is_rejected(self) -> None:
        with self.assertRaises(WatcherError):
            referenced_tasks(RemoteFile(CURRENT_PATH, "sha", "[bad](../secrets.md)"))

    def test_remote_error_preserves_previous_task_state(self) -> None:
        self.watcher({CURRENT_PATH: CURRENT, "tasks/WATCHER-01B.md": task()}).check()
        with self.assertRaises(WatcherError):
            self.watcher({CURRENT_PATH: "[broken](tasks/MISSING.md)"}).check()
        state = self.store.read_state()
        self.assertEqual(state["last_result"], "error")
        self.assertEqual(state["detected_tasks"][0]["task_id"], "WATCHER-01B")

    def test_lock_blocks_concurrent_check(self) -> None:
        lock = self.store.acquire()
        lock.__enter__()
        try:
            with self.assertRaises(Exception):
                self.watcher({CURRENT_PATH: ""}).check()
        finally:
            lock.__exit__(None, None, None)

    def test_stale_lock_recovers(self) -> None:
        self.store.ensure_directory()
        self.store.lock_path.write_text(json.dumps({"pid": 999999, "started_at": "2000-01-01T00:00:00Z"}), encoding="utf-8")
        self.watcher({CURRENT_PATH: "# Queue\n"}).check()
        self.assertFalse(self.store.lock_path.exists())

    def test_corrupt_state_recovers(self) -> None:
        self.store.ensure_directory()
        self.store.state_path.write_text("{not-json", encoding="utf-8")
        self.watcher({CURRENT_PATH: "# Queue\n"}).check()
        self.assertEqual(self.store.read_state()["last_result"], "ok")

    def test_restart_status_and_next_check(self) -> None:
        self.watcher({CURRENT_PATH: "# Queue\n"}).check()
        restored = Watcher(self.config, self.store, None).status()
        self.assertEqual(restored["last_result"], "ok")
        self.assertIsNotNone(restored["next_scheduled_check"])

    def test_classification_never_dispatches(self) -> None:
        record = classify_task({"task_id": "X", "status": "APPROVED", "execution": "automatic_after_verified_approval"}, "sha", "tasks/X.md")
        self.assertFalse(record.eligible)

    def test_dispatch_enabled_config_is_rejected(self) -> None:
        config_path = Path(self.temp.name) / "dispatch.json"
        config_path.write_text(
            json.dumps(
                {
                    "repository": "bandora78/pingplace",
                    "branch": "main",
                    "check_interval_minutes": 15,
                    "dispatch_enabled": True,
                }
            ),
            encoding="utf-8",
        )
        with self.assertRaises(WatcherError):
            load_config(config_path)


if __name__ == "__main__":
    unittest.main()
