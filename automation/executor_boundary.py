"""Disabled WATCHER-C2B preflight, source, reservation, and audit interfaces.

This module is intentionally not imported by the Stage B watcher or scheduler.
It provides a fail-closed library for a future isolated broker. No Codex
process, publisher, GitHub write, account, ACL, or approval-creation path is
implemented here.
"""

from __future__ import annotations

import contextlib
import hashlib
import json
import os
import re
import sqlite3
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any, Mapping, Protocol, Sequence

from approval_gate import ApprovalVerifier, GitHubCommitResolver, VerifiedApproval


COMMIT_SHA_RE = re.compile(r"^[0-9a-fA-F]{40}$")
SHA256_RE = re.compile(r"^[0-9a-fA-F]{64}$")
REPOSITORY_RE = re.compile(r"^[^/\s]+/[^/\s]+$")


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def valid_repo_path(path: str) -> bool:
    pure = PurePosixPath(path)
    return (
        isinstance(path, str)
        and path
        and not path.startswith("/")
        and "\\" not in path
        and ".." not in pure.parts
        and all(part not in ("", ".") for part in pure.parts)
    )


@dataclass(frozen=True)
class BoundaryEvidence:
    """Evidence supplied by a separately provisioned Windows preflight.

    The production default is all false. Tests may inject disposable fixture
    evidence, but that does not constitute physical Windows proof.
    """

    activation_enabled: bool = False
    identity_separated: bool = False
    acl_verified: bool = False
    local_ntfs_verified: bool = False
    sandbox_verified: bool = False
    network_disabled: bool = False
    trust_store_external: bool = False
    audit_storage_verified: bool = False
    executor_sid: str | None = None
    broker_sid: str | None = None
    supervisor_sid: str | None = None


@dataclass(frozen=True)
class PreflightResult:
    passed: bool
    reason: str
    missing: tuple[str, ...] = ()


class BoundaryPreflight:
    """Default-deny security boundary preflight; never provisions controls."""

    REQUIRED = (
        "activation_enabled",
        "identity_separated",
        "acl_verified",
        "local_ntfs_verified",
        "sandbox_verified",
        "network_disabled",
        "trust_store_external",
        "audit_storage_verified",
    )

    def __init__(self, evidence: BoundaryEvidence | None = None):
        self.evidence = evidence or BoundaryEvidence()

    def check(self) -> PreflightResult:
        missing = tuple(name for name in self.REQUIRED if not getattr(self.evidence, name))
        for name, value in (
            ("executor_sid", self.evidence.executor_sid),
            ("broker_sid", self.evidence.broker_sid),
            ("supervisor_sid", self.evidence.supervisor_sid),
        ):
            if not value:
                missing += (name,)
        if missing:
            return PreflightResult(False, "EXECUTOR_NOT_ACTIVATED", missing)
        if len({self.evidence.executor_sid, self.evidence.broker_sid, self.evidence.supervisor_sid}) != 3:
            return PreflightResult(False, "IDENTITY_SEPARATION_INVALID", ("distinct_service_sids",))
        return PreflightResult(True, "BOUNDARY_PREFLIGHT_PASSED")


@dataclass(frozen=True)
class SourceEntry:
    path: str
    blob_sha: str
    byte_length: int
    sha256: str


