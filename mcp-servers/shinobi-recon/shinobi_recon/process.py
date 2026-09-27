"""Small, non-shell process runner shared by recon capabilities."""
from __future__ import annotations

from dataclasses import dataclass
import shutil
import subprocess


@dataclass(frozen=True)
class ProcessResult:
    stdout: str
    stderr: str
    returncode: int
    timed_out: bool


def run(argv: list[str], timeout: int, output_limit: int = 128 * 1024) -> ProcessResult:
    """Run a fixed executable argv with bounded output and no shell."""
    if not argv or any(not isinstance(arg, str) or "\x00" in arg for arg in argv):
        raise ValueError("invalid process argv")
    if timeout <= 0 or output_limit <= 0:
        raise ValueError("timeout and output_limit must be positive")
    if shutil.which(argv[0]) is None:
        return ProcessResult("", f"executable not found: {argv[0]}", 127, False)
    try:
        completed = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, check=False)
        return ProcessResult(completed.stdout[:output_limit], completed.stderr[:output_limit], completed.returncode, False)
    except subprocess.TimeoutExpired as exc:
        stdout = exc.stdout or ""
        stderr = exc.stderr or ""
        if isinstance(stdout, bytes):
            stdout = stdout.decode(errors="replace")
        if isinstance(stderr, bytes):
            stderr = stderr.decode(errors="replace")
        return ProcessResult(stdout[:output_limit], stderr[:output_limit], 124, True)
