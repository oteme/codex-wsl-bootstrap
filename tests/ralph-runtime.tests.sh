#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
# install.sh derives its default paths and PATH from HOME and CODEX_HOME; keep both temporary.
export HOME="$TEST_ROOT/home"
unset CODEX_HOME
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

# expect_refusal MESSAGE COMMAND...: the command fails with MESSAGE and prints no executable.
expect_refusal() {
  local expected="$1"
  shift
  if "$@" > "$TEST_ROOT/out" 2> "$TEST_ROOT/error"; then
    echo "accepted: $*" >&2
    exit 1
  fi
  [[ ! -s "$TEST_ROOT/out" ]]
  grep -Fq -- "$expected" "$TEST_ROOT/error"
}

# An agent skill records its own agent, the one named by --record's agent option.
agent_scripts="$TEST_ROOT/cursor skill/scripts"
agent_runtime="$agent_scripts/ralph_runtime.py"
mkdir -p "$agent_scripts" "$TEST_ROOT/agent bin"
cp "$ROOT/skills/ralph-run/scripts/ralph_runtime.py" "$agent_scripts/"
printf '%s\n' '#!/bin/sh' '[ "$1" = --version ] || exit 90' 'echo 2026.09.28-fixture' > "$TEST_ROOT/agent bin/agent"
printf '%s\n' '#!/bin/sh' '[ "$1" = --version ] || exit 90' 'echo 1.2.13' > "$TEST_ROOT/agent bin/agy"
chmod +x "$TEST_ROOT/agent bin/agent" "$TEST_ROOT/agent bin/agy"
# --record and an agent option only work together; a refusal writes no record.
expect_refusal '--record requires --codex, --cursor or --antigravity' \
  python3 "$agent_runtime" --record "$agent_scripts/cursor-runtime.json"
expect_refusal '--cursor requires --record' python3 "$agent_runtime" --cursor "$TEST_ROOT/agent bin/agent"
[[ "$(ls -A "$agent_scripts")" == ralph_runtime.py ]]
python3 "$agent_runtime" --record "$agent_scripts/cursor-runtime.json" --cursor "$TEST_ROOT/agent bin/agent"
python3 - "$agent_scripts/cursor-runtime.json" "$TEST_ROOT/agent bin/agent" <<'PY'
import json, sys
record = json.load(open(sys.argv[1]))
assert record == {'schema': 1, 'cursor': sys.argv[2], 'setup_version': '2026.09.28-fixture'}, record
PY
[[ "$(python3 "$agent_runtime" --expect cursor)" == "$TEST_ROOT/agent bin/agent" ]]
expect_refusal 'this Ralph skill is configured for Cursor, not Antigravity' \
  python3 "$agent_runtime" --expect antigravity
# A second record next to the script leaves the agent ambiguous, so every lookup is refused.
python3 "$agent_runtime" --record "$agent_scripts/antigravity-runtime.json" --antigravity "$TEST_ROOT/agent bin/agy"
for expect in '' cursor antigravity; do
  expect_refusal 'expected exactly one Ralph runtime record' python3 "$agent_runtime" ${expect:+--expect "$expect"}
  grep -Fq 'found cursor-runtime.json, antigravity-runtime.json' "$TEST_ROOT/error"
done
printf '%s\n' 'PASS: installed CLI record, both homes, reinstall, dry run, failed version probe, agent records.'
