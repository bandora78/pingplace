from __future__ import annotations

import json
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
from pathlib import Path

from approval_gate import ApprovalPolicy, ApprovalVerifier, task_digest
from executor_boundary import (
    ApprovalBroker,
    AuditLog,
    BoundaryEvidence,
    BoundaryPreflight,
    DurableReservationJournal,
    SourceManifest,
    SourceSnapshot,
)
from test_approval_gate import NOW, StaticResolver, TASK_BYTES, signed_proof


COMMIT = "a" * 40
TREE = "c" * 40
TASK_PATH = "tasks/WATCHER-X.md"
ALLOWED = (TASK_PATH, "README.md")


def evidence() -> BoundaryEvidence:
    return BoundaryEvidence(
        activation_enabled=True,
        identity_separated=True,
        acl_verified=True,
        local_ntfs_verified=True,
        sandbox_verified=True,
        network_disabled=True,
        trust_store_external=True,
        audit_storage_verified=True,
        executor_sid="S-1-5-21-executor",
        broker_sid="S-1-5-21-broker",
        supervisor_sid="S-1-5-21-supervisor",
    )


class FixtureSource:
    def __init__(self, task_bytes: bytes = TASK_BYTES, reachable: bool = True):
        self.task_bytes = task_bytes
        self.reachable = reachable

    def resolve(self, repository: str, commit_sha: str, allowed_paths: tuple[str, ...]) -> SourceSnapshot:
        files = {TASK_PATH: self.task_bytes, "README.md": b"fixture source\n"}
        manifest = SourceManifest.create(TREE, files, allowed_paths)
        return SourceSnapshot(repository, commit_sha, self.reachable, files, manifest)


