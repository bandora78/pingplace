from __future__ import annotations

import base64
import hashlib
import json
import math
import random
import tempfile
import unittest
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

from approval_gate import (
    ALGORITHM,
    ApprovalReservationStore,
    ApprovalPolicy,
    ApprovalVerifier,
    RSA_DIGEST_INFO_PREFIX,
    load_trust_store,
    request_approval,
    task_digest,
)


def probable_prime(rng: random.Random, bits: int) -> int:
    while True:
        candidate = rng.getrandbits(bits) | (1 << (bits - 1)) | 1
        if all(candidate % divisor for divisor in range(3, 100, 2)):
            if all(pow(2 + index, candidate - 1, candidate) == 1 for index in range(8)):
                return candidate


def test_key_pair() -> tuple[int, int, int]:
    rng = random.Random(601)
    e = 65537
    while True:
        p = probable_prime(rng, 512)
        q = probable_prime(rng, 512)
        if p != q and math.gcd(e, (p - 1) * (q - 1)) == 1:
            n = p * q
            d = pow(e, -1, (p - 1) * (q - 1))
            return n, e, d


def signed_proof(task_bytes: bytes, n: int, d: int, **overrides: object) -> dict[str, object]:
    proof: dict[str, object] = {
        "version": 1,
        "algorithm": ALGORITHM,
        "approval_id": str(uuid.uuid4()),
        "repository": "bandora78/pingplace",
        "task_id": "WATCHER-X",
        "path": "tasks/WATCHER-X.md",
        "commit_sha": "a" * 40,
        "task_sha256": task_digest(task_bytes),
        "approver_id": "human-reviewer",
        "approved_at": "2026-10-14T10:00:00Z",
    }
    proof.update(overrides)
    payload = json.dumps(proof, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
    size = (n.bit_length() + 7) // 8
    digest_info = RSA_DIGEST_INFO_PREFIX + hashlib.sha256(payload).digest()
    encoded = b"\x00\x01" + (b"\xff" * (size - len(digest_info) - 3)) + b"\x00" + digest_info
    proof["signature"] = base64.b64encode(pow(int.from_bytes(encoded, "big"), d, n).to_bytes(size, "big")).decode("ascii")
    return proof


class ApprovalGateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.n, cls.e, cls.d = test_key_pair()
        cls.task_bytes = b"---\ntask_id: WATCHER-X\nstatus: MANUAL_READY\n---\n\nTask\n"
        cls.trust = {"human-reviewer": {"n": str(cls.n), "e": cls.e, "revoked": False}}
        cls.policy = ApprovalPolicy("bandora78/pingplace", max_age=None)
        cls.now = datetime(2026, 10, 14, 10, 1, tzinfo=timezone.utc)

    def verify(self, proof: object, trust: dict[str, dict[str, object]] | None = None):
        return ApprovalVerifier(trust or self.trust, self.policy).verify(
            self.task_bytes,
            "bandora78/pingplace",
            "tasks/WATCHER-X.md",
            "a" * 40,
            proof,
            now=self.now,
        )

    def test_valid_revision_bound_proof_is_allowed(self) -> None:
        proof = signed_proof(self.task_bytes, self.n, self.d)
        result = self.verify(proof)
        self.assertTrue(result.allowed)
        self.assertEqual(result.reason, "APPROVAL_VALID")

    def test_changed_bytes_commit_repo_path_or_task_id_is_denied(self) -> None:
        proof = signed_proof(self.task_bytes, self.n, self.d)
        self.assertEqual(self.verify(proof).reason, "APPROVAL_VALID")
        self.assertEqual(
            ApprovalVerifier(self.trust, self.policy).verify(
                self.task_bytes + b"changed", "bandora78/pingplace", "tasks/WATCHER-X.md", "a" * 40, proof, self.now
            ).reason,
            "TASK_BYTES_MISMATCH",
        )
        for field, value in (("repository", "other/repo"), ("path", "tasks/OTHER.md"), ("task_id", "OTHER"), ("commit_sha", "b" * 40)):
            changed = dict(proof)
            changed[field] = value
            self.assertNotEqual(self.verify(changed).reason, "APPROVAL_VALID")

    def test_unauthorized_revoked_expired_and_malformed_proofs_are_denied(self) -> None:
        proof = signed_proof(self.task_bytes, self.n, self.d)
        self.assertEqual(self.verify(proof, {"other": self.trust["human-reviewer"]}).reason, "APPROVER_UNAUTHORIZED")
        revoked = {"human-reviewer": {**self.trust["human-reviewer"], "revoked": True}}
        self.assertEqual(self.verify(proof, revoked).reason, "APPROVER_REVOKED")
        expired = ApprovalVerifier(self.trust, ApprovalPolicy("bandora78/pingplace", max_age=timedelta(days=1))).verify(
            self.task_bytes, "bandora78/pingplace", "tasks/WATCHER-X.md", "a" * 40, proof, self.now + timedelta(days=2)
        )
        self.assertEqual(expired.reason, "APPROVAL_EXPIRED")
        malformed = dict(proof)
        malformed["signature"] = "not base64"
        self.assertIn("SIGNATURE", self.verify(malformed).reason)

    def test_corrupt_trust_store_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "trust.json"
            path.write_text("not-json", encoding="utf-8")
            with self.assertRaises(Exception):
                load_trust_store(path)

    def test_interactive_approval_creation_stays_disabled(self) -> None:
        class Args:
            task_file = Path(__file__)
            task_id = "WATCHER-X"
            repository = "bandora78/pingplace"
            path = "tasks/WATCHER-X.md"
            commit_sha = "a" * 40

        import unittest.mock

        with unittest.mock.patch("builtins.input", return_value=f"APPROVE WATCHER-X {task_digest(Path(__file__).read_bytes())}"):
            self.assertEqual(request_approval(Args()), 4)

    def test_reservation_is_single_use_and_survives_restart(self) -> None:
        proof = signed_proof(self.task_bytes, self.n, self.d)
        result = self.verify(proof)
        with tempfile.TemporaryDirectory() as directory:
            first = ApprovalReservationStore(Path(directory)).reserve(result, "bandora78/pingplace", "tasks/WATCHER-X.md", "a" * 40)
            second = ApprovalReservationStore(Path(directory)).reserve(result, "bandora78/pingplace", "tasks/WATCHER-X.md", "a" * 40)
            self.assertEqual(first.reason, "APPROVAL_RESERVED")
            self.assertEqual(second.reason, "APPROVAL_ALREADY_RESERVED")

    def test_concurrent_reservation_has_one_winner(self) -> None:
        from concurrent.futures import ThreadPoolExecutor

        proof = signed_proof(self.task_bytes, self.n, self.d)
        result = self.verify(proof)
        with tempfile.TemporaryDirectory() as directory:
            store = ApprovalReservationStore(Path(directory))
            with ThreadPoolExecutor(max_workers=2) as executor:
                outcomes = list(executor.map(
                    lambda _: store.reserve(result, "bandora78/pingplace", "tasks/WATCHER-X.md", "a" * 40).reserved,
                    range(2),
                ))
            self.assertEqual(sorted(outcomes), [False, True])


if __name__ == "__main__":
    unittest.main()
