from __future__ import annotations

import json
import multiprocessing
import sqlite3
import tempfile
import unittest
from pathlib import Path

from approval_gate import ApprovalPolicy, ApprovalVerifier, task_digest
from executor_boundary import (
    ApprovalBroker, AuditFailure, AuditLog, BoundaryPreflight, DurableReservationJournal,
    PreflightResult, RecoveryAuthority, ReservationStoreError, SourceManifest, SourceSnapshot,
)
from test_approval_gate import NOW, StaticResolver, TASK_BYTES, signed_proof

COMMIT = "a" * 40
TREE = "c" * 40
TASK_PATH = "tasks/WATCHER-X.md"
ALLOWED = (TASK_PATH, "README.md")


class TestOnlyPreflight(BoundaryPreflight):
    """Test-module-only fixture; no production import can supply this evidence."""
    def __init__(self): self.result = PreflightResult(True, "FIXTURE_ONLY", (), "S-1-5-21-executor", "S-1-5-21-broker", "S-1-5-21-supervisor")
    def check(self): return self.result


class TestOnlyRecoveryAuthority:
    def authorize(self, approval_id, current, target): return target == "ABANDONED" and bool(approval_id) and current in {"RESERVED", "RUNNING"}


class FixtureSource:
    def __init__(self, task_bytes=TASK_BYTES, reachable=True): self.task_bytes, self.reachable = task_bytes, reachable
    def resolve(self, repository, commit_sha, allowed_paths):
        files = {TASK_PATH: self.task_bytes, "README.md": b"fixture source\n"}
        return SourceSnapshot(repository, commit_sha, self.reachable, files, SourceManifest.create(TREE, files, allowed_paths))


def make_broker(directory, source=None, audit=None):
    preflight = TestOnlyPreflight()
    trust = {"human-reviewer": {"n": str(__import__("test_approval_gate").TEST_N), "e": 65537, "revoked": False}}
    verifier = ApprovalVerifier(trust, ApprovalPolicy("bandora78/pingplace", max_age=None))
    journal = DurableReservationJournal(Path(directory) / "reservation.sqlite", preflight)
    return ApprovalBroker(verifier, StaticResolver(), source or FixtureSource(), journal, preflight, audit or AuditLog(Path(directory) / "audit.jsonl"), "bandora78/pingplace", ALLOWED)


def reserve_process(path, output):
    journal = DurableReservationJournal(Path(path), TestOnlyPreflight())
    proof = signed_proof(TASK_BYTES, approval_id="00000000-0000-4000-8000-000000000001")
    capability = ApprovalVerifier({"human-reviewer": {"n": str(__import__("test_approval_gate").TEST_N), "e": 65537, "revoked": False}}, ApprovalPolicy("bandora78/pingplace", max_age=None)).verify_from_github(StaticResolver(), "bandora78/pingplace", TASK_PATH, COMMIT, proof, NOW).descriptor
    manifest = SourceManifest.create(TREE, {TASK_PATH: TASK_BYTES, "README.md": b"fixture source\n"}, ALLOWED)
    output.put(journal.reserve(capability, manifest).reason)


def audit_process(path): AuditLog(Path(path)).append("CONCURRENT")


