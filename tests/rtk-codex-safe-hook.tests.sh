#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fake_rtk="$TEST_ROOT/rtk"
cp "$ROOT/hooks/rtk-codex-safe-hook.py" "$TEST_ROOT/hook.py"
cat > "$fake_rtk" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == hook && "${2:-}" == check ]]
case "${3:-}" in
  'go test ./...') printf 'rtk go test ./...\n' ;;
  *) printf 'rtk %s\n' "${3:-}" ;;
esac
EOF
chmod 0755 "$fake_rtk" "$TEST_ROOT/hook.py"
RTK_BIN="$fake_rtk" HOOK="$TEST_ROOT/hook.py" \
  bash "$ROOT/hooks/test-rtk-codex-safe-hook.sh"

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
    EXPECTED_PYTHON_CWD="$ROOT/hooks" \
    RTK_BIN="$fake_rtk" \
    HOOK="$TEST_ROOT/hook.py" \
    bash "$ROOT/hooks/test-rtk-codex-safe-hook.sh"
)

payload() {
  python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1"
}

assert_empty() {
  local command="$1"
  local output
  output="$(payload "$command" | RTK_BIN="$fake_rtk" python3 "$TEST_ROOT/hook.py")"
  [[ -z "$output" ]] || {
    echo "unexpected hook output for: $command" >&2
    exit 1
  }
}

assert_denied_json() {
  local input="$1"
  local expected="$2"
  local output
  output="$(printf '%s' "$input" | RTK_BIN="$fake_rtk" python3 "$TEST_ROOT/hook.py")"
  python3 -c '
import json, sys
data = json.load(sys.stdin)["hookSpecificOutput"]
assert data["permissionDecision"] == "deny"
assert sys.argv[1] in data["permissionDecisionReason"]
' "$expected" <<< "$output"
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
  'npm test' \
  'ruff check .'; do
  rewrite_output="$(payload "$command" | RTK_BIN="$fake_rtk" python3 "$TEST_ROOT/hook.py")"
  python3 -c '
import json, sys
data = json.load(sys.stdin)["hookSpecificOutput"]
assert data["permissionDecision"] == "allow"
assert data["updatedInput"]["command"].startswith("rtk ")
' <<< "$rewrite_output"
done

assert_empty 'npx prettier --write example.js'
assert_empty 'git push origin main'
assert_empty 'go env'
assert_empty 'unknown-command argument'

assert_denied_json '[]' 'JSON object'
assert_denied_json '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}' 'unexpected Codex hook event'
assert_denied_json '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"command":"ls"}}' 'unexpected Codex hook event'
assert_denied_json '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{}}' 'without a string command'
assert_denied_json '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":7}}' 'without a string command'
assert_denied_json '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":""}}' 'empty or invalid Bash command'
assert_denied_json '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"if then"}}' 'empty or invalid Bash command'

oversized_output="$(python3 -c 'print("x" * (1024 * 1024 + 1), end="")' | python3 "$TEST_ROOT/hook.py")"
python3 -c '
import json, sys
data = json.load(sys.stdin)["hookSpecificOutput"]
assert data["permissionDecision"] == "deny"
assert "oversized" in data["permissionDecisionReason"]
' <<< "$oversized_output"

failing_rtk="$TEST_ROOT/failing-rtk"
printf '%s\n' '#!/usr/bin/env bash' 'exit 9' > "$failing_rtk"
chmod 0755 "$failing_rtk"
failure_output="$(
  printf '%s\n' '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"go test ./..."}}' \
    | RTK_BIN="$failing_rtk" python3 "$TEST_ROOT/hook.py"
)"
python3 -c '
import json, sys
data = json.load(sys.stdin)["hookSpecificOutput"]
assert data["permissionDecision"] == "deny"
assert "exit code 9" in data["permissionDecisionReason"]
' <<< "$failure_output"

missing_output="$(payload 'go test ./...' | RTK_BIN="$TEST_ROOT/missing-rtk" python3 "$TEST_ROOT/hook.py")"
python3 -c '
import json, sys
data = json.load(sys.stdin)["hookSpecificOutput"]
assert data["permissionDecision"] == "deny"
assert "failed to inspect" in data["permissionDecisionReason"]
' <<< "$missing_output"

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
  special_output="$(payload 'go test ./...' | RTK_BIN="$special_rtk" python3 "$TEST_ROOT/hook.py")"
  if [[ "$mode" == no-rewrite ]]; then
    [[ -z "$special_output" ]]
  else
    python3 -c '
import json, sys
data = json.load(sys.stdin)["hookSpecificOutput"]
assert data["permissionDecision"] == "deny"
' <<< "$special_output"
  fi
