#!/usr/bin/env python3
"""Install the bootstrap-managed Cursor CLI hooks and Chrome MCP servers without replacing user settings."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shlex
import stat
import tempfile


MARKER = ".codex-workstation-bootstrap-managed"
MANAGED_DIR_NAME = "codex-workstation-bootstrap"
# Managed file name -> file name in --hook-source-dir. All of them are executable.
HOOK_FILES = {
    "rtk-codex-safe-hook.py": "rtk-codex-safe-hook.py",
    "rtk-cursor-safe-hook.py": "rtk-cursor-safe-hook.py",
    "cursor-session-guidance.py": "cursor-session-guidance.py",
    "test.sh": "test-rtk-cursor-safe-hook.sh",
}
SERVERS = {"chrome-devtools": 9222, "chrome-devtools-9223": 9223}


def server(port: int) -> dict[str, object]:
    return {
        "command": "npx",
        "args": ["-y", "chrome-devtools-mcp@latest", f"--browser-url=http://127.0.0.1:{port}"],
    }


def unique_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    data: dict[str, object] = {}
    for key, value in pairs:
        if key in data:
            raise ValueError(f"duplicate key {key!r}")
        data[key] = value
    return data


def reject_constant(name: str) -> object:
    raise ValueError(f"non-standard JSON constant {name}")


def read_json_object(path: Path, label: str) -> dict[str, object] | None:
    if path.is_symlink():
        raise SystemExit(f"error: refusing to replace symlinked {label}: {path}")
    if not path.exists():
        return None
    if not path.is_file():
        raise SystemExit(f"error: refusing to replace non-regular {label}: {path}")
    try:
        data = json.loads(
            path.read_bytes().decode("utf-8"),
            object_pairs_hook=unique_keys,
            parse_constant=reject_constant,
        )
    except (OSError, ValueError) as error:
        hint = ""
        if isinstance(error, json.JSONDecodeError):
            hint = " (strict JSON is required: remove // comments and trailing commas)"
        raise SystemExit(f"error: refusing to replace invalid {label} {path}: {error}{hint}")
    if not isinstance(data, dict):
        raise SystemExit(f"error: refusing to replace {label} that is not a JSON object: {path}")
    return data


def existing_mode(path: Path) -> int:
    return stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o644


def json_bytes(data: dict[str, object]) -> bytes:
    return (json.dumps(data, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def atomic_write(destination: Path, content: bytes, mode: int) -> None:
    if (
        not destination.is_symlink()
        and destination.is_file()
        and stat.S_IMODE(destination.stat().st_mode) == mode
        and destination.read_bytes() == content
    ):
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    descriptor, name = tempfile.mkstemp(prefix=f".{destination.name}.", dir=destination.parent)
    temporary_path = Path(name)
    try:
        with os.fdopen(descriptor, "wb") as temporary:
            temporary.write(content)
        os.chmod(temporary_path, mode)
        os.replace(temporary_path, destination)
    finally:
        temporary_path.unlink(missing_ok=True)


def require_directory(path: Path, label: str) -> None:
    if (path.exists() or path.is_symlink()) and not path.is_dir():
        raise SystemExit(f"error: refusing to use non-directory {label}: {path}")


def validate_managed_dir(hooks_dir: Path, managed_dir: Path, names: list[str]) -> None:
    if hooks_dir.is_symlink():
        raise SystemExit(f"error: refusing to use symlinked hooks directory: {hooks_dir}")
    require_directory(hooks_dir, "hooks directory")
    marker = managed_dir / MARKER
    if managed_dir.is_symlink() or (
        managed_dir.exists() and (marker.is_symlink() or not marker.is_file())
    ):
        raise SystemExit(f"error: refusing to overwrite unmanaged hook directory: {managed_dir}")
    for name in names:
        path = managed_dir / name
        if path.exists() and not path.is_symlink() and not path.is_file():
            raise SystemExit(f"error: refusing to replace non-regular managed file: {path}")


def references(command: object, directory: Path) -> bool:
    # Managed commands name a file inside the directory; shlex.quote escapes single quotes.
    prefix = str(directory) + "/"
    return isinstance(command, str) and (
        prefix in command or prefix.replace("'", "'\"'\"'") in command
    )


def hook_command(script: Path) -> str:
    return f"/usr/bin/python3 -B {shlex.quote(str(script))}"


def merge_hooks(path: Path, managed_dir: Path) -> dict[str, object]:
    data = read_json_object(path, "Cursor hooks file")
    if data is None:
        data = {"version": 1, "hooks": {}}
    version = data.get("version")
    if type(version) is not int or version != 1:
        raise SystemExit(f'error: refusing to replace Cursor hooks file without "version": 1: {path}')
    hooks = data.get("hooks", {})
    if not isinstance(hooks, dict):
        raise SystemExit(
            f'error: refusing to replace unsupported Cursor hooks structure in {path}: "hooks" must be an object'
        )
    cleaned: dict[str, list[object]] = {}
    for event, handlers in hooks.items():
        if not isinstance(handlers, list):
            raise SystemExit(
                f"error: refusing to replace unsupported Cursor hooks structure in {path}: hooks.{event} must be an array"
            )
        if not all(isinstance(handler, dict) for handler in handlers):
            raise SystemExit(
                f"error: refusing to replace unsupported Cursor hooks structure in {path}: hooks.{event} entries must be objects"
            )
        # Drop every handler of an earlier install, whichever event it was registered under.
        cleaned[event] = [
            handler for handler in handlers if not references(handler.get("command"), managed_dir)
        ]
    cleaned.setdefault("preToolUse", []).append(
        {
            "command": hook_command(managed_dir / "rtk-cursor-safe-hook.py"),
            "matcher": "Shell",
            "timeout": 10,
            "failClosed": True,
        }
    )
    cleaned.setdefault("sessionStart", []).append(
        {"command": hook_command(managed_dir / "cursor-session-guidance.py"), "timeout": 10}
    )
    data["hooks"] = cleaned
    return data


def merge_mcp(path: Path) -> dict[str, object]:
    data = read_json_object(path, "Cursor MCP config")
    if data is None:
        data = {"mcpServers": {}}
    servers = data.setdefault("mcpServers", {})
    if not isinstance(servers, dict):
        raise SystemExit(
            f'error: refusing to replace unsupported Cursor MCP structure in {path}: "mcpServers" must be an object'
        )
    # Check both names before adding either.
    for name, port in SERVERS.items():
        if name in servers and servers[name] != server(port):
            raise SystemExit(
                f"error: refusing to overwrite MCP server {name} with different existing settings in {path}"
            )
    for name, port in SERVERS.items():
        servers.setdefault(name, server(port))
    return data


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cursor-dir", required=True, type=Path)
    parser.add_argument("--hook-source-dir", required=True, type=Path)
    parser.add_argument("--guidance-file", required=True, type=Path)
    parser.add_argument("--rtk-version", required=True)
    parser.add_argument("--check-only", action="store_true")
    args = parser.parse_args()

    if not args.cursor_dir.is_absolute():
        raise SystemExit(f"error: --cursor-dir must be an absolute path: {args.cursor_dir}")
    if not args.rtk_version or any(character.isspace() for character in args.rtk_version):
        raise SystemExit(f"error: invalid RTK version: {args.rtk_version!r}")
    contents: dict[str, tuple[bytes, int]] = {}
    for name, source_name in HOOK_FILES.items():
        source = args.hook_source_dir / source_name
        if not source.is_file():
            raise SystemExit(f"error: Cursor hook source is missing: {source}")
        contents[name] = (source.read_bytes(), 0o755)
    if not args.guidance_file.is_file():
        raise SystemExit(f"error: Cursor guidance file is missing: {args.guidance_file}")
    guidance = args.guidance_file.read_bytes()
    # cursor-session-guidance.py fails every session on empty guidance.
    if not guidance.strip():
        raise SystemExit(f"error: Cursor guidance file is empty: {args.guidance_file}")
    contents["guidance.md"] = (guidance, 0o644)
    contents["rtk-version"] = (f"{args.rtk_version}\n".encode("utf-8"), 0o644)

    require_directory(args.cursor_dir, "Cursor directory")
    hooks_dir = args.cursor_dir / "hooks"
    managed_dir = hooks_dir / MANAGED_DIR_NAME
    validate_managed_dir(hooks_dir, managed_dir, [MARKER, *contents])
    hooks_path = args.cursor_dir / "hooks.json"
    mcp_path = args.cursor_dir / "mcp.json"
    hooks_data = merge_hooks(hooks_path, managed_dir)
    mcp_data = merge_mcp(mcp_path)
    if args.check_only:
        return 0

    managed_dir.mkdir(parents=True, exist_ok=True)
    atomic_write(managed_dir / MARKER, b"managed by codex-workstation-bootstrap\n", 0o644)
    for name, (content, mode) in contents.items():
        atomic_write(managed_dir / name, content, mode)
    atomic_write(hooks_path, json_bytes(hooks_data), existing_mode(hooks_path))
    atomic_write(mcp_path, json_bytes(mcp_data), existing_mode(mcp_path))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except OSError as error:
        raise SystemExit(f"error: {error}")
