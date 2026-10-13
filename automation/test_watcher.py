from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from datetime import datetime, timezone
from unittest.mock import patch
from urllib.error import HTTPError
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
    GitHubFetcher,
    RateLimited,
    iso_timestamp,
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

    def __init__(self, files: dict[str, str | tuple[str, str]]):
        super().__init__(files)
        self.fetch_count = 0

    def begin_read_cycle(self) -> str:
        return self.snapshot

    def fetch(self, path: str) -> RemoteFile:
        self.fetch_count += 1
        return super().fetch(path)


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

    def test_unchanged_revision_reuses_bounded_cache(self) -> None:
        fetcher = SnapshotMappingFetcher({CURRENT_PATH: CURRENT, "tasks/WATCHER-01B.md": task()})
        Watcher(self.config, self.store, fetcher).check()
        first_count = fetcher.fetch_count
        Watcher(self.config, self.store, fetcher).check()
        self.assertEqual(fetcher.fetch_count, first_count)
        self.assertEqual(self.store.read_state()["last_result"], "ok_cached")

    def test_changed_revision_refreshes_cache(self) -> None:
        fetcher = SnapshotMappingFetcher({CURRENT_PATH: CURRENT, "tasks/WATCHER-01B.md": task()})
        Watcher(self.config, self.store, fetcher).check()
        fetcher.snapshot = "abcdefabcdefabcdefabcdefabcdefabcdefabcd"
        Watcher(self.config, self.store, fetcher).check()
        self.assertGreater(fetcher.fetch_count, 2)
        self.assertEqual(self.store.read_state()["last_successful_revision"], fetcher.snapshot)

    def test_corrupt_cache_fails_closed_for_same_revision(self) -> None:
        fetcher = SnapshotMappingFetcher({CURRENT_PATH: CURRENT, "tasks/WATCHER-01B.md": task()})
        Watcher(self.config, self.store, fetcher).check()
        self.store.cache_path.write_text("{broken", encoding="utf-8")
        with self.assertRaises(WatcherError):
            Watcher(self.config, self.store, fetcher).check()
        self.assertEqual(self.store.read_state()["last_result"], "error")

    def test_rate_limit_cooldown_persists_and_blocks_manual_check(self) -> None:
        now = time.time() + 600
        retry_not_before = iso_timestamp(datetime.fromtimestamp(now, timezone.utc))
        self.store.write_state({
            "state_version": 1,
            "detected_tasks": [],
            "retry_not_before": retry_not_before,
            "last_successful_revision": "0123456789abcdef0123456789abcdef01234567",
        })
        with self.assertRaises(WatcherError):
            self.watcher({CURRENT_PATH: "# Queue\n"}).check()
        state = self.store.read_state()
        self.assertEqual(state["retry_not_before"], retry_not_before)
        self.assertEqual(state["last_successful_revision"], "0123456789abcdef0123456789abcdef01234567")
        self.assertEqual(state["last_result"], "rate_limit_cooldown")
        self.assertIsNotNone(state["last_check_finished"])

    def test_permission_403_with_retry_after_is_not_rate_limited(self) -> None:
        fetcher = GitHubFetcher("bandora78/pingplace", "main")
        error = HTTPError("https://api.github.com", 403, "forbidden", {"Retry-After": "7"}, None)
        try:
            with self.assertRaises(WatcherError) as raised:
                fetcher._raise_http_error(error, "main")
            self.assertIn("permission", str(raised.exception))
        finally:
            error.close()

    def test_configured_token_is_not_logged_or_used_as_anonymous(self) -> None:
        original = os.environ.get("PINGPLACE_GITHUB_TOKEN")
        os.environ["PINGPLACE_GITHUB_TOKEN"] = "secret-token-value"
        try:
            fetcher = GitHubFetcher("bandora78/pingplace", "main")
            self.assertEqual(fetcher.auth_mode, "bearer")
            self.assertEqual(fetcher.token, "secret-token-value")
            self.assertNotIn("secret-token-value", json.dumps(self.store.read_state()))
        finally:
            if original is None:
                os.environ.pop("PINGPLACE_GITHUB_TOKEN", None)
            else:
                os.environ["PINGPLACE_GITHUB_TOKEN"] = original

    def test_empty_configured_token_fails_closed(self) -> None:
        original = os.environ.get("PINGPLACE_GITHUB_TOKEN")
        os.environ["PINGPLACE_GITHUB_TOKEN"] = ""
        try:
            with self.assertRaises(WatcherError):
                GitHubFetcher("bandora78/pingplace", "main")
        finally:
            if original is None:
                os.environ.pop("PINGPLACE_GITHUB_TOKEN", None)
            else:
                os.environ["PINGPLACE_GITHUB_TOKEN"] = original

    def test_invalid_configured_token_fails_without_anonymous_fallback(self) -> None:
        original = os.environ.get("PINGPLACE_GITHUB_TOKEN")
        os.environ["PINGPLACE_GITHUB_TOKEN"] = "invalid-token"
        error = HTTPError("https://api.github.com", 401, "bad credentials", {}, None)
        try:
            fetcher = GitHubFetcher("bandora78/pingplace", "main")
            with patch("watcher.urlopen", side_effect=error):
                with self.assertRaises(WatcherError) as raised:
                    fetcher._get_json("https://api.github.com/test", "test")
            self.assertIn("authentication", str(raised.exception))
            self.assertEqual(fetcher.auth_mode, "bearer")
            self.assertEqual(fetcher.request_count, 1)
        finally:
            error.close()
            if original is None:
                os.environ.pop("PINGPLACE_GITHUB_TOKEN", None)
            else:
                os.environ["PINGPLACE_GITHUB_TOKEN"] = original

    def test_primary_rate_limit_uses_reset_header(self) -> None:
        fetcher = GitHubFetcher("bandora78/pingplace", "main")
        error = HTTPError("https://api.github.com", 403, "forbidden", {"X-RateLimit-Remaining": "0", "X-RateLimit-Reset": str(int(time.time()) + 120)}, None)
        try:
            with self.assertRaises(RateLimited) as raised:
                fetcher._raise_http_error(error, "main")
            self.assertEqual(raised.exception.kind, "primary")
        finally:
            error.close()

    def test_secondary_rate_limit_uses_retry_after(self) -> None:
        fetcher = GitHubFetcher("bandora78/pingplace", "main")
        error = HTTPError("https://api.github.com", 403, "secondary rate limit", {"Retry-After": "7"}, None)
        try:
            with self.assertRaises(RateLimited) as raised:
                fetcher._raise_http_error(error, "main")
            self.assertEqual(raised.exception.kind, "secondary")
        finally:
            error.close()

    def test_malformed_rate_limit_reset_uses_bounded_fallback(self) -> None:
        fetcher = GitHubFetcher("bandora78/pingplace", "main")
        error = HTTPError("https://api.github.com", 403, "forbidden", {"X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "not-a-timestamp"}, None)
        try:
            with self.assertRaises(RateLimited) as raised:
                fetcher._raise_http_error(error, "main")
            self.assertGreater(raised.exception.retry_not_before.timestamp(), time.time() + 14 * 60)
        finally:
            error.close()


if __name__ == "__main__":
    unittest.main()
