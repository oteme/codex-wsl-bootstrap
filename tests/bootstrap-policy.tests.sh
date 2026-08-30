#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

legacy_home="$TEST_ROOT/legacy-home"
mkdir -p "$legacy_home/.codex" "$legacy_home/gstack"
legacy_bin="$TEST_ROOT/legacy-bin"
mkdir -p "$legacy_bin"
printf '%s\n' '#!/usr/bin/env bash' 'printf "codex-cli 0.0.0-test\\n"' > "$legacy_bin/codex"
chmod 0755 "$legacy_bin/codex"
git -C "$legacy_home/gstack" init -q
git -C "$legacy_home/gstack" remote add origin https://github.com/garrytan/gstack.git
printf 'generated name patch\n' > "$legacy_home/gstack/SKILL.md"
git -C "$legacy_home/gstack" add SKILL.md
git -C "$legacy_home/gstack" \
  -c user.name='Bootstrap Test' -c user.email='bootstrap@example.invalid' \
  commit -qm 'fixture'
printf 'locally patched name\n' > "$legacy_home/gstack/SKILL.md"

gstack_dry_run_output="$(
  HOME="$legacy_home" CODEX_HOME="$legacy_home/.codex" PATH="$legacy_bin:$PATH" \
    bash "$ROOT/install.sh" --dry-run
)"
grep -Fq "$legacy_home/.local/share/codex-workstation-bootstrap/gstack" \
  <<< "$gstack_dry_run_output"
grep -Fq "$legacy_home/.local/share/codex-workstation-bootstrap/ralph" \
  <<< "$gstack_dry_run_output"
[[ "$(git -C "$legacy_home/gstack" status --short)" == ' M SKILL.md' ]]

custom_state="$TEST_ROOT/custom-state"
custom_gstack="$TEST_ROOT/custom-gstack"
custom_ralph="$TEST_ROOT/custom-ralph"
override_dry_run_output="$(
  HOME="$legacy_home" CODEX_HOME="$legacy_home/.codex" PATH="$legacy_bin:$PATH" \
    BOOTSTRAP_STATE_DIR="$custom_state" GSTACK_INSTALL_DIR="$custom_gstack" \
    RALPH_SOURCE_DIR="$custom_ralph" bash "$ROOT/install.sh" --dry-run
)"
grep -Fq "$custom_gstack" <<< "$override_dry_run_output"
grep -Fq "$custom_ralph" <<< "$override_dry_run_output"
if grep -Fq "$custom_state/gstack" <<< "$override_dry_run_output" || \
   grep -Fq "$custom_state/ralph" <<< "$override_dry_run_output"; then
  echo 'explicit source checkout override was ignored' >&2
  exit 1
fi

ralph_dir="$TEST_ROOT/project/scripts/ralph"
bash "$ROOT/skills/ralph-bootstrap/scripts/bootstrap-ralph.sh" "$ralph_dir" >/dev/null
grep -Fq 'Do not run `git commit`' "$ralph_dir/CLAUDE.md"
grep -Fq 'POLICY REVIEW REJECTED' "$ralph_dir/CLAUDE.md"
grep -Fq 'untrusted diagnostic data' "$ralph_dir/CLAUDE.md"
grep -Fq 'Keep `passes: false`' "$ralph_dir/CLAUDE.md"
grep -Fq 'installed `go-backend` skill' "$ralph_dir/CLAUDE.md"

source_skill="$TEST_ROOT/source-skill"
overlay="$TEST_ROOT/overlay.md"
mkdir -p "$source_skill"
printf '%s\n' '---' 'name: test-skill' 'description: Test skill.' '---' '# Base' > "$source_skill/SKILL.md"
printf '\n## Policy Overlay\nfail closed\n' > "$overlay"

mkdir -p "$TEST_ROOT/codex/skills"
bash "$ROOT/scripts/install-skill.sh" \
  "$source_skill" "$TEST_ROOT/codex/skills/test-skill" .managed "$overlay"
grep -Fq '## Policy Overlay' "$TEST_ROOT/codex/skills/test-skill/SKILL.md"
grep -Fq 'fail closed' "$TEST_ROOT/codex/skills/test-skill/SKILL.md"

