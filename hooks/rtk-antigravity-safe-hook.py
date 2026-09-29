#!/usr/bin/env python3
"""Conservatively rewrite simple Antigravity CLI run_command calls through RTK.

agy blocks the tool when a hook crashes, prints invalid JSON, times out or exits non-zero,
so every path prints exactly one JSON object and exits 0. The command rules come from the
sibling Codex RTK Safe Hook.
"""

from __future__ import annotations

import sys

sys.dont_write_bytecode = True

import importlib.util
import json
from pathlib import Path
from types import ModuleType


CODEX_HOOK_NAME = "rtk-codex-safe-hook.py"


def emit(response: dict[str, object]) -> None:
    json.dump(response, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")


def deny(reason: str) -> dict[str, object]:
    return {"decision": "deny", "reason": reason}


def load_codex_hook() -> ModuleType:
    path = Path(__file__).resolve().parent / CODEX_HOOK_NAME
    spec = importlib.util.spec_from_file_location("rtk_codex_safe_hook", path)
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def decide(codex: ModuleType) -> dict[str, object]:
    payload, error = codex.parse_input()
    if error:
        return deny(error)
    assert payload is not None

    tool_call = payload.get("toolCall")
    if not isinstance(tool_call, dict) or tool_call.get("name") != "run_command":
        return deny("RTK Safe Hook received an unexpected Antigravity tool call.")
    args = tool_call.get("args")
    if not isinstance(args, dict) or not isinstance(args.get("CommandLine"), str):
        return deny("RTK Safe Hook received a run_command call without a string CommandLine.")
    command = args["CommandLine"]
    if not command or not codex.bash_syntax_ok(command):
        return deny("RTK Safe Hook rejected an empty or invalid run_command CommandLine.")

    # "ask" keeps agy's normal permission flow. Complex and non-allowlisted commands
    # intentionally stay byte-for-byte unchanged.
    if not codex.command_is_allowlisted(command):
        return {"decision": "ask"}

    rewritten, error = codex.rewrite(command)
    if error:
        return deny(error)
    if not rewritten:
        return {"decision": "ask"}
    # agy shallow-merges overwrite into the call's args, so only CommandLine changes.
    return {"decision": "ask", "overwrite": {"CommandLine": rewritten}}


def respond() -> dict[str, object]:
    try:
        codex = load_codex_hook()
    except Exception as error:
        return deny(f"RTK Safe Hook could not load {CODEX_HOOK_NAME}: {type(error).__name__}.")
    try:
        return decide(codex)
    except Exception as error:
        return deny(f"RTK Safe Hook failed unexpectedly: {type(error).__name__}.")


def main() -> int:
    emit(respond())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
