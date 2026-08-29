#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_TOOL="$ROOT/skills/ralph-run/scripts/ralph-state.py"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

write_prd() {
  local path="$1"
  local first_passes="$2"
  local second_passes="$3"
  cat > "$path" <<JSON
{
  "project": "Test",
  "branchName": "ralph/test",
  "description": "State tests",
  "userStories": [
    {"id":"US-001","title":"First","acceptanceCriteria":["A"],"passes":$first_passes,"notes":""},
    {"id":"US-002","title":"Second","acceptanceCriteria":["B"],"passes":$second_passes,"notes":""}
  ]
}
JSON
}

expect_failure() {
  local expected="$1"
  shift
  local output=""
  local status=0
  output="$("$@" 2>&1)" || status=$?
  [[ "$status" -ne 0 ]]
  grep -Fq "$expected" <<< "$output"
}

before="$TEST_ROOT/before.json"
after="$TEST_ROOT/after.json"
write_prd "$before" false false
write_prd "$after" true false
transition="$(python3 "$STATE_TOOL" validate-transition "$before" "$after")"
grep -Fq 'US-001' <<< "$transition"
grep -Fq 'First' <<< "$transition"

python3 - "$after" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["description"] = "tampered"
json.dump(data, open(path, "w", encoding="utf-8"))
PY
expect_failure 'changed PRD metadata' python3 "$STATE_TOOL" validate-transition "$before" "$after"

write_prd "$after" true false
python3 - "$after" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["userStories"][0]["acceptanceCriteria"] = ["weakened"]
json.dump(data, open(path, "w", encoding="utf-8"))
PY
expect_failure 'changed a story specification' python3 "$STATE_TOOL" validate-transition "$before" "$after"

write_prd "$after" true true
expect_failure 'observed 2' python3 "$STATE_TOOL" validate-transition "$before" "$after"

write_prd "$after" true false
python3 - "$after" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["userStories"][1]["id"] = "US-001"
json.dump(data, open(path, "w", encoding="utf-8"))
PY
expect_failure 'story ids must be unique' python3 "$STATE_TOOL" validate-transition "$before" "$after"

printf '{broken json\n' > "$after"
expect_failure 'Expecting property name' python3 "$STATE_TOOL" validate-transition "$before" "$after"
printf '[]\n' > "$after"
expect_failure 'expected JSON object' python3 "$STATE_TOOL" validate-transition "$before" "$after"
printf '{"userStories":"wrong"}\n' > "$after"
expect_failure 'userStories array' python3 "$STATE_TOOL" all-passed "$after"

write_prd "$after" true false
python3 - "$after" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["userStories"][0]["id"] = ""
json.dump(data, open(path, "w", encoding="utf-8"))
PY
expect_failure 'non-empty string id' python3 "$STATE_TOOL" all-passed "$after"

approved="$TEST_ROOT/approved.json"
rejected="$TEST_ROOT/rejected.json"
printf '{"approved":true,"findings":[]}\n' > "$approved"
printf '%s\n' \
  '{"approved":false,"findings":[{"category":"fallback","message":"bad fallback","evidence":"app.py:1"}]}' \
  > "$rejected"
[[ "$(python3 "$STATE_TOOL" review-result "$approved")" == "approved" ]]
[[ "$(python3 "$STATE_TOOL" review-result "$rejected")" == "rejected" ]]

printf '%s\n' \
  '{"approved":true,"findings":[{"category":"fallback","message":"x","evidence":"y"}]}' \
  > "$approved"
expect_failure 'approved review must have no findings' python3 "$STATE_TOOL" review-result "$approved"
printf '%s\n' \
  '{"approved":false,"findings":[{"category":"unknown","message":"x","evidence":"y"}]}' \
  > "$approved"
expect_failure 'invalid policy review finding values' python3 "$STATE_TOOL" review-result "$approved"
printf '%s\n' \
  '{"approved":false,"findings":[{"category":"acceptance","message":"general story issue","evidence":"app.py:1"}]}' \
  > "$approved"
expect_failure 'invalid policy review finding values' python3 "$STATE_TOOL" review-result "$approved"
if grep -Fq '"acceptance"' "$ROOT/skills/ralph-run/assets/policy-review.schema.json"; then
  echo 'policy review schema must not allow general acceptance findings' >&2
  exit 1
fi

python3 - "$approved" <<'PY'
import json, sys
json.dump({
    "approved": False,
    "findings": [{"category": "test", "message": "x" * 501, "evidence": "test.py:1"}],
}, open(sys.argv[1], "w", encoding="utf-8"))
PY
expect_failure 'invalid policy review finding values' python3 "$STATE_TOOL" review-result "$approved"

write_prd "$after" true false
progress="$TEST_ROOT/progress.txt"
printf '# Progress\n' > "$progress"
python3 "$STATE_TOOL" reject "$after" "$rejected" "$progress" US-001
grep -Fq '"passes": false' "$after"
grep -Fq 'POLICY REVIEW REJECTED' "$progress"

write_prd "$after" true false
python3 "$STATE_TOOL" reset "$after" "$progress" US-001 'review crashed'
grep -Fq '"passes": false' "$after"
grep -Fq 'POLICY GATE FAILED' "$progress"
expect_failure 'story not found' python3 "$STATE_TOOL" reset "$after" "$progress" US-999 missing

control_review="$TEST_ROOT/control-review.json"
python3 - "$control_review" <<'PY'
import json, sys
json.dump({
    "approved": False,
    "findings": [{"category": "test", "message": "bad\u0001message", "evidence": "test.py:1"}],
}, open(sys.argv[1], "w", encoding="utf-8"))
PY
write_prd "$after" true false
python3 "$STATE_TOOL" reject "$after" "$control_review" "$progress" US-001
python3 - "$progress" <<'PY'
import sys
assert "\x01" not in open(sys.argv[1], encoding="utf-8").read()
PY

write_prd "$after" true true
[[ "$(python3 "$STATE_TOOL" all-passed "$after")" == "true" ]]
write_prd "$after" true false
[[ "$(python3 "$STATE_TOOL" all-passed "$after")" == "false" ]]
printf '{"userStories":[]}\n' > "$after"
expect_failure 'no user stories' python3 "$STATE_TOOL" all-passed "$after"

printf 'PASS: Ralph state transition and policy-result trust boundaries.\n'