set +e
missing_output="$(
  bash "$ROOT/scripts/install-skill.sh" \
    "$source_skill" "$TEST_ROOT/missing-codex/skills/missing-skill" \
    .managed "$TEST_ROOT/does-not-exist.md" 2>&1
)"
missing_status=$?
set -e
[[ "$missing_status" -eq 1 ]]
grep -Fq 'skill overlay not found' <<< "$missing_output"
[[ ! -e "$TEST_ROOT/missing-codex/skills/missing-skill" ]]

mkdir -p "$TEST_ROOT/plain-codex/skills"
bash "$ROOT/scripts/install-skill.sh" \
  "$source_skill" "$TEST_ROOT/plain-codex/skills/test-skill" .managed
grep -Fq '# Base' "$TEST_ROOT/plain-codex/skills/test-skill/SKILL.md"
if grep -Fq 'Policy Overlay' "$TEST_ROOT/plain-codex/skills/test-skill/SKILL.md"; then
  echo 'unexpected overlay in plain skill install' >&2
  exit 1
fi

doctor_home="$TEST_ROOT/doctor-codex"
for skill in gstack-plan-eng-review gstack-review prd ralph ralph-bootstrap ralph-run; do
  mkdir -p "$doctor_home/skills/$skill"
  printf '%s\n' '---' "name: $skill" 'description: Test fixture.' '---' > "$doctor_home/skills/$skill/SKILL.md"
done
bash "$ROOT/scripts/install-skill.sh" \
  "$ROOT/skills/go-backend" "$doctor_home/skills/go-backend" .managed
printf '\n## Fail-close and clean-break requirements\n' >> "$doctor_home/skills/prd/SKILL.md"
printf '\n## Preserve failure and removal semantics\n' >> "$doctor_home/skills/ralph/SKILL.md"
mkdir -p "$doctor_home/skills/ralph-run/scripts" "$doctor_home/skills/ralph-run/assets"
printf '# fixture\n' > "$doctor_home/skills/ralph-run/scripts/ralph-state.py"
printf '{}\n' > "$doctor_home/skills/ralph-run/assets/policy-review.schema.json"
printf '%s\n' \
  '<!-- BEGIN codex-workstation-bootstrap -->' \
  '## Go backend' \
  '## Fail-close and clean-break' \
  '<!-- END codex-workstation-bootstrap -->' \
  > "$doctor_home/AGENTS.md"

test_bin="$TEST_ROOT/bin"
mkdir -p "$test_bin"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'if [[ "${1:-}" == --version ]]; then printf "rtk 0.46.0\n"; exit 0; fi' \
  '[[ "${1:-}" == hook && "${2:-}" == check ]]' \
  '[[ "${3:-}" == "go test ./..." ]] && printf "rtk go test ./...\n" || printf "No rewrite for: %s\n" "${3:-}"' \
  > "$test_bin/rtk"
chmod 0755 "$test_bin/rtk"
python3 "$ROOT/scripts/install-codex-rtk-hook.py" \
  --codex-dir "$doctor_home" \
  --hook-source "$ROOT/hooks/rtk-codex-safe-hook.py" \
  --test-source "$ROOT/hooks/test-rtk-codex-safe-hook.sh" \
  --rtk-version 0.46.0

PATH="$test_bin:$PATH" RTK_BIN="$test_bin/rtk" CODEX_HOME="$doctor_home" \
  bash "$ROOT/doctor.sh" --skip-login >/dev/null

doctor_app_home="$TEST_ROOT/doctor-app-codex"
cp -a "$doctor_home" "$doctor_app_home"
PATH="$test_bin:$PATH" RTK_BIN="$test_bin/rtk" CODEX_HOME="$doctor_home" \
  CODEX_APP_HOME="$doctor_app_home" bash "$ROOT/doctor.sh" --skip-login >/dev/null

