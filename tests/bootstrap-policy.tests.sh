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
# The dry run must not depend on the Cursor or Antigravity CLI installed on this machine.
printf '%s\n' '#!/usr/bin/env bash' 'printf "2026.09.28-64d2043\\n"' > "$legacy_bin/agent"
printf '%s\n' '#!/usr/bin/env bash' 'printf "1.2.13\\n"' > "$legacy_bin/agy"
chmod 0755 "$legacy_bin/agent" "$legacy_bin/agy"
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
grep -Fq 'Cursor CLI already present: 2026.09.28' <<< "$gstack_dry_run_output"
grep -Fq "register Cursor hooks, guidance and Chrome MCP servers -> $legacy_home/.cursor" \
  <<< "$gstack_dry_run_output"
grep -Fq "install skill ralph-run-cursor -> $legacy_home/.cursor/skills/ralph-run-cursor" \
  <<< "$gstack_dry_run_output"
grep -Fq 'Antigravity CLI already present: 1.2.13' <<< "$gstack_dry_run_output"
grep -Fq "update managed block in $legacy_home/.gemini/AGENTS.md" <<< "$gstack_dry_run_output"
grep -Fq "install skill ralph-run -> $legacy_home/.gemini/antigravity-cli/skills/ralph-run" \
  <<< "$gstack_dry_run_output"
[[ ! -e "$legacy_home/.cursor" && ! -e "$legacy_home/.gemini" ]]
[[ "$(git -C "$legacy_home/gstack" status --short)" == ' M SKILL.md' ]]

# A setting that Cursor or Antigravity setup would refuse stops the run before any Codex change,
# in a dry run too.
refusal_home="$TEST_ROOT/refusal-home"
mkdir -p "$refusal_home/.codex" "$refusal_home/.gemini"
# expect_early_refusal EXPECTED CODEX_HOME: the dry run must exit 1 with EXPECTED before it creates
# CODEX_HOME or installs anything (only the source checkouts come first, as for the Codex App check).
expect_early_refusal() {
  local expected="$1" codex_home="$2" output status
  set +e
  output="$(HOME="$refusal_home" CODEX_HOME="$codex_home" PATH="$legacy_bin:$PATH" \
    bash "$ROOT/install.sh" --dry-run 2>&1)"
  status=$?
  set -e
  [[ "$status" -eq 1 ]] || { echo "dry run did not stop for: $expected" >&2; exit 1; }
  grep -Fq -- "$expected" <<< "$output" || {
    printf 'dry run did not report: %s\n%s\n' "$expected" "$output" >&2
    exit 1
  }
  if grep -Fq -e "+ mkdir -p $codex_home" -e '+ install skill' -e '+ update managed block' <<< "$output"; then
    echo "dry run changed Codex before refusing: $expected" >&2
    exit 1
  fi
}
expect_early_refusal "CODEX_HOME=$TEST_ROOT/other-codex is not supported" "$TEST_ROOT/other-codex"
ln -s "$TEST_ROOT/elsewhere.md" "$refusal_home/.gemini/AGENTS.md"
expect_early_refusal 'refusing to replace non-regular AGENTS.md' "$refusal_home/.codex"
rm "$refusal_home/.gemini/AGENTS.md"
# The Antigravity and Cursor settings checks run in a dry run too, and so does the check of the
# Codex AGENTS.md markers.
mkdir -p "$refusal_home/.gemini/config"
printf '{broken\n' > "$refusal_home/.gemini/config/mcp_config.json"
expect_early_refusal \
  "refusing to replace invalid Antigravity MCP config $refusal_home/.gemini/config/mcp_config.json:" \
  "$refusal_home/.codex"
rm -r -- "$refusal_home/.gemini/config"
mkdir -p "$refusal_home/.cursor"
printf '{"hooks": {}}\n' > "$refusal_home/.cursor/hooks.json"
expect_early_refusal \
  "refusing to replace Cursor hooks file without \"version\": 1: $refusal_home/.cursor/hooks.json" \
  "$refusal_home/.codex"
rm -r -- "$refusal_home/.cursor"
codex_agents="$refusal_home/.codex/AGENTS.md"
printf '%s\n' 'user notes' '<!-- BEGIN codex-workstation-bootstrap -->' 'old guidance' > "$codex_agents"
expect_early_refusal \
  "refusing to update $codex_agents: its codex-workstation-bootstrap BEGIN and END markers do not pair up" \
  "$refusal_home/.codex"
rm "$codex_agents"

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

