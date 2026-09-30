#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Only temporary Cursor homes and fixture hook sources are used; ~/.cursor is never touched.
python3 "$ROOT/tests/cursor-setup.tests.py"
printf 'PASS: Cursor hooks, guidance and MCP installer tests.\n'
