#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

# Installed layout: the adapter, the Codex rules it loads and the regression test side by side.
hook_dir="$TEST_ROOT/cursor home/hooks/rtk-safe"
mkdir -p "$hook_dir"
cp "$ROOT/hooks/rtk-cursor-safe-hook.py" "$ROOT/hooks/rtk-codex-safe-hook.py" "$hook_dir/"
cp "$ROOT/hooks/test-rtk-cursor-safe-hook.sh" "$hook_dir/test.sh"
chmod 0755 "$hook_dir/rtk-cursor-safe-hook.py" "$hook_dir/rtk-codex-safe-hook.py" "$hook_dir/test.sh"
HOOK="$hook_dir/rtk-cursor-safe-hook.py"

fake_rtk="$TEST_ROOT/rtk"
cat > "$fake_rtk" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == hook && "${2:-}" == check ]]
case "${3:-}" in
  'go test ./...') printf 'rtk go test ./...\n' ;;
  'npm test' | 'bun test' | 'yarn lint' | 'pnpm test' | 'tail -f app.log' | '  npm test -- --grep "a b"  ')
    # Like RTK 0.46: no rewrite is reported with the verbatim command on stderr and exit code 1.
    printf 'No rewrite for: %s\n' "${3:-}" >&2
    exit 1
    ;;
  *) printf 'rtk %s\n' "${3:-}" ;;
esac
EOF
failing_rtk="$TEST_ROOT/failing-rtk"
printf '%s\n' '#!/usr/bin/env bash' 'exit 9' > "$failing_rtk"
fixed_rtk="$TEST_ROOT/fixed-rtk"
cat > "$fixed_rtk" <<'EOF'
#!/usr/bin/env bash
printf '%s' "$FAKE_STDOUT"
printf '%s' "$FAKE_STDERR" >&2
exit "$FAKE_STATUS"
EOF
chmod 0755 "$fake_rtk" "$failing_rtk" "$fixed_rtk"

RTK_BIN="$fake_rtk" "$hook_dir/test.sh"
RTK_BIN="$fake_rtk" HOOK="$HOOK" bash "$ROOT/hooks/test-rtk-cursor-safe-hook.sh"

real_python="$(command -v python3)"
assert_bin="$TEST_ROOT/assert-bin"
caller_dir="$TEST_ROOT/caller"
mkdir -p "$assert_bin" "$caller_dir"
cat > "$assert_bin/python3" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$PWD" == "$EXPECTED_PYTHON_CWD" ]] || {
  echo "python3 invoked from unsafe caller cwd: $PWD" >&2
  exit 91
}
exec "$REAL_PYTHON" "$@"
EOF
chmod 0755 "$assert_bin/python3"
(
  cd "$caller_dir"
  PATH="$assert_bin:$PATH" \
    REAL_PYTHON="$real_python" \
    EXPECTED_PYTHON_CWD="$hook_dir" \
    RTK_BIN="$fake_rtk" \
    "$hook_dir/test.sh"
)

# Cursor may start the hook from any directory; nothing there may be imported or loaded.
hostile_dir="$TEST_ROOT/hostile"
mkdir -p "$hostile_dir"
for decoy in rtk-codex-safe-hook json shlex; do
  printf 'raise SystemExit("loaded %s.py from the caller cwd")\n' "$decoy" > "$hostile_dir/$decoy.py"
done

stdin_file="$TEST_ROOT/stdin"
stdout_file="$TEST_ROOT/stdout"
stderr_file="$TEST_ROOT/stderr"

payload() {
  python3 -c 'import json,sys; print(json.dumps({"conversation_id":"test","generation_id":"test","hook_event_name":"preToolUse","tool_name":"Shell","tool_input":{"command":sys.argv[1],"working_directory":"/work/project","timeout":30000}}))' "$1"
}

# Runs the adapter as registered and requires exactly one JSON object, no stderr and exit 0.
run_hook() {
  local status=0
  printf '%s' "$1" > "$stdin_file"
  (cd "$hostile_dir" && RTK_BIN="${2:-$fake_rtk}" /usr/bin/python3 -B "$HOOK") \
    < "$stdin_file" > "$stdout_file" 2> "$stderr_file" || status=$?
  if [[ "$status" -ne 0 || -s "$stderr_file" ]]; then
    echo "hook exited with $status for input: ${1:0:200}" >&2
    cat "$stderr_file" >&2
    exit 1
  fi
  python3 - "$stdout_file" <<'PY'
import json, pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
assert text.endswith("\n") and text.count("\n") == 1, repr(text)
assert isinstance(json.loads(text), dict), text
PY
}

assert_rewritten() {
  local command="$1"
  local expected="$2"
  run_hook "$(payload "$command")"
  python3 - "$stdout_file" "$expected" <<'PY'
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert "permission" not in data, data
expected = {"command": sys.argv[2], "working_directory": "/work/project", "timeout": 30000}
assert data == {"updated_input": expected}, data
PY
}