@dataclass(frozen=True)
class SourceManifest:
    tree_sha: str
    entries: tuple[SourceEntry, ...]
    digest: str

    @staticmethod
    def create(tree_sha: str, files: Mapping[str, bytes], allowed_paths: Sequence[str]) -> "SourceManifest":
        if not COMMIT_SHA_RE.fullmatch(tree_sha):
            raise ValueError("source tree SHA is invalid")
        expected = set(allowed_paths)
        if len(expected) != len(allowed_paths) or not expected or any(not valid_repo_path(path) for path in expected):
            raise ValueError("source allowlist is invalid")
        if set(files) != expected:
            raise ValueError("source file set does not match the allowlist")
        entries: list[SourceEntry] = []
        for path in sorted(expected):
            content = files[path]
            if not isinstance(content, bytes):
                raise ValueError("source content must be exact bytes")
            blob_sha = hashlib.sha1(b"blob " + str(len(content)).encode("ascii") + b"\0" + content).hexdigest()
            digest = hashlib.sha256(content).hexdigest()
            entries.append(SourceEntry(path, blob_sha, len(content), digest))
        canonical = [entry.__dict__ for entry in entries]
        manifest_digest = hashlib.sha256(
            json.dumps({"tree_sha": tree_sha, "entries": canonical}, sort_keys=True, separators=(",", ":")).encode("utf-8")
        ).hexdigest()
        return SourceManifest(tree_sha, tuple(entries), manifest_digest)

    def entry(self, path: str) -> SourceEntry | None:
        return next((entry for entry in self.entries if entry.path == path), None)


@dataclass(frozen=True)
class SourceSnapshot:
    repository: str
    commit_sha: str
    main_reachable: bool
    files: Mapping[str, bytes]
    manifest: SourceManifest


class SourceSnapshotProvider(Protocol):
    def resolve(self, repository: str, commit_sha: str, allowed_paths: Sequence[str]) -> SourceSnapshot:
        """Resolve exact files and tree identity from an immutable source."""


@dataclass(frozen=True)
class ReservationRecord:
    approval_id: str
    reservation_id: str
    repository: str
    task_id: str
    path: str
    commit_sha: str
    task_sha256: str
    tree_sha: str
    manifest_digest: str
    executor_sid: str
    state: str


@dataclass(frozen=True)
class ReservationResult:
    reserved: bool
    reason: str
    record: ReservationRecord | None = None


