from __future__ import annotations

import json
import multiprocessing
import sqlite3
import tempfile
import unittest
from pathlib import Path

from approval_gate import ApprovalPolicy, ApprovalVerifier, VerifiedApproval, task_digest
from executor_boundary import (
    ApprovalBroker,
    AuditLog,
    BoundaryPreflight,
    DurableReservationJournal,
    PreflightResult,
    ReservationStoreError,
    SourceManifest,
    SourceSnapshot,
)
from test_approval_gate import NOW, StaticResolver, TASK_BYTES, signed_proof

COMMIT = "a" * 40
TREE = "c" * 40
TASK_PATH = "tasks/WATCHER-X.md"
ALLOWED = (TASK_PATH, "README.md")


class FixtureProvider:
    fixture_only = True

    def __init__(self, executor_sid="S-1-5-21-executor", broker_sid="S-1-5-21-broker", supervisor_sid="S-1-5-21-supervisor"):
        self.result = PreflightResult(True, "FIXTURE_ONLY", (), executor_sid, broker_sid, supervisor_sid)

    def attest(self) -> PreflightResult:
        return self.result


def fixture_preflight(**kwargs) -> BoundaryPreflight:
    return BoundaryPreflight(FixtureProvider(**kwargs))


class FixtureSource:
    def __init__(self, task_bytes: bytes = TASK_BYTES, reachable: bool = True):
        self.task_bytes, self.reachable = task_bytes, reachable

    def resolve(self, repository: str, commit_sha: str, allowed_paths: tuple[str, ...]) -> SourceSnapshot:
        files = {TASK_PATH: self.task_bytes, "README.md": b"fixture source\n"}
        manifest = SourceManifest.create(TREE, files, allowed_paths)
        return SourceSnapshot(repository, commit_sha, self.reachable, files, manifest)


def make_broker(directory: str, source: FixtureSource | None = None) -> ApprovalBroker:
    trust = {"human-reviewer": {"n": str(__import__("test_approval_gate").TEST_N), "e": 65537, "revoked": False}}
    preflight = fixture_preflight()
    journal = DurableReservationJournal(Path(directory) / "reservation.sqlite", preflight)
    verifier = ApprovalVerifier(trust, ApprovalPolicy("bandora78/pingplace", max_age=None))
    return ApprovalBroker(verifier, StaticResolver(), source or FixtureSource(), journal, preflight, AuditLog(Path(directory) / "audit.jsonl"), "bandora78/pingplace", ALLOWED)


def reserve_process(path: str, output) -> None:
    with tempfile.TemporaryDirectory() as _unused:
        preflight = fixture_preflight()
        journal = DurableReservationJournal(Path(path), preflight)
        proof = signed_proof(TASK_BYTES, approval_id="00000000-0000-4000-8000-000000000001")
        capability = ApprovalVerifier(
            {"human-reviewer": {"n": str(__import__("test_approval_gate").TEST_N), "e": 65537, "revoked": False}},
            ApprovalPolicy("bandora78/pingplace", max_age=None),
        ).verify_from_github(StaticResolver(), "bandora78/pingplace", TASK_PATH, COMMIT, proof, NOW).descriptor
        manifest = SourceManifest.create(TREE, {TASK_PATH: TASK_BYTES, "README.md": b"fixture source\n"}, ALLOWED)
        output.put(journal.reserve(capability, manifest).reason)


def audit_process(path: str) -> None:
    AuditLog(Path(path)).append("CONCURRENT")


