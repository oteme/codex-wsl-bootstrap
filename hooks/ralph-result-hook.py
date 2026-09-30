#!/usr/bin/env python3
"""Add finished Ralph results to the next message of the Cursor or Antigravity conversation that
started them.

Cursor and Antigravity have no message queue. The Ralph supervisor leaves each result in an inbox
named by the conversation, and this hook adds it when that conversation next goes to the model:
Cursor runs it before a prompt is submitted (beforeSubmitPrompt, returned as additional_context),
Antigravity before each model call (PreInvocation, injected as a user message at the first call of a
turn, so that a result never lands inside a turn's tool loop). Resuming the conversation from outside
lost the result when that conversation was open in an interactive session, which overwrote it with
its next turn.

A failure with exit status 1 lets the message go on without the result, which stays in the inbox.
Cursor blocks the message on exit status 2, which python3 returns when this file is missing; the
installers' --verify and Doctor require the file. A result leaves the inbox only after the hook has
written its output, so a failed write can deliver it again but never lose it.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
import uuid


MAX_INPUT_BYTES = 1024 * 1024
# Keep in step with INBOX in skills/ralph-run/scripts/ralph-notify.py, which fills these inboxes.
INBOX = {
    "cursor": Path.home() / ".cursor" / "ralph-inbox",
    "antigravity": Path.home() / ".gemini" / "antigravity-cli" / "ralph-inbox",
}
# Cursor drops the whole additional_context when it is longer than 10,000 UTF-16 code units (CLI
# 2026.09.28), counted after it joins every hook's context and adds its own mode text. The hook keeps
# its text 500 units below that, and results that do not fit wait for the next message. Antigravity
# states no limit.
CONTEXT_LIMIT = {"cursor": 10_000 - 500, "antigravity": None}
# The names ralph-notify.py gives the results (keep in step with INBOX_ENTRY there); anything else in
# an inbox is left alone. A result that was delivered but could not be recorded in its result file
# is kept as <entry>.delivered, so that --status can tell.
ENTRY = re.compile(r"\d{20}-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.json")
CLAIMED = re.compile(f"({ENTRY.pattern})\\.(\\d+)\\.claimed")


def fail(reason: str) -> int:
    print(reason, file=sys.stderr)
    return 1


def read_input(agent: str) -> tuple[str | None, bool, str | None]:
    """The conversation, whether this call may add results, and an error."""
    raw = sys.stdin.buffer.read(MAX_INPUT_BYTES + 1)
    if len(raw) > MAX_INPUT_BYTES:
        return None, False, "Ralph result hook rejected an oversized hook payload."
    try:
        payload = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None, False, "Ralph result hook rejected invalid JSON."
    if not isinstance(payload, dict):
        return None, False, "Ralph result hook expected a JSON object."
    # Antigravity names no event; its PreInvocation input is the one that carries invocationNum.
    if agent == "cursor":
        if payload.get("hook_event_name") != "beforeSubmitPrompt":
            return None, False, "Ralph result hook received an unexpected Cursor hook event."
        value, first_call = payload.get("conversation_id"), True
    else:
        invocation = payload.get("invocationNum")
        if type(invocation) is not int:
            return None, False, "Ralph result hook received an unexpected Antigravity hook input."
        value, first_call = payload.get("conversationId"), invocation == 0
    try:
        return str(uuid.UUID(value)), first_call, None
    except (TypeError, ValueError, AttributeError):
        return None, False, "Ralph result hook received no valid conversation ID."


def read_result(result_file: Path) -> tuple[dict[str, object] | None, str | None]:
    try:
        state = json.loads(result_file.read_text(encoding="utf-8"))
    except (OSError, ValueError, RecursionError) as error:
        return None, f"{type(error).__name__}: {error}"
    if not isinstance(state, dict):
        return None, "it is not a JSON object"
    return state, None


def record_delivery(result_file: Path) -> str | None:
    """Mark the run's result file as delivered, keeping its mode; return why it could not be, or None."""
    state, problem = read_result(result_file)
    if state is None:
        return problem
    try:
        state["notification"] = "delivered"
        mode = stat.S_IMODE(result_file.stat().st_mode)
        descriptor, name = tempfile.mkstemp(prefix=".result.", suffix=".tmp", dir=result_file.parent)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as temporary:
                temporary.write(json.dumps(state, ensure_ascii=False, indent=2) + "\n")
            os.chmod(name, mode)
            os.replace(name, result_file)
        finally:
            Path(name).unlink(missing_ok=True)
    except (OSError, ValueError) as error:
        return f"{type(error).__name__}: {error}"
    return None


def printable(text: str) -> str:
    """TEXT with what cannot be written as UTF-8 escaped: a path that is not UTF-8 (for example under
    such a HOME) reaches a report as lone surrogates."""
    return text.encode("utf-8", "backslashreplace").decode("utf-8")


def utf16_length(text: str) -> int:
    return len(text.encode("utf-16-le", "surrogatepass")) // 2


def shortened(text: str, limit: int) -> str:
    """TEXT cut to LIMIT UTF-16 code units, marked as cut."""
    marker = " [cut to fit the message]"
    while utf16_length(text) > limit:
        text = text[:max(0, len(text) - (utf16_length(text) - limit) - len(marker))] + marker
    return text


