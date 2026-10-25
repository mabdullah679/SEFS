"""SEFS writer: drops one JSON file into SHARED_DIR every WRITER_INTERVAL_SECONDS.

Contract (docs/CONTRACTS.md section 3, "apps (application code)"); log lines are a
test interface, do not reword them:
  WRITER_START uid=<uid> gid=<gid> dir=<dir>
  WROTE <filename> sha256=<hex>
  WRITE_ERROR <errno-name> <message>
  WRITER_STOP signal=<name> files=<n>
Python 3.12 standard library only. Deterministic given (clock, uuid): the file's bytes are a
canonical JSON dump, so the logged sha256 is reproducible from the payload.
"""

from __future__ import annotations

import datetime as _dt
import errno
import hashlib
import json
import os
import signal
import sys
import threading
import uuid
from dataclasses import dataclass


@dataclass(frozen=True)
class WriterConfig:
    """Everything the writer reads from its environment, in one immutable object."""

    shared_dir: str
    interval_seconds: float
    file_mode: int = 0o644  # group/other readable so the reader (other UID, same GID) can read
    dir_mode: int = 0o775  # matches the access point creation_info permissions

    @classmethod
    def from_env(cls, env: dict[str, str] | None = None) -> "WriterConfig":
        env = os.environ if env is None else env
        return cls(
            shared_dir=env.get("SHARED_DIR", "/mnt/shared"),
            interval_seconds=float(env.get("WRITER_INTERVAL_SECONDS", "5")),
        )


class Log:
    """Line-buffered stdout: every contract line is flushed as it is written."""

    @staticmethod
    def line(text: str) -> None:
        sys.stdout.write(text + "\n")
        sys.stdout.flush()


class AtomicFileWriter:
    """Writes one file so that a concurrent reader never sees a partial file.

    temp file ("." prefix, ".tmp" suffix: never matches a reader's "*.json" listing)
    -> fsync -> rename (atomic within one directory on POSIX and NFSv4) -> fsync(dir).
    """

    def __init__(self, directory: str, file_mode: int) -> None:
        self._dir = directory
        self._mode = file_mode

    @staticmethod
    def _fsync_dir(path: str) -> None:
        fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)

    def write(self, filename: str, data: bytes) -> None:
        tmp_path = os.path.join(self._dir, f".{filename}.tmp")
        final_path = os.path.join(self._dir, filename)
        fd = os.open(tmp_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, self._mode)
        try:
            os.fchmod(fd, self._mode)  # independent of whatever umask the runtime set
            view = memoryview(data)
            while view:
                written = os.write(fd, view)
                view = view[written:]
            os.fsync(fd)
        except BaseException:
            os.close(fd)
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
            raise
        os.close(fd)
        os.rename(tmp_path, final_path)
        self._fsync_dir(self._dir)


class Payload:
    """The content of one file: canonical JSON, so identical inputs give identical bytes."""

    def __init__(self, seq: int, now: _dt.datetime) -> None:
        self.seq = seq
        self.now = now
        self.filename = f"{now.strftime('%Y%m%dT%H%M%S.%fZ')}-{uuid.uuid4()}.json"  # ISO 8601 basic, no colons

    def bytes(self) -> bytes:
        body = {
            "timestamp": self.now.isoformat(),
            "seq": self.seq,
            "writer_uid": os.getuid(),
            "writer_gid": os.getgid(),
        }
        return (json.dumps(body, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")

    @staticmethod
    def sha256(data: bytes) -> str:
        return hashlib.sha256(data).hexdigest()


class Writer:
    """The service: write a file every interval until told to stop; never crash on a write error."""

    def __init__(self, config: WriterConfig, log: Log | None = None) -> None:
        self._cfg = config
        self._log = log or Log()
        self._stop = threading.Event()
        self._stop_signal = "none"
        self._files = 0

    # ---- lifecycle
    def install_signal_handlers(self) -> None:
        signal.signal(signal.SIGTERM, self._on_signal)
        signal.signal(signal.SIGINT, self._on_signal)

    def _on_signal(self, signum, _frame) -> None:
        # Only set a flag: a write in progress finishes (temp+fsync+rename) before exit.
        self._stop_signal = signal.Signals(signum).name
        self._stop.set()

    # ---- one iteration, isolated so it is unit-testable without the loop
    def write_once(self, seq: int) -> tuple[str, str]:
        if not os.path.isdir(self._cfg.shared_dir):
            os.makedirs(self._cfg.shared_dir, mode=self._cfg.dir_mode, exist_ok=True)
        payload = Payload(seq, _dt.datetime.now(_dt.timezone.utc))
        data = payload.bytes()
        AtomicFileWriter(self._cfg.shared_dir, self._cfg.file_mode).write(payload.filename, data)
        return payload.filename, Payload.sha256(data)

    @staticmethod
    def _errno_name(exc: BaseException) -> str:
        if isinstance(exc, OSError) and exc.errno is not None:
            return errno.errorcode.get(exc.errno, f"ERRNO{exc.errno}")
        return type(exc).__name__

    def run(self) -> int:
        os.umask(0o022)
        self._log.line(f"WRITER_START uid={os.getuid()} gid={os.getgid()} dir={self._cfg.shared_dir}")
        while not self._stop.is_set():
            try:
                filename, digest = self.write_once(self._files)
                self._log.line(f"WROTE {filename} sha256={digest}")
                self._files += 1
            except Exception as exc:  # keep running on any write error
                self._log.line(f"WRITE_ERROR {self._errno_name(exc)} {exc}")
            self._stop.wait(self._cfg.interval_seconds)
        self._log.line(f"WRITER_STOP signal={self._stop_signal} files={self._files}")
        return 0


def main() -> int:
    writer = Writer(WriterConfig.from_env())
    writer.install_signal_handlers()
    return writer.run()


if __name__ == "__main__":
    sys.exit(main())
