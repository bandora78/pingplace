from __future__ import annotations

import base64
import hashlib
import json
import multiprocessing
import os
import tempfile
import unittest
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from pathlib import Path

from approval_gate import (
    ALGORITHM,
    ApprovalError,
    ApprovalPolicy,
    ApprovalReservationStore,
    ApprovalVerifier,
    GitHubCommitResolver,
    RSA_DIGEST_INFO_PREFIX,
    ResolvedTask,
    load_trust_store,
    request_approval,
    task_digest,
)


# Fixed 2048-bit test vector generated once with cryptographically random
# primes; the private exponent is test-only and never used by production code.
TEST_N = int("25122715308324077874831906804311291660409347661195471902596817472490286836491740391245255646051113764289040835857846574953075271196427382585958625259793518987763639041516397127311049560567127670095998086200865618355562524568775892404813355715374476184879047144781831359697331211071283983289580990151073370094600721959829961330360527198689486691926556801765686089633464117732304396410676399572597135285230136112783714163689305853513033139979436823663895302228222077844802322738841334257825834393243579970311861371278887337311360390010254608529118959172947261891688799212828541004326480801880781829824000516238858853397")
TEST_E = 65537
TEST_D = int("13992160633979845987903618265470901275563446587138500692993063987722476766083052566044266236423878168215119391330809433333265185680467459477395605239906056679011254537961609648656188412808958711661718207187051527161700836310555699050430936676486316969410716081475832376524898706613255667394799818751305813232394670393605604593554299348076123905317976310576160254928605961824314738432978662908874956130376598313027063797803151261083689829847645103502210478947807291187583134608117844853654552074688226899719624576089569588018194408263199443048674809056720914935745573719042933705612868245525317512474638072417070806113")
TASK_BYTES = b"---\ntask_id: WATCHER-X\nstatus: MANUAL_READY\n---\n\nTask\n"
NOW = datetime(2026, 10, 14, 10, 1, tzinfo=timezone.utc)


def signed_proof(task_bytes: bytes, n: int = TEST_N, d: int = TEST_D, **overrides: object) -> dict[str, object]:
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


class StaticResolver:
    def resolve(self, repository: str, path: str, commit_sha: str) -> ResolvedTask:
        return ResolvedTask(repository, path, commit_sha, TASK_BYTES, "b" * 40)


def reservation_worker(directory: str, output) -> None:
    proof = signed_proof(TASK_BYTES)
    result = ApprovalVerifier(
        {"human-reviewer": {"n": str(TEST_N), "e": TEST_E, "revoked": False}},
        ApprovalPolicy("bandora78/pingplace", max_age=None),
    ).verify_from_github(
        StaticResolver(), "bandora78/pingplace", "tasks/WATCHER-X.md", "a" * 40, proof, NOW
    )
    output.put(ApprovalReservationStore(Path(directory)).reserve(result).reason)


class ApprovalGateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.trust = {"human-reviewer": {"n": str(TEST_N), "e": TEST_E, "revoked": False}}
        cls.policy = ApprovalPolicy("bandora78/pingplace", max_age=None)

    def verify(self, proof: object, trust=None):
        return ApprovalVerifier(trust or self.trust, self.policy).verify(
            TASK_BYTES, "bandora78/pingplace", "tasks/WATCHER-X.md", "a" * 40, proof, NOW
        )

    def source_verified(self, proof: object, trust=None):
        return ApprovalVerifier(trust or self.trust, self.policy).verify_from_github(
            StaticResolver(), "bandora78/pingplace", "tasks/WATCHER-X.md", "a" * 40, proof, NOW
        )

    def test_valid_revision_bound_proof_is_local_only_without_source_resolver(self) -> None:
        result = self.verify(signed_proof(TASK_BYTES))
        self.assertTrue(result.allowed)
        self.assertEqual(result.reason, "APPROVAL_VALID_LOCAL_BYTES_ONLY")
        self.assertFalse(result.source_verified)

    def test_github_resolver_pins_commit_and_returns_source_verified_result(self) -> None:
        commit_sha = "a" * 40
        responses = [
            {"sha": commit_sha},
            {"type": "file", "encoding": "base64", "content": base64.b64encode(TASK_BYTES).decode("ascii"), "sha": "b" * 40},
        ]
        urls: list[str] = []

        class Response:
            def __init__(self, payload): self.payload = payload
            def __enter__(self): return self
            def __exit__(self, *_): return False
            def read(self): return json.dumps(self.payload).encode("utf-8")

        def opener(request, timeout):
            urls.append(request.full_url)
            return Response(responses.pop(0))

        result = ApprovalVerifier(self.trust, self.policy).verify_from_github(
            GitHubCommitResolver(opener=opener), "bandora78/pingplace", "tasks/WATCHER-X.md", commit_sha, signed_proof(TASK_BYTES), NOW
        )
        self.assertTrue(result.allowed)
        self.assertTrue(result.source_verified)
        self.assertIn(f"git/commits/{commit_sha}", urls[0])
        self.assertIn(f"ref={commit_sha}", urls[1])

    def test_missing_or_mismatched_source_denies(self) -> None:
        proof = signed_proof(TASK_BYTES)

        class MissingSource:
            def resolve(self, *_): raise ApprovalError("missing")

        denied = ApprovalVerifier(self.trust, self.policy).verify_from_github(
            MissingSource(), "bandora78/pingplace", "tasks/WATCHER-X.md", "a" * 40, proof, NOW
        )
        self.assertEqual(denied.reason, "TASK_SOURCE_UNVERIFIED")

        class WrongScope:
            def resolve(self, repository, path, commit_sha): return ResolvedTask(repository, path, "b" * 40, TASK_BYTES, "b" * 40)

        denied = ApprovalVerifier(self.trust, self.policy).verify_from_github(
            WrongScope(), "bandora78/pingplace", "tasks/WATCHER-X.md", "a" * 40, proof, NOW
        )
        self.assertEqual(denied.reason, "TASK_SOURCE_SCOPE_MISMATCH")

    def test_changed_bytes_commit_repo_path_or_task_id_is_denied(self) -> None:
        proof = signed_proof(TASK_BYTES)
        self.assertEqual(self.verify(proof).reason, "APPROVAL_VALID_LOCAL_BYTES_ONLY")
        self.assertEqual(
            ApprovalVerifier(self.trust, self.policy).verify(TASK_BYTES + b"changed", "bandora78/pingplace", "tasks/WATCHER-X.md", "a" * 40, proof, NOW).reason,
            "TASK_BYTES_MISMATCH",
        )
        for field, value in (("repository", "other/repo"), ("path", "tasks/OTHER.md"), ("task_id", "OTHER"), ("commit_sha", "b" * 40)):
            changed = dict(proof)
            changed[field] = value
            self.assertNotEqual(self.verify(changed).reason, "APPROVAL_VALID_LOCAL_BYTES_ONLY")

    def test_unauthorized_revoked_expired_and_malformed_proofs_are_denied(self) -> None:
        proof = signed_proof(TASK_BYTES)
        self.assertEqual(self.verify(proof, {"other": self.trust["human-reviewer"]}).reason, "APPROVER_UNAUTHORIZED")
        self.assertEqual(self.verify(proof, {"human-reviewer": {**self.trust["human-reviewer"], "revoked": True}}).reason, "APPROVER_REVOKED")
        expired = ApprovalVerifier(self.trust, ApprovalPolicy("bandora78/pingplace", max_age=timedelta(days=1))).verify(TASK_BYTES, "bandora78/pingplace", "tasks/WATCHER-X.md", "a" * 40, proof, NOW + timedelta(days=2))
        self.assertEqual(expired.reason, "APPROVAL_EXPIRED")
        malformed = dict(proof)
        malformed["signature"] = "not base64"
        self.assertIn("SIGNATURE", self.verify(malformed).reason)

    def test_small_or_malformed_rsa_keys_and_invalid_signature_are_denied(self) -> None:
        proof = signed_proof(TASK_BYTES)
        self.assertIn("RSA_KEY", self.verify(proof, {"human-reviewer": {"n": "3233", "e": 17, "revoked": False}}).reason)
        self.assertIn("RSA_KEY", self.verify(proof, {"human-reviewer": {"n": str(TEST_N), "e": 3, "revoked": False}}).reason)
        invalid = dict(proof)
        invalid["signature"] = base64.b64encode(b"x" * 256).decode("ascii")
        self.assertEqual(self.verify(invalid).reason, "SIGNATURE_INVALID")

    def test_corrupt_trust_store_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "trust.json"
            path.write_text("not-json", encoding="utf-8")
            with self.assertRaises(Exception): load_trust_store(path)

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

    def test_unverified_local_bytes_cannot_be_reserved(self) -> None:
        result = self.verify(signed_proof(TASK_BYTES))
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(ApprovalReservationStore(Path(directory)).reserve(result).reason, "APPROVAL_NOT_VERIFIED")

    def test_reservation_is_single_use_and_survives_restart(self) -> None:
        result = self.source_verified(signed_proof(TASK_BYTES))
        with tempfile.TemporaryDirectory() as directory:
            first = ApprovalReservationStore(Path(directory)).reserve(result)
            second = ApprovalReservationStore(Path(directory)).reserve(result)
            if os.name == "nt":
                self.assertEqual(first.reason, "RESERVATION_DURABILITY_UNVERIFIED")
                self.assertEqual(second.reason, "RESERVATION_DURABILITY_UNVERIFIED")
            else:
                self.assertEqual(first.reason, "APPROVAL_RESERVED")
                self.assertEqual(second.reason, "APPROVAL_ALREADY_RESERVED")

    def test_multiprocess_reservation_contention_and_restart(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            context = multiprocessing.get_context("spawn")
            queue = context.Queue()
            processes = [context.Process(target=reservation_worker, args=(directory, queue)) for _ in range(2)]
            for process in processes: process.start()
            for process in processes: process.join(timeout=15)
            self.assertTrue(all(process.exitcode == 0 for process in processes))
            outcomes = sorted(queue.get(timeout=5) for _ in processes)
            expected = ["RESERVATION_DURABILITY_UNVERIFIED"] * 2 if os.name == "nt" else ["APPROVAL_ALREADY_RESERVED", "APPROVAL_RESERVED"]
            self.assertEqual(outcomes, expected)

    def test_threaded_reservation_has_one_winner_when_durable(self) -> None:
        result = self.source_verified(signed_proof(TASK_BYTES))
        with tempfile.TemporaryDirectory() as directory:
            store = ApprovalReservationStore(Path(directory))
            if os.name == "nt":
                self.assertEqual(store.reserve(result).reason, "RESERVATION_DURABILITY_UNVERIFIED")
            else:
                with ThreadPoolExecutor(max_workers=2) as executor:
                    outcomes = list(executor.map(lambda _: store.reserve(result).reserved, range(2)))
                self.assertEqual(sorted(outcomes), [False, True])


if __name__ == "__main__":
    unittest.main()
