#!/usr/bin/env python3
"""Independent, read-only approval proof verifier for WATCHER-C1.

This module intentionally has no proof-issuing, Codex, GitHub-write, or task
execution capability. Approval creation is blocked on this workstation until
an independently controlled human signer and executor boundary are deployed.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import hmac
import json
import re
import sys
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path, PurePosixPath
from typing import Any, Mapping


APPROVAL_VERSION = 1
ALGORITHM = "RSA-SHA256"
DEFAULT_MAX_AGE = timedelta(days=30)
MAX_FUTURE_SKEW = timedelta(minutes=5)
SHA256_HEX = re.compile(r"^[0-9a-fA-F]{64}$")
COMMIT_SHA = re.compile(r"^[0-9a-fA-F]{40}$")
TASK_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]*$")
REPOSITORY = re.compile(r"^[^/\s]+/[^/\s]+$")
APPROVAL_ID = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F-]{27,}$")
RSA_DIGEST_INFO_PREFIX = bytes.fromhex("3031300d060960864801650304020105000420")


class ApprovalError(Exception):
    """Expected proof or trust-store validation failure."""


@dataclass(frozen=True)
class VerificationResult:
    allowed: bool
    reason: str
    approval_id: str | None = None
    approver_id: str | None = None


@dataclass(frozen=True)
class ApprovalPolicy:
    repository: str
    max_age: timedelta | None = DEFAULT_MAX_AGE
    future_skew: timedelta = MAX_FUTURE_SKEW


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def parse_timestamp(value: Any) -> datetime | None:
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed if parsed.tzinfo else None


def canonical_payload(proof: Mapping[str, Any]) -> bytes:
    fields = {key: proof[key] for key in proof if key != "signature"}
    return json.dumps(fields, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("utf-8")


def task_digest(task_bytes: bytes) -> str:
    return hashlib.sha256(task_bytes).hexdigest()


def valid_task_path(path: str) -> bool:
    pure = PurePosixPath(path)
    return (
        path.startswith("tasks/")
        and "\\" not in path
        and len(pure.parts) == 2
        and pure.parts[0] == "tasks"
        and bool(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*\.md", pure.parts[1]))
        and ".." not in pure.parts
    )


def _deny(reason: str, proof: Mapping[str, Any] | None = None) -> VerificationResult:
    return VerificationResult(False, reason, _optional_string(proof, "approval_id"), _optional_string(proof, "approver_id"))


def _optional_string(value: Mapping[str, Any] | None, key: str) -> str | None:
    if value is None or not isinstance(value.get(key), str):
        return None
    return value[key]


def _decode_signature(value: Any) -> bytes:
    if not isinstance(value, str) or not value:
        raise ApprovalError("signature is missing")
    try:
        return base64.b64decode(value.encode("ascii"), validate=True)
    except (UnicodeEncodeError, binascii.Error) as error:
        raise ApprovalError("signature is not valid base64") from error


def _verify_rsa_sha256(signature: bytes, payload: bytes, key: Mapping[str, Any]) -> bool:
    try:
        modulus = int(key["n"])
        exponent = int(key["e"])
    except (KeyError, TypeError, ValueError) as error:
        raise ApprovalError("trusted RSA key is malformed") from error
    if modulus <= 0 or exponent <= 1 or exponent % 2 == 0:
        raise ApprovalError("trusted RSA key has invalid parameters")
    size = (modulus.bit_length() + 7) // 8
    if len(signature) != size:
        return False
    encoded = pow(int.from_bytes(signature, "big"), exponent, modulus).to_bytes(size, "big")
    digest_info = RSA_DIGEST_INFO_PREFIX + hashlib.sha256(payload).digest()
    padding_length = size - len(digest_info) - 3
    if padding_length < 8:
        return False
    expected = b"\x00\x01" + (b"\xff" * padding_length) + b"\x00" + digest_info
    return hmac.compare_digest(encoded, expected)


def load_trust_store(path: Path) -> dict[str, dict[str, Any]]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ApprovalError(f"cannot read trust store: {error}") from error
    if not isinstance(value, dict) or not isinstance(value.get("approvers"), dict):
        raise ApprovalError("trust store must contain an approvers object")
    return {str(key): entry for key, entry in value["approvers"].items() if isinstance(entry, dict)}


class ApprovalVerifier:
    def __init__(self, trust_store: Mapping[str, Mapping[str, Any]], policy: ApprovalPolicy):
        self.trust_store = trust_store
        self.policy = policy

    def verify(
        self,
        task_bytes: bytes,
        repository: str,
        path: str,
        commit_sha: str,
        proof: Any,
        now: datetime | None = None,
    ) -> VerificationResult:
        if not isinstance(proof, dict):
            return _deny("PROOF_MALFORMED")
        required = {
            "version", "algorithm", "approval_id", "repository", "task_id",
            "path", "commit_sha", "task_sha256", "approver_id", "approved_at", "signature",
        }
        if set(proof) != required:
            return _deny("PROOF_FIELDS_INVALID", proof)
        if proof["version"] != APPROVAL_VERSION or proof["algorithm"] != ALGORITHM:
            return _deny("PROOF_ALGORITHM_OR_VERSION_INVALID", proof)
        approval_id = proof["approval_id"]
        task_id = proof["task_id"]
        approver_id = proof["approver_id"]
        if not isinstance(approval_id, str) or not APPROVAL_ID.fullmatch(approval_id):
            return _deny("APPROVAL_ID_INVALID", proof)
        if not isinstance(task_id, str) or not TASK_ID.fullmatch(task_id):
            return _deny("TASK_ID_INVALID", proof)
        if not isinstance(approver_id, str) or not approver_id or len(approver_id) > 128:
            return _deny("APPROVER_ID_INVALID", proof)
        if not REPOSITORY.fullmatch(repository) or proof["repository"] != repository:
            return _deny("REPOSITORY_MISMATCH", proof)
        if not valid_task_path(path) or proof["path"] != path or PurePosixPath(path).stem != task_id:
            return _deny("TASK_PATH_MISMATCH", proof)
        if not COMMIT_SHA.fullmatch(commit_sha) or proof["commit_sha"] != commit_sha:
            return _deny("COMMIT_SHA_MISMATCH", proof)
        digest = task_digest(task_bytes)
        if not SHA256_HEX.fullmatch(proof["task_sha256"]) or proof["task_sha256"].lower() != digest:
            return _deny("TASK_BYTES_MISMATCH", proof)
        approved_at = parse_timestamp(proof["approved_at"])
        current = now or utc_now()
        if approved_at is None:
            return _deny("APPROVAL_TIME_INVALID", proof)
        if approved_at > current + self.policy.future_skew:
            return _deny("APPROVAL_TIME_IN_FUTURE", proof)
        if self.policy.max_age is not None and current - approved_at > self.policy.max_age:
            return _deny("APPROVAL_EXPIRED", proof)
        trusted = self.trust_store.get(approver_id)
        if trusted is None:
            return _deny("APPROVER_UNAUTHORIZED", proof)
        if trusted.get("revoked") is True:
            return _deny("APPROVER_REVOKED", proof)
        try:
            signature = _decode_signature(proof["signature"])
            valid_signature = _verify_rsa_sha256(signature, canonical_payload(proof), trusted)
        except ApprovalError as error:
            return _deny(str(error).upper().replace(" ", "_"), proof)
        if not valid_signature:
            return _deny("SIGNATURE_INVALID", proof)
        return VerificationResult(True, "APPROVAL_VALID", approval_id, approver_id)


@dataclass(frozen=True)
class ReservationResult:
    reserved: bool
    reason: str


class ApprovalReservationStore:
    """Atomic, durable single-use reservation store for a future executor.

    The verifier and Stage B watcher never call this class. A future isolated
    executor may use it after successful verification. O_EXCL makes the first
    reservation win across processes; an orphaned reservation is retained so a
    crash fails closed rather than replaying approval.
    """

    def __init__(self, directory: Path):
        self.directory = directory

    def reserve(self, result: VerificationResult, repository: str, path: str, commit_sha: str) -> ReservationResult:
        if not result.allowed or not result.approval_id:
            return ReservationResult(False, "APPROVAL_NOT_VERIFIED")
        self.directory.mkdir(parents=True, exist_ok=True)
        reservation = self.directory / f"approval-{result.approval_id}.json"
        payload = {
            "approval_id": result.approval_id,
            "approver_id": result.approver_id,
            "repository": repository,
            "path": path,
            "commit_sha": commit_sha,
            "reserved_at": utc_now().isoformat().replace("+00:00", "Z"),
        }
        try:
            descriptor = reservation.open("x", encoding="utf-8")
        except FileExistsError:
            return ReservationResult(False, "APPROVAL_ALREADY_RESERVED")
        with descriptor:
            descriptor.write(json.dumps(payload, sort_keys=True) + "\n")
        return ReservationResult(True, "APPROVAL_RESERVED")


def read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ApprovalError(f"cannot read JSON input: {error}") from error


def request_approval(args: argparse.Namespace) -> int:
    task_bytes = args.task_file.read_bytes()
    digest = task_digest(task_bytes)
    print("Approval creation is BLOCKED on this workstation.")
    print(f"Task: {args.task_id}")
    print(f"Repository: {args.repository}")
    print(f"Path: {args.path}")
    print(f"Commit: {args.commit_sha}")
    print(f"SHA-256: {digest}")
    expected = f"APPROVE {args.task_id} {digest}"
    response = input(f"Type '{expected}' to confirm the human review scope: ")
    if response != expected:
        print("Approval not created: confirmation did not match.", file=sys.stderr)
        return 4
    print("Approval not created: independent signer/executor isolation is not configured.", file=sys.stderr)
    print("No proof, key, or repository file was written.", file=sys.stderr)
    return 4


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Read-only WATCHER-C1 approval verifier")
    subparsers = parser.add_subparsers(dest="command", required=True)
    verify = subparsers.add_parser("verify")
    verify.add_argument("--task-file", type=Path, required=True)
    verify.add_argument("--repository", required=True)
    verify.add_argument("--path", required=True)
    verify.add_argument("--commit-sha", required=True)
    verify.add_argument("--proof-file", type=Path, required=True)
    verify.add_argument("--trust-file", type=Path, required=True)
    request = subparsers.add_parser("request")
    request.add_argument("--task-file", type=Path, required=True)
    request.add_argument("--task-id", required=True)
    request.add_argument("--repository", required=True)
    request.add_argument("--path", required=True)
    request.add_argument("--commit-sha", required=True)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        if args.command == "request":
            return request_approval(args)
        task_bytes = args.task_file.read_bytes()
        proof = read_json(args.proof_file)
        trust_store = load_trust_store(args.trust_file)
        result = ApprovalVerifier(trust_store, ApprovalPolicy(args.repository)).verify(
            task_bytes, args.repository, args.path, args.commit_sha, proof
        )
        print(json.dumps({"allowed": result.allowed, "reason": result.reason}, sort_keys=True))
        return 0 if result.allowed else 1
    except (OSError, ApprovalError) as error:
        print(f"approval verifier error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
