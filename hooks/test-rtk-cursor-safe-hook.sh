#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
HOOK="${HOOK:-$SCRIPT_DIR/rtk-cursor-safe-hook.py}"
[[ -z "${RTK_BIN:-}" ]] || export RTK_BIN

payload() {
  python3 -c 'import json,sys; print(json.dumps({"conversation_id":"test","generation_id":"test","hook_event_name":"preToolUse","tool_name":"Shell","tool_input":{"command":sys.argv[1],"working_directory":"/tmp"}}))' "$1"
}

simple_output="$(payload 'go test ./...' | python3 "$HOOK")"
python3 -c '
import json, sys
data = json.load(sys.stdin)
assert data == {"updated_input": {"command": "rtk go test ./...", "working_directory": "/tmp"}}, data
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
  'go test --output=marker ./...' \
  'go test --output marker ./...' \
  'git log' \
  'git log --oneline -30' \
  'git log main~20..main' \
  'git diff --cached HEAD' \
  'git show HEAD' \
  'head -2 notes.txt' \
  'head -n 3 notes.txt' \
  'head  -n 3 notes.txt' \
  'tail -n 5 app.log' \
  'npx eslint --fix example.js' \
  'rm -rf /tmp/not-run'; do
  output="$(payload "$command" | python3 "$HOOK")"
  [[ "$output" == '{}' ]] || {
    echo "unexpected rewrite for: $command" >&2
    exit 1
  }
done

# RTK has no rewrite for npm test, so the allowlisted command must run unchanged, not be denied.
no_rewrite_output="$(payload 'npm test' | python3 "$HOOK")"
[[ "$no_rewrite_output" == '{}' ]] || {
  echo "npm test was not passed through unchanged: $no_rewrite_output" >&2
  exit 1
}

invalid_output="$(printf '{' | python3 "$HOOK")"
python3 -c '
import json, sys
data = json.load(sys.stdin)
assert data["permission"] == "deny"
assert "invalid JSON" in data["user_message"]
' <<< "$invalid_output"

printf 'PASS: Cursor RTK Safe Hook regression tests.\n'