# Doctor also checks Cursor CLI and Antigravity CLI. They are set up in their own home by the real
# setup functions with fake CLIs, so Doctor never reads this machine's configuration.
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'case "$*" in' \
  '  --version) printf "%s\\n" "${FAKE_CURSOR_VERSION:-2026.09.28-64d2043}" ;;' \
  '  *) exit 90 ;;' \
  'esac' > "$test_bin/agent"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'case "$*" in' \
  '  --version) printf "%s\\n" "${FAKE_AGY_VERSION:-1.2.13}" ;;' \
  '  *) exit 90 ;;' \
  'esac' > "$test_bin/agy"
chmod 0755 "$test_bin/agent" "$test_bin/agy"
export HOME="$TEST_ROOT/doctor-user-home"
mkdir -p "$HOME"
(
  export PATH="$test_bin:$PATH" CODEX_HOME="$doctor_home"
  source "$ROOT/install.sh"
  install_cursor_environment
  install_antigravity_environment
) >/dev/null

doctor_healthy_output="$(PATH="$test_bin:$PATH" RTK_BIN="$test_bin/rtk" CODEX_HOME="$doctor_home" \
  bash "$ROOT/doctor.sh" --skip-login)"
# Doctor probes both Ralph result hooks: each answers {} while no result waits and delivers one once.
for agent_label in Cursor Antigravity; do
  grep -Fxq "ok   $agent_label Ralph result hook" <<< "$doctor_healthy_output" || {
    printf 'Doctor did not report: ok   %s Ralph result hook\n%s\n' "$agent_label" "$doctor_healthy_output" >&2
    exit 1
  }
done
# The probes run in a temporary home, so Doctor leaves no inbox in the real one.
for inbox in "$HOME/.cursor/ralph-inbox" "$HOME/.gemini/antigravity-cli/ralph-inbox"; do
  [[ ! -e "$inbox" ]] || { echo "Doctor created a Ralph inbox: $inbox" >&2; exit 1; }
done

# check_doctor_failure EXPECTED [ENV...]: Doctor must exit 1 and report EXPECTED. Its output stays in
# doctor_failure_output.
check_doctor_failure() {
  local expected="$1"
  local status
  shift
  set +e
  doctor_failure_output="$(env "$@" PATH="$test_bin:$PATH" RTK_BIN="$test_bin/rtk" CODEX_HOME="$doctor_home" \
    bash "$ROOT/doctor.sh" --skip-login 2>&1)"
  status=$?
  set -e
  [[ "$status" -eq 1 ]] || {
    printf 'Doctor exited %s instead of 1; expected: %s\n%s\n' "$status" "$expected" "$doctor_failure_output" >&2
    exit 1
  }
  grep -Fq -- "$expected" <<< "$doctor_failure_output" || {
    printf 'Doctor did not report: %s\n%s\n' "$expected" "$doctor_failure_output" >&2
    exit 1
  }
}
check_doctor_failure 'Antigravity CLI version 1.2.9 is older than the verified minimum 1.2.13' \
  FAKE_AGY_VERSION=1.2.9
check_doctor_failure 'Cursor CLI version unrecognized is older than the verified minimum' \
  FAKE_CURSOR_VERSION=unknown
cursor_guidance="$HOME/.cursor/hooks/codex-workstation-bootstrap/guidance.md"
mv "$cursor_guidance" "$cursor_guidance.missing"
check_doctor_failure 'Cursor guidance hook does not return the shared guidance'
mv "$cursor_guidance.missing" "$cursor_guidance"
# Doctor probes each managed Ralph result hook in a temporary home, and a hook that is missing or fails
# a step of the probe fails Doctor with the reason. Each fake below fails one step: one adds a result
# to every message, one fails after printing {}, one answers {} whatever waits, and the real hook
# (REAL_HOOK) wrapped as FAKE says leaves a result it delivered waiting, leaves it unrecorded, or
# repeats it with the next message.
cat > "$TEST_ROOT/broken-result-hook.py" <<'PY'
import json, os, subprocess, sys
from pathlib import Path
fake, last = os.environ["FAKE"], Path.home() / "last-answer"
entries = list(Path.home().glob("**/ralph-inbox/*/*.json"))
kept = {path: path.read_bytes() for path in entries} if fake == "waiting" else {}
for entry in entries if fake == "unrecorded" else []:
    result_file = Path(json.loads(entry.read_text())["result_file"])
    kept[result_file] = result_file.read_bytes()