class DurableReservationJournal:
    """SQLite single-use journal; it is inert until verified evidence is supplied."""

    STATES = {"RESERVED", "RUNNING", "SUCCEEDED", "FAILED", "ABANDONED"}

    def __init__(self, path: Path, evidence: BoundaryEvidence | None = None, connection_factory: Any = sqlite3.connect):
        self.path = path
        self.preflight = BoundaryPreflight(evidence)
        self.connection_factory = connection_factory

    def _connect_checked(self) -> sqlite3.Connection:
        result = self.preflight.check()
        if not result.passed:
            raise RuntimeError(result.reason)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        connection = self.connection_factory(str(self.path), timeout=2.0)
        try:
            connection.execute("PRAGMA journal_mode=DELETE")
            connection.execute("PRAGMA synchronous=FULL")
            connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS reservations (
                  approval_id TEXT PRIMARY KEY,
                  reservation_id TEXT NOT NULL UNIQUE,
                  repository TEXT NOT NULL,
                  task_id TEXT NOT NULL,
                  path TEXT NOT NULL,
                  commit_sha TEXT NOT NULL,
                  task_sha256 TEXT NOT NULL,
                  tree_sha TEXT NOT NULL,
                  manifest_digest TEXT NOT NULL,
                  executor_sid TEXT NOT NULL,
                  state TEXT NOT NULL,
                  created_at TEXT NOT NULL,
                  updated_at TEXT NOT NULL
                );
                """
            )
            integrity = connection.execute("PRAGMA integrity_check").fetchone()
            if not integrity or integrity[0] != "ok":
                raise RuntimeError("RESERVATION_DATABASE_INTEGRITY_FAILED")
            return connection
        except Exception:
            with contextlib.suppress(Exception):
                connection.close()
            raise

    def reserve(self, capability: VerifiedApproval, task_id: str, manifest: SourceManifest, executor_sid: str) -> ReservationResult:
        if not isinstance(capability, VerifiedApproval):
            return ReservationResult(False, "APPROVAL_CAPABILITY_INVALID")
        if capability.task_sha256 != (manifest.entry(capability.path).sha256 if manifest.entry(capability.path) else None):
            return ReservationResult(False, "SOURCE_MANIFEST_TASK_MISMATCH")
        if not executor_sid:
            return ReservationResult(False, "EXECUTOR_IDENTITY_MISSING")
        try:
            connection = self._connect_checked()
        except (OSError, RuntimeError, sqlite3.Error):
            return ReservationResult(False, "RESERVATION_DURABILITY_UNKNOWN")
        reservation_id = str(uuid.uuid4())
        timestamp = utc_now()
        try:
            connection.execute("BEGIN IMMEDIATE")
            existing = connection.execute("SELECT 1 FROM reservations WHERE approval_id = ?", (capability.approval_id,)).fetchone()
            if existing:
                connection.rollback()
                connection.close()
                return ReservationResult(False, "APPROVAL_ALREADY_RESERVED")
            connection.execute(
                "INSERT INTO reservations VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (
                    capability.approval_id, reservation_id, capability.repository, task_id,
                    capability.path, capability.commit_sha, capability.task_sha256,
                    manifest.tree_sha, manifest.digest, executor_sid, "RESERVED", timestamp, timestamp,
                ),
            )
            connection.commit()
            connection.close()
        except Exception:
            with contextlib.suppress(Exception):
                connection.rollback()
            with contextlib.suppress(Exception):
                connection.close()
            return ReservationResult(False, "RESERVATION_DURABILITY_UNKNOWN")
        return ReservationResult(True, "APPROVAL_RESERVED", self.get(capability.approval_id))

    def get(self, approval_id: str) -> ReservationRecord | None:
        try:
            connection = self._connect_checked()
            row = connection.execute("SELECT approval_id, reservation_id, repository, task_id, path, commit_sha, task_sha256, tree_sha, manifest_digest, executor_sid, state FROM reservations WHERE approval_id = ?", (approval_id,)).fetchone()
            connection.close()
        except (OSError, RuntimeError, sqlite3.Error):
            return None
        return ReservationRecord(*row) if row else None

    def recoverable(self) -> list[ReservationRecord]:
        try:
            connection = self._connect_checked()
            rows = connection.execute("SELECT approval_id, reservation_id, repository, task_id, path, commit_sha, task_sha256, tree_sha, manifest_digest, executor_sid, state FROM reservations WHERE state IN ('RESERVED', 'RUNNING')").fetchall()
            connection.close()
        except (OSError, RuntimeError, sqlite3.Error):
            return []
        return [ReservationRecord(*row) for row in rows]

    def transition(self, approval_id: str, state: str) -> bool:
        if state not in self.STATES or state == "RESERVED":
            return False
        try:
            connection = self._connect_checked()
            connection.execute("BEGIN IMMEDIATE")
            changed = connection.execute("UPDATE reservations SET state = ?, updated_at = ? WHERE approval_id = ? AND state IN ('RESERVED', 'RUNNING')", (state, utc_now(), approval_id)).rowcount
            connection.commit()
            connection.close()
            return changed == 1
        except (OSError, RuntimeError, sqlite3.Error):
            return False


class AuditLog:
    """Bounded hash-chained audit records with conservative secret redaction."""

    def __init__(self, path: Path, max_bytes: int = 512 * 1024, max_lines: int = 500):
        self.path = path
        self.max_bytes = max_bytes
        self.max_lines = max_lines
        self.previous_hash = "0" * 64

    @staticmethod
    def _safe(value: Any) -> Any:
        if isinstance(value, Mapping):
            return {str(key): ("<redacted>" if re.search(r"token|secret|password|signature|private|proof", str(key), re.I) else AuditLog._safe(item)) for key, item in value.items()}
        if isinstance(value, (list, tuple)):
            return [AuditLog._safe(item) for item in value]
        if isinstance(value, str) and re.search(r"bearer\s+\S+|gh[pousr]_[A-Za-z0-9_]+", value, re.I):
            return "<redacted>"
        return value

    def append(self, event: str, details: Mapping[str, Any] | None = None) -> None:
        record = {"timestamp": utc_now(), "event": event, "details": self._safe(details or {}), "previous_hash": self.previous_hash}
        encoded = json.dumps(record, sort_keys=True, ensure_ascii=True, separators=(",", ":"))
        record["record_hash"] = hashlib.sha256(encoded.encode("utf-8")).hexdigest()
        line = json.dumps(record, sort_keys=True, ensure_ascii=True) + "\n"
        if len(line.encode("utf-8")) > self.max_bytes:
            raise RuntimeError("AUDIT_RECORD_TOO_LARGE")
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.path.open("a", encoding="utf-8", newline="\n") as stream:
            stream.write(line)
            stream.flush()
            os.fsync(stream.fileno())
        self.previous_hash = record["record_hash"]
        lines = self.path.read_text(encoding="utf-8").splitlines()[-self.max_lines:]
        while len(("\n".join(lines) + "\n").encode("utf-8")) > self.max_bytes:
            lines.pop(0)
        self.path.write_text("\n".join(lines) + "\n", encoding="utf-8")


@dataclass(frozen=True)
class BrokerResult:
    allowed: bool
    reason: str
    reservation: ReservationRecord | None = None


class ApprovalBroker:
    """Broker-side re-verification and reservation interface.

    It accepts a proof and source scope, never a caller-created allowed flag.
    It does not execute a process or publish anything.
    """

    def __init__(self, verifier: ApprovalVerifier, resolver: GitHubCommitResolver, source_provider: SourceSnapshotProvider, journal: DurableReservationJournal, preflight: BoundaryPreflight, audit: AuditLog):
        self.verifier = verifier
        self.resolver = resolver
        self.source_provider = source_provider
        self.journal = journal
        self.preflight = preflight
        self.audit = audit

    def reserve(self, proof: Any, repository: str, path: str, commit_sha: str, task_id: str, allowed_paths: Sequence[str], executor_sid: str, now: datetime | None = None) -> BrokerResult:
        preflight = self.preflight.check()
        if not preflight.passed:
            self.audit.append("EXECUTOR_BLOCKED", {"reason": preflight.reason, "missing": preflight.missing})
            return BrokerResult(False, preflight.reason)
        if not REPOSITORY_RE.fullmatch(repository) or not COMMIT_SHA_RE.fullmatch(commit_sha) or not valid_repo_path(path) or path not in allowed_paths:
            return BrokerResult(False, "SOURCE_SCOPE_INVALID")
        result = self.verifier.verify_from_github(self.resolver, repository, path, commit_sha, proof, now)
        if not result.allowed or result.descriptor is None or not result.source_verified:
            self.audit.append("PROOF_DENIED", {"reason": result.reason})
            return BrokerResult(False, result.reason)
        capability = result.descriptor
        if capability.repository != repository or capability.path != path or capability.commit_sha != commit_sha:
            return BrokerResult(False, "CAPABILITY_SCOPE_MISMATCH")
        try:
            snapshot = self.source_provider.resolve(repository, commit_sha, allowed_paths)
            task_entry = snapshot.manifest.entry(path)
            expected_manifest = SourceManifest.create(snapshot.manifest.tree_sha, snapshot.files, allowed_paths)
            if (
                snapshot.repository != repository
                or snapshot.commit_sha != commit_sha
                or not snapshot.main_reachable
                or snapshot.manifest != expected_manifest
                or task_entry is None
                or task_entry.sha256 != capability.task_sha256
            ):
                return BrokerResult(False, "SOURCE_MANIFEST_UNVERIFIED")
            reservation = self.journal.reserve(capability, task_id, snapshot.manifest, executor_sid)
        except (OSError, ValueError, RuntimeError):
            return BrokerResult(False, "SOURCE_MANIFEST_UNVERIFIED")
        self.audit.append("RESERVATION_CREATED" if reservation.reserved else "RESERVATION_BLOCKED", {"approval_id": capability.approval_id, "reason": reservation.reason, "manifest_digest": snapshot.manifest.digest})
        return BrokerResult(reservation.reserved, reservation.reason, reservation.record)
