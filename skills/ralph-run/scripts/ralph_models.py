#!/usr/bin/env python3
"""Resolve the models a Ralph run uses, without touching the agent's own default model.

Saved Ralph defaults live in a per-agent settings file that setup never rewrites:
  codex        $CODEX_HOME/ralph.json (default ~/.codex/ralph.json)
  cursor       ~/.cursor/ralph.json
  antigravity  ~/.gemini/antigravity-cli/ralph.json
The file is a JSON object with optional "model" (workers) and "review_model" (policy reviewer).
A run may override them with RALPH_MODEL and RALPH_REVIEW_MODEL. The worker uses RALPH_MODEL, then
"model"; the reviewer uses RALPH_REVIEW_MODEL, then "review_model", then the worker's model. With
none of these the agent CLI runs with its own default model, exactly as without this file.

`resolve --agent AGENT` prints two lines, the worker and reviewer model, each empty for the CLI
default. `check --agent AGENT` only validates the settings file. Invalid input is an error.
"""
import argparse
import json
import os
from pathlib import Path
import re
import sys

KEYS = ('model', 'review_model')
# Model slugs as the CLIs print them: letters, digits and . _ - : / [ ] = , only.
MODEL = re.compile(r'[A-Za-z0-9][A-Za-z0-9._:/\[\]=,-]*')


def settings_path(agent):
    home = Path.home()
    if agent == 'codex':
        return Path(os.environ.get('CODEX_HOME') or home / '.codex') / 'ralph.json'
    if agent == 'cursor':
        return home / '.cursor' / 'ralph.json'
    return home / '.gemini' / 'antigravity-cli' / 'ralph.json'


def valid_model(value, origin):
    if not isinstance(value, str) or not MODEL.fullmatch(value):
        raise ValueError(f'{origin} is not a valid model name: {value!r}')
    return value


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
    unknown = sorted(set(data) - set(KEYS))
    if unknown:
        raise ValueError(f'unknown keys in Ralph model settings {path}: {", ".join(unknown)}')
    return {key: valid_model(data[key], f'{key} in {path}') for key in KEYS if key in data}


def resolve(agent, model=None, review_model=None):
    """Return (worker model, reviewer model); None means the CLI's own default."""
    defaults = saved(agent)
    if model is None:
        model = os.environ.get('RALPH_MODEL') or None
    if review_model is None:
        review_model = os.environ.get('RALPH_REVIEW_MODEL') or None
    worker = valid_model(model, 'the run model') if model else defaults.get('model')
    reviewer = (valid_model(review_model, 'the run review model') if review_model
                else defaults.get('review_model', worker))
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
            print(worker or '')
            print(reviewer or '')
    except ValueError as exc:
        print(f'error: {exc}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
