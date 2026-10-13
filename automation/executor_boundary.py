"""Disabled WATCHER-C2B broker boundary primitives.

There is no executor, Codex, scheduler, GitHub-write, account, ACL, key, or
approval-creation path here. Production attestation and recovery authorization
are deny-by-default; test doubles live in the test module only.
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
ZERO_HASH = "0" * 64


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def valid_repo_path(path: str) -> bool:
    pure = PurePosixPath(path)
    return isinstance(path, str) and bool(path) and not path.startswith("/") and "\\" not in path and ".." not in pure.parts and all(part not in ("", ".") for part in pure.parts)


@dataclass(frozen=True)
class PreflightResult:
    passed: bool
    reason: str
    missing: tuple[str, ...] = ()
    executor_sid: str | None = None
    broker_sid: str | None = None
    supervisor_sid: str | None = None


class WindowsBoundaryAttestationProvider:
    """Production provider. Independent Windows attestation is not active."""

    def attest(self) -> PreflightResult:
        return PreflightResult(False, "EXECUTOR_NOT_ACTIVATED", (
            "activation_enabled", "identity_separated", "acl_verified", "local_ntfs_verified",
            "sandbox_verified", "network_disabled", "trust_store_external", "audit_storage_verified",
            "executor_sid", "broker_sid", "supervisor_sid"))


class BoundaryPreflight:
    """Production-only gate; it cannot consume caller-provided evidence."""

    def __init__(self) -> None:
        self.provider = WindowsBoundaryAttestationProvider()

    def check(self) -> PreflightResult:
        return self.provider.attest()


class RecoveryAuthority(Protocol):
    def authorize(self, approval_id: str, current: str, target: str) -> bool: ...


class WindowsRecoveryAuthority:
    """Production recovery authority; human-authenticated IPC is not active."""

    def authorize(self, approval_id: str, current: str, target: str) -> bool:
        return False


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
    def _digest(tree_sha: str, entries: Sequence[SourceEntry]) -> str:
        return hashlib.sha256(json.dumps({"tree_sha": tree_sha, "entries": [e.__dict__ for e in entries]}, sort_keys=True, separators=(",", ":")).encode()).hexdigest()

    @staticmethod
    def create(tree_sha: str, files: Mapping[str, bytes], allowed_paths: Sequence[str]) -> "SourceManifest":
        expected = set(allowed_paths)
        if not COMMIT_SHA_RE.fullmatch(tree_sha) or not expected or len(expected) != len(allowed_paths) or any(not valid_repo_path(p) for p in expected) or set(files) != expected:
            raise ValueError("source manifest scope is invalid")
        entries = []
        for path in sorted(expected):
            content = files[path]
            if not isinstance(content, bytes):
                raise ValueError("source content must be exact bytes")
            entries.append(SourceEntry(path, hashlib.sha1(b"blob " + str(len(content)).encode() + b"\0" + content).hexdigest(), len(content), hashlib.sha256(content).hexdigest()))
        return SourceManifest(tree_sha, tuple(entries), SourceManifest._digest(tree_sha, entries))

    def validate(self, allowed_paths: Sequence[str] | None = None) -> bool:
        paths = [e.path for e in self.entries]
        if not COMMIT_SHA_RE.fullmatch(self.tree_sha) or paths != sorted(paths) or len(paths) != len(set(paths)):
            return False
        if any(not valid_repo_path(e.path) or e.byte_length < 0 or not SHA256_RE.fullmatch(e.sha256) or not re.fullmatch(r"[0-9a-f]{40}", e.blob_sha) for e in self.entries):
            return False
        return (allowed_paths is None or set(paths) == set(allowed_paths)) and self.digest == self._digest(self.tree_sha, self.entries)

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
    def resolve(self, repository: str, commit_sha: str, allowed_paths: Sequence[str]) -> SourceSnapshot: ...


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


class ReservationStoreError(RuntimeError):
    pass


class AuditFailure(RuntimeError):
    pass


class DurableReservationJournal:
    SCHEMA_VERSION = 2
    STATES = {"RESERVED", "RUNNING", "SUCCEEDED", "FAILED", "ABANDONED"}
    COLUMNS = ("approval_id", "reservation_id", "repository", "task_id", "path", "commit_sha", "task_sha256", "tree_sha", "manifest_digest", "executor_sid", "state", "created_at", "updated_at")
    COLUMN_INFO = (("approval_id", "TEXT", 0, 1), ("reservation_id", "TEXT", 1, 0), ("repository", "TEXT", 1, 0), ("task_id", "TEXT", 1, 0), ("path", "TEXT", 1, 0), ("commit_sha", "TEXT", 1, 0), ("task_sha256", "TEXT", 1, 0), ("tree_sha", "TEXT", 1, 0), ("manifest_digest", "TEXT", 1, 0), ("executor_sid", "TEXT", 1, 0), ("state", "TEXT", 1, 0), ("created_at", "TEXT", 1, 0), ("updated_at", "TEXT", 1, 0))
    TRANSITIONS = {("RESERVED", "RUNNING", "executor"), ("RUNNING", "SUCCEEDED", "executor"), ("RUNNING", "FAILED", "executor")}

    def __init__(self, path: Path, preflight: BoundaryPreflight | None = None, connection_factory: Any = sqlite3.connect, recovery_authority: RecoveryAuthority | None = None):
        self.path, self.preflight, self.connection_factory = path, preflight or BoundaryPreflight(), connection_factory
        self.recovery_authority = recovery_authority or WindowsRecoveryAuthority()

    def _connect_checked(self) -> sqlite3.Connection:
        result = self.preflight.check()
        if not result.passed:
            raise ReservationStoreError(result.reason)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        new_file, connection = not self.path.exists(), None
        try:
            connection = self.connection_factory(str(self.path), timeout=5.0)
            connection.execute("PRAGMA journal_mode=DELETE")
            connection.execute("PRAGMA synchronous=FULL")
            journal_mode = connection.execute("PRAGMA journal_mode").fetchone()
            synchronous = connection.execute("PRAGMA synchronous").fetchone()
            if not journal_mode or str(journal_mode[0]).lower() != "delete" or not synchronous or int(synchronous[0]) != 2:
                raise ReservationStoreError("RESERVATION_PRAGMA_UNSAFE")
            table_exists = connection.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='reservations'").fetchone()
            if new_file or not table_exists:
                connection.execute("BEGIN EXCLUSIVE")
                table_exists = connection.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='reservations'").fetchone()
                if not table_exists:
                    connection.executescript("""CREATE TABLE reservations (approval_id TEXT PRIMARY KEY, reservation_id TEXT NOT NULL UNIQUE, repository TEXT NOT NULL, task_id TEXT NOT NULL, path TEXT NOT NULL, commit_sha TEXT NOT NULL, task_sha256 TEXT NOT NULL, tree_sha TEXT NOT NULL, manifest_digest TEXT NOT NULL, executor_sid TEXT NOT NULL, state TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL); PRAGMA user_version=2;""")
                connection.commit()
            version = connection.execute("PRAGMA user_version").fetchone()
            table = connection.execute("SELECT name, sql FROM sqlite_master WHERE type='table' AND name='reservations'").fetchone()
            info = connection.execute("PRAGMA table_info(reservations)").fetchall()
            actual = tuple((row[1], str(row[2]).upper(), int(row[3]), int(row[5])) for row in info)
            if not version or int(version[0]) != self.SCHEMA_VERSION or not table or actual != self.COLUMN_INFO or "WITHOUT ROWID" in table[1].upper():
                raise ReservationStoreError("RESERVATION_SCHEMA_INVALID")
            integrity = connection.execute("PRAGMA integrity_check").fetchone()
            if not integrity or integrity[0] != "ok":
                raise ReservationStoreError("RESERVATION_DATABASE_INTEGRITY_FAILED")
            return connection
        except Exception:
            with contextlib.suppress(Exception): connection.close()  # type: ignore[union-attr]
            raise

    @staticmethod
    def _row(row: Sequence[Any]) -> ReservationRecord:
        if len(row) != 11:
            raise ReservationStoreError("RESERVATION_ROW_INVALID")
        record = ReservationRecord(*row)
        if (not record.approval_id or not record.reservation_id or not REPOSITORY_RE.fullmatch(record.repository) or not valid_repo_path(record.path) or
                not COMMIT_SHA_RE.fullmatch(record.commit_sha) or not SHA256_RE.fullmatch(record.task_sha256) or not COMMIT_SHA_RE.fullmatch(record.tree_sha) or
                not SHA256_RE.fullmatch(record.manifest_digest) or not record.executor_sid.startswith("S-") or record.state not in DurableReservationJournal.STATES):
            raise ReservationStoreError("RESERVATION_ROW_INVALID")
        return record

    def reserve(self, capability: VerifiedApproval, manifest: SourceManifest) -> ReservationResult:
        if not isinstance(capability, VerifiedApproval): return ReservationResult(False, "APPROVAL_CAPABILITY_INVALID")
        task_id, entry = PurePosixPath(capability.path).stem, manifest.entry(capability.path)
        if not valid_repo_path(capability.path) or not task_id or not manifest.validate() or entry is None: return ReservationResult(False, "SOURCE_MANIFEST_INVALID")
        if entry.sha256 != capability.task_sha256: return ReservationResult(False, "SOURCE_MANIFEST_TASK_MISMATCH")
        result = self.preflight.check()
        if not result.passed or not result.executor_sid: return ReservationResult(False, "RESERVATION_DURABILITY_UNKNOWN")
        try: connection = self._connect_checked()
        except (OSError, sqlite3.Error, ReservationStoreError): return ReservationResult(False, "RESERVATION_DURABILITY_UNKNOWN")
        reservation_id, timestamp = str(uuid.uuid4()), utc_now()
        try:
            connection.execute("BEGIN IMMEDIATE")
            if connection.execute("SELECT 1 FROM reservations WHERE approval_id=?", (capability.approval_id,)).fetchone():
                connection.rollback(); connection.close(); return ReservationResult(False, "APPROVAL_ALREADY_RESERVED")
            connection.execute("INSERT INTO reservations VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)", (capability.approval_id, reservation_id, capability.repository, task_id, capability.path, capability.commit_sha, capability.task_sha256, manifest.tree_sha, manifest.digest, result.executor_sid, "RESERVED", timestamp, timestamp))
            connection.commit()
            record = ReservationRecord(capability.approval_id, reservation_id, capability.repository, task_id, capability.path, capability.commit_sha, capability.task_sha256, manifest.tree_sha, manifest.digest, result.executor_sid, "RESERVED")
            connection.close(); return ReservationResult(True, "APPROVAL_RESERVED", record)
        except Exception:
            with contextlib.suppress(Exception): connection.rollback()
            with contextlib.suppress(Exception): connection.close()
            return ReservationResult(False, "RESERVATION_DURABILITY_UNKNOWN")

    def get(self, approval_id: str) -> ReservationRecord | None:
        connection = self._connect_checked()
        try:
            row = connection.execute("SELECT approval_id,reservation_id,repository,task_id,path,commit_sha,task_sha256,tree_sha,manifest_digest,executor_sid,state FROM reservations WHERE approval_id=?", (approval_id,)).fetchone()
            return self._row(row) if row else None
        finally: connection.close()

    def recoverable(self) -> list[ReservationRecord]:
        connection = self._connect_checked()
        try:
            rows = connection.execute("SELECT approval_id,reservation_id,repository,task_id,path,commit_sha,task_sha256,tree_sha,manifest_digest,executor_sid,state FROM reservations WHERE state IN ('RESERVED','RUNNING')").fetchall()
            return [self._row(row) for row in rows]
        finally: connection.close()

    def transition(self, approval_id: str, state: str, actor: str) -> bool:
        if state not in self.STATES or actor not in {"executor", "human_recovery"}: raise ReservationStoreError("RESERVATION_TRANSITION_INVALID")
        connection = self._connect_checked()
        try:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute("SELECT approval_id,reservation_id,repository,task_id,path,commit_sha,task_sha256,tree_sha,manifest_digest,executor_sid,state FROM reservations WHERE approval_id=?", (approval_id,)).fetchone()
            if not row: connection.rollback(); return False
            current = self._row(row).state
            if actor == "human_recovery":
                if state != "ABANDONED" or not self.recovery_authority.authorize(approval_id, current, state):
                    connection.rollback(); raise ReservationStoreError("RECOVERY_AUTHORIZATION_REQUIRED")
            elif (current, state, actor) not in self.TRANSITIONS:
                connection.rollback(); raise ReservationStoreError("RESERVATION_TRANSITION_INVALID")
            changed = connection.execute("UPDATE reservations SET state=?,updated_at=? WHERE approval_id=? AND state=?", (state, utc_now(), approval_id, current)).rowcount
            connection.commit(); return changed == 1
        except Exception:
            with contextlib.suppress(Exception): connection.rollback()
            raise
        finally: connection.close()


class _InterprocessLock:
    def __init__(self, path: Path): self.path, self.stream = path, None
    def __enter__(self):
        self.path.parent.mkdir(parents=True, exist_ok=True); self.stream = self.path.open("a+b")
        if os.name == "nt":
            import msvcrt; msvcrt.locking(self.stream.fileno(), msvcrt.LK_LOCK, 1)
        else:
            import fcntl; fcntl.flock(self.stream.fileno(), fcntl.LOCK_EX)
        return self
    def __exit__(self, *_):
        if self.stream is None: return
        if os.name == "nt":
            import msvcrt; self.stream.seek(0); msvcrt.locking(self.stream.fileno(), msvcrt.LK_UNLCK, 1)
        else:
            import fcntl; fcntl.flock(self.stream.fileno(), fcntl.LOCK_UN)
        self.stream.close()


class AuditLog:
    TERMINAL_EVENTS = {"SUCCEEDED", "FAILED", "ABANDONED", "RESERVATION_SUCCEEDED", "EXECUTION_SUCCEEDED", "EXECUTION_FAILED", "TERMINAL"}

    def __init__(self, path: Path, max_bytes: int = 512 * 1024, max_lines: int = 500, max_segments: int = 8):
        if max_bytes <= 0 or max_lines <= 0 or max_segments <= 0: raise ValueError("audit bounds are invalid")
        self.path, self.anchor, self.lock = path, path.with_name(path.name + ".anchor"), path.with_name(path.name + ".lock")
        self.max_bytes, self.max_lines, self.max_segments = max_bytes, max_lines, max_segments

    @staticmethod
    def _safe(value: Any) -> Any:
        if isinstance(value, Mapping): return {str(k): ("<redacted>" if re.search(r"token|secret|password|signature|private|proof", str(k), re.I) else AuditLog._safe(v)) for k, v in value.items()}
        if isinstance(value, (list, tuple)): return [AuditLog._safe(v) for v in value]
        if isinstance(value, str) and re.search(r"bearer\s+\S+|gh[pousr]_[A-Za-z0-9_]+", value, re.I): return "<redacted>"
        return value

    def _anchor_value(self) -> tuple[int, str]:
        if not self.anchor.exists():
            if self.path.exists() and self.path.stat().st_size: raise AuditFailure("AUDIT_ANCHOR_MISSING")
            return 0, ZERO_HASH
        try:
            value = json.loads(self.anchor.read_text(encoding="utf-8")); sequence, last_hash = value["sequence"], value["last_hash"]
            if not isinstance(sequence, int) or sequence < 0 or not SHA256_RE.fullmatch(last_hash): raise ValueError
            for segment in self.path.parent.glob(self.path.stem + ".*." + self.path.suffix.lstrip(".")):
                match = re.search(r"\.(\d{20})\." + re.escape(self.path.suffix.lstrip(".")) + r"$", segment.name)
                if match and int(match.group(1)) > sequence: raise AuditFailure("AUDIT_ROTATION_RECOVERY_REQUIRED")
            return sequence, last_hash
        except AuditFailure: raise
        except (OSError, ValueError, KeyError, json.JSONDecodeError) as exc: raise AuditFailure("AUDIT_ANCHOR_INVALID") from exc

    def _write_anchor(self, sequence: int, last_hash: str) -> None:
        temp = self.anchor.with_name(self.anchor.name + ".tmp")
        try:
            temp.write_text(json.dumps({"sequence": sequence, "last_hash": last_hash}, sort_keys=True) + "\n", encoding="utf-8")
            with temp.open("r+b") as stream: stream.flush(); os.fsync(stream.fileno())
            os.replace(temp, self.anchor)
        except Exception as exc: raise AuditFailure("AUDIT_DURABILITY_UNKNOWN") from exc

    def _rotate_and_prune(self, sequence: int) -> None:
        try: os.replace(self.path, self.path.with_name(f"{self.path.stem}.{sequence:020d}{self.path.suffix}"))
        except OSError as exc: raise AuditFailure("AUDIT_ROTATION_FAILED") from exc
        segments = sorted(self.path.parent.glob(self.path.stem + ".*." + self.path.suffix.lstrip(".")))
        if len(segments) <= self.max_segments: return
        for segment in segments[:-self.max_segments]:
            try:
                events = {json.loads(line).get("event") for line in segment.read_text(encoding="utf-8").splitlines() if line.strip()}
                if not events.intersection(self.TERMINAL_EVENTS): segment.unlink()
            except Exception as exc: raise AuditFailure("AUDIT_RETENTION_FAILED") from exc

    def append(self, event: str, details: Mapping[str, Any] | None = None) -> None:
        if not isinstance(event, str) or not event or len(event) > 128: raise AuditFailure("AUDIT_EVENT_INVALID")
        try:
            with _InterprocessLock(self.lock):
                sequence, previous_hash = self._anchor_value()
                record = {"timestamp": utc_now(), "event": event, "details": self._safe(details or {}), "previous_hash": previous_hash, "sequence": sequence + 1}
                encoded = json.dumps(record, sort_keys=True, ensure_ascii=True, separators=(",", ":")); record["record_hash"] = hashlib.sha256(encoded.encode()).hexdigest()
                line = json.dumps(record, sort_keys=True, ensure_ascii=True) + "\n"
                if len(line.encode()) > self.max_bytes: raise AuditFailure("AUDIT_RECORD_TOO_LARGE")
                self.path.parent.mkdir(parents=True, exist_ok=True)
                with self.path.open("a", encoding="utf-8", newline="\n") as stream: stream.write(line); stream.flush(); os.fsync(stream.fileno())
                self._write_anchor(sequence + 1, record["record_hash"])
                if self.path.stat().st_size > self.max_bytes or sequence + 1 > self.max_lines: self._rotate_and_prune(sequence + 1)
        except AuditFailure: raise
        except Exception as exc: raise AuditFailure("AUDIT_DURABILITY_UNKNOWN") from exc


@dataclass(frozen=True)
class BrokerResult:
    allowed: bool
    reason: str
    reservation: ReservationRecord | None = None


class ApprovalBroker:
    def __init__(self, verifier: ApprovalVerifier, resolver: GitHubCommitResolver, source_provider: SourceSnapshotProvider, journal: DurableReservationJournal, preflight: BoundaryPreflight, audit: AuditLog, repository: str, allowed_paths: Sequence[str]):
        if not REPOSITORY_RE.fullmatch(repository) or not allowed_paths or len(set(allowed_paths)) != len(allowed_paths) or any(not valid_repo_path(p) for p in allowed_paths): raise ValueError("broker policy is invalid")
        self.verifier, self.resolver, self.source_provider, self.journal, self.preflight, self.audit = verifier, resolver, source_provider, journal, preflight, audit
        self.repository, self.allowed_paths = repository, tuple(sorted(allowed_paths))

    def _audit(self, event: str, details: Mapping[str, Any]) -> BrokerResult | None:
        try: self.audit.append(event, details)
        except AuditFailure: return BrokerResult(False, "AUDIT_DURABILITY_UNKNOWN")
        return None

    def reserve(self, proof: Any, path: str, commit_sha: str, now: datetime | None = None) -> BrokerResult:
        preflight = self.preflight.check()
        if not preflight.passed:
            failure = self._audit("EXECUTOR_BLOCKED", {"reason": preflight.reason, "missing": preflight.missing})
            return failure or BrokerResult(False, preflight.reason)
        if path not in self.allowed_paths or not COMMIT_SHA_RE.fullmatch(commit_sha): return BrokerResult(False, "SOURCE_SCOPE_INVALID")
        result = self.verifier.verify_from_github(self.resolver, self.repository, path, commit_sha, proof, now)
        if not result.allowed or result.descriptor is None or not result.source_verified:
            failure = self._audit("PROOF_DENIED", {"reason": result.reason})
            return failure or BrokerResult(False, result.reason)
        capability = result.descriptor
        if capability.repository != self.repository or capability.path != path or capability.commit_sha != commit_sha: return BrokerResult(False, "CAPABILITY_SCOPE_MISMATCH")
        try:
            snapshot = self.source_provider.resolve(self.repository, commit_sha, self.allowed_paths)
            expected = SourceManifest.create(snapshot.manifest.tree_sha, snapshot.files, self.allowed_paths)
            entry = snapshot.manifest.entry(path)
            if snapshot.repository != self.repository or snapshot.commit_sha != commit_sha or not snapshot.main_reachable or snapshot.manifest != expected or not snapshot.manifest.validate(self.allowed_paths) or entry is None or entry.sha256 != capability.task_sha256: return BrokerResult(False, "SOURCE_MANIFEST_UNVERIFIED")
        except (OSError, ValueError, RuntimeError): return BrokerResult(False, "SOURCE_MANIFEST_UNVERIFIED")
        try: reservation = self.journal.reserve(capability, snapshot.manifest)
        except (OSError, sqlite3.Error, ReservationStoreError): return BrokerResult(False, "RESERVATION_DURABILITY_UNKNOWN")
        failure = self._audit("RESERVATION_CREATED" if reservation.reserved else "RESERVATION_BLOCKED", {"approval_id": capability.approval_id, "reason": reservation.reason, "manifest_digest": snapshot.manifest.digest})
        return failure or BrokerResult(reservation.reserved, reservation.reason, reservation.record)
