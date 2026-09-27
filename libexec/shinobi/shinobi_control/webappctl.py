"""Validated HTTPS webapp wrappers with isolated browser profiles."""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlparse

NAME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")


def root() -> Path:
    return Path(os.environ.get("SHINOBI_WEBAPP_DIR", Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "shinobi/webapps"))


def validate_url(value: str) -> str:
    parsed = urlparse(value)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.fragment:
        raise ValueError("webapp URL must be an HTTPS URL without credentials or fragments")
    if len(value) > 2048:
        raise ValueError("webapp URL is too long")
    return value


def browser() -> str:
    configured = os.environ.get("SHINOBI_BROWSER")
    if configured:
        path = shutil.which(configured)
        if path:
            return path
    for candidate in ("chromium", "chromium-browser", "firefox"):
        path = shutil.which(candidate)
        if path:
            return path
    raise RuntimeError("no supported browser found (set SHINOBI_BROWSER)")


def read_record(path: Path) -> dict[str, str]:
    return json.loads((path / "webapp.json").read_text(encoding="utf-8"))


def main() -> int:
    action = sys.argv[1] if len(sys.argv) > 1 else "list"
    data_root = root()
    if action == "list":
        if data_root.is_dir():
            for path in sorted(data_root.iterdir()):
                if (path / "webapp.json").is_file():
                    print(json.dumps(read_record(path), sort_keys=True))
        return 0
    if action == "install":
        if len(sys.argv) < 4:
            raise SystemExit("usage: shinobi webapp install <name> <https-url>")
        name, url = sys.argv[2], validate_url(sys.argv[3])
        if not NAME_RE.fullmatch(name):
            raise SystemExit("invalid webapp name")
        if os.environ.get("SHINOBI_CONFIRM") != "1":
            raise SystemExit("set SHINOBI_CONFIRM=1 to install a webapp")
        target = data_root / name
        if target.exists():
            raise SystemExit(f"webapp already exists: {name}")
        target.mkdir(mode=0o700, parents=True)
        profile = target / "profile"
        profile.mkdir(mode=0o700)
        record = {"name": name, "url": url, "profile": str(profile), "browser": browser()}
        (target / "webapp.json").write_text(json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        desktop = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "applications" / f"shinobi-webapp-{name}.desktop"
        desktop.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        desktop.write_text(f"[Desktop Entry]\nName=Shinobi Webapp: {name}\nType=Application\nExec={record['browser']} --user-data-dir={profile} {url}\nCategories=Network;Shinobi;\n", encoding="utf-8")
        os.chmod(desktop, 0o644)
        print(f"Installed webapp: {name}")
        return 0
    if action == "launch":
        name = sys.argv[2] if len(sys.argv) > 2 else ""
        if not NAME_RE.fullmatch(name):
            raise SystemExit("invalid webapp name")
        record = read_record(data_root / name)
        subprocess.Popen([record["browser"], f"--user-data-dir={record['profile']}", record["url"]], start_new_session=True)
        return 0
    if action == "remove":
        name = sys.argv[2] if len(sys.argv) > 2 else ""
        if not NAME_RE.fullmatch(name):
            raise SystemExit("invalid webapp name")
        if os.environ.get("SHINOBI_CONFIRM") != "1":
            raise SystemExit("set SHINOBI_CONFIRM=1 to remove a webapp")
        target = data_root / name
        if not target.is_dir():
            raise SystemExit(f"webapp not found: {name}")
        shutil.rmtree(target)
        desktop = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "applications" / f"shinobi-webapp-{name}.desktop"
        desktop.unlink(missing_ok=True)
        print(f"Removed webapp: {name}")
        return 0
    if action in {"help", "-h", "--help"}:
        print("Usage: shinobi webapp <list|install|launch|remove> [name] [url]")
        return 0
    raise SystemExit(f"unknown webapp action: {action}")


if __name__ == "__main__":
    raise SystemExit(main())