assert_no_opinion() {
  local input="$1"
  run_hook "$input" "${2:-$fake_rtk}"
  [[ "$(< "$stdout_file")" == '{}' ]] || {
    echo "unexpected hook output for: $input" >&2
    cat "$stdout_file" >&2
    exit 1
  }
}

assert_denied() {
  local input="$1"
  local expected="$2"
  run_hook "$input" "${3:-$fake_rtk}"
  python3 - "$stdout_file" "$expected" <<'PY'
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert set(data) == {"permission", "user_message", "agent_message"}, data
assert data["permission"] == "deny", data
assert sys.argv[2] in data["user_message"], data
assert sys.argv[2] in data["agent_message"], data
PY
}

for command in \
  'cat README.md' \
  'ls -la' \
  'rg needle .' \
  'pytest -q' \
  'npx eslint example.js' \
  'npx tsc --noEmit' \
  'npx vitest run' \
  'cargo test' \
  'git status --short' \
  'ruff check .'; do
  assert_rewritten "$command" "rtk $command"
done
assert_rewritten 'go test ./...' 'rtk go test ./...'

# RTK has no rewrite for these allowlisted commands; they must run unchanged, not be denied.
for command in 'npm test' 'bun test' 'yarn lint' 'pnpm test' 'tail -f app.log' '  npm test -- --grep "a b"  '; do
  assert_no_opinion "$(payload "$command")"
done

# A failing RTK proves these commands stay unchanged without RTK being consulted.
for command in \
  'npx prettier --write example.js' \
  'git push origin main' \
  'go env' \
  'unknown-command argument' \
  'go test ./... | tail -20' \
  $'go test ./...\nprintf done'; do
  assert_no_opinion "$(payload "$command")" "$failing_rtk"
done

assert_denied '[]' 'JSON object'
assert_denied 'null' 'JSON object'
assert_denied '' 'invalid JSON'
assert_denied '{' 'invalid JSON'
assert_denied $'\xff' 'invalid JSON'
assert_denied '{"hook_event_name":"postToolUse","tool_name":"Shell","tool_input":{"command":"ls"}}' 'unexpected Cursor hook event'
assert_denied '{"hook_event_name":"PreToolUse","tool_name":"Shell","tool_input":{"command":"ls"}}' 'unexpected Cursor hook event'
assert_denied '{"tool_name":"Shell","tool_input":{"command":"ls"}}' 'unexpected Cursor hook event'
assert_denied '{"hook_event_name":"preToolUse","tool_name":"Read","tool_input":{"command":"ls"}}' 'unexpected Cursor hook event'
assert_denied '{"hook_event_name":"preToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}' 'unexpected Cursor hook event'
assert_denied '{"hook_event_name":"preToolUse","tool_name":"Shell"}' 'without a string command'
assert_denied '{"hook_event_name":"preToolUse","tool_name":"Shell","tool_input":"ls"}' 'without a string command'
assert_denied '{"hook_event_name":"preToolUse","tool_name":"Shell","tool_input":{}}' 'without a string command'
assert_denied '{"hook_event_name":"preToolUse","tool_name":"Shell","tool_input":{"command":7}}' 'without a string command'
assert_denied '{"hook_event_name":"preToolUse","tool_name":"Shell","tool_input":{"command":null}}' 'without a string command'
assert_denied '{"hook_event_name":"preToolUse","tool_name":"Shell","tool_input":{"command":""}}' 'empty or invalid Shell command'
assert_denied '{"hook_event_name":"preToolUse","tool_name":"Shell","tool_input":{"command":"if then"}}' 'empty or invalid Shell command'
assert_denied "$(python3 -c 'print("x" * (1024 * 1024 + 1), end="")')" 'oversized'

assert_denied "$(payload 'go test ./...')" 'exit code 9' "$failing_rtk"
assert_denied "$(payload 'go test ./...')" 'failed to inspect' "$TEST_ROOT/missing-rtk"

for mode in no-rewrite non-rtk invalid complex; do
  special_rtk="$TEST_ROOT/rtk-$mode"
  case "$mode" in
    no-rewrite) response='No rewrite for: go test ./...' ;;
    non-rtk) response='go test ./...' ;;
    invalid) response='rtk "' ;;
    complex) response='rtk go test ./... | tail -1' ;;
  esac
  printf '%s\n' '#!/usr/bin/env bash' "printf '%s\\n' '$response'" > "$special_rtk"
  chmod 0755 "$special_rtk"
done
assert_no_opinion "$(payload 'go test ./...')" "$TEST_ROOT/rtk-no-rewrite"
assert_denied "$(payload 'go test ./...')" 'unexpected RTK rewrite' "$TEST_ROOT/rtk-non-rtk"
assert_denied "$(payload 'go test ./...')" 'unparsable RTK rewrite' "$TEST_ROOT/rtk-invalid"
assert_denied "$(payload 'go test ./...')" 'complex or invalid RTK rewrite' "$TEST_ROOT/rtk-complex"

# Only exit 1 with empty stdout and the exact report for this command means "no rewrite".
FAKE_STDOUT='' FAKE_STDERR=$'No rewrite for: go test ./...\n' FAKE_STATUS=1 \
  assert_no_opinion "$(payload 'go test ./...')" "$fixed_rtk"
