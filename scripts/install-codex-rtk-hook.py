#!/usr/bin/env python3
"""Install the bootstrap-managed Codex RTK hook without replacing other hooks."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import stat
import tempfile


HOOK_NAME = "rtk-codex-safe-hook.py"
MARKER = ".codex-workstation-bootstrap-managed"


def atomic_copy(source: Path, destination: Path, mode: int) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as temporary:
        temporary_path = Path(temporary.name)
    try:
        shutil.copyfile(source, temporary_path)
        os.chmod(temporary_path, mode)
        os.replace(temporary_path, destination)
    finally:
        temporary_path.unlink(missing_ok=True)


def atomic_json(destination: Path, data: dict[str, object]) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", dir=destination.parent, delete=False
    ) as temporary:
        json.dump(data, temporary, ensure_ascii=False, indent=2)
        temporary.write("\n")
        temporary_path = Path(temporary.name)
    try:
        os.chmod(temporary_path, stat.S_IRUSR | stat.S_IWUSR)
        os.replace(temporary_path, destination)
    finally:
        temporary_path.unlink(missing_ok=True)


def load_hooks(path: Path) -> dict[str, object]:
    if not path.exists():
        return {"description": "Codex workstation bootstrap hooks.", "hooks": {}}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"error: refusing to replace invalid hooks file {path}: {error}")
    if not isinstance(data, dict) or not isinstance(data.get("hooks"), dict):
        raise SystemExit(f"error: refusing to replace unsupported hooks structure: {path}")
    return data


def remove_managed_handler(groups: object) -> list[object]:
    if not isinstance(groups, list):
        raise SystemExit("error: PreToolUse in hooks.json must be an array")
    cleaned: list[object] = []
    for group in groups:
        if not isinstance(group, dict):
            raise SystemExit("error: PreToolUse hook group must be an object")
        handlers = group.get("hooks")
        if not isinstance(handlers, list):
            raise SystemExit("error: PreToolUse hook handlers must be an array")
        retained = []
        for handler in handlers:
            if not isinstance(handler, dict):
                raise SystemExit("error: PreToolUse hook handler must be an object")
            command = handler.get("command")
            if isinstance(command, str) and HOOK_NAME in command:
                continue
            retained.append(handler)
        if retained:
            updated = dict(group)
            updated["hooks"] = retained
            cleaned.append(updated)
    return cleaned


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--codex-dir", required=True, type=Path)
    parser.add_argument("--hook-source", required=True, type=Path)
    parser.add_argument("--test-source", required=True, type=Path)
    parser.add_argument("--rtk-version", required=True)
    args = parser.parse_args()

    for source in (args.hook_source, args.test_source):
        if not source.is_file():
            raise SystemExit(f"error: RTK hook source is missing: {source}")

    managed_dir = args.codex_dir / "hooks" / "rtk-safe"
    marker = managed_dir / MARKER
    if managed_dir.exists() and not marker.is_file():
        raise SystemExit(f"error: refusing to overwrite unmanaged hook directory: {managed_dir}")
    hooks_path = args.codex_dir / "hooks.json"
    data = load_hooks(hooks_path)
    managed_dir.mkdir(parents=True, exist_ok=True)

    hook_destination = managed_dir / HOOK_NAME
    test_destination = managed_dir / "test.sh"
    atomic_copy(args.hook_source, hook_destination, 0o755)
    atomic_copy(args.test_source, test_destination, 0o755)
    marker.write_text("managed by codex-workstation-bootstrap\n", encoding="utf-8")
    (managed_dir / "rtk-version").write_text(args.rtk_version + "\n", encoding="utf-8")

    hooks = data["hooks"]
    assert isinstance(hooks, dict)
    groups = remove_managed_handler(hooks.get("PreToolUse", []))
    command = f"/usr/bin/python3 {shlex.quote(str(hook_destination))}"
    groups.append(
        {
            "matcher": "^Bash$",
            "hooks": [
                {
                    "type": "command",
                    "command": command,
                    "timeout": 10,
                    "statusMessage": "Applying safe RTK rewrite",
                }
            ],
        }
    )
    hooks["PreToolUse"] = groups
    atomic_json(hooks_path, data)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