find "$doctor_app_home/skills/go-backend/references" -type f -name 'api-design.md' -delete
set +e
doctor_app_output="$(PATH="$test_bin:$PATH" RTK_BIN="$test_bin/rtk" \
  CODEX_HOME="$doctor_home" CODEX_APP_HOME="$doctor_app_home" \
  bash "$ROOT/doctor.sh" --skip-login 2>&1)"
doctor_app_status=$?
set -e
[[ "$doctor_app_status" -eq 1 ]]
grep -Fq 'App go-backend API rules missing' <<< "$doctor_app_output"

PATH="$test_bin:$PATH" RTK_BIN="$test_bin/rtk" CODEX_HOME="$doctor_home" \
  CODEX_APP_HOME="$doctor_home" bash "$ROOT/doctor.sh" --skip-login >/dev/null

find "$doctor_home/skills/go-backend/references" -type f -name 'api-design.md' -delete
set +e
doctor_go_rules_output="$(PATH="$test_bin:$PATH" RTK_BIN="$test_bin/rtk" \
  CODEX_HOME="$doctor_home" bash "$ROOT/doctor.sh" --skip-login 2>&1)"
doctor_go_rules_status=$?
set -e
[[ "$doctor_go_rules_status" -eq 1 ]]
grep -Fq 'go-backend API rules missing' <<< "$doctor_go_rules_output"
printf '# fixture\n' > "$doctor_home/skills/go-backend/references/api-design.md"

find "$doctor_home/skills/ralph-run/assets" -type f -delete
set +e
doctor_output="$(PATH="$test_bin:$PATH" RTK_BIN="$test_bin/rtk" \
  CODEX_HOME="$doctor_home" bash "$ROOT/doctor.sh" --skip-login 2>&1)"
doctor_status=$?
set -e
[[ "$doctor_status" -eq 1 ]]
grep -Fq 'ralph review schema missing' <<< "$doctor_output"

printf '{}\n' > "$doctor_home/skills/ralph-run/assets/policy-review.schema.json"
sed -i '/Fail-close and clean-break requirements/d' "$doctor_home/skills/prd/SKILL.md"
set +e
doctor_policy_output="$(PATH="$test_bin:$PATH" RTK_BIN="$test_bin/rtk" \
  CODEX_HOME="$doctor_home" bash "$ROOT/doctor.sh" --skip-login 2>&1)"
doctor_policy_status=$?
set -e
[[ "$doctor_policy_status" -eq 1 ]]
grep -Fq 'prd fail-close/clean-break policy is missing' <<< "$doctor_policy_output"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'echo "RTK regression diagnostic marker" >&2' \
  'exit 7' \
  > "$doctor_home/hooks/rtk-safe/test.sh"
chmod 0755 "$doctor_home/hooks/rtk-safe/test.sh"
set +e
doctor_rtk_output="$(PATH="$test_bin:$PATH" RTK_BIN="$test_bin/rtk" \
  CODEX_HOME="$doctor_home" bash "$ROOT/doctor.sh" --skip-login 2>&1)"
doctor_rtk_status=$?
set -e
[[ "$doctor_rtk_status" -eq 1 ]]
grep -Fq 'Codex RTK Safe Hook regression failed' <<< "$doctor_rtk_output"
grep -Fq 'RTK regression diagnostic marker' <<< "$doctor_rtk_output"

printf '%s\n' '#!/usr/bin/env bash' 'exit 9' \
  > "$doctor_home/hooks/rtk-safe/test.sh"
chmod 0755 "$doctor_home/hooks/rtk-safe/test.sh"
set +e
doctor_silent_rtk_output="$(PATH="$test_bin:$PATH" RTK_BIN="$test_bin/rtk" \
  CODEX_HOME="$doctor_home" bash "$ROOT/doctor.sh" --skip-login 2>&1)"
doctor_silent_rtk_status=$?
set -e
[[ "$doctor_silent_rtk_status" -eq 1 ]]
grep -Fq 'Codex RTK Safe Hook regression failed' <<< "$doctor_silent_rtk_output"
[[ "$doctor_silent_rtk_output" != *'RTK regression diagnostic marker'* ]]

printf 'PASS: bootstrap policy, skill overlays, and doctor fail-close checks.\n'
