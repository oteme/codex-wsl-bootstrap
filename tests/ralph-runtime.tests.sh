#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
source "$ROOT/install.sh"
# Only isolated temporary destinations are installed. No network or model calls.
RALPH_SOURCE_DIR="$TEST_ROOT/upstream"
for name in prd ralph; do
  mkdir -p "$RALPH_SOURCE_DIR/skills/$name"
  printf '%s\n' '# fixture' > "$RALPH_SOURCE_DIR/skills/$name/SKILL.md"
done
mkdir -p "$TEST_ROOT/setup bin"
printf '%s\n' '#!/bin/sh' '[ "$1" = --version ] || exit 90' 'echo codex-cli-fixture' > "$TEST_ROOT/setup bin/codex"
chmod +x "$TEST_ROOT/setup bin/codex"
export PATH="$TEST_ROOT/setup bin:$PATH"
for destination in "$TEST_ROOT/linux" "$TEST_ROOT/windows app"; do
  install_ralph "$destination"
  runtime="$destination/skills/ralph-run/scripts/ralph_runtime.py"
  [[ "$(python3 "$runtime")" == "$TEST_ROOT/setup bin/codex" ]]
  python3 - "$destination/skills/ralph-run/scripts/codex-runtime.json" <<'PY'
import json, sys
assert json.load(open(sys.argv[1]))['setup_version'] == 'codex-cli-fixture'
PY
  # Reinstallation must regenerate the machine-local record.
  install_ralph "$destination"
  [[ "$(python3 "$runtime")" == "$TEST_ROOT/setup bin/codex" ]]
done
DRY_RUN=1
install_ralph "$TEST_ROOT/dry-run" > "$TEST_ROOT/dry-run.log"
[[ ! -e "$TEST_ROOT/dry-run" ]]
DRY_RUN=0
# A failed version probe must not publish a runtime record.
printf '%s\n' '#!/bin/sh' 'exit 17' > "$TEST_ROOT/setup bin/codex"
if python3 "$ROOT/skills/ralph-run/scripts/ralph_runtime.py" \
  --record "$TEST_ROOT/invalid.json" --codex "$TEST_ROOT/setup bin/codex" 2> "$TEST_ROOT/error"; then
  echo 'invalid executable was accepted' >&2
  exit 1
fi
[[ ! -e "$TEST_ROOT/invalid.json" ]]
grep -Fq 'setup-wsl.cmd' "$TEST_ROOT/error"
printf '%s\n' 'PASS: installed CLI record, both homes, reinstall, dry run, failed version probe.'
