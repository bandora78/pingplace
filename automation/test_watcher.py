from __future__ import annotations

import json
import os
import subprocess
import sys
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
    MAX_LOG_BYTES,
    MAX_LOG_LINES,
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


class SnapshotMappingFetcher(MappingFetcher):
    snapshot = "0123456789abcdef0123456789abcdef01234567"

    def begin_read_cycle(self) -> str:
        return self.snapshot


class WatcherTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.store = LocalStore(Path(self.temp.name))
        self.config = {"repo": "bandora78/pingplace", "branch": "main", "interval_minutes": 15, "dispatch_enabled": False}

    def tearDown(self) -> None:
        self.temp.cleanup()

    def watcher(self, files: dict[str, str | tuple[str, str]]) -> Watcher:
        return Watcher(self.config, self.store, MappingFetcher(files))

    def snapshot_watcher(self, files: dict[str, str | tuple[str, str]]) -> Watcher:
        return Watcher(self.config, self.store, SnapshotMappingFetcher(files))

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

    def test_read_cycle_persists_one_remote_snapshot(self) -> None:
        self.snapshot_watcher({CURRENT_PATH: CURRENT, "tasks/WATCHER-01B.md": task()}).check()
        self.assertEqual(self.store.read_state()["remote_revision"], SnapshotMappingFetcher.snapshot)

    def test_invalid_metadata_is_rejected(self) -> None:
        with self.assertRaises(WatcherError):
            self.watcher({CURRENT_PATH: CURRENT, "tasks/WATCHER-01B.md": "# no front matter"}).check()

    def test_invalid_path_is_rejected(self) -> None:
        with self.assertRaises(WatcherError):
            referenced_tasks(RemoteFile(CURRENT_PATH, "sha", "[bad](../secrets.md)"))

    def test_duplicate_task_links_are_rejected(self) -> None:
        current = "[A](A.md)\n[A](A.md)\n"
        with self.assertRaises(WatcherError):
            referenced_tasks(RemoteFile(CURRENT_PATH, "sha", current))

    def test_malformed_task_link_is_rejected(self) -> None:
        current = "[not a task id](A.md)\n"
        with self.assertRaises(WatcherError):
            referenced_tasks(RemoteFile(CURRENT_PATH, "sha", current))

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

    def test_lock_blocks_a_competing_process(self) -> None:
        self.store.ensure_directory()
        helper = (
            "import sys,time; "
            "from pathlib import Path; "
            "from watcher import FileLock; "
            "lock=FileLock(Path(sys.argv[1])); lock.__enter__(); "
            "print('ready', flush=True); time.sleep(3)"
        )
        process = subprocess.Popen(
            [sys.executable, "-c", helper, str(self.store.lock_path)],
            cwd=Path(__file__).parent,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            self.assertEqual(process.stdout.readline().strip(), "ready")
            with self.assertRaises(Exception):
                self.store.acquire().__enter__()
        finally:
            process.terminate()
            process.wait(timeout=5)
            if process.stdout is not None:
                process.stdout.close()
            if process.stderr is not None:
                process.stderr.close()

    def test_log_is_bounded_by_bytes_and_lines(self) -> None:
        self.store.ensure_directory()
        self.store.log_path.write_text("x" * (MAX_LOG_BYTES + 10) + "\n", encoding="utf-8")
        for index in range(MAX_LOG_LINES + 20):
            self.store.log("event", {"index": index})
        self.assertLessEqual(self.store.log_path.stat().st_size, MAX_LOG_BYTES)
        self.assertLessEqual(len(self.store.log_path.read_text(encoding="utf-8").splitlines()), MAX_LOG_LINES)

    def test_lock_file_is_reusable_after_release(self) -> None:
        self.store.ensure_directory()
        self.store.lock_path.write_text(json.dumps({"pid": 999999, "started_at": "2000-01-01T00:00:00Z"}), encoding="utf-8")
        self.watcher({CURRENT_PATH: "# Queue\n"}).check()
        self.assertTrue(self.store.lock_path.exists())

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

    def test_dry_run_logs_without_persisting_state(self) -> None:
        self.watcher({CURRENT_PATH: CURRENT, "tasks/WATCHER-01B.md": task()}).check(dry_run=True)
        self.assertFalse(self.store.state_path.exists())
        self.assertIn("dry_run_completed", self.store.log_path.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