class ExecutorBoundaryTests(unittest.TestCase):
    def test_production_preflight_never_accepts_caller_fixture_values(self):
        result = BoundaryPreflight().check()
        self.assertFalse(result.passed)
        self.assertEqual(result.reason, "EXECUTOR_NOT_ACTIVATED")

        class UnmarkedProvider:
            def attest(self):
                return FixtureProvider().result

        self.assertEqual(BoundaryPreflight(UnmarkedProvider()).check().reason, "ATTESTATION_PROVIDER_UNTRUSTED")

    def test_policy_owns_task_id_allowlist_and_sid(self):
        with tempfile.TemporaryDirectory() as directory:
            broker = make_broker(directory)
            result = broker.reserve(signed_proof(TASK_BYTES), TASK_PATH, COMMIT, NOW)
            self.assertTrue(result.allowed)
            self.assertEqual(result.reservation.task_id, "WATCHER-X")
            self.assertEqual(result.reservation.executor_sid, "S-1-5-21-executor")
            self.assertEqual(broker.reserve(signed_proof(TASK_BYTES, approval_id=result.reservation.approval_id), TASK_PATH, COMMIT, NOW).reason, "APPROVAL_ALREADY_RESERVED")
            self.assertEqual(broker.reserve(signed_proof(TASK_BYTES), "README.md", COMMIT, NOW).reason, "TASK_PATH_MISMATCH")

    def test_manifest_and_negative_scope_validation(self):
        manifest = SourceManifest.create(TREE, {TASK_PATH: TASK_BYTES, "README.md": b"x"}, ALLOWED)
        self.assertTrue(manifest.validate(ALLOWED))
        self.assertNotEqual(SourceManifest(manifest.tree_sha, manifest.entries, "f" * 64).digest, manifest.digest)
        with self.assertRaises(ValueError): SourceManifest.create(TREE, {TASK_PATH: TASK_BYTES}, ALLOWED)

    def test_invalid_transition_requires_actor_and_human_guard(self):
        with tempfile.TemporaryDirectory() as directory:
            broker = make_broker(directory)
            result = broker.reserve(signed_proof(TASK_BYTES), TASK_PATH, COMMIT, NOW)
            journal = broker.journal
            with self.assertRaises(ReservationStoreError): journal.transition(result.reservation.approval_id, "SUCCEEDED", "executor")
            with self.assertRaises(ReservationStoreError): journal.transition(result.reservation.approval_id, "ABANDONED", "human_recovery")
            self.assertTrue(journal.transition(result.reservation.approval_id, "RUNNING", "executor"))
            with self.assertRaises(ReservationStoreError): journal.transition(result.reservation.approval_id, "RUNNING", "executor")
            self.assertTrue(journal.transition(result.reservation.approval_id, "ABANDONED", "human_recovery", "HUMAN_REVIEW_CONFIRMED"))

    def test_corrupt_schema_and_rows_raise_unambiguous_errors(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.sqlite"
            connection = sqlite3.connect(path)
            connection.execute("CREATE TABLE reservations (bad TEXT)")
            connection.commit(); connection.close()
            with self.assertRaises(ReservationStoreError): DurableReservationJournal(path, fixture_preflight()).get("missing")

            connection = sqlite3.connect(path)
            connection.execute("DROP TABLE reservations")
            connection.execute("CREATE TABLE reservations (approval_id TEXT PRIMARY KEY, reservation_id TEXT NOT NULL UNIQUE, repository TEXT NOT NULL, task_id TEXT NOT NULL, path TEXT NOT NULL, commit_sha TEXT NOT NULL, task_sha256 TEXT NOT NULL, tree_sha TEXT NOT NULL, manifest_digest TEXT NOT NULL, executor_sid TEXT NOT NULL, state TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL)")
            connection.execute("PRAGMA user_version=1")
            connection.execute("INSERT INTO reservations VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)", ("id", "rid", "bandora78/pingplace", "WATCHER-X", TASK_PATH, COMMIT, task_digest(TASK_BYTES), TREE, "f" * 64, "not-a-sid", "BROKEN", "now", "now"))
            connection.commit(); connection.close()
            with self.assertRaises(ReservationStoreError): DurableReservationJournal(path, fixture_preflight()).get("id")

    def test_commit_failure_does_not_claim_reserved(self):
        class FailingConnection:
            def __init__(self, connection): self.connection = connection
            def __getattr__(self, name): return getattr(self.connection, name)
            def commit(self): raise sqlite3.OperationalError("injected commit failure")

        def factory(path, timeout): return FailingConnection(sqlite3.connect(path, timeout=timeout))

        with tempfile.TemporaryDirectory() as directory:
            journal = DurableReservationJournal(Path(directory) / "reservation.sqlite", fixture_preflight(), factory)
            broker = make_broker(directory)
            broker.journal = journal
            result = broker.reserve(signed_proof(TASK_BYTES), TASK_PATH, COMMIT, NOW)
            self.assertFalse(result.allowed)
            self.assertIsNone(result.reservation)

    def test_close_failure_does_not_claim_durable_success(self):
        class FailingClose:
            def __init__(self, connection): self.connection = connection
            def __getattr__(self, name): return getattr(self.connection, name)
            def close(self):
                self.connection.close()
                raise OSError("injected close failure")

        def factory(path, timeout): return FailingClose(sqlite3.connect(path, timeout=timeout))

        with tempfile.TemporaryDirectory() as directory:
            journal = DurableReservationJournal(Path(directory) / "reservation.sqlite", fixture_preflight(), factory)
            manifest = SourceManifest.create(TREE, {TASK_PATH: TASK_BYTES, "README.md": b"fixture source\n"}, ALLOWED)
            result = journal.reserve(ApprovalVerifier(
                {"human-reviewer": {"n": str(__import__("test_approval_gate").TEST_N), "e": 65537, "revoked": False}},
                ApprovalPolicy("bandora78/pingplace", max_age=None),
            ).verify_from_github(StaticResolver(), "bandora78/pingplace", TASK_PATH, COMMIT, signed_proof(TASK_BYTES), NOW).descriptor, manifest)
            self.assertFalse(result.reserved)
            self.assertEqual(result.reason, "RESERVATION_DURABILITY_UNKNOWN")

    def test_separate_processes_have_one_reservation_winner(self):
        with tempfile.TemporaryDirectory() as directory:
            context = multiprocessing.get_context("spawn")
            queue = context.Queue()
            processes = [context.Process(target=reserve_process, args=(str(Path(directory) / "reservation.sqlite"), queue)) for _ in range(2)]
            for process in processes: process.start()
            for process in processes: process.join(30)
            outcomes = sorted(queue.get(timeout=5) for _ in processes)
            self.assertEqual(outcomes, ["APPROVAL_ALREADY_RESERVED", "APPROVAL_RESERVED"])

    def test_audit_restart_rotation_and_redaction_preserve_chain(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "audit.jsonl"
            AuditLog(path, max_bytes=350, max_lines=2).append("ONE", {"token": "secret"})
            AuditLog(path, max_bytes=350, max_lines=2).append("TWO", {"value": 2})
            AuditLog(path, max_bytes=350, max_lines=2).append("THREE", {"value": 3})
            self.assertTrue(list(Path(directory).glob("audit.*.jsonl")))
            self.assertNotIn("secret", "".join(p.read_text() for p in Path(directory).glob("audit*jsonl")))
            anchor = json.loads(Path(str(path) + ".anchor").read_text())
            self.assertEqual(anchor["sequence"], 3)

    def test_audit_missing_or_invalid_anchor_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "audit.jsonl"
            path.write_text('{"old":true}\n')
            with self.assertRaisesRegex(RuntimeError, "AUDIT_ANCHOR_MISSING"): AuditLog(path).append("NEW")

    def test_audit_separate_process_concurrency_is_serialized(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "audit.jsonl"
            context = multiprocessing.get_context("spawn")
            processes = [context.Process(target=audit_process, args=(str(path),)) for _ in range(2)]
            for process in processes: process.start()
            for process in processes: process.join(30)
            self.assertTrue(all(process.exitcode == 0 for process in processes))
            self.assertEqual(len(path.read_text().splitlines()), 2)

    def test_no_execution_or_publishing_symbols_are_exposed(self):
        source = Path(__file__).with_name("executor_boundary.py").read_text(encoding="utf-8").lower()
        self.assertNotIn("codex exec", source)
        self.assertNotIn("git push", source)
        self.assertNotIn("create_pull", source)


if __name__ == "__main__":
    unittest.main()
