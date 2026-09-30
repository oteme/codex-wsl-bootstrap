#!/usr/bin/env python3
"""Install the bootstrap-managed Antigravity CLI hook, skills entries and Chrome MCP servers without replacing user settings."""

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
HOOK_NAME = "codex-workstation-bootstrap-rtk"
SKILLS_RECORD = "skills-entry.json"
AGENT_SKILLS_RECORD = "antigravity-skills-entry.json"
# ralph-run drives Codex workers, so Antigravity must not load the Codex copy.
EXCLUDED_SKILLS = ["ralph-run"]
# Managed file name -> file name in --hook-source-dir. All of them are executable.
HOOK_FILES = {
    "rtk-codex-safe-hook.py": "rtk-codex-safe-hook.py",
    "rtk-antigravity-safe-hook.py": "rtk-antigravity-safe-hook.py",
    "ralph-result-hook.py": "ralph-result-hook.py",
    "test.sh": "test-rtk-antigravity-safe-hook.sh",
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


def commands_in(value: object) -> list[object]:
    if isinstance(value, dict):
        found = [value["command"]] if "command" in value else []
        return found + [command for child in value.values() for command in commands_in(child)]
    if isinstance(value, list):
        return [command for child in value for command in commands_in(child)]
    return []


def managed_hook(managed_dir: Path) -> dict[str, object]:
    return {
        "PreToolUse": [
            {
                "matcher": "run_command",
                "hooks": [
                    {
                        "type": "command",
                        "command": hook_command(managed_dir / "rtk-antigravity-safe-hook.py"),
                        "timeout": 10,
                    }
                ],
            }
        ],
        # Adds a finished Ralph run's result to the next model call of the conversation that started it.
        "PreInvocation": [
            {
                "type": "command",
                "command": hook_command(managed_dir / "ralph-result-hook.py") + " antigravity",
                "timeout": 10,
            }
        ],
    }


def verify_hooks(path: Path, managed_dir: Path) -> None:
    """Refuse when the managed hook is not registered exactly as setup writes it."""
    data = read_json_object(path, "Antigravity hooks file") or {}
    elsewhere = [name for name, value in data.items() if name != HOOK_NAME
                 and any(references(command, managed_dir) for command in commands_in(value))]
    if data.get(HOOK_NAME) != managed_hook(managed_dir) or elsewhere:
        raise SystemExit(f"error: the Antigravity hook registration in {path} is not the one setup writes")


def verify_files(managed_dir: Path) -> None:
    """Refuse when a managed hook file is missing: a registered hook whose file is gone fails every
    time it runs, and Cursor blocks the message when python3 exits 2 on a missing script."""
    for name in HOOK_FILES:
        path = managed_dir / name
        if path.is_symlink() or not path.is_file():
            raise SystemExit(f"error: the Antigravity hook file {path} is missing")


def merge_hooks(path: Path, managed_dir: Path) -> dict[str, object]:
    data = read_json_object(path, "Antigravity hooks file")
    if data is None:
        data = {}
    if HOOK_NAME in data:
        # Another tool may use the same name; take it over only when every command is ours.
        commands = commands_in(data[HOOK_NAME])
        if not commands or not all(references(command, managed_dir) for command in commands):
            raise SystemExit(
                f"error: refusing to replace hook {HOOK_NAME} that this bootstrap does not manage in {path}"
            )
    data[HOOK_NAME] = managed_hook(managed_dir)
    return data


def merge_skills(
    path: Path, managed: list[tuple[dict[str, object], dict[str, object] | None]]
) -> dict[str, object]:
    """Merge the managed entries, each given with the entry recorded by the previous run.

    The first managed entry always goes first: Antigravity shows the model only as many skill
    descriptions as its budget allows, and the skills in its own directory lost out to the Codex
    skills until that directory was listed first. Every other managed entry keeps its place, or is
    appended when it is missing.
    """
    data = read_json_object(path, "Antigravity skills file")
    if data is None:
        data = {"entries": []}
    entries = data.get("entries", [])
    if not isinstance(entries, list):
        raise SystemExit(
            f'error: refusing to replace unsupported Antigravity skills structure in {path}: "entries" must be an array'
        )
    if not all(isinstance(entry, dict) for entry in entries):
        raise SystemExit(
            f"error: refusing to replace unsupported Antigravity skills structure in {path}: entries must be objects"
        )
    targets = {os.path.normpath(str(desired["path"])): desired for desired, _ in managed}
    merged: list[object] = []
    placed: set[int] = set()
    for entry in entries:
        # An entry is ours when it matches this run or the entry recorded by the previous run.
        owner = next((index for index, (desired, recorded) in enumerate(managed)
                      if entry == desired or (recorded is not None and entry == recorded)), None)
        entry_path = entry.get("path")
        if owner is None and isinstance(entry_path, str) and os.path.normpath(entry_path) in targets:
            raise SystemExit(
                f"error: refusing to replace skills entry for {targets[os.path.normpath(entry_path)]['path']}"
                f" that this bootstrap does not manage in {path}"
            )
        if owner is None:
            merged.append(entry)
        elif owner > 0 and owner not in placed:
            merged.append(managed[owner][0])
            placed.add(owner)
    merged.extend(desired for index, (desired, _) in enumerate(managed) if index > 0 and index not in placed)
    data["entries"] = [managed[0][0], *merged]
    return data


def merge_mcp(path: Path) -> dict[str, object]:
    # agy creates mcp_config.json as an empty file on first run; empty means no servers.
    if not path.is_symlink() and path.is_file() and path.stat().st_size == 0:
        data: dict[str, object] | None = {"mcpServers": {}}
    else:
        data = read_json_object(path, "Antigravity MCP config")
    if data is None:
        data = {"mcpServers": {}}
    servers = data.setdefault("mcpServers", {})
    if not isinstance(servers, dict):
        raise SystemExit(
            f'error: refusing to replace unsupported Antigravity MCP structure in {path}: "mcpServers" must be an object'
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
    parser.add_argument("--gemini-dir", required=True, type=Path)
    parser.add_argument("--codex-skills-dir", required=True, type=Path)
    parser.add_argument("--hook-source-dir", required=True, type=Path)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check-only", action="store_true", help="check the settings without writing")
    mode.add_argument("--verify", action="store_true", help="check the installed hook registration")
    args = parser.parse_args()

    for option, value in (("--gemini-dir", args.gemini_dir), ("--codex-skills-dir", args.codex_skills_dir)):
        if not value.is_absolute():
            raise SystemExit(f"error: {option} must be an absolute path: {value}")
    contents: dict[str, tuple[bytes, int]] = {}
    for name, source_name in HOOK_FILES.items():
        source = args.hook_source_dir / source_name
        if not source.is_file():
            raise SystemExit(f"error: Antigravity hook source is missing: {source}")
        contents[name] = (source.read_bytes(), 0o755)

    config_dir = args.gemini_dir / "config"
    require_directory(args.gemini_dir, "Gemini directory")
    require_directory(config_dir, "Antigravity config directory")
    hooks_dir = config_dir / "hooks"
    managed_dir = hooks_dir / MANAGED_DIR_NAME
    validate_managed_dir(hooks_dir, managed_dir, [MARKER, SKILLS_RECORD, AGENT_SKILLS_RECORD, *contents])
    # Antigravity's own skills, among them its ralph-run, installed by setup.
    agent_desired: dict[str, object] = {"path": str(args.gemini_dir / "antigravity-cli" / "skills")}
    desired: dict[str, object] = {
        "path": str(args.codex_skills_dir),
        "exclude": list(EXCLUDED_SKILLS),
    }
    hooks_path = config_dir / "hooks.json"
    skills_path = config_dir / "skills.json"
    mcp_path = config_dir / "mcp_config.json"
    if args.verify:
        verify_hooks(hooks_path, managed_dir)
        verify_files(managed_dir)
        return 0
    hooks_data = merge_hooks(hooks_path, managed_dir)
    agent_recorded = read_json_object(managed_dir / AGENT_SKILLS_RECORD, "recorded Antigravity skills entry")
    recorded = read_json_object(managed_dir / SKILLS_RECORD, "recorded skills entry")
    skills_data = merge_skills(skills_path, [(agent_desired, agent_recorded), (desired, recorded)])
    mcp_data = merge_mcp(mcp_path)
    if args.check_only:
        return 0

    managed_dir.mkdir(parents=True, exist_ok=True)
    atomic_write(managed_dir / MARKER, b"managed by codex-workstation-bootstrap\n", 0o644)
    for name, (content, mode) in contents.items():
        atomic_write(managed_dir / name, content, mode)
    atomic_write(hooks_path, json_bytes(hooks_data), existing_mode(hooks_path))
    atomic_write(skills_path, json_bytes(skills_data), existing_mode(skills_path))
    # Record the entries only once skills.json holds them, so an interrupted run still owns them.
    atomic_write(managed_dir / AGENT_SKILLS_RECORD, json_bytes(agent_desired), 0o644)
    atomic_write(managed_dir / SKILLS_RECORD, json_bytes(desired), 0o644)
    atomic_write(mcp_path, json_bytes(mcp_data), existing_mode(mcp_path))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except OSError as error:
        raise SystemExit(f"error: {error}")