done

codex_dir="$TEST_ROOT/codex home"
mkdir -p "$codex_dir"
cat > "$codex_dir/hooks.json" <<'EOF'
{
  "description": "existing hooks",
  "hooks": {
    "SessionEnd": [{"hooks": [{"type": "command", "command": "true"}]}],
    "PreToolUse": [{"matcher": "^Bash$", "hooks": [{"type": "command", "command": "existing-hook"}]}]
  }
}
EOF

for _ in 1 2; do
  python3 "$ROOT/scripts/install-codex-rtk-hook.py" \
    --codex-dir "$codex_dir" \
    --hook-source "$ROOT/hooks/rtk-codex-safe-hook.py" \
    --test-source "$ROOT/hooks/test-rtk-codex-safe-hook.sh" \
    --rtk-version 0.46.0
done

python3 - "$codex_dir/hooks.json" <<'PY'
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert data["description"] == "existing hooks"
assert data["hooks"]["SessionEnd"][0]["hooks"][0]["command"] == "true"
commands = [
    hook["command"]
    for group in data["hooks"]["PreToolUse"]
    for hook in group["hooks"]
]
assert "existing-hook" in commands
managed = [command for command in commands if "rtk-codex-safe-hook.py" in command]
assert len(managed) == 1
assert "codex home" in managed[0]
PY

[[ -x "$codex_dir/hooks/rtk-safe/rtk-codex-safe-hook.py" ]]
[[ -x "$codex_dir/hooks/rtk-safe/test.sh" ]]
grep -Fxq '0.46.0' "$codex_dir/hooks/rtk-safe/rtk-version"

invalid_dir="$TEST_ROOT/invalid"
mkdir -p "$invalid_dir"
printf '{\n' > "$invalid_dir/hooks.json"
set +e
invalid_output="$(python3 "$ROOT/scripts/install-codex-rtk-hook.py" \
  --codex-dir "$invalid_dir" \
  --hook-source "$ROOT/hooks/rtk-codex-safe-hook.py" \
  --test-source "$ROOT/hooks/test-rtk-codex-safe-hook.sh" \
  --rtk-version 0.46.0 2>&1)"
invalid_status=$?
set -e
[[ "$invalid_status" -ne 0 ]]
grep -Fq 'refusing to replace invalid hooks file' <<< "$invalid_output"
grep -Fxq '{' "$invalid_dir/hooks.json"

unsupported_dir="$TEST_ROOT/unsupported"
mkdir -p "$unsupported_dir"
printf '%s\n' '{"hooks":{"PreToolUse":{}}}' > "$unsupported_dir/hooks.json"
set +e
unsupported_output="$(python3 "$ROOT/scripts/install-codex-rtk-hook.py" \
  --codex-dir "$unsupported_dir" \
  --hook-source "$ROOT/hooks/rtk-codex-safe-hook.py" \
  --test-source "$ROOT/hooks/test-rtk-codex-safe-hook.sh" \
  --rtk-version 0.46.0 2>&1)"
unsupported_status=$?
set -e
[[ "$unsupported_status" -ne 0 ]]
grep -Fq 'PreToolUse in hooks.json must be an array' <<< "$unsupported_output"

unmanaged_dir="$TEST_ROOT/unmanaged"
mkdir -p "$unmanaged_dir/hooks/rtk-safe"
set +e
unmanaged_output="$(python3 "$ROOT/scripts/install-codex-rtk-hook.py" \
  --codex-dir "$unmanaged_dir" \
  --hook-source "$ROOT/hooks/rtk-codex-safe-hook.py" \
  --test-source "$ROOT/hooks/test-rtk-codex-safe-hook.sh" \
  --rtk-version 0.46.0 2>&1)"
unmanaged_status=$?
set -e
[[ "$unmanaged_status" -ne 0 ]]
grep -Fq 'refusing to overwrite unmanaged hook directory' <<< "$unmanaged_output"

set +e
missing_source_output="$(python3 "$ROOT/scripts/install-codex-rtk-hook.py" \
  --codex-dir "$TEST_ROOT/missing-source" \
  --hook-source "$TEST_ROOT/no-hook.py" \
  --test-source "$ROOT/hooks/test-rtk-codex-safe-hook.sh" \
  --rtk-version 0.46.0 2>&1)"
missing_source_status=$?
set -e
[[ "$missing_source_status" -ne 0 ]]
grep -Fq 'RTK hook source is missing' <<< "$missing_source_output"

printf 'PASS: RTK hook bootstrap install and fail-close tests.\n'
