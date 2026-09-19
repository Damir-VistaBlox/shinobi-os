"""Validate and manage explicitly trusted Shinobi plugin manifests."""
from __future__ import annotations

import json
import os
import re
import shutil
import sys
import tomllib
from pathlib import Path

PERMISSIONS = {"desktop", "filesystem", "network", "shell", "privileged", "microphone", "camera", "engagement-data", "tool-execution"}
PLUGIN_ID = r"^[a-z0-9]+(?:[._-][a-z0-9]+)*$"


def root() -> Path:
    return Path(os.environ.get("SHINOBI_PLUGIN_DIR", Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "shinobi/plugins"))


def validate(path: Path) -> dict[str, object]:
    manifest = path / "manifest.toml"
    if not manifest.is_file():
        raise ValueError(f"missing manifest.toml: {path}")
    try:
        data = tomllib.loads(manifest.read_text(encoding="utf-8"))
    except (OSError, tomllib.TOMLDecodeError) as exc:
        raise ValueError(f"invalid manifest: {exc}") from exc
    for key in ("id", "name", "version", "api_version"):
        if not isinstance(data.get(key), str) or not data[key]:
            raise ValueError(f"manifest missing {key}")
    if not re.fullmatch(PLUGIN_ID, data["id"]):
        raise ValueError("manifest id is invalid")
    permissions = data.get("permissions", [])
    if not isinstance(permissions, list) or any(item not in PERMISSIONS for item in permissions):
        raise ValueError("manifest contains an unknown permission")
    if "entrypoint" in data and not isinstance(data["entrypoint"], str):
        raise ValueError("entrypoint must be a string")
    return data


def main() -> int:
    action = sys.argv[1] if len(sys.argv) > 1 else "list"
    plugins = root()
    if action == "list":
        if plugins.is_dir():
            for path in sorted(plugins.iterdir()):
                if path.is_dir():
                    print(path.name)
        return 0
    if action in {"audit", "validate"}:
        paths = [Path(sys.argv[2])] if len(sys.argv) > 2 else ([path for path in sorted(plugins.iterdir()) if path.is_dir()] if plugins.is_dir() else [])
        for path in paths:
            data = validate(path)
            print(json.dumps({"path": str(path), "manifest": data}, sort_keys=True))
        return 0
    if action == "install":
        if len(sys.argv) < 3:
            raise SystemExit("usage: shinobi plugin install <directory>")
        source = Path(sys.argv[2]).resolve()
        data = validate(source)
        if os.environ.get("SHINOBI_CONFIRM") != "1":
            raise SystemExit("set SHINOBI_CONFIRM=1 to install a plugin")
        target = plugins / data["id"]
        plugins.mkdir(mode=0o700, parents=True, exist_ok=True)
        if target.exists():
            raise SystemExit(f"plugin already installed: {data['id']}")
        shutil.copytree(source, target)
        (target / ".trusted").write_text("explicit-user-trust\n", encoding="utf-8")
        os.chmod(target / ".trusted", 0o600)
        print(f"Installed plugin: {data['id']}")
        return 0
    if action in {"help", "-h", "--help"}:
        print("Usage: shinobi plugin <list|audit|validate|install> [directory]")
        return 0
    raise SystemExit(f"unknown plugin action: {action}")


if __name__ == "__main__":
    raise SystemExit(main())
