#!/usr/bin/env python3
"""Use the agent executable recorded by workstation setup, never ambient PATH."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

# Each installed Ralph skill holds exactly one record, <agent>-runtime.json, whose key is the agent.
AGENTS = {'codex': 'Codex', 'cursor': 'Cursor', 'antigravity': 'Antigravity'}
SCRIPTS = Path(__file__).parent


def validate(executable, agent='codex'):
    if (not isinstance(executable, str) or not Path(executable).is_absolute()
            or any(c in executable for c in '\r\n\0')
            or not Path(executable).is_file() or not os.access(executable, os.X_OK)):
        raise ValueError(f'recorded {AGENTS[agent]} executable is invalid or unavailable')
    return executable


def record_agent():
    present = [agent for agent in AGENTS if (SCRIPTS / f'{agent}-runtime.json').exists()]
    if len(present) != 1:
        found = ', '.join(f'{agent}-runtime.json' for agent in present) or 'none'
        raise ValueError(f'expected exactly one Ralph runtime record next to {SCRIPTS}, found {found}')
    return present[0]


def load_agent():
    try:
        agent = record_agent()
        data = json.loads((SCRIPTS / f'{agent}-runtime.json').read_text())
        if not isinstance(data, dict) or data.get('schema') != 1:
            raise ValueError(f'invalid {AGENTS[agent]} runtime record')
        return agent, validate(data.get(agent), agent)
    except (ValueError, OSError) as exc:
        raise ValueError(f'{exc}; rerun Downloads/setup-wsl.cmd to configure Ralph runtime') from exc


def load():
    return load_agent()[1]


def record(path, agent, executable):
    executable = validate(executable, agent)
    version = subprocess.check_output([executable, '--version'], text=True, timeout=10).strip()
    if not version:
        raise ValueError(f'{AGENTS[agent]} returned an empty version')
    temp = path.with_suffix('.tmp')
    temp.write_text(json.dumps({'schema': 1, agent: executable, 'setup_version': version}) + '\n')
    temp.replace(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--record', type=Path)
    executables = parser.add_mutually_exclusive_group()
    for agent in AGENTS:
        executables.add_argument(f'--{agent}')
    parser.add_argument('--expect', choices=AGENTS)
    args = parser.parse_args()
    chosen = [agent for agent in AGENTS if getattr(args, agent) is not None]
    try:
        if args.record is not None:
            if not chosen:
                raise ValueError('--record requires --codex, --cursor or --antigravity')
            record(args.record, chosen[0], getattr(args, chosen[0]))
        else:
            if chosen:
                raise ValueError(f'--{chosen[0]} requires --record')
            agent, executable = load_agent()
            if args.expect is not None and agent != args.expect:
                raise ValueError(f'this Ralph skill is configured for {AGENTS[agent]}, '
                                 f'not {AGENTS[args.expect]}')
            print(executable)
    except (ValueError, OSError, subprocess.SubprocessError) as exc:
        print(f'error: {exc}; rerun Downloads/setup-wsl.cmd to configure Ralph runtime', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
