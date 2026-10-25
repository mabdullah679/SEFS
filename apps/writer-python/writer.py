"""SEFS writer: drops one JSON file into SHARED_DIR every WRITER_INTERVAL_SECONDS.

Contract (docs/CONTRACTS.md section 3, "apps (application code)"); log lines are a
test interface, do not reword them:
  WRITER_START uid=<uid> gid=<gid> dir=<dir>
  WROTE <filename> sha256=<hex>
  WRITE_ERROR <errno-name> <message>
Python 3.12 standard library only.
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

FILE_MODE = 0o644  # group/other readable so the reader (other UID, same GID) can read
DIR_MODE = 0o775  # matches the access point creation_info permissions

_stop = threading.Event()
_stop_signal = {"name": "none"}


def log(line: str) -> None:
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def _errno_name(exc: BaseException) -> str:
    if isinstance(exc, OSError) and exc.errno is not None:
        return errno.errorcode.get(exc.errno, f"ERRNO{exc.errno}")
    return type(exc).__name__


def _fsync_dir(path: str) -> None:
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def write_one(shared_dir: str, seq: int) -> tuple[str, str]:
    """Write one file atomically; return (filename, sha256 hex) of the final file."""
    now = _dt.datetime.now(_dt.timezone.utc)
    # ISO 8601 basic format (no colons: safe for every tool that touches the share).
    filename = f"{now.strftime('%Y%m%dT%H%M%S.%fZ')}-{uuid.uuid4()}.json"
    payload = {
        "timestamp": now.isoformat(),
        "seq": seq,
        "writer_uid": os.getuid(),
        "writer_gid": os.getgid(),
    }
    data = (json.dumps(payload, sort_keys=True) + "\n").encode("utf-8")
    digest = hashlib.sha256(data).hexdigest()

    # Temp name starts with "." and does not end in ".json", so a reader listing
    # "*.json" can never pick it up mid-write.
    tmp_path = os.path.join(shared_dir, f".{filename}.tmp")
    final_path = os.path.join(shared_dir, filename)
    fd = os.open(tmp_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, FILE_MODE)
    try:
        os.fchmod(fd, FILE_MODE)  # independent of whatever umask the runtime set
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
    os.rename(tmp_path, final_path)  # atomic within one directory (POSIX, NFSv4)
    _fsync_dir(shared_dir)
    return filename, digest


def _handle_term(signum, _frame) -> None:
    # Only set a flag: a write in progress finishes (temp+fsync+rename) before exit.
    _stop_signal["name"] = signal.Signals(signum).name
    _stop.set()


def main() -> int:
    os.umask(0o022)
    shared_dir = os.environ.get("SHARED_DIR", "/mnt/shared")
    interval = float(os.environ.get("WRITER_INTERVAL_SECONDS", "5"))

    signal.signal(signal.SIGTERM, _handle_term)
    signal.signal(signal.SIGINT, _handle_term)

    log(f"WRITER_START uid={os.getuid()} gid={os.getgid()} dir={shared_dir}")

    seq = 0
    while not _stop.is_set():
        try:
            if not os.path.isdir(shared_dir):
                os.makedirs(shared_dir, mode=DIR_MODE, exist_ok=True)
            filename, digest = write_one(shared_dir, seq)
            log(f"WROTE {filename} sha256={digest}")
            seq += 1
        except Exception as exc:  # keep running on any write error
            log(f"WRITE_ERROR {_errno_name(exc)} {exc}")
        _stop.wait(interval)

    log(f"WRITER_STOP signal={_stop_signal['name']} files={seq}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
