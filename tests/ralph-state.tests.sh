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

edit_json() {
  local path="$1"
  local code="$2"
  python3 - "$path" "$code" <<'PY'
import json, sys
path, code = sys.argv[1], sys.argv[2]
data = json.load(open(path, encoding="utf-8"))
exec(code)
json.dump(data, open(path, "w", encoding="utf-8"))
PY
}

json_get() {
  local path="$1"
  local expr="$2"
  python3 - "$path" "$expr" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
print(eval(sys.argv[2]))
PY
}

json_equal() {
  python3 - "$1" "$2" <<'PY'
import json, sys
left = json.load(open(sys.argv[1], encoding="utf-8"))
right = json.load(open(sys.argv[2], encoding="utf-8"))
sys.exit(0 if left == right else 1)
PY
}

before="$TEST_ROOT/before.json"
after="$TEST_ROOT/after.json"

# One story completed: reported as id<TAB>title, prd.json unchanged otherwise.
write_prd "$before" false false
write_prd "$after" true false
transition="$(python3 "$STATE_TOOL" apply-transition "$before" "$after")"
[[ "$transition" == "US-001	First" ]]
[[ "$(json_get "$after" 'data["userStories"][0]["passes"]')" == "True" ]]
[[ "$(json_get "$after" 'data["userStories"][1]["passes"]')" == "False" ]]

# Metadata edits are discarded with a warning; the story completion is still applied.
write_prd "$after" true false
edit_json "$after" 'data["description"] = "tampered"'
set +e
metadata_stderr="$(python3 "$STATE_TOOL" apply-transition "$before" "$after" 2>&1 >/dev/null)"
metadata_status=$?
set -e
[[ "$metadata_status" -eq 0 ]]
grep -Fq 'ignored edits to prd.json metadata' <<< "$metadata_stderr"
[[ "$(json_get "$after" 'data["description"]')" == "State tests" ]]
[[ "$(json_get "$after" 'data["userStories"][0]["passes"]')" == "True" ]]

# Specification edits are discarded; passes and notes are kept.
write_prd "$after" true false
edit_json "$after" 'data["userStories"][0]["acceptanceCriteria"] = ["weakened"]; data["userStories"][0]["notes"] = "done"'
set +e
spec_stderr="$(python3 "$STATE_TOOL" apply-transition "$before" "$after" 2>&1 >/dev/null)"
spec_status=$?
set -e
[[ "$spec_status" -eq 0 ]]
grep -Fq 'ignored edits to the specification of US-001' <<< "$spec_stderr"
[[ "$(json_get "$after" 'data["userStories"][0]["acceptanceCriteria"]')" == "['A']" ]]
[[ "$(json_get "$after" 'data["userStories"][0]["notes"]')" == "done" ]]
[[ "$(json_get "$after" 'data["userStories"][0]["passes"]')" == "True" ]]

# Two stories completed in one iteration are both reported.
write_prd "$after" true true
two="$(python3 "$STATE_TOOL" apply-transition "$before" "$after")"
[[ "$(head -1 <<< "$two")" == "US-001	First" ]]
[[ "$(tail -1 <<< "$two")" == "US-002	Second" ]]
[[ "$(wc -l <<< "$two")" -eq 2 ]]

# Added or removed stories, duplicate ids, and a passing story set back to false are discarded.
write_prd "$after" true false
edit_json "$after" 'data["userStories"].append({"id":"US-003","title":"Extra","acceptanceCriteria":[],"passes":True,"notes":""})'
set +e
added_stderr="$(python3 "$STATE_TOOL" apply-transition "$before" "$after" 2>&1 >/dev/null)"
added_status=$?
set -e
[[ "$added_status" -eq 0 ]]
grep -Fq 'ignored added or removed stories' <<< "$added_stderr"
[[ "$(json_get "$after" 'len(data["userStories"])')" == "2" ]]

write_prd "$before" true false
write_prd "$after" false true
set +e
back_stderr="$(python3 "$STATE_TOOL" apply-transition "$before" "$after" 2>&1 >/dev/null)"
back_status=$?
set -e
[[ "$back_status" -eq 0 ]]
grep -Fq 'ignored US-001 being set back to passes: false' <<< "$back_stderr"
[[ "$(json_get "$after" 'data["userStories"][0]["passes"]')" == "True" ]]
[[ "$(json_get "$after" 'data["userStories"][1]["passes"]')" == "True" ]]

write_prd "$before" false false
write_prd "$after" true false
edit_json "$after" 'data["userStories"][1]["id"] = "US-001"'
set +e
dup_stderr="$(python3 "$STATE_TOOL" apply-transition "$before" "$after" 2>&1 >/dev/null)"
dup_status=$?
set -e
[[ "$dup_status" -eq 3 ]]
grep -Fq 'story ids must be unique' <<< "$dup_stderr"
grep -Fq 'restored it' <<< "$dup_stderr"
json_equal "$before" "$after"

