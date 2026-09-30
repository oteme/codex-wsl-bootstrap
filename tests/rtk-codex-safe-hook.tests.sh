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
  'npm test' | 'bun test' | 'yarn lint' | 'pnpm test' | 'npm test -- --grep "a b"')
    # Like RTK 0.46: no rewrite is reported with the verbatim command on stderr and exit code 1.
    printf 'No rewrite for: %s\n' "${3:-}" >&2
    exit 1
    ;;
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
  output="$(payload "$command" | RTK_BIN="${2:-$fake_rtk}" python3 "$TEST_ROOT/hook.py")"
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
# RTK would shorten these diffs to 100 lines per file, so the hook leaves them unchanged.
assert_empty 'git diff --cached HEAD'
assert_empty 'git show HEAD'
# go test is allowlisted, so only the mutating-option guard keeps these unchanged.
assert_empty 'go test --output=marker ./...'
assert_empty 'go test --output marker ./...'

# RTK has no rewrite for these allowlisted commands; they must run unchanged, not be denied.
for command in 'npm test' 'bun test' 'yarn lint' 'pnpm test' 'npm test -- --grep "a b"'; do
  assert_empty "$command"
done

assert_denied_json '[]' 'JSON object'
assert_denied_json '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}' 'unexpected Codex hook event'
assert_denied_json '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"command":"ls"}}' 'unexpected Codex hook event'
assert_denied_json '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{}}' 'without a string command'
assert_denied_json '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":7}}' 'without a string command'
assert_denied_json '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":""}}' 'empty or invalid Bash command'
assert_denied_json '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"if then"}}' 'empty or invalid Bash command'
# bash -n drops a NUL byte, so it would check another command than the one given.
assert_denied_json '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls\u0000 -la"}}' 'empty or invalid Bash command'

oversized_output="$(python3 -c 'print("x" * (1024 * 1024 + 1), end="")' | python3 "$TEST_ROOT/hook.py")"
python3 -c '
import json, sys
data = json.load(sys.stdin)["hookSpecificOutput"]
assert data["permissionDecision"] == "deny"
assert "oversized" in data["permissionDecisionReason"]
' <<< "$oversized_output"

# long_payload PREFIX SUFFIX: a Bash call whose command is PREFIX, 140,000 a's and SUFFIX, longer
# than the 128 KiB one argument may hold. bash -n reads it on stdin, so it is still checked; RTK
# takes it only as an argument, so an allowlisted one runs unchanged, not denied.
long_payload() {
  python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":sys.argv[1] + "a" * 140000 + sys.argv[2]}}))' "$1" "$2"
}
assert_long_unchanged() {
  local output
  output="$(long_payload "$1" "$2" | RTK_BIN="$fake_rtk" python3 "$TEST_ROOT/hook.py")"
  [[ -z "$output" ]] || {
    echo "a command longer than 128 KiB did not run unchanged: $1...: $output" >&2
    exit 1
  }
}
assert_long_unchanged 'ls ' ''
assert_long_unchanged $'cat > notes.txt <<\'EOF\'\n' $'\nEOF'
assert_denied_json "$(long_payload 'echo ' ' )')" 'empty or invalid Bash command'

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

# A failing RTK proves these commands stay unchanged without RTK being consulted. head and tail are
# not rewritten, since RTK printed a single line for `head -2`.
for command in 'head -2 notes.txt' 'head -n 3 notes.txt' 'tail -n 5 app.log' 'tail -f app.log'; do
  assert_empty "$command" "$failing_rtk"
done
# Nor is git log, since RTK cut a log to 10 commits without saying so.
for command in 'git log' 'git log --oneline -30' 'git log main~20..main'; do
  assert_empty "$command" "$failing_rtk"
done
# RTK misread other spacing (`head  -n 3` read the whole file), so only single-spaced commands are
# rewritten; 'ls -la' above still is.
for command in 'ls  -la' 'git  status' ' ls -la' 'ls -la ' $'ls\t-la' '  npm test -- --grep "a b"  '; do
  assert_empty "$command" "$failing_rtk"
done

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

fixed_rtk="$TEST_ROOT/fixed-rtk"
cat > "$fixed_rtk" <<'EOF'
#!/usr/bin/env bash
printf '%s' "$FAKE_STDOUT"
printf '%s' "$FAKE_STDERR" >&2
exit "$FAKE_STATUS"
EOF
chmod 0755 "$fixed_rtk"

# assert_fixed_rtk EXPECTED COMMAND STDOUT STDERR STATUS: only exit 1 with empty stdout and a
# last stderr line that is the exact report for COMMAND, after nothing but "[rtk] " lines,
# means "no rewrite"; any other non-zero result must be denied.
assert_fixed_rtk() {
  local expected="$1"
  local output
  output="$(payload "$2" \
    | FAKE_STDOUT="$3" FAKE_STDERR="$4" FAKE_STATUS="$5" RTK_BIN="$fixed_rtk" python3 "$TEST_ROOT/hook.py")"
  if [[ "$expected" == passthrough ]]; then
    [[ -z "$output" ]] || {
      echo "RTK no-rewrite report was not passed through for $2: $output" >&2
      exit 1
    }
    return
  fi
  python3 -c '
import json, sys
data = json.load(sys.stdin)["hookSpecificOutput"]
assert data["permissionDecision"] == "deny"
assert sys.argv[1] in data["permissionDecisionReason"]
' "$expected" <<< "$output"
}
assert_fixed_rtk passthrough 'go test ./...' '' $'No rewrite for: go test ./...\n' 1
assert_fixed_rtk 'exit code 1' 'go test ./...' '' $'error: failed to load RTK config\n' 1
assert_fixed_rtk 'exit code 1' 'go test ./...' $'rtk go test ./...\n' $'No rewrite for: go test ./...\n' 1
assert_fixed_rtk 'exit code 1' 'go test ./...' '' $'No rewrite for: npm test\n' 1
assert_fixed_rtk 'exit code 2' 'go test ./...' '' $'No rewrite for: go test ./...\n' 2

# RTK may print its own "[rtk] " diagnostics before the report, such as this real warning.
rtk_warning='[rtk] /!\ No hook installed — run `rtk init -g` for automatic token savings'
assert_fixed_rtk passthrough 'npm test' '' "$rtk_warning"$'\nNo rewrite for: npm test\n' 1
assert_fixed_rtk 'exit code 1' 'npm test' '' $'warning: low disk space\nNo rewrite for: npm test\n' 1
assert_fixed_rtk 'exit code 1' 'npm test' '' $'No rewrite for: npm test\n'"$rtk_warning"$'\n' 1
assert_fixed_rtk 'exit code 1' 'npm test' '' "$rtk_warning"$'\nNo rewrite for: go test ./...\n' 1
assert_fixed_rtk 'exit code 1' 'npm test' '' "$rtk_warning"$'\n' 1

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
