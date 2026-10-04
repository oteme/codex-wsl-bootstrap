#!/usr/bin/env python3
"""Resolve the models and the Codex reasoning effort a Ralph run uses, without touching the agent's
own defaults.

Saved Ralph defaults live in a per-agent settings file that setup never rewrites:
  codex        $CODEX_HOME/ralph.json (default ~/.codex/ralph.json)
  cursor       ~/.cursor/ralph.json
  antigravity  ~/.gemini/antigravity-cli/ralph.json
The file is a JSON object with optional "model" (workers) and "review_model" (policy reviewer).
A run may override them with RALPH_MODEL and RALPH_REVIEW_MODEL. The worker uses RALPH_MODEL, then
"model"; the reviewer uses RALPH_REVIEW_MODEL, then "review_model", then the worker's model. With
none of these the agent CLI runs with its own default model, exactly as without this file.

The Codex file may also hold "effort" and "review_effort", the reasoning effort Codex runs with (its
model_reasoning_effort), resolved the same way with RALPH_EFFORT and RALPH_REVIEW_EFFORT; without
any, Codex keeps its configured effort. Cursor and Antigravity take the effort in the model name, so
an effort for them is an error.

`resolve --agent AGENT` prints four lines: the worker and reviewer model, then the worker and
reviewer effort, each empty for the CLI default. `check --agent AGENT` only validates the settings
file. Invalid input is an error.
"""
import argparse
import json
import os
from pathlib import Path
import re
import sys

MODEL_KEYS = ('model', 'review_model')
EFFORT_KEYS = ('effort', 'review_effort')
# Model slugs as the CLIs print them: letters, digits and . _ - : / [ ] = , only.
MODEL = re.compile(r'[A-Za-z0-9][A-Za-z0-9._:/\[\]=,-]*')
# Reasoning efforts as Codex sends them to the model: lowercase letters only. Which ones a model
# accepts is up to the model; the first codex exec fails on any other.
EFFORT = re.compile(r'[a-z]+')


def settings_path(agent):
    home = Path.home()
    if agent == 'codex':
        return Path(os.environ.get('CODEX_HOME') or home / '.codex') / 'ralph.json'
    if agent == 'cursor':
        return home / '.cursor' / 'ralph.json'
    if agent == 'antigravity':
        return home / '.gemini' / 'antigravity-cli' / 'ralph.json'
    raise ValueError(f'unknown agent: {agent!r}')


def valid_model(value, origin):
    if not isinstance(value, str) or not MODEL.fullmatch(value):
        raise ValueError(f'{origin} is not a valid model name: {value!r}')
    return value


def valid_effort(value, origin):
    if not isinstance(value, str) or not EFFORT.fullmatch(value):
        raise ValueError(f'{origin} is not a valid reasoning effort: {value!r}')
    return value


def codex_only(agent, origin):
    if agent != 'codex':
        raise ValueError(f'{origin}: only Codex takes a Ralph reasoning effort; '
                         f'{agent} takes it in the model name')


def saved(agent):
    path = settings_path(agent)
    if not path.exists() and not path.is_symlink():
        return {}
    try:
        data = json.loads(path.read_text(encoding='utf-8'))
    except (OSError, UnicodeDecodeError, ValueError) as exc:
        raise ValueError(f'invalid Ralph model settings {path}: {exc}') from exc
    if not isinstance(data, dict):
        raise ValueError(f'Ralph model settings must be a JSON object: {path}')
    unknown = sorted(set(data) - set(MODEL_KEYS + EFFORT_KEYS))
    if unknown:
        raise ValueError(f'unknown keys in Ralph model settings {path}: {", ".join(unknown)}')
    efforts = [key for key in EFFORT_KEYS if key in data]
    if efforts:
        codex_only(agent, f'{", ".join(efforts)} in {path}')
    values = {key: valid_model(data[key], f'{key} in {path}') for key in MODEL_KEYS if key in data}
    values.update((key, valid_effort(data[key], f'{key} in {path}')) for key in efforts)
    return values


def resolve(agent, model=None, review_model=None):
    """Return (worker model, reviewer model); None means the CLI's own default."""
    defaults = saved(agent)
    if model is None:
        model = os.environ.get('RALPH_MODEL') or None
    if review_model is None:
        review_model = os.environ.get('RALPH_REVIEW_MODEL') or None
    worker = valid_model(model, 'the run model') if model is not None else defaults.get('model')
    reviewer = (valid_model(review_model, 'the run review model') if review_model is not None
                else defaults.get('review_model', worker))
    return worker, reviewer


def resolve_efforts(agent, effort=None, review_effort=None):
    """Return (worker effort, reviewer effort); None means the CLI's own effort."""
    defaults = saved(agent)
    if effort is None:
        effort = os.environ.get('RALPH_EFFORT') or None
    if review_effort is None:
        review_effort = os.environ.get('RALPH_REVIEW_EFFORT') or None
    if effort is not None:
        codex_only(agent, 'the run effort')
    if review_effort is not None:
        codex_only(agent, 'the run review effort')
    worker = (valid_effort(effort, 'the run effort') if effort is not None
              else defaults.get('effort'))
    reviewer = (valid_effort(review_effort, 'the run review effort') if review_effort is not None
                else defaults.get('review_effort', worker))
    return worker, reviewer


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('command', choices=('resolve', 'check'))
    parser.add_argument('--agent', required=True, choices=('codex', 'cursor', 'antigravity'))
    args = parser.parse_args()
    try:
        if args.command == 'check':
            saved(args.agent)
        else:
            worker, reviewer = resolve(args.agent)
            worker_effort, review_effort = resolve_efforts(args.agent)
            for value in (worker, reviewer, worker_effort, review_effort):
                print(value or '')
    except ValueError as exc:
        print(f'error: {exc}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
