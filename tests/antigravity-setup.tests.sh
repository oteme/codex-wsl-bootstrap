#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Only temporary Gemini homes and fixture hook sources are used; ~/.gemini is never touched.
python3 "$ROOT/tests/antigravity-setup.tests.py"
printf 'PASS: Antigravity hook, skills and MCP installer tests.\n'