class ExecutorBoundaryTests(unittest.TestCase):
    def broker(self, directory: str, source: FixtureSource | None = None) -> ApprovalBroker:
        source = source or FixtureSource()
        trust = {"human-reviewer": {"n": str(__import__("test_approval_gate").TEST_N), "e": 65537, "revoked": False}}
        verifier = ApprovalVerifier(trust, ApprovalPolicy("bandora78/pingplace", max_age=None))
        journal = DurableReservationJournal(Path(directory) / "reservation.sqlite", evidence())
        return ApprovalBroker(verifier, StaticResolver(), source, journal, BoundaryPreflight(evidence()), AuditLog(Path(directory) / "audit.jsonl"))

    def test_default_preflight_fails_closed_without_physical_evidence(self) -> None:
        result = BoundaryPreflight().check()
        self.assertFalse(result.passed)
        self.assertEqual(result.reason, "EXECUTOR_NOT_ACTIVATED")
        self.assertIn("acl_verified", result.missing)

    def test_preflight_rejects_collapsed_service_identities(self) -> None:
        current = evidence()
        result = BoundaryPreflight(BoundaryEvidence(**{**current.__dict__, "supervisor_sid": current.broker_sid})).check()
        self.assertFalse(result.passed)
        self.assertEqual(result.reason, "IDENTITY_SEPARATION_INVALID")

    def test_manifest_requires_exact_allowlist_and_binds_tree(self) -> None:
        manifest = SourceManifest.create(TREE, {TASK_PATH: TASK_BYTES, "README.md": b"x"}, ALLOWED)
        self.assertEqual(manifest.entry(TASK_PATH).sha256, task_digest(TASK_BYTES))
        with self.assertRaises(ValueError):
            SourceManifest.create(TREE, {TASK_PATH: TASK_BYTES}, ALLOWED)
        with self.assertRaises(ValueError):
            SourceManifest.create(TREE, {TASK_PATH: TASK_BYTES, "README.md": b"x", "extra": b"x"}, ALLOWED)
        with self.assertRaises(ValueError):
            SourceManifest.create(TREE, {"../escape": b"x", "README.md": b"x"}, ("../escape", "README.md"))

    def test_journal_default_denies_and_fixture_journal_is_single_use(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            default = DurableReservationJournal(Path(directory) / "default.sqlite")
            self.assertEqual(default.preflight.check().reason, "EXECUTOR_NOT_ACTIVATED")
            result = self.broker(directory).reserve(signed_proof(TASK_BYTES), "bandora78/pingplace", TASK_PATH, COMMIT, "WATCHER-X", ALLOWED, evidence().executor_sid, NOW)
            self.assertTrue(result.allowed)
            self.assertEqual(result.reason, "APPROVAL_RESERVED")
            duplicate = self.broker(directory).reserve(signed_proof(TASK_BYTES, approval_id=result.reservation.approval_id), "bandora78/pingplace", TASK_PATH, COMMIT, "WATCHER-X", ALLOWED, evidence().executor_sid, NOW)
            self.assertEqual(duplicate.reason, "APPROVAL_ALREADY_RESERVED")

    def test_broker_reverifies_source_and_rejects_forged_or_unreachable_requests(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            broker = self.broker(directory, FixtureSource(reachable=False))
            denied = broker.reserve({"allowed": True}, "bandora78/pingplace", TASK_PATH, COMMIT, "WATCHER-X", ALLOWED, evidence().executor_sid, NOW)
            self.assertFalse(denied.allowed)
            self.assertEqual(denied.reason, "PROOF_FIELDS_INVALID")
            denied = broker.reserve(signed_proof(TASK_BYTES), "bandora78/pingplace", TASK_PATH, COMMIT, "WATCHER-X", ALLOWED, evidence().executor_sid, NOW)
            self.assertFalse(denied.allowed)
            self.assertEqual(denied.reason, "SOURCE_MANIFEST_UNVERIFIED")

    def test_changed_source_bytes_and_manifest_are_denied(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            broker = self.broker(directory, FixtureSource(task_bytes=TASK_BYTES + b"tampered"))
            result = broker.reserve(signed_proof(TASK_BYTES), "bandora78/pingplace", TASK_PATH, COMMIT, "WATCHER-X", ALLOWED, evidence().executor_sid, NOW)
            self.assertEqual(result.reason, "SOURCE_MANIFEST_UNVERIFIED")

    def test_broker_rejects_inconsistent_source_manifest(self) -> None:
        class ForgedManifestSource(FixtureSource):
            def resolve(self, repository: str, commit_sha: str, allowed_paths: tuple[str, ...]) -> SourceSnapshot:
                snapshot = super().resolve(repository, commit_sha, allowed_paths)
                forged = replace(snapshot.manifest, digest="f" * 64)
                return replace(snapshot, manifest=forged)

        with tempfile.TemporaryDirectory() as directory:
            broker = self.broker(directory, ForgedManifestSource())
            result = broker.reserve(signed_proof(TASK_BYTES), "bandora78/pingplace", TASK_PATH, COMMIT, "WATCHER-X", ALLOWED, evidence().executor_sid, NOW)
            self.assertEqual(result.reason, "SOURCE_MANIFEST_UNVERIFIED")

    def test_corrupt_journal_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "reservation.sqlite"
            path.write_bytes(b"not a sqlite database")
            journal = DurableReservationJournal(path, evidence())
            result = self.broker(directory).reserve(signed_proof(TASK_BYTES), "bandora78/pingplace", TASK_PATH, COMMIT, "WATCHER-X", ALLOWED, evidence().executor_sid, NOW)
            self.assertEqual(result.reason, "RESERVATION_DURABILITY_UNKNOWN")

    def test_two_threads_have_one_reservation_winner(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            proof = signed_proof(TASK_BYTES)

            def reserve(_: int):
                return self.broker(directory).reserve(proof, "bandora78/pingplace", TASK_PATH, COMMIT, "WATCHER-X", ALLOWED, evidence().executor_sid, NOW).reason

            with ThreadPoolExecutor(max_workers=2) as pool:
                outcomes = list(pool.map(reserve, range(2)))
            self.assertEqual(sorted(outcomes), ["APPROVAL_ALREADY_RESERVED", "APPROVAL_RESERVED"])

    def test_restart_recovery_never_replays_and_requires_new_approval(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            broker = self.broker(directory)
            first = broker.reserve(signed_proof(TASK_BYTES), "bandora78/pingplace", TASK_PATH, COMMIT, "WATCHER-X", ALLOWED, evidence().executor_sid, NOW)
            journal = DurableReservationJournal(Path(directory) / "reservation.sqlite", evidence())
            self.assertEqual(journal.recoverable()[0].state, "RESERVED")
            self.assertTrue(journal.transition(first.reservation.approval_id, "RUNNING"))
            self.assertTrue(journal.recoverable())
            self.assertTrue(journal.transition(first.reservation.approval_id, "ABANDONED"))
            self.assertFalse(journal.transition(first.reservation.approval_id, "RUNNING"))

    def test_audit_is_bounded_and_redacts_sensitive_details(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "audit.jsonl"
            audit = AuditLog(path, max_bytes=4096, max_lines=3)
            audit.append("TEST", {"token": "secret", "message": "Bearer secret", "approval_id": "public-id"})
            data = path.read_text(encoding="utf-8")
            self.assertNotIn("secret", data)
            self.assertIn("public-id", data)
            for index in range(10):
                audit.append("TEST", {"index": index})
            self.assertLessEqual(path.stat().st_size, 4096)
            self.assertLessEqual(len(path.read_text(encoding="utf-8").splitlines()), 3)

    def test_no_execution_or_publishing_symbols_are_exposed(self) -> None:
        source = Path(__file__).with_name("executor_boundary.py").read_text(encoding="utf-8")
        self.assertNotIn("codex exec", source.lower())
        self.assertNotIn("git push", source.lower())
        self.assertNotIn("create_pull", source.lower())


if __name__ == "__main__":
    unittest.main()