answer = subprocess.run([sys.executable, "-B", os.environ["REAL_HOOK"], *sys.argv[1:]], stdin=sys.stdin,
                        capture_output=True, text=True).stdout
for path, content in kept.items():
    path.write_bytes(content)
if fake == "repeat" and answer.strip() != "{}":
    last.write_text(answer)
elif fake == "repeat" and last.exists():
    answer = last.read_text()
sys.stdout.write(answer)
PY
for agent_label in Cursor Antigravity; do
  case "$agent_label" in
    Cursor)
      result_hook="$HOME/.cursor/hooks/codex-workstation-bootstrap/ralph-result-hook.py"
      stale_answer='{"additional_context":"stale result"}'
      ;;
    Antigravity)
      result_hook="$HOME/.gemini/config/hooks/codex-workstation-bootstrap/ralph-result-hook.py"
      stale_answer='{"injectSteps":[{"userMessage":"stale result"}]}'
      ;;
  esac
  result_failure="$agent_label Ralph result hook does not work: $result_hook"
  real_hook="$TEST_ROOT/ralph-result-hook.py.saved"
  mv "$result_hook" "$real_hook"
  check_doctor_failure "$result_failure (exit 2: "
  # The installer's --verify reports the missing file as well.
  grep -Fq "$agent_label hook registrations: the $agent_label hook file $result_hook is missing" \
    <<< "$doctor_failure_output" || {
    printf 'Doctor did not report the missing %s hook file:\n%s\n' "$agent_label" "$doctor_failure_output" >&2
    exit 1
  }
  printf "print('%s')\n" "$stale_answer" > "$result_hook"
  check_doctor_failure "$result_failure (it answers something other than {} while no result waits)"
  printf "import sys\nprint('{}')\nsys.exit(1)\n" > "$result_hook"
  check_doctor_failure "$result_failure (exit 1: "
  printf "print('{}')\n" > "$result_hook"
  check_doctor_failure "$result_failure (it does not deliver a queued result)"
  cp "$TEST_ROOT/broken-result-hook.py" "$result_hook"
  for fake in waiting unrecorded; do
    check_doctor_failure "$result_failure (it does not record the delivery, or leaves the result in the inbox)" \
      REAL_HOOK="$real_hook" FAKE="$fake"
  done
  check_doctor_failure "$result_failure (it delivers a result twice)" REAL_HOOK="$real_hook" FAKE=repeat
  mv "$real_hook" "$result_hook"
done
cp "$HOME/.gemini/config/skills.json" "$TEST_ROOT/skills.json.saved"
# Antigravity's own skills directory must come first, and the Codex skills must be registered.
own_skills="{\"path\": \"$HOME/.gemini/antigravity-cli/skills\"}"
codex_skills="{\"path\": \"$doctor_home/skills\", \"exclude\": [\"ralph-run\"]}"
for entries in '' "$codex_skills" "$codex_skills, $own_skills" "$own_skills"; do
  printf '{"entries": [%s]}\n' "$entries" > "$HOME/.gemini/config/skills.json"
  check_doctor_failure "Antigravity skills.json does not register $HOME/.gemini/antigravity-cli/skills first and $doctor_home/skills"
done
cp "$TEST_ROOT/skills.json.saved" "$HOME/.gemini/config/skills.json"
printf '{"model": "has space"}\n' > "$HOME/.cursor/ralph.json"
check_doctor_failure 'Cursor Ralph model settings are invalid'
rm "$HOME/.cursor/ralph.json"
printf '{"review_model": 5}\n' > "$doctor_home/ralph.json"
check_doctor_failure 'CLI Ralph model settings are invalid'
rm "$doctor_home/ralph.json"
# A regression script that cannot run fails Doctor instead of being skipped.
chmod 0644 "$doctor_home/hooks/rtk-safe/test.sh"
check_doctor_failure 'CLI Codex RTK Safe Hook regression not executable'
chmod 0755 "$doctor_home/hooks/rtk-safe/test.sh"
mv "$HOME/.cursor/skills/ralph-run-cursor/scripts/cursor-runtime.json" "$TEST_ROOT/cursor-runtime.json"
check_doctor_failure 'Cursor Ralph runtime record is missing or invalid'
mv "$TEST_ROOT/cursor-runtime.json" "$HOME/.cursor/skills/ralph-run-cursor/scripts/cursor-runtime.json"
# A removed regression script is reported once, as missing.
mv "$doctor_home/hooks/rtk-safe/test.sh" "$TEST_ROOT/codex-test.sh"
check_doctor_failure "CLI Codex RTK Safe Hook regression missing: $doctor_home/hooks/rtk-safe/test.sh"
[[ "$(grep -c 'Codex RTK Safe Hook regression' <<< "$doctor_failure_output")" -eq 1 ]] || {
  printf 'Doctor reported the removed regression script more than once:\n%s\n' "$doctor_failure_output" >&2
  exit 1
}
mv "$TEST_ROOT/codex-test.sh" "$doctor_home/hooks/rtk-safe/test.sh"
# Guidance longer than the 10,000 characters Cursor accepts at session start fails Doctor: the Cursor
# installer's --verify reports its length. Here the guidance is padded to 10,001 characters.
cp -p "$cursor_guidance" "$TEST_ROOT/guidance.md.saved"
python3 - "$cursor_guidance" <<'PY'
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    length = len(source.read().encode("utf-16-le")) // 2
if length >= 10_000:
    raise SystemExit(f"error: the composed Cursor guidance is already {length} characters")