FAKE_STDOUT='' FAKE_STDERR=$'error: failed to load RTK config\n' FAKE_STATUS=1 \
  assert_denied "$(payload 'go test ./...')" 'exit code 1' "$fixed_rtk"
FAKE_STDOUT=$'rtk go test ./...\n' FAKE_STDERR=$'No rewrite for: go test ./...\n' FAKE_STATUS=1 \
  assert_denied "$(payload 'go test ./...')" 'exit code 1' "$fixed_rtk"
FAKE_STDOUT='' FAKE_STDERR=$'No rewrite for: npm test\n' FAKE_STATUS=1 \
  assert_denied "$(payload 'go test ./...')" 'exit code 1' "$fixed_rtk"
FAKE_STDOUT='' FAKE_STDERR=$'No rewrite for: go test ./...\n' FAKE_STATUS=2 \
  assert_denied "$(payload 'go test ./...')" 'exit code 2' "$fixed_rtk"

# RTK may print its own "[rtk] " diagnostics before the report, such as this real warning.
rtk_warning='[rtk] /!\ No hook installed — run `rtk init -g` for automatic token savings'
FAKE_STDOUT='' FAKE_STDERR="$rtk_warning"$'\nNo rewrite for: npm test\n' FAKE_STATUS=1 \
  assert_no_opinion "$(payload 'npm test')" "$fixed_rtk"
FAKE_STDOUT='' FAKE_STDERR=$'warning: low disk space\nNo rewrite for: npm test\n' FAKE_STATUS=1 \
  assert_denied "$(payload 'npm test')" 'exit code 1' "$fixed_rtk"
FAKE_STDOUT='' FAKE_STDERR=$'No rewrite for: npm test\n'"$rtk_warning"$'\n' FAKE_STATUS=1 \
  assert_denied "$(payload 'npm test')" 'exit code 1' "$fixed_rtk"
FAKE_STDOUT='' FAKE_STDERR="$rtk_warning"$'\nNo rewrite for: go test ./...\n' FAKE_STATUS=1 \
  assert_denied "$(payload 'npm test')" 'exit code 1' "$fixed_rtk"
FAKE_STDOUT='' FAKE_STDERR="$rtk_warning"$'\n' FAKE_STATUS=1 \
  assert_denied "$(payload 'npm test')" 'exit code 1' "$fixed_rtk"

# Crashes inside the shared rules still become a single deny instead of a blocked, silent call.
assert_denied '{"hook_event_name":"preToolUse","tool_name":"Shell","tool_input":{"command":"ls\u0000 -la"}}' 'failed unexpectedly: ValueError'
assert_denied "$(python3 -c 'print("[" * 100000)')" 'RTK Safe Hook'

missing_dir="$TEST_ROOT/missing-rules"
broken_dir="$TEST_ROOT/broken-rules"
empty_dir="$TEST_ROOT/empty-rules"
mkdir -p "$missing_dir" "$broken_dir" "$empty_dir"
for dir in "$missing_dir" "$broken_dir" "$empty_dir"; do
  cp "$ROOT/hooks/rtk-cursor-safe-hook.py" "$dir/"
done
printf 'def broken(:\n' > "$broken_dir/rtk-codex-safe-hook.py"
: > "$empty_dir/rtk-codex-safe-hook.py"
HOOK="$missing_dir/rtk-cursor-safe-hook.py" \
  assert_denied "$(payload 'go test ./...')" 'could not load rtk-codex-safe-hook.py: FileNotFoundError'
HOOK="$broken_dir/rtk-cursor-safe-hook.py" \
  assert_denied "$(payload 'go test ./...')" 'could not load rtk-codex-safe-hook.py: SyntaxError'
HOOK="$empty_dir/rtk-cursor-safe-hook.py" \
  assert_denied "$(payload 'go test ./...')" 'failed unexpectedly: AttributeError'

# Loading the rules module writes bytecode unless the adapter disables it, even without -B.
control_dir="$TEST_ROOT/bytecode-control"
mkdir -p "$control_dir"
cp "$ROOT/hooks/rtk-codex-safe-hook.py" "$control_dir/"
env -u PYTHONDONTWRITEBYTECODE -u PYTHONPYCACHEPREFIX python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("control", sys.argv[1])
spec.loader.exec_module(importlib.util.module_from_spec(spec))
' "$control_dir/rtk-codex-safe-hook.py"
[[ -d "$control_dir/__pycache__" ]]
payload 'go test ./...' \
  | RTK_BIN="$fake_rtk" env -u PYTHONDONTWRITEBYTECODE -u PYTHONPYCACHEPREFIX python3 "$HOOK" \
  > "$stdout_file"
grep -Fq '"updated_input":{"command":"rtk go test ./..."' "$stdout_file"
[[ ! -e "$hook_dir/__pycache__" ]] || {
  echo "Cursor RTK Safe Hook wrote bytecode next to the installed hook" >&2
  exit 1
}

printf 'PASS: Cursor RTK Safe Hook adapter and fail-close tests.\n'
