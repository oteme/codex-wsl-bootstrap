#!/usr/bin/env python3
"""Conservatively rewrite simple Codex Bash calls through RTK."""

from __future__ import annotations

import errno
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys


MAX_INPUT_BYTES = 1024 * 1024
COMPLEX_MARKERS = ("\n", "\r", ";", "|", "&", "(", ")", "{", "}", "<", ">", "`", "$(", "${")
# Not head or tail: RTK printed a single line for `head -2`, and their output is short anyway.
SIMPLE_COMMANDS = {"cat", "df", "du", "grep", "ls", "ps", "rg"}
MUTATING_OPTIONS = {"--fix", "--output", "--update", "--update-snapshot", "--write", "-u", "-w"}
SUBCOMMANDS = {
    "bun": {"lint", "test"},
    "cargo": {"check", "clippy", "test"},
    # Not diff, show or log: RTK cuts each file's diff to 100 lines and a log to 10 commits without
    # saying so, which hides part of a change or a history from whoever reads it, including the Ralph
    # policy reviewer.
    "git": {"status"},
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
    # RTK parses the command text itself and misread other spacing: `head  -n 3 file` (two spaces)
    # became a read of the whole file. Only single-spaced commands are rewritten.
    if " ".join(command.split()) != command:
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
    # A command line cannot hold a NUL byte; bash would read past it and check something else.
    if "\x00" in command:
        return False
    try:
        # On stdin, not as an argument: an argument longer than 128 KiB fails with E2BIG.
        result = subprocess.run(
            ["/bin/bash", "-n"],
            input=command.encode("utf-8", "surrogatepass"),
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
    except OSError as error:
        # RTK takes the command as an argument, which cannot exceed 128 KiB; such a command runs
        # unchanged, like any command RTK has no rewrite for.
        if error.errno == errno.E2BIG:
            return "", None
        return None, f"RTK Safe Hook failed to inspect the command: {type(error).__name__}."
    except subprocess.TimeoutExpired as error:
        return None, f"RTK Safe Hook failed to inspect the command: {type(error).__name__}."
    # RTK 0.46 reports a command without a rewrite as the last stderr line with exit code 1,
    # possibly after its own "[rtk] " diagnostics such as the missing-hook warning.
    stderr = result.stderr[:-1] if result.stderr.endswith("\n") else result.stderr
    *diagnostics, report = stderr.split("\n")
    if (
        result.returncode == 1
        and not result.stdout.strip()
        and report == f"No rewrite for: {command}"
        and all(line.startswith("[rtk] ") for line in diagnostics)
    ):
        return "", None
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