class Taken:
    """A result claimed from the inbox, with the text to add and where it came from."""

    def __init__(self, message: str, entry: Path, claimed: Path, result_file: Path | None):
        self.message, self.entry, self.claimed, self.result_file = message, entry, claimed, result_file


def recover(inbox: Path) -> None:
    """Put back the results that a hook call claimed and could not finish (it was killed, for
    example on the CLI's hook timeout): a claim names the claiming process."""
    for claimed in inbox.iterdir():
        match = CLAIMED.fullmatch(claimed.name)
        if not match:
            continue
        try:
            os.kill(int(match.group(2)), 0)
        except (ProcessLookupError, OverflowError):  # No such process, or no such process ID at all.
            try:
                claimed.rename(claimed.with_name(match.group(1)))
            except FileNotFoundError:
                pass  # Another call put it back, or its owner finished it.
        except PermissionError:
            pass  # Alive, under another user.


def take_results(inbox: Path, limit: int | None) -> list[Taken]:
    """Claim the results waiting in INBOX, oldest first, as many as fit in LIMIT. Each one is claimed
    by one hook call only: a call that loses the rename to another leaves that result to it."""
    taken: list[Taken] = []
    if not inbox.is_dir():
        return taken
    try:
        recover(inbox)
        claim(inbox, limit, taken)
    except OSError:
        release(taken)
        raise
    return taken


def claim(inbox: Path, limit: int | None, taken: list[Taken]) -> None:
    for entry in sorted(path for path in inbox.iterdir() if ENTRY.fullmatch(path.name)):
        claimed = entry.with_name(f"{entry.name}.{os.getpid()}.claimed")
        try:
            os.rename(entry, claimed)
        except FileNotFoundError:
            continue
        try:
            data = json.loads(claimed.read_text(encoding="utf-8"))
            message, result_file = data["message"], data["result_file"]
            if not isinstance(message, str) or not isinstance(result_file, str):
                raise ValueError("message and result_file must be strings")
            message.encode("utf-8")  # A lone surrogate could not be written as output.
        except (OSError, ValueError, KeyError, TypeError, RecursionError) as error:
            # Keep the entry for inspection and tell the conversation, instead of dropping it.
            result_file = None
            message = printable(f"[Ralph result] A Ralph result in {entry} could not be read "
                                f"({type(error).__name__}: {error}); it was kept as {entry.name}.invalid.")[:2000]
        if result_file is not None:
            state, problem = read_result(Path(result_file))
            if state is not None and state.get("notification") == "delivered":
                # An earlier call delivered and recorded it, and was stopped before it removed it.
                claimed.unlink()
                continue
            if problem:
                message += printable(f"\n(The delivery cannot be recorded in the result file: {problem[:300]}.)")
        if limit is not None:
            if taken and utf16_length("\n\n".join([*(item.message for item in taken), message])) > limit:
                claimed.rename(entry)  # Next message.
                break
            message = shortened(message, limit)  # Only a result that is not from the supervisor.
        taken.append(Taken(message, entry, claimed, None if result_file is None else Path(result_file)))


def release(taken: list[Taken]) -> None:
    """Put claimed results back into the inbox for the next message."""
    for item in taken:
        item.claimed.rename(item.entry)


def finish(taken: list[Taken]) -> None:
    """After the output is written: record each delivery and take the result out of the inbox."""
    for item in taken:
        if item.result_file is None:
            item.claimed.rename(item.entry.with_name(item.entry.name + ".invalid"))
            continue
        problem = record_delivery(item.result_file)
        if problem:
            item.claimed.rename(item.entry.with_name(item.entry.name + ".delivered"))
            print(f"Ralph result hook delivered {item.entry.name} but could not record it in "
                  f"{item.result_file}: {problem}", file=sys.stderr)
            continue
        item.claimed.unlink()


def main() -> int:
    agent = sys.argv[1] if len(sys.argv) == 2 else None
    if agent not in INBOX:
        return fail("usage: ralph-result-hook.py cursor|antigravity")
    conversation, first_call, error = read_input(agent)
    if error:
        return fail(error)
    try:
        taken = take_results(INBOX[agent] / conversation, CONTEXT_LIMIT[agent]) if first_call else []
    except OSError as error:
        return fail(f"Ralph result hook could not read its inbox: {type(error).__name__}: {error}")
    messages = [item.message for item in taken]
    if not messages:
        output: dict[str, object] = {}
    elif agent == "cursor":
        output = {"additional_context": "\n\n".join(messages)}
    else:
        output = {"injectSteps": [{"userMessage": message} for message in messages]}
    try:
        if sys.stdout is None:  # Started with stdout closed.
            raise OSError("stdout is closed")
        sys.stdout.buffer.write((json.dumps(output, ensure_ascii=False, separators=(",", ":")) + "\n")
                                .encode("utf-8"))
        sys.stdout.buffer.flush()
    except (OSError, ValueError) as error:
        release(taken)
        # Python would flush the broken stdout again on exit and end with status 120 instead.
        os.dup2(os.open(os.devnull, os.O_WRONLY), 1)
        return fail(f"Ralph result hook could not write its output: {type(error).__name__}: {error}")
    try:
        finish(taken)
    except OSError as error:
        return fail(f"Ralph result hook could not update its inbox: {type(error).__name__}: {error}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
