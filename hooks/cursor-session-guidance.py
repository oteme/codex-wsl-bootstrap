#!/usr/bin/env python3
"""Inject the bootstrap-managed guidance.md into new Cursor CLI sessions.

A sessionStart hook cannot block the session, so failures are reported on stderr with
exit code 1 instead of being replaced with default text.
"""

from __future__ import annotations

import sys

sys.dont_write_bytecode = True

import json
from pathlib import Path


MAX_INPUT_BYTES = 1024 * 1024
GUIDANCE_NAME = "guidance.md"


def fail(reason: str) -> int:
    print(reason, file=sys.stderr)
    return 1


def parse_input() -> tuple[dict[str, object] | None, str | None]:
    raw = sys.stdin.buffer.read(MAX_INPUT_BYTES + 1)
    if len(raw) > MAX_INPUT_BYTES:
        return None, "Cursor session guidance rejected an oversized hook payload."
    try:
        payload = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None, "Cursor session guidance rejected invalid JSON."
    if not isinstance(payload, dict):
        return None, "Cursor session guidance expected a JSON object."
    return payload, None


def read_guidance() -> tuple[str | None, str | None]:
    path = Path(__file__).resolve().parent / GUIDANCE_NAME
    try:
        guidance = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as error:
        return None, f"Cursor session guidance could not read {path}: {type(error).__name__}."
    if not guidance.strip():
        return None, f"Cursor session guidance found an empty {path}."
    return guidance, None


def main() -> int:
    payload, error = parse_input()
    if error:
        return fail(error)
    assert payload is not None
    if payload.get("hook_event_name") != "sessionStart":
        return fail("Cursor session guidance received an unexpected Cursor hook event.")

    guidance, error = read_guidance()
    if error:
        return fail(error)
    json.dump({"additional_context": guidance}, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
