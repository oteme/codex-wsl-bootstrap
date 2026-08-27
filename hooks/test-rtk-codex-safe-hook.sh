#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
HOOK="${HOOK:-$SCRIPT_DIR/rtk-codex-safe-hook.py}"
[[ -z "${RTK_BIN:-}" ]] || export RTK_BIN

payload() {
  python3 -c 'import json,sys; print(json.dumps({"session_id":"test","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":sys.argv[1]},"cwd":"/tmp","permission_mode":"default"}))' "$1"
}

simple_output="$(payload 'go test ./...' | python3 "$HOOK")"
python3 -c '
import json, sys
data = json.load(sys.stdin)["hookSpecificOutput"]
assert data["hookEventName"] == "PreToolUse"
assert data["permissionDecision"] == "allow"
assert data["updatedInput"]["command"] == "rtk go test ./..."
' <<< "$simple_output"

for command in \
  'case x in x) ;; esac' \
  '( tail -25 /tmp/example.log )' \
  $'go test ./...\nprintf done' \
  'go test ./... | tail -20' \
  'value=$(go test ./...)' \
  'printf "a;b"' \
  'name="go test ./..."' \
  'find ./marker -delete' \
  'git diff --output=marker' \
  'npx eslint --fix example.js' \
  'rm -rf /tmp/not-run'; do
  output="$(payload "$command" | python3 "$HOOK")"
  [[ -z "$output" ]] || {
    echo "unexpected rewrite for: $command" >&2
    exit 1
  }
done

invalid_output="$(printf '{' | python3 "$HOOK")"
python3 -c '
import json, sys
data = json.load(sys.stdin)["hookSpecificOutput"]
assert data["permissionDecision"] == "deny"
assert "invalid JSON" in data["permissionDecisionReason"]
' <<< "$invalid_output"

printf 'PASS: Codex RTK Safe Hook regression tests.\n'
