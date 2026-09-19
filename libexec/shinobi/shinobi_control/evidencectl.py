"""Evidence inventory, hashing, verification, tagging, and export."""
from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
import shutil
import sys
import tarfile
from pathlib import Path


def engagement_dir() -> Path:
    value = os.environ.get("SHINOBI_ENGAGEMENT_DIR")
    if value:
        return Path(value)
    name = os.environ.get("SHINOBI_ENGAGEMENT")
    if not name:
        state = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "shinobi/current-engagement"
        try:
            name = state.read_text(encoding="utf-8").strip()
        except OSError:
            name = ""
    if not name or "/" in name or "\\" in name:
        raise ValueError("no safe active engagement")
    return Path(os.environ.get("SHINOBI_ENGAGEMENTS_DIR", Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "shinobi/engagements")) / name


def evidence_dir() -> Path:
    path = engagement_dir() / "evidence"
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    return path


def digest(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def metadata_path(path: Path) -> Path:
    return path.with_name(path.name + ".evidence.json")


def add(source: Path, label: str = "") -> dict[str, object]:
    if not source.is_file():
        raise ValueError(f"evidence source is not a file: {source}")
    target_dir = evidence_dir()
    target = target_dir / source.name
    if source.resolve() != target.resolve():
        if target.exists():
            raise ValueError(f"evidence already exists: {target.name}")
        shutil.copy2(source, target)
    record = {
        "evidence_version": 1,
        "file": target.name,
        "sha256": digest(target),
        "bytes": target.stat().st_size,
        "created_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "label": label,
        "engagement": engagement_dir().name,
        "tags": [],
    }
    metadata_path(target).write_text(json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(metadata_path(target), 0o600)
    return record


def records() -> list[dict[str, object]]:
    result = []
    for path in sorted(evidence_dir().glob("*.evidence.json")):
        try:
            result.append(json.loads(path.read_text(encoding="utf-8")))
        except (OSError, json.JSONDecodeError):
            continue
    return result


def find_record(name: str) -> tuple[Path, dict[str, object]]:
    if "/" in name or "\\" in name:
        raise ValueError("invalid evidence name")
    path = evidence_dir() / name
    meta = metadata_path(path)
    if not path.is_file() or not meta.is_file():
        raise ValueError(f"evidence not found: {name}")
    return path, json.loads(meta.read_text(encoding="utf-8"))


def main() -> int:
    action = sys.argv[1] if len(sys.argv) > 1 else "list"
    if action == "list":
        print(json.dumps(records(), indent=2, sort_keys=True))
        return 0
    if action == "add":
        if len(sys.argv) < 3:
            raise SystemExit("usage: shinobi evidence add <file> [label]")
        print(json.dumps(add(Path(sys.argv[2]).resolve(), sys.argv[3] if len(sys.argv) > 3 else ""), indent=2, sort_keys=True))
        return 0
    if action == "verify":
        names = sys.argv[2:] or [record["file"] for record in records()]
        failures = 0
        for name in names:
            path, record = find_record(str(name))
            actual = digest(path)
            ok = actual == record.get("sha256")
            print(json.dumps({"file": path.name, "expected": record.get("sha256"), "actual": actual, "valid": ok}, sort_keys=True))
            failures += not ok
        return int(failures > 0)
    if action == "tag":
        if len(sys.argv) < 4:
            raise SystemExit("usage: shinobi evidence tag <file> <tag>")
        path, record = find_record(sys.argv[2])
        tag = sys.argv[3]
        if not tag or any(char not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-" for char in tag):
            raise SystemExit("invalid tag")
        tags = set(record.get("tags", [])); tags.add(tag); record["tags"] = sorted(tags)
        metadata_path(path).write_text(json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(json.dumps(record, indent=2, sort_keys=True))
        return 0
    if action == "export":
        destination = Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else Path.cwd() / f"{engagement_dir().name}-evidence.tar.gz"
        with tarfile.open(destination, "w:gz") as archive:
            archive.add(evidence_dir(), arcname="evidence")
        print(destination)
        return 0
    if action in {"help", "-h", "--help"}:
        print("Usage: shinobi evidence <list|add|verify|tag|export> [args]")
        return 0
    raise SystemExit(f"unknown evidence action: {action}")


if __name__ == "__main__":
    raise SystemExit(main())
