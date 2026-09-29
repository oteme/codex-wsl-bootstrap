#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

global="$ROOT/config/AGENTS.global.md"
global_before="$(sha256sum < "$global")"
fragments="$TEST_ROOT/guidance fragments"
mkdir -p "$fragments"
# Fixture fragments stand in for the real per-agent files; one ends without a blank line and
# one with extra blank lines, so the blank line between sections must come from the global file.
for agent in cursor antigravity; do
  printf '## gstack\n\n%s gstack fixture.\n\n### Routing\n- `%s-review`\n' "$agent" "$agent" \
    > "$fragments/$agent-gstack.md"
  printf '## Ralph\n\n%s Ralph fixture.\n\n\n' "$agent" > "$fragments/$agent-ralph.md"
done

compose() {
  python3 "$ROOT/scripts/compose-guidance.py" --agent "$1" --global-guidance "$2" \
    --guidance-dir "$3" --output "$4"
}

for agent in cursor antigravity; do
  output="$TEST_ROOT/composed output/$agent guidance.md"
  compose "$agent" "$global" "$fragments" "$output"
  first="$(sha256sum < "$output")"
  compose "$agent" "$global" "$fragments" "$output"
  [[ "$(sha256sum < "$output")" == "$first" ]]
  [[ "$(stat -c %a "$output")" == 644 ]]
  python3 - "$global" "$output" "$fragments/$agent-gstack.md" "$fragments/$agent-ralph.md" <<'PY'
import re
import sys
from pathlib import Path

global_text, output, gstack, ralph = (Path(path).read_bytes().decode("utf-8") for path in sys.argv[1:])


def parts(text):
    # Split before every "## " heading and before the END marker.
    return re.split(r"(?m)^(?=## |<!-- END codex-workstation-bootstrap -->$)", text)


titles = ["Workstation setup updates", "gstack", "Ralph", "Open implementation choices", "Go backend",
          "Fail-close and clean-break"]
source, composed = parts(global_text), parts(output)
assert [part.split("\n", 1)[0] for part in source[1:-1]] == ["## " + title for title in titles], source
assert len(composed) == len(source), composed
assert composed[0] == source[0] and source[0].startswith("<!-- BEGIN codex-workstation-bootstrap -->\n")
assert composed[-1] == source[-1] == "<!-- END codex-workstation-bootstrap -->\n"
fragments = {"gstack": gstack, "Ralph": ralph}
for title, before, after in zip(titles, source[1:-1], composed[1:-1]):
    if title in fragments:
        assert after.rstrip("\n") == fragments[title].rstrip("\n"), (title, after)
        assert after[len(after.rstrip("\n")):] == before[len(before.rstrip("\n")):], (title, after)
        assert before not in output, title
    else:
        assert after == before, title
PY
done
[[ "$(sha256sum < "$global")" == "$global_before" ]]
printf 'PASS: composed guidance keeps every shared byte and swaps only gstack and Ralph.\n'

variants="$TEST_ROOT/variants"
python3 - "$global" "$variants" <<'PY'
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
out = Path(sys.argv[2])
out.mkdir()
opening, go, fail = (text.index(f"## {title}\n") for title in
                     ["Open implementation choices", "Go backend", "Fail-close and clean-break"])
variants = {
    "missing": text[:go] + text[fail:],
    "duplicate": text.replace("## Ralph\n", "## gstack\n\nextra\n\n## Ralph\n", 1),
    "unknown": text.replace("## Go backend\n", "## Extra\n\nextra\n\n## Go backend\n", 1),
    "order": text[:opening] + text[go:fail] + text[opening:go] + text[fail:],
    "no-begin": text.split("\n", 1)[1],
    "no-end": text.replace("<!-- END codex-workstation-bootstrap -->\n", ""),
    "inner-marker": text.replace("## Go backend\n", "<!-- END codex-workstation-bootstrap -->\n## Go backend\n", 1),
}
for name, value in variants.items():
    assert value != text, name
    (out / f"{name}.md").write_text(value, encoding="utf-8")
PY