class ExecutorBoundaryTests(unittest.TestCase):
    def test_production_attestation_cannot_consume_test_evidence(self):
        self.assertEqual(BoundaryPreflight().check().reason, "EXECUTOR_NOT_ACTIVATED")
        self.assertIsInstance(TestOnlyPreflight(), BoundaryPreflight)

    def test_policy_manifest_task_binding_and_single_use(self):
        with tempfile.TemporaryDirectory() as directory:
            broker = make_broker(directory)
            first = broker.reserve(signed_proof(TASK_BYTES), TASK_PATH, COMMIT, NOW)
            self.assertTrue(first.allowed); self.assertEqual(first.reservation.task_id, "WATCHER-X")
            duplicate = broker.reserve(signed_proof(TASK_BYTES, approval_id=first.reservation.approval_id), TASK_PATH, COMMIT, NOW)
            self.assertEqual(duplicate.reason, "APPROVAL_ALREADY_RESERVED")
            self.assertEqual(broker.reserve(signed_proof(TASK_BYTES), "README.md", COMMIT, NOW).reason, "TASK_PATH_MISMATCH")

    def test_delete_full_schema_and_pragma_are_enforced(self):
        with tempfile.TemporaryDirectory() as directory:
            broker = make_broker(directory)
            result = broker.reserve(signed_proof(TASK_BYTES), TASK_PATH, COMMIT, NOW)
            connection = sqlite3.connect(broker.journal.path)
            self.assertEqual(connection.execute("PRAGMA journal_mode").fetchone()[0].lower(), "delete")
            self.assertEqual(connection.execute("PRAGMA synchronous").fetchone()[0], 2)
            connection.close()
            self.assertEqual(result.reason, "APPROVAL_RESERVED")

    def test_unknown_schema_and_malformed_row_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.sqlite"
            connection = sqlite3.connect(path); connection.execute("CREATE TABLE reservations (bad TEXT)"); connection.commit(); connection.close()
            with self.assertRaises(ReservationStoreError): DurableReservationJournal(path, TestOnlyPreflight()).get("missing")
            connection = sqlite3.connect(path)
            connection.execute("DROP TABLE reservations")
            connection.execute("CREATE TABLE reservations (approval_id TEXT PRIMARY KEY, reservation_id TEXT NOT NULL UNIQUE, repository TEXT NOT NULL, task_id TEXT NOT NULL, path TEXT NOT NULL, commit_sha TEXT NOT NULL, task_sha256 TEXT NOT NULL, tree_sha TEXT NOT NULL, manifest_digest TEXT NOT NULL, executor_sid TEXT NOT NULL, state TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL)")
            connection.execute("PRAGMA user_version=2")
            connection.execute("INSERT INTO reservations VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)", ("id", "rid", "bandora78/pingplace", "WATCHER-X", TASK_PATH, COMMIT, task_digest(TASK_BYTES), TREE, "f" * 64, "bad-sid", "UNKNOWN", "now", "now"))
            connection.commit(); connection.close()
            with self.assertRaises(ReservationStoreError): DurableReservationJournal(path, TestOnlyPreflight()).get("id")

    def test_commit_close_and_pragma_faults_never_claim_success(self):
        class FailingCommit:
            def __init__(self, c): self.c = c
            def __getattr__(self, name): return getattr(self.c, name)
            def commit(self): raise sqlite3.OperationalError("commit fault")
        def factory(path, timeout): return FailingCommit(sqlite3.connect(path, timeout=timeout))
        with tempfile.TemporaryDirectory() as directory:
            journal = DurableReservationJournal(Path(directory) / "r.sqlite", TestOnlyPreflight(), factory)
            manifest = SourceManifest.create(TREE, {TASK_PATH: TASK_BYTES, "README.md": b"fixture source\n"}, ALLOWED)
            capability = ApprovalVerifier({"human-reviewer": {"n": str(__import__("test_approval_gate").TEST_N), "e": 65537, "revoked": False}}, ApprovalPolicy("bandora78/pingplace", max_age=None)).verify_from_github(StaticResolver(), "bandora78/pingplace", TASK_PATH, COMMIT, signed_proof(TASK_BYTES), NOW).descriptor
            result = journal.reserve(capability, manifest)
            self.assertFalse(result.reserved); self.assertEqual(result.reason, "RESERVATION_DURABILITY_UNKNOWN")

            class FailingClose:
                def __init__(self, c): self.c = c
                def __getattr__(self, name): return getattr(self.c, name)
                def close(self):
                    self.c.close()
                    raise OSError("close fault")
            def close_factory(path, timeout): return FailingClose(sqlite3.connect(path, timeout=timeout))
            close_journal = DurableReservationJournal(Path(directory) / "close.sqlite", TestOnlyPreflight(), close_factory)
            close_result = close_journal.reserve(capability, manifest)
            self.assertFalse(close_result.reserved); self.assertEqual(close_result.reason, "RESERVATION_DURABILITY_UNKNOWN")

    def test_recovery_requires_authenticated_authority_and_strict_transitions(self):
        with tempfile.TemporaryDirectory() as directory:
            broker = make_broker(directory); result = broker.reserve(signed_proof(TASK_BYTES), TASK_PATH, COMMIT, NOW)
            with self.assertRaises(ReservationStoreError): broker.journal.transition(result.reservation.approval_id, "ABANDONED", "human_recovery")
            journal = DurableReservationJournal(Path(directory) / "reservation.sqlite", TestOnlyPreflight(), recovery_authority=TestOnlyRecoveryAuthority())
            self.assertTrue(journal.transition(result.reservation.approval_id, "ABANDONED", "human_recovery"))
            with self.assertRaises(ReservationStoreError): journal.transition(result.reservation.approval_id, "RUNNING", "executor")

    def test_separate_processes_have_one_reservation_winner(self):
        with tempfile.TemporaryDirectory() as directory:
            context, queue = multiprocessing.get_context("spawn"), multiprocessing.get_context("spawn").Queue()
            processes = [context.Process(target=reserve_process, args=(str(Path(directory) / "r.sqlite"), queue)) for _ in range(2)]
            for process in processes: process.start()
            for process in processes: process.join(30)
            self.assertEqual(sorted(queue.get(timeout=5) for _ in processes), ["APPROVAL_ALREADY_RESERVED", "APPROVAL_RESERVED"])

    def test_audit_restart_bounded_retention_terminal_preservation_and_redaction(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "audit.jsonl"; audit = AuditLog(path, max_bytes=512, max_lines=1, max_segments=2)
            audit.append("NOISE", {"token": "secret"}); audit.append("NOISE", {"n": 2}); audit.append("TERMINAL", {"n": 3}); audit.append("NOISE", {"n": 4})
            segments = list(Path(directory).glob("audit.*.jsonl"))
            self.assertLessEqual(len(segments), 2); self.assertTrue(any("TERMINAL" in p.read_text() for p in segments)); self.assertNotIn("secret", "".join(p.read_text() for p in Path(directory).glob("audit*jsonl")))
            self.assertEqual(json.loads(Path(str(path) + ".anchor").read_text())["sequence"], 4)

    def test_audit_rotation_and_anchor_faults_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "audit.jsonl"; path.write_text('{"old":true}\n')
            with self.assertRaisesRegex(AuditFailure, "AUDIT_ANCHOR_MISSING"): AuditLog(path).append("NEW")
            path.unlink(); AuditLog(path).append("OK"); Path(str(path) + ".anchor").write_text("bad")
            with self.assertRaisesRegex(AuditFailure, "AUDIT_ANCHOR_INVALID"): AuditLog(path).append("NEW")

    def test_audit_separate_process_concurrency(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "audit.jsonl"; context = multiprocessing.get_context("spawn")
            processes = [context.Process(target=audit_process, args=(str(path),)) for _ in range(2)]
            for process in processes: process.start()
            for process in processes: process.join(30)
            self.assertTrue(all(process.exitcode == 0 for process in processes)); self.assertEqual(len(path.read_text().splitlines()), 2)

    def test_audit_failure_blocks_broker(self):
        class BrokenAudit:
            def append(self, event, details): raise AuditFailure("injected")
        with tempfile.TemporaryDirectory() as directory:
            result = make_broker(directory, audit=BrokenAudit()).reserve(signed_proof(TASK_BYTES), TASK_PATH, COMMIT, NOW)
            self.assertEqual(result.reason, "AUDIT_DURABILITY_UNKNOWN")

    def test_no_execution_or_publishing_symbols_are_exposed(self):
        source = Path(__file__).with_name("executor_boundary.py").read_text(encoding="utf-8").lower()
        self.assertNotIn("codex exec", source); self.assertNotIn("git push", source); self.assertNotIn("create_pull", source)


if __name__ == "__main__": unittest.main()