with open(sys.argv[1], "a", encoding="utf-8") as target:
    target.write("x" * (10_000 - length) + "\n")
PY
check_doctor_failure \
  "Cursor hook registrations: Cursor guidance is 10001 characters; Cursor accepts at most 10000: $cursor_guidance"
cp -p "$TEST_ROOT/guidance.md.saved" "$cursor_guidance"

# Doctor compares the Chrome MCP servers and the managed hook registrations with what setup writes,
# instead of only looking for them.
# check_changed_json EXPECTED FILE STATEMENTS: Doctor reports EXPECTED once the Python STATEMENTS have
# changed `data`, the JSON in FILE; FILE is restored afterwards.
check_changed_json() {
  local expected="$1" file="$2" statements="$3"
  cp -p "$file" "$TEST_ROOT/changed.json.saved"
  python3 - "$file" "$statements" <<'PY'
import json, sys
path, statements = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as source:
    data = json.load(source)
exec(statements)
with open(path, "w", encoding="utf-8") as target:
    json.dump(data, target, indent=2)
PY
  check_doctor_failure "$expected"
  cp -p "$TEST_ROOT/changed.json.saved" "$file"
}
check_changed_json "Cursor Chrome MCP registrations are missing or different: $HOME/.cursor/mcp.json" \
  "$HOME/.cursor/mcp.json" \
  'data["mcpServers"]["chrome-devtools"]["args"][-1] = "--browser-url=http://127.0.0.1:9223"'
check_changed_json \
  "Antigravity Chrome MCP registrations are missing or different: $HOME/.gemini/config/mcp_config.json" \
  "$HOME/.gemini/config/mcp_config.json" \
  'data["mcpServers"]["chrome-devtools-9223"]["args"][1] = "chrome-devtools-mcp@0.1.0"'
cursor_hooks_mismatch="Cursor hook registrations: the Cursor hook registration in $HOME/.cursor/hooks.json"
check_changed_json "$cursor_hooks_mismatch" "$HOME/.cursor/hooks.json" \
  'data["hooks"]["preToolUse"][0]["failClosed"] = False'
check_changed_json "$cursor_hooks_mismatch" "$HOME/.cursor/hooks.json" \
  'data["hooks"]["preToolUse"][0]["matcher"] = "Shell"'
# Cursor needs "version": 1 in hooks.json; the managed handlers alone do not make the file valid.
check_changed_json \
  "Cursor hook registrations: the Cursor hooks file $HOME/.cursor/hooks.json lacks \"version\": 1" \
  "$HOME/.cursor/hooks.json" 'del data["version"]'
check_changed_json \
  "Antigravity hook registrations: the Antigravity hook registration in $HOME/.gemini/config/hooks.json" \
  "$HOME/.gemini/config/hooks.json" \
  'data["codex-workstation-bootstrap-rtk"]["PreToolUse"][0]["matcher"] = "view_file"'
# The registrations that setup wrote before the Ralph result hook existed fail Doctor.
check_changed_json "$cursor_hooks_mismatch" "$HOME/.cursor/hooks.json" 'del data["hooks"]["beforeSubmitPrompt"]'
check_changed_json \
  "Antigravity hook registrations: the Antigravity hook registration in $HOME/.gemini/config/hooks.json" \
  "$HOME/.gemini/config/hooks.json" 'del data["codex-workstation-bootstrap-rtk"]["PreInvocation"]'
# With every file restored, Doctor passes again.
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