failure_output="$TEST_ROOT/failure output.md"
expect_failure() {
  local expected="$1"
  shift
  local message status
  printf 'previous output\n' > "$failure_output"
  set +e
  message="$(python3 "$ROOT/scripts/compose-guidance.py" "$@" --output "$failure_output" 2>&1)"
  status=$?
  set -e
  [[ "$status" -eq 1 ]] || {
    echo "expected exit 1 for '$expected', got $status: $message" >&2
    exit 1
  }
  grep -Fq -- "$expected" <<< "$message" || {
    echo "expected '$expected', got: $message" >&2
    exit 1
  }
  [[ "$(cat "$failure_output")" == 'previous output' ]]
}

for case in \
  'missing|missing section "## Go backend"' \
  'duplicate|duplicate section "## gstack"' \
  'unknown|unknown section "## Extra"' \
  'order|sections are out of order' \
  'no-begin|must start with <!-- BEGIN codex-workstation-bootstrap -->' \
  'no-end|and end with <!-- END codex-workstation-bootstrap -->' \
  'inner-marker|unexpected bootstrap marker inside'; do
  expect_failure "${case#*|}" --agent cursor --global-guidance "$variants/${case%%|*}.md" \
    --guidance-dir "$fragments"
done
expect_failure 'global guidance is missing' --agent cursor \
  --global-guidance "$TEST_ROOT/no-global.md" --guidance-dir "$fragments"
set +e
python3 "$ROOT/scripts/compose-guidance.py" --agent cursor --global-guidance "$variants/missing.md" \
  --guidance-dir "$fragments" --output "$TEST_ROOT/never created/guidance.md" 2>/dev/null
missing_status=$?
set -e
[[ "$missing_status" -eq 1 && ! -e "$TEST_ROOT/never created" ]]

bad="$TEST_ROOT/bad fragments"
mkdir -p "$bad"
cp "$fragments/cursor-ralph.md" "$bad/"
printf 'Cursor gstack without a heading.\n' > "$bad/cursor-gstack.md"
expect_failure 'guidance fragment must start with "## gstack"' --agent cursor \
  --global-guidance "$global" --guidance-dir "$bad"
printf '## Ralph\n\nWrong heading.\n' > "$bad/cursor-gstack.md"
expect_failure 'guidance fragment must start with "## gstack"' --agent cursor \
  --global-guidance "$global" --guidance-dir "$bad"
printf '## gstack\n\nText.\n\n## Extra\n' > "$bad/cursor-gstack.md"
expect_failure 'guidance fragment must hold only the "## gstack" section' --agent cursor \
  --global-guidance "$global" --guidance-dir "$bad"
printf '## gstack\n\n<!-- END codex-workstation-bootstrap -->\n' > "$bad/cursor-gstack.md"
expect_failure 'guidance fragment must hold only the "## gstack" section' --agent cursor \
  --global-guidance "$global" --guidance-dir "$bad"
rm "$bad/cursor-gstack.md"
expect_failure 'guidance fragment is missing' --agent cursor \
  --global-guidance "$global" --guidance-dir "$bad"
# Each agent reads only its own fragments.
cp "$fragments/cursor-gstack.md" "$bad/"
expect_failure "guidance fragment is missing: $bad/antigravity-gstack.md" --agent antigravity \
  --global-guidance "$global" --guidance-dir "$bad"

printf 'target\n' > "$TEST_ROOT/link target.md"
ln -s "$TEST_ROOT/link target.md" "$TEST_ROOT/linked output.md"
set +e
link_message="$(compose cursor "$global" "$fragments" "$TEST_ROOT/linked output.md" 2>&1)"
link_status=$?
set -e
[[ "$link_status" -eq 1 && "$(cat "$TEST_ROOT/link target.md")" == target ]]
grep -Fq 'refusing to replace symlinked output' <<< "$link_message"
cp "$global" "$TEST_ROOT/global copy.md"
set +e
input_message="$(compose cursor "$TEST_ROOT/global copy.md" "$fragments" "$TEST_ROOT/global copy.md" 2>&1)"
input_status=$?
set -e
[[ "$input_status" -eq 1 ]]
cmp -s "$global" "$TEST_ROOT/global copy.md"
grep -Fq 'refusing to overwrite an input file' <<< "$input_message"
[[ "$(sha256sum < "$global")" == "$global_before" ]]
printf 'PASS: compose-guidance fails closed on malformed guidance, fragments and outputs.\n'
