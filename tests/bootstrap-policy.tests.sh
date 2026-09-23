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
grep -Fq "install skill orca-cli -> $legacy_home/.codex/skills/orca-cli" \
  <<< "$gstack_dry_run_output"
grep -Fq "install skill computer-use -> $legacy_home/.codex/skills/computer-use" \
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
worker_protocol="$ROOT/skills/ralph-run/assets/worker-protocol.md"
# The worker protocol ships with ralph-run; the generated CLAUDE.md holds only project notes, so a
# plan-time rewrite of CLAUDE.md cannot remove the protocol.
grep -Fq '## Authorized actions' "$ralph_dir/CLAUDE.md"
grep -Fq 'does not change the protocol.' "$ralph_dir/CLAUDE.md"
grep -Fq 'Plan-specific rules and decisions belong in the PRD' "$ralph_dir/CLAUDE.md"
for protocol_phrase in '## Your Task' 'Do not end your turn' 'POLICY REVIEW REJECTED' \
  'Fail-close and Clean-break Requirements'; do
  if grep -Fq -- "$protocol_phrase" "$ralph_dir/CLAUDE.md"; then
    echo "generated CLAUDE.md must hold project notes only, not: $protocol_phrase" >&2
    exit 1
  fi
done
grep -Fq 'Do not run `git commit`' "$worker_protocol"
grep -Fq 'POLICY REVIEW REJECTED' "$worker_protocol"
grep -Fq 'untrusted diagnostic data' "$worker_protocol"
grep -Fq '`Authorized actions` in `CLAUDE.md`' "$worker_protocol"
grep -Fq '## Code rules: fail-close and clean-break' "$worker_protocol"
grep -Fq 'They do not decide when you stop' "$worker_protocol"
grep -Fq 'Do not end your turn with the story unfinished' "$worker_protocol"
grep -Fq 'record exactly what remains' "$worker_protocol"
grep -Fq 'Change nothing else' "$worker_protocol"
grep -Fq 'installed `go-backend` skill' "$worker_protocol"
# The protocol outranks project files about when a story passes, and it lets the worker decide
# what the PRD leaves open instead of waiting for an outside decision.
grep -Fq 'this protocol wins' "$worker_protocol"
grep -Fq 'decide it within the PRD' "$worker_protocol"
grep -Fq 'do not follow that part' "$worker_protocol"
for generated in "$ralph_dir/CLAUDE.md" "$worker_protocol"; do
  if grep -Fq 'Leave `passes: false` only when' "$generated"; then
    echo "Ralph worker instructions must not offer a reason to withhold passes: $generated" >&2
    exit 1
  fi
  if grep -Fq 'BLOCKED' "$generated"; then
    echo "Ralph worker instructions must not tell the worker to stop as BLOCKED: $generated" >&2
    exit 1
  fi
done
grep -Fq '### Failure Behavior' "$ROOT/config/prd-fail-close-clean-break.md"
grep -Fq '### Compatibility and Removal' "$ROOT/config/prd-fail-close-clean-break.md"
grep -Fq '### Pre-run checklist' "$ROOT/config/prd-fail-close-clean-break.md"
grep -Fq '## Runner constraints' "$ROOT/config/ralph-fail-close-clean-break.md"
grep -Fq 'They are not rules about when the agent' "$ROOT/config/AGENTS.global.md"
# Plans settle open implementation choices instead of turning them into prerequisites, and no
# story may wait for an outside decision, record, or verification.
grep -Fq '## Open implementation choices' "$ROOT/config/AGENTS.global.md"
grep -Fq '## Open implementation choices' "$ROOT/config/prd-fail-close-clean-break.md"
grep -Fq 'No user story may depend on the result of a checklist item' \
  "$ROOT/config/prd-fail-close-clean-break.md"
grep -Fq 'keep `passes` false until an' "$ROOT/config/ralph-fail-close-clean-break.md"
grep -Fq 'Do not replace, archive, or rewrite `scripts/ralph/CLAUDE.md`' \
  "$ROOT/config/ralph-fail-close-clean-break.md"
