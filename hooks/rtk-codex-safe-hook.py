#!/usr/bin/env python3
"""Conservatively rewrite simple Codex Bash calls through RTK."""

from __future__ import annotations

import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys


MAX_INPUT_BYTES = 1024 * 1024
COMPLEX_MARKERS = ("\n", "\r", ";", "|", "&", "(", ")", "{", "}", "<", ">", "`", "$(", "${")
SIMPLE_COMMANDS = {"cat", "df", "du", "grep", "head", "ls", "ps", "rg", "tail"}
MUTATING_OPTIONS = {"--fix", "--output", "--update", "--update-snapshot", "--write", "-u", "-w"}
SUBCOMMANDS = {
    "bun": {"lint", "test"},
    "cargo": {"check", "clippy", "test"},
    "git": {"diff", "log", "show", "status"},
    "go": {"test"},
    "make": {"check", "lint", "test"},
    "npm": {"test"},
    "pnpm": {"lint", "test"},
    "ruff": {"check"},
    "yarn": {"lint", "test"},
}
NPX_TOOLS = {"eslint", "tsc", "vitest"}


def emit_decision(decision: str, reason: str, updated_command: str | None = None) -> None:
    output: dict[str, object] = {
        "hookEventName": "PreToolUse",
        "permissionDecision": decision,
        "permissionDecisionReason": reason,
    }
    if updated_command is not None:
        output["updatedInput"] = {"command": updated_command}
    json.dump({"hookSpecificOutput": output}, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")


def deny(reason: str) -> int:
    emit_decision("deny", reason)
    return 0


def parse_input() -> tuple[dict[str, object] | None, str | None]:
    raw = sys.stdin.buffer.read(MAX_INPUT_BYTES + 1)
    if len(raw) > MAX_INPUT_BYTES:
        return None, "RTK Safe Hook rejected an oversized hook payload."
    try:
        payload = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None, "RTK Safe Hook rejected invalid JSON."
    if not isinstance(payload, dict):
        return None, "RTK Safe Hook expected a JSON object."
    return payload, None


def command_is_allowlisted(command: str) -> bool:
    if any(marker in command for marker in COMPLEX_MARKERS):
        return False
    try:
        words = shlex.split(command, posix=True)
    except ValueError:
        return False
    if not words:
        return False
    if any(
        word in MUTATING_OPTIONS
        or word.startswith("--fix=")
        or word.startswith("--output=")
        for word in words[1:]
    ):
        return False

    executable = Path(words[0]).name
    if executable in SIMPLE_COMMANDS:
        return True
    if executable == "pytest":
        return True
    if executable == "npx":
        remaining = [word for word in words[1:] if not word.startswith("-")]
        return bool(remaining) and Path(remaining[0]).name in NPX_TOOLS
    if executable not in SUBCOMMANDS or len(words) < 2:
        return False

    remaining = [word for word in words[1:] if not word.startswith("-")]
    return bool(remaining) and remaining[0] in SUBCOMMANDS[executable]


def bash_syntax_ok(command: str) -> bool:
    try:
        result = subprocess.run(
            ["/bin/bash", "-n", "-c", command],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=2,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    return result.returncode == 0


def rtk_binary() -> str | None:
    override = os.environ.get("RTK_BIN")
    if override:
        return override
    managed = Path.home() / ".local" / "bin" / "rtk"
    if managed.is_file() and os.access(managed, os.X_OK):
        return str(managed)
    return shutil.which("rtk")


def rewrite(command: str) -> tuple[str | None, str | None]:
    binary = rtk_binary()
    if binary is None:
        return None, "RTK Safe Hook could not find the RTK binary."
    try:
        result = subprocess.run(
            [binary, "hook", "check", command],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            check=False,
            timeout=3,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return None, f"RTK Safe Hook failed to inspect the command: {type(error).__name__}."
    if result.returncode != 0:
        return None, f"RTK Safe Hook received RTK exit code {result.returncode}."

    rewritten = result.stdout.strip()
    if not rewritten or rewritten.startswith("No rewrite for:"):
        return "", None
    try:
        words = shlex.split(rewritten, posix=True)
    except ValueError:
        return None, "RTK Safe Hook rejected an unparsable RTK rewrite."
    if not words or Path(words[0]).name != "rtk":
        return None, "RTK Safe Hook rejected an unexpected RTK rewrite."
    if any(marker in rewritten for marker in COMPLEX_MARKERS) or not bash_syntax_ok(rewritten):
        return None, "RTK Safe Hook rejected a complex or invalid RTK rewrite."
    return rewritten, None


def main() -> int:
    payload, error = parse_input()
    if error:
        return deny(error)
    assert payload is not None

    if payload.get("hook_event_name") != "PreToolUse" or payload.get("tool_name") != "Bash":
        return deny("RTK Safe Hook received an unexpected Codex hook event.")
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict) or not isinstance(tool_input.get("command"), str):
        return deny("RTK Safe Hook received a Bash call without a string command.")
    command = tool_input["command"]
    if not command or not bash_syntax_ok(command):
        return deny("RTK Safe Hook rejected an empty or invalid Bash command.")

    # Complex and non-allowlisted commands intentionally stay byte-for-byte unchanged.
    if not command_is_allowlisted(command):
        return 0

    rewritten, error = rewrite(command)
    if error:
        return deny(error)
    if not rewritten:
        return 0
    emit_decision("allow", "RTK Safe Hook rewrote an allowlisted simple command.", rewritten)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
