"""Validated HTTPS webapp wrappers with isolated browser profiles.

`install` validates the URL, but the record it writes outlives that check, so
`launch` re-validates everything it uses. Trusting a stored record to hand a
path to subprocess.Popen means anything able to edit that JSON -- a restored
backup, a synced config directory, a bug in another tool -- chooses the program
that runs. The browser is therefore resolved fresh on every launch instead of
being read back from the record.
"""
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

# Characters that are structural in a desktop entry's Exec= line: a double quote
# closes a quoted argument (letting a URL smuggle in extra browser flags), a
# percent introduces a field code such as %u, and a backslash escapes. A URL
# containing any of these is refused at install time rather than escaped,
# because a legitimate webapp URL never needs them and a real one that does is
# better expressed by the user than silently mangled.
UNSAFE_IN_URL = re.compile(r'[\s"\'\\`<>$%]|[\x00-\x1f\x7f]')


def root() -> Path:
    return Path(os.environ.get("SHINOBI_WEBAPP_DIR", Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "shinobi/webapps"))


def validate_url(value: str) -> str:
    if not isinstance(value, str) or not value:
        raise ValueError("webapp URL must be a non-empty string")
    parsed = urlparse(value)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.fragment:
        raise ValueError("webapp URL must be an HTTPS URL without credentials or fragments")
    if len(value) > 2048:
        raise ValueError("webapp URL is too long")
    if UNSAFE_IN_URL.search(value):
        raise ValueError("webapp URL contains characters that are unsafe in a desktop entry")
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


def desktop_exec_arg(value: str) -> str:
    """Quote one Exec= argument per the desktop entry specification.

    Reserved characters are wrapped in double quotes, and inside the quotes a
    double quote, backtick, dollar or backslash is backslash-escaped. A literal
    percent is doubled, since a single one is a field code.
    """
    escaped = value.replace("%", "%%")
    for char in ('\\', '"', "`", "$"):
        escaped = escaped.replace(char, "\\" + char)
    return f'"{escaped}"'


def read_record(path: Path, expect_name: str | None = None) -> dict[str, str]:
    """Load a webapp record, checking its shape.

    The record is data on disk that outlives the install-time check, so it is
    treated as untrusted input here. A missing or malformed field is an error
    rather than something to pass through to a subprocess.
    """
    try:
        record = json.loads((path / "webapp.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SystemExit(f"unreadable webapp record for {path.name}: {exc}")
    if not isinstance(record, dict):
        raise SystemExit(f"malformed webapp record for {path.name}")
    for field in ("name", "url"):
        if not isinstance(record.get(field), str):
            raise SystemExit(f"webapp record for {path.name} has no {field}")
    if not NAME_RE.fullmatch(record["name"]):
        raise SystemExit(f"webapp record for {path.name} has an invalid name")
    if expect_name is not None and record["name"] != expect_name:
        # A record whose name disagrees with its directory is either a copy-paste
        # mistake or an attempt to get one webapp's settings applied to another.
        raise SystemExit(f"webapp record name mismatch: expected {expect_name}, found {record['name']}")
    validate_url(record["url"])
    return record


def main() -> int:
    action = sys.argv[1] if len(sys.argv) > 1 else "list"
    data_root = root()
    if action == "list":
        if data_root.is_dir():
            for path in sorted(data_root.iterdir()):
                if (path / "webapp.json").is_file():
                    try:
                        record = read_record(path)
                    except SystemExit as exc:
                        print(json.dumps({"name": path.name, "error": str(exc)}, sort_keys=True))
                        continue
                    print(json.dumps({"name": record["name"], "url": record["url"]}, sort_keys=True))
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
        exec_line = " ".join(
            desktop_exec_arg(part)
            for part in (record["browser"], f"--user-data-dir={profile}", url)
        )
        desktop.write_text(
            f"[Desktop Entry]\nName=Shinobi Webapp: {name}\nType=Application\n"
            f"Exec={exec_line}\nCategories=Network;Shinobi;\n",
            encoding="utf-8",
        )
        os.chmod(desktop, 0o644)
        print(f"Installed webapp: {name}")
        return 0
    if action == "launch":
        name = sys.argv[2] if len(sys.argv) > 2 else ""
        if not NAME_RE.fullmatch(name):
            raise SystemExit("invalid webapp name")
        target = data_root / name
        record = read_record(target, expect_name=name)
        url = validate_url(record["url"])
        # Re-resolve the browser instead of trusting record["browser"]: a stored
        # path is a program name chosen by whatever wrote the file, and this is
        # the line that executes it.
        executable = browser()
        # Derive the profile from the record's own location rather than the
        # recorded string, so a tampered record cannot point the browser's
        # profile at an arbitrary directory.
        profile = target / "profile"
        if not profile.is_dir():
            raise SystemExit(f"webapp profile is missing: {profile}")
        subprocess.Popen(
            [executable, f"--user-data-dir={profile}", url],
            start_new_session=True,
        )
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