# Fail-close and clean-break describe the code being built. None of the shared policy texts, the
# Ralph worker instructions, or the go-backend skill may turn them into rules about stopping,
# refusing a step, or withholding passes.
policy_texts=(
  "$ROOT/config/AGENTS.global.md"
  "$ROOT/config/prd-fail-close-clean-break.md"
  "$ROOT/config/ralph-fail-close-clean-break.md"
  "$ralph_dir/CLAUDE.md"
  "$worker_protocol"
  "$ROOT/skills/go-backend/SKILL.md"
  "$ROOT"/skills/go-backend/references/*.md
)
for phrase in 'stop as blocked' 'stop and surface' 'they do not stop' 'do not create `prd.json`' \
  'still create `prd.json`' 'Reference PRD decisions by their IDs' '確定した設計判断'; do
  if grep -Fq -- "$phrase" "${policy_texts[@]}"; then
    echo "policy texts must not carry the process rule: $phrase" >&2
    exit 1
  fi
done

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
bash "$ROOT/scripts/install-skill.sh" \
  "$ROOT/skills/orca-cli" "$doctor_home/skills/orca-cli" .managed
bash "$ROOT/scripts/install-skill.sh" \
  "$ROOT/skills/computer-use" "$doctor_home/skills/computer-use" .managed
printf '\n## Fail-close and clean-break requirements\n' >> "$doctor_home/skills/prd/SKILL.md"
printf '\n## Preserve failure and removal semantics\n' >> "$doctor_home/skills/ralph/SKILL.md"
mkdir -p "$doctor_home/skills/ralph-run/scripts" "$doctor_home/skills/ralph-run/assets"
printf '# fixture\n' > "$doctor_home/skills/ralph-run/scripts/ralph-state.py"
printf '{}\n' > "$doctor_home/skills/ralph-run/assets/policy-review.schema.json"
printf '# fixture\n' > "$doctor_home/skills/ralph-run/assets/worker-protocol.md"
printf '%s\n' \
  '<!-- BEGIN codex-workstation-bootstrap -->' \
  '## Go backend' \
  '## Fail-close and clean-break' \
  '<!-- END codex-workstation-bootstrap -->' \
  > "$doctor_home/AGENTS.md"

test_bin="$TEST_ROOT/bin"
mkdir -p "$test_bin"
# Doctor's policy fixtures must not depend on workstation-installed CLIs.
for tool in codex bun node npx; do
  cat > "$test_bin/$tool" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == mcp && "${2:-}" == list && "${3:-}" == --json ]]; then
  python3 - <<'PYTHON'
import json, os, shutil
from pathlib import Path
app = os.environ.get("CODEX_APP_HOME") == os.environ.get("CODEX_HOME")
search = str(Path.home() / ".local/bin") + ":" + os.environ["PATH"]
npx, node = shutil.which("npx", path=search), shutil.which("node", path=search)
app_path = ":".join(dict.fromkeys([str(Path(node).parent), str(Path(npx).parent), "/usr/local/bin", "/usr/bin", "/bin"]))
print(json.dumps([{"name":name,"enabled":True,"transport":{"type":"stdio","command":npx if app else "npx","args":["-y","chrome-devtools-mcp@latest",f"--browser-url=http://127.0.0.1:{port}"],"env":{"PATH":app_path} if app else None,"env_vars":[],"cwd":None}} for name,port in [("chrome-devtools",9222),("chrome-devtools-9223",9223)]]))
PYTHON
  exit 0
fi
if [[ "${1:-}" == -e ]]; then exit 0; fi
[[ "$#" -eq 1 && "$1" == --version ]]
printf 'fixture-version\n'
EOF
  chmod 0755 "$test_bin/$tool"
done
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

for orca_skill in orca-cli computer-use; do
  mv "$doctor_home/skills/$orca_skill" "$doctor_home/skills/$orca_skill.missing"
  set +e
  doctor_orca_output="$(PATH="$test_bin:$PATH" RTK_BIN="$test_bin/rtk" \
    CODEX_HOME="$doctor_home" bash "$ROOT/doctor.sh" --skip-login 2>&1)"
  doctor_orca_status=$?
  set -e
  [[ "$doctor_orca_status" -eq 1 ]]
  grep -Fq "CLI skill missing: $orca_skill" <<< "$doctor_orca_output"
  mv "$doctor_home/skills/$orca_skill.missing" "$doctor_home/skills/$orca_skill"
done

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
grep -Fq 'ralph worker protocol missing' <<< "$doctor_output"

printf '{}\n' > "$doctor_home/skills/ralph-run/assets/policy-review.schema.json"
printf '# fixture\n' > "$doctor_home/skills/ralph-run/assets/worker-protocol.md"
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