# An unreadable prd.json is restored from the trusted copy and counts as no transition.
printf '{broken json\n' > "$after"
set +e
broken_stderr="$(python3 "$STATE_TOOL" apply-transition "$before" "$after" 2>&1 >/dev/null)"
broken_status=$?
set -e
[[ "$broken_status" -eq 3 ]]
grep -Fq 'restored it' <<< "$broken_stderr"
json_equal "$before" "$after"
printf '[]\n' > "$after"
set +e
python3 "$STATE_TOOL" apply-transition "$before" "$after" >/dev/null 2>&1
array_status=$?
set -e
[[ "$array_status" -eq 3 ]]
json_equal "$before" "$after"

# The trusted copy itself must be valid.
printf '{"userStories":"wrong"}\n' > "$after"
expect_failure 'userStories array' python3 "$STATE_TOOL" all-passed "$after"
write_prd "$after" true false
edit_json "$after" 'data["userStories"][0]["id"] = ""'
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
[[ "$(json_get "$after" 'data["userStories"][0]["passes"]')" == "False" ]]
grep -Fq 'US-001 - POLICY REVIEW REJECTED' "$progress"

# Several stories can be rejected or reset together.
write_prd "$after" true true
python3 "$STATE_TOOL" reject "$after" "$rejected" "$progress" US-001 US-002
[[ "$(json_get "$after" 'data["userStories"][0]["passes"]')" == "False" ]]
[[ "$(json_get "$after" 'data["userStories"][1]["passes"]')" == "False" ]]
grep -Fq 'US-001, US-002 - POLICY REVIEW REJECTED' "$progress"

write_prd "$after" true false
python3 "$STATE_TOOL" reset "$after" "$progress" 'review crashed' US-001
[[ "$(json_get "$after" 'data["userStories"][0]["passes"]')" == "False" ]]
grep -Fq 'US-001 - POLICY GATE FAILED' "$progress"
expect_failure 'story not found' python3 "$STATE_TOOL" reset "$after" "$progress" missing US-999

# Control characters in reviewer text never reach progress.txt.
control_review="$TEST_ROOT/control-review.json"
python3 - "$control_review" <<'PY'
import json, sys
json.dump({
    "approved": False,
    "findings": [{"category": "test", "message": "bad" + chr(1) + "message", "evidence": "test.py:1"}],
}, open(sys.argv[1], "w", encoding="utf-8"))
PY
write_prd "$after" true false
python3 "$STATE_TOOL" reject "$after" "$control_review" "$progress" US-001
python3 - "$progress" <<'PY'
import sys
assert chr(1) not in open(sys.argv[1], encoding="utf-8").read()
PY

write_prd "$after" true true
[[ "$(python3 "$STATE_TOOL" all-passed "$after")" == "true" ]]
write_prd "$after" true false
[[ "$(python3 "$STATE_TOOL" all-passed "$after")" == "false" ]]
printf '{"userStories":[]}\n' > "$after"
expect_failure 'no user stories' python3 "$STATE_TOOL" all-passed "$after"

# A worker that changes nothing, or only notes, yields the distinct continue status 3 and keeps
# the notes.
write_prd "$before" false false
write_prd "$after" false false
set +e
zero_output="$(python3 "$STATE_TOOL" apply-transition "$before" "$after" 2>&1)"
zero_status=$?
set -e
[[ "$zero_status" -eq 3 ]]
grep -Fq 'no story changed false->true' <<< "$zero_output"
edit_json "$after" 'data["userStories"][0]["notes"] = "partial work recorded"'
set +e
python3 "$STATE_TOOL" apply-transition "$before" "$after" >/dev/null 2>&1
notes_status=$?
set -e
[[ "$notes_status" -eq 3 ]]
[[ "$(json_get "$after" 'data["userStories"][0]["notes"]')" == "partial work recorded" ]]

# next-story picks the pending story with the lowest priority, then file order.
write_prd "$after" false false
[[ "$(python3 "$STATE_TOOL" next-story "$after" | head -1)" == "US-001" ]]
[[ "$(python3 "$STATE_TOOL" pending-count "$after")" == "2" ]]
edit_json "$after" 'data["userStories"][0]["priority"] = 2; data["userStories"][1]["priority"] = 1'
next_output="$(python3 "$STATE_TOOL" next-story "$after")"
[[ "$(head -1 <<< "$next_output")" == "US-002" ]]
[[ "$(tail -1 <<< "$next_output")" == "Second" ]]
write_prd "$after" true false
[[ "$(python3 "$STATE_TOOL" next-story "$after" | head -1)" == "US-002" ]]
[[ "$(python3 "$STATE_TOOL" pending-count "$after")" == "1" ]]
write_prd "$after" true true
[[ -z "$(python3 "$STATE_TOOL" next-story "$after")" ]]
[[ "$(python3 "$STATE_TOOL" pending-count "$after")" == "0" ]]

printf 'PASS: Ralph state sanitizing, multi-story transitions, and policy-result trust boundaries.\n'
