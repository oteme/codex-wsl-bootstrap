#!/usr/bin/env python3
"""Use the Codex executable recorded by workstation setup, never ambient PATH."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

RECORD = Path(__file__).with_name('codex-runtime.json')


def validate(codex):
    if (not isinstance(codex, str) or not Path(codex).is_absolute()
            or any(c in codex for c in '\r\n\0')
            or not Path(codex).is_file() or not os.access(codex, os.X_OK)):
        raise ValueError('recorded Codex executable is invalid or unavailable')
    return codex


def load():
    try:
        data = json.loads(RECORD.read_text())
        if not isinstance(data, dict) or data.get('schema') != 1:
            raise ValueError('invalid Codex runtime record')
        return validate(data.get('codex'))
    except (ValueError, OSError) as exc:
        raise ValueError(f'{exc}; rerun Downloads/setup-wsl.cmd to configure Ralph runtime') from exc


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--record', type=Path)
    parser.add_argument('--codex')
    args = parser.parse_args()
    try:
        if args.record is not None:
            codex = validate(args.codex)
            version = subprocess.check_output([codex, '--version'], text=True, timeout=10).strip()
            if not version:
                raise ValueError('Codex returned an empty version')
            temp = args.record.with_suffix('.tmp')
            temp.write_text(json.dumps(dict(schema=1, codex=codex, setup_version=version)) + '\n')
            temp.replace(args.record)
        else:
            if args.codex is not None:
                raise ValueError('--codex requires --record')
            print(load())
    except (ValueError, OSError, subprocess.SubprocessError) as exc:
        print(f'error: {exc}; rerun Downloads/setup-wsl.cmd to configure Ralph runtime', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
