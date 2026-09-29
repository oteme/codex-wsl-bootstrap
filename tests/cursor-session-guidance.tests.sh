#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

hook_dir="$TEST_ROOT/cursor home/hooks/session-guidance"
mkdir -p "$hook_dir"
cp "$ROOT/hooks/cursor-session-guidance.py" "$hook_dir/"
chmod 0755 "$hook_dir/cursor-session-guidance.py"
HOOK="$hook_dir/cursor-session-guidance.py"
guidance="$hook_dir/guidance.md"

# Cursor may start the hook from any directory; a guidance.md or module there must be ignored.
hostile_dir="$TEST_ROOT/hostile"
mkdir -p "$hostile_dir"
printf 'decoy guidance from the caller cwd\n' > "$hostile_dir/guidance.md"
printf 'raise SystemExit("loaded json.py from the caller cwd")\n' > "$hostile_dir/json.py"

stdin_file="$TEST_ROOT/stdin"
stdout_file="$TEST_ROOT/stdout"
stderr_file="$TEST_ROOT/stderr"
session_payload='{"hook_event_name":"sessionStart","session_id":"test","conversation_id":"test"}'

run_hook() {
  hook_status=0
  printf '%s' "$1" > "$stdin_file"
  (cd "$hostile_dir" && /usr/bin/python3 -B "$HOOK") \
    < "$stdin_file" > "$stdout_file" 2> "$stderr_file" || hook_status=$?
}

assert_guidance() {
  run_hook "$1"
  if [[ "$hook_status" -ne 0 || -s "$stderr_file" ]]; then
    echo "session guidance exited with $hook_status for input: $1" >&2
    cat "$stderr_file" >&2
    exit 1
  fi
  python3 - "$stdout_file" "$guidance" <<'PY'
import json, pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
assert text.endswith("\n") and text.count("\n") == 1, repr(text)
expected = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
assert json.loads(text) == {"additional_context": expected}, text
PY
}

assert_failed() {
  local input="$1"
  local expected="$2"
  run_hook "$input"
  [[ "$hook_status" -eq 1 ]] || {
    echo "expected exit 1, got $hook_status for: $expected" >&2
    exit 1
  }
  [[ ! -s "$stdout_file" ]] || {
    echo "unexpected stdout for: $expected" >&2
    cat "$stdout_file" >&2
    exit 1
  }
  grep -Fq "$expected" "$stderr_file" || {
    echo "missing failure reason: $expected" >&2
    cat "$stderr_file" >&2
    exit 1
  }
}

printf '%s\n' '# Workstation guidance' '' '回答は日本語で行う。' 'Keep "quotes" and \backslashes intact.' > "$guidance"
assert_guidance "$session_payload"
assert_guidance '{"hook_event_name":"sessionStart"}'

assert_failed '' 'invalid JSON'
assert_failed '{' 'invalid JSON'
assert_failed $'\xff' 'invalid JSON'
assert_failed '[]' 'JSON object'
assert_failed "$(python3 -c 'print("x" * (1024 * 1024 + 1), end="")')" 'oversized'
assert_failed '{"hook_event_name":"preToolUse","session_id":"test"}' 'unexpected Cursor hook event'
assert_failed '{"hook_event_name":"SessionStart","session_id":"test"}' 'unexpected Cursor hook event'
assert_failed '{"session_id":"test"}' 'unexpected Cursor hook event'

: > "$guidance"
assert_failed "$session_payload" "found an empty $guidance"
printf ' \n\t\n' > "$guidance"
assert_failed "$session_payload" "found an empty $guidance"
printf '\xff\n' > "$guidance"
assert_failed "$session_payload" "could not read $guidance: UnicodeDecodeError"
rm "$guidance"
assert_failed "$session_payload" "could not read $guidance: FileNotFoundError"

printf 'Session guidance.\n' > "$guidance"
printf '%s' "$session_payload" \
  | env -u PYTHONDONTWRITEBYTECODE -u PYTHONPYCACHEPREFIX python3 "$HOOK" \
  > "$stdout_file"
grep -Fxq '{"additional_context":"Session guidance.\n"}' "$stdout_file"
[[ ! -e "$hook_dir/__pycache__" ]] || {
  echo "Cursor session guidance wrote bytecode next to the installed hook" >&2
  exit 1
}

printf 'PASS: Cursor session guidance hook tests.\n'
