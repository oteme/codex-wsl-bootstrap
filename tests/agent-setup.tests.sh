#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

# Cursor CLI and Antigravity CLI setup from install.sh, run against fake CLIs and a fake installer.
# Everything these functions touch stays in TEST_ROOT: the home, temporary files and the fakes. PATH
# holds only the fakes and system tools, so this machine's agent and agy are never found.
FAKE_BIN="$TEST_ROOT/bin"
export HOME="$TEST_ROOT/home" TMPDIR="$TEST_ROOT/tmp" PATH="$FAKE_BIN:/usr/bin:/bin"
export FAKE_STATE="$TEST_ROOT/state" FAKE_CALLS="$TEST_ROOT/calls" FAKE_CLI="$TEST_ROOT/fake-cli"
unset CODEX_HOME CODEX_APP_HOME RALPH_MODEL RALPH_REVIEW_MODEL RALPH_EFFORT RALPH_REVIEW_EFFORT
mkdir -p "$HOME" "$TMPDIR"

# install.sh parses its positional arguments; sourcing it defines the functions without running main.
set --
# shellcheck source=../install.sh
source "$ROOT/install.sh"
DEFAULT_CODEX_DIR="$CODEX_DIR"

for cli in agent agy; do
  if command -v "$cli" >/dev/null 2>&1; then
    echo "error: $cli is reachable on the test PATH: $(command -v "$cli")" >&2
    exit 1
  fi
done

# A fake agent or agy. --version prints $FAKE_STATE/<name>.version; update records the call and, when
# the test prepared <name>.after-update, moves to that version.
cat > "$FAKE_CLI" <<'EOF'
#!/usr/bin/env bash
name="${0##*/}"
case "$*" in
  --version) cat "$FAKE_STATE/$name.version" ;;
  update)
    printf '%s update\n' "$name" >> "$FAKE_CALLS"
    if [[ -f "$FAKE_STATE/$name.after-update" ]]; then
      mv "$FAKE_STATE/$name.after-update" "$FAKE_STATE/$name.version"
    fi
    ;;
  *) printf '%s %s\n' "$name" "$*" >> "$FAKE_CALLS"; exit 90 ;;
esac
EOF
chmod 0755 "$FAKE_CLI"
# A fake official installer. It records how it was run, then installs the fake CLI named in
# $FAKE_STATE/installs into ~/.local/bin, which install.sh keeps on PATH.
cat > "$TEST_ROOT/fake-installer" <<'EOF'
#!/usr/bin/env bash
{
  printf 'installer NON_INTERACTIVE=%s' "${NON_INTERACTIVE:-}"
  for arg in "$@"; do printf ' [%s]' "$arg"; done
  printf '\n'
} >> "$FAKE_CALLS"
if [[ -f "$FAKE_STATE/installs" ]]; then
  mkdir -p "$HOME/.local/bin"
  cp "$FAKE_CLI" "$HOME/.local/bin/$(cat "$FAKE_STATE/installs")"
fi
EOF

# curl only downloads installers here: it records the URL and saves the fake installer. No network.
curl() {
  local url="" output=""
  while (($#)); do
    case "$1" in
      -o) output="$2"; shift ;;
      http://* | https://*) url="$1" ;;
    esac
    shift
  done
  printf 'curl %s\n' "$url" >> "$FAKE_CALLS"
  cp "$TEST_ROOT/fake-installer" "$output"
}

# cli_profile NAME: expectations for agent (Cursor CLI) or agy (Antigravity CLI). older and current
# are what `NAME --version` prints below and at the verified minimum; install.sh reports Cursor's
# version without its build suffix.
cli_profile() {
  case "$1" in
    agent)
      label="Cursor CLI" ensure=ensure_cursor_cli minimum="$CURSOR_MIN_VERSION"
      older="2000.01.01-1a2b3c4" current="$CURSOR_MIN_VERSION-64d2043"
      unrecognized="Cursor Agent $CURSOR_MIN_VERSION"
      url="https://cursor.com/install" installer_call="installer NON_INTERACTIVE=1"
      ;;
    agy)
      label="Antigravity CLI" ensure=ensure_antigravity_cli minimum="$ANTIGRAVITY_MIN_VERSION"
      older="0.0.1" current="$ANTIGRAVITY_MIN_VERSION" unrecognized="v$ANTIGRAVITY_MIN_VERSION"
      url="https://antigravity.google/cli/install.sh"
      installer_call="installer NON_INTERACTIVE=1 [--skip-path] [--skip-aliases]"
      ;;
  esac
  reported_older="${older%%-*}"
}

# Every case starts with an empty home, no CLI on PATH, no recorded calls and the default CODEX_HOME.
reset_case() {
  rm -rf -- "$TEST_ROOT/home" "$TEST_ROOT/user" "$FAKE_BIN" "$FAKE_STATE"
  mkdir -p "$TEST_ROOT/home" "$TEST_ROOT/user" "$FAKE_BIN" "$FAKE_STATE"
  : > "$FAKE_CALLS"
  CODEX_DIR="$DEFAULT_CODEX_DIR"
  DRY_RUN=0
}

# add_cli NAME VERSION [VERSION_AFTER_UPDATE]: put a fake CLI on PATH.
add_cli() {
  cp "$FAKE_CLI" "$FAKE_BIN/$1"
  printf '%s\n' "$2" > "$FAKE_STATE/$1.version"
  if [[ $# -ge 3 ]]; then printf '%s\n' "$3" > "$FAKE_STATE/$1.after-update"; fi
}

# installer_adds NAME VERSION: the downloaded installer puts a fake CLI into ~/.local/bin.
installer_adds() {
  printf '%s\n' "$1" > "$FAKE_STATE/installs"
  printf '%s\n' "$2" > "$FAKE_STATE/$1.version"
}

# A skill directory the bootstrap installed, and one the user made.
managed_skill() { mkdir -p "$1"; printf 'managed skill\n' > "$1/SKILL.md"; : > "$1/$MANAGED_MARKER"; }
user_skill() { mkdir -p "$1"; printf 'user skill\n' > "$1/SKILL.md"; }

# Paths, link targets and file contents under the home and the fixtures' outside targets.
home_state() {
  find "$TEST_ROOT/home" "$TEST_ROOT/user" -printf '%y %p %l\n' | sort
  find "$TEST_ROOT/home" "$TEST_ROOT/user" -type f -exec cksum {} + | sort
}

# capture COMMAND...: run COMMAND in a subshell with install.sh's errexit. install.sh exits on
# errors, which ends only the subshell; its status and combined output are kept.
capture() {
  home_before="$(home_state)"
  set +e
  out="$(set -e; "$@" 2>&1)"
  status=$?
  set -e
}

fail() {
  printf 'FAIL: %s (DRY_RUN=%s)\n' "$1" "$DRY_RUN" >&2
  printf '%s\n' '--- output ---' "${out:-}" >&2
  exit 1
}

expect_output() { grep -Fq -- "$1" <<< "$out" || fail "expected output: $1"; }

expect_success() {
  capture "$@"
  [[ "$status" -eq 0 ]] || fail "$* exited $status"
}

# expect_exit_1 MESSAGE COMMAND...
expect_exit_1() {
  local message="$1"
  shift
  capture "$@"
  [[ "$status" -eq 1 ]] || fail "$* exited $status instead of 1"
  expect_output "$message"
}

# expect_calls [LINE...]: exactly these CLI updates, downloads and installer runs happened.
expect_calls() {
  local expected="" actual
  if [[ $# -gt 0 ]]; then expected="$(printf '%s\n' "$@")"; fi
  actual="$(cat "$FAKE_CALLS")"
  [[ "$actual" == "$expected" ]] ||
    fail "expected calls [${expected//$'\n'/, }], got [${actual//$'\n'/, }]"
}

expect_home_unchanged() {
  local after
  after="$(home_state)"
  [[ "$after" == "$home_before" ]] ||
    fail "the home changed: $(diff <(printf '%s\n' "$home_before") <(printf '%s\n' "$after") || true)"
}

expect_no_temporary_files() {
  local leftovers
  leftovers="$(find "$TMPDIR" -mindepth 1)"
  [[ -z "$leftovers" ]] || fail "temporary files were left behind: $leftovers"
}

# ensure_cursor_cli and ensure_antigravity_cli.
for name in agent agy; do
  cli_profile "$name"

  # At the verified minimum: nothing to do.
  reset_case
  add_cli "$name" "$current"
  expect_success "$ensure"
  expect_output "$label already present: $minimum"
  expect_calls

  # Older: `update` runs, and setup continues only once the version reaches the minimum.
  reset_case
  add_cli "$name" "$older" "$current"
  expect_success "$ensure"
  expect_output "Updating $label $reported_older to at least $minimum"
  expect_calls "$name update"
  reset_case
  add_cli "$name" "$older"
  expect_exit_1 "error: $label $reported_older is older than the verified minimum $minimum" "$ensure"
  expect_calls "$name update"
  reset_case
  add_cli "$name" "$older" "$unrecognized"
  expect_exit_1 "error: $label with an unrecognized version is older than the verified minimum $minimum" \
    "$ensure"
  expect_calls "$name update"

  # An unrecognized version stops setup before any update.
  reset_case
  add_cli "$name" "$unrecognized"
  expect_exit_1 "error: unrecognized $label version: $unrecognized" "$ensure"
  expect_calls

  # A dry run reports the update or installation and changes nothing.
  reset_case
  add_cli "$name" "$older" "$current"
  DRY_RUN=1 expect_success "$ensure"
  expect_output "Would update $label $reported_older to at least $minimum"
  expect_calls
  expect_home_unchanged
  reset_case
  DRY_RUN=1 expect_success "$ensure"
  expect_output "Would install $label from the official installer"
  expect_calls
  expect_home_unchanged

  # Missing: the official installer is downloaded and run (agy's without touching shell profiles,
  # Cursor's without arguments), and setup stops unless the CLI is then on PATH.
  reset_case
  installer_adds "$name" "$current"
  expect_success "$ensure"
  expect_calls "curl $url" "$installer_call"
  reset_case
  expect_exit_1 "error: $label installed, but $name is not on PATH" "$ensure"
  expect_calls "curl $url" "$installer_call"
done

# validate_agent_skill_target replaces only a bootstrap-managed skill directory.
reset_case
skills="$HOME/skills"
expect_success validate_agent_skill_target "$skills" ralph-run
managed_skill "$skills/ralph-run"
expect_success validate_agent_skill_target "$skills" ralph-run
user_skill "$skills/user-skill"
expect_exit_1 "error: refusing to overwrite an unmanaged skill: $skills/user-skill" \
  validate_agent_skill_target "$skills" user-skill
ln -s "$skills/ralph-run" "$skills/linked-skill"
expect_exit_1 "error: refusing to overwrite an unmanaged skill: $skills/linked-skill" \
  validate_agent_skill_target "$skills" linked-skill
ln -s "$skills" "$HOME/linked-skills"
expect_exit_1 "error: refusing to use symlinked skills directory: $HOME/linked-skills" \
  validate_agent_skill_target "$HOME/linked-skills" ralph-run
# It refuses any path between the skills directory and the home that is not a directory, however far
# up; the preflight cases below cover the skills directory itself and a symlink to nothing.
printf 'user file\n' > "$HOME/file"
expect_exit_1 "error: refusing to use non-directory $HOME/file for the ralph-run skill" \
  validate_agent_skill_target "$HOME/file/nested/skills" ralph-run

# A home the bootstrap already manages passes both preflights, which write nothing. CODEX_HOME may
# spell ~/.codex differently.
reset_case
managed_skill "$HOME/.cursor/skills/ralph-run-cursor"
CODEX_DIR="$HOME/./.codex/"
expect_success preflight_cursor_environment
expect_home_unchanged
reset_case
managed_skill "$HOME/.gemini/antigravity-cli/skills/ralph-run"
printf 'user guidance\n' > "$HOME/.gemini/AGENTS.md"
expect_success preflight_antigravity_environment
expect_home_unchanged
# A symlink to a directory is fine above the skills directory (only the skills directory itself must
# not be a symlink), in a dry run too.
for dry_run in 0 1; do
  reset_case
  mkdir -p "$TEST_ROOT/user/cursor" "$TEST_ROOT/user/antigravity-cli" "$HOME/.gemini"
  ln -s "$TEST_ROOT/user/cursor" "$HOME/.cursor"
  ln -s "$TEST_ROOT/user/antigravity-cli" "$HOME/.gemini/antigravity-cli"
  managed_skill "$HOME/.cursor/skills/ralph-run-cursor"
  managed_skill "$HOME/.gemini/antigravity-cli/skills/ralph-run"
  DRY_RUN="$dry_run" expect_success preflight_cursor_environment
  expect_home_unchanged
  DRY_RUN="$dry_run" expect_success preflight_antigravity_environment
  expect_home_unchanged
done

# Refusal fixtures. What a symlink points to lives in $TEST_ROOT/user, outside the home.
custom_codex_home() { CODEX_DIR="$TEST_ROOT/user/codex"; }
unmanaged_cursor_skill() { user_skill "$HOME/.cursor/skills/ralph-run-cursor"; }
symlinked_cursor_skills() { mkdir -p "$HOME/.cursor"; ln -s "$TEST_ROOT/user" "$HOME/.cursor/skills"; }
unmanaged_antigravity_skill() { user_skill "$HOME/.gemini/antigravity-cli/skills/ralph-run"; }
symlinked_antigravity_skills() {
  mkdir -p "$HOME/.gemini/antigravity-cli"
  ln -s "$TEST_ROOT/user" "$HOME/.gemini/antigravity-cli/skills"
}
symlinked_agents_md() {
  mkdir -p "$HOME/.gemini"
  printf 'user guidance\n' > "$TEST_ROOT/user/AGENTS.md"
  ln -s "$TEST_ROOT/user/AGENTS.md" "$HOME/.gemini/AGENTS.md"
}
# Settings files the Cursor and Antigravity installers refuse to merge into.
cursor_hooks_without_version() { mkdir -p "$HOME/.cursor"; printf '{"hooks": {}}\n' > "$HOME/.cursor/hooks.json"; }
invalid_antigravity_mcp() {
  mkdir -p "$HOME/.gemini/config"
  printf '{broken\n' > "$HOME/.gemini/config/mcp_config.json"
}

# expect_refusal MESSAGE COMMAND: COMMAND exits 1 with MESSAGE before any CLI update or installer
# download, and the home is left as it was: nothing appears in ~/.cursor/hooks, ~/.cursor/*.json or
# ~/.gemini/config, and no skill or guidance is written. No temporary file is left behind either.
expect_refusal() {
  expect_exit_1 "$@"
  expect_calls
  expect_home_unchanged
  expect_no_temporary_files
}

# check_refusal AGENT FIXTURE MESSAGE: with FIXTURE, the preflight and the whole setup stop with
# MESSAGE, whether the CLI is current (setup would go on to write hooks, settings and skills), older
# (a successful update would run) or missing (a working installer would be downloaded). A dry run
# stops the same way.
check_refusal() {
  local agent="$1" fixture="$2" message="$3" name=agent state dry_run
  [[ "$agent" == cursor ]] || name=agy
  cli_profile "$name"
  for dry_run in 0 1; do
    reset_case
    "$fixture"
    DRY_RUN="$dry_run" expect_refusal "$message" "preflight_${agent}_environment"
    for state in current older missing; do
      reset_case
      "$fixture"
      case "$state" in
        current) add_cli "$name" "$current" ;;
        older) add_cli "$name" "$older" "$current" ;;
        missing) installer_adds "$name" "$current" ;;
      esac
      DRY_RUN="$dry_run" expect_refusal "$message" "setup_$agent"
    done
  done
}

check_refusal cursor unmanaged_cursor_skill \
  "error: refusing to overwrite an unmanaged skill: $HOME/.cursor/skills/ralph-run-cursor"
check_refusal cursor symlinked_cursor_skills \
  "error: refusing to use symlinked skills directory: $HOME/.cursor/skills"
check_refusal cursor custom_codex_home \
  "error: Cursor loads Codex skills only from ~/.codex/skills; CODEX_HOME=$TEST_ROOT/user/codex is not supported"
check_refusal antigravity unmanaged_antigravity_skill \
  "error: refusing to overwrite an unmanaged skill: $HOME/.gemini/antigravity-cli/skills/ralph-run"
check_refusal antigravity symlinked_antigravity_skills \
  "error: refusing to use symlinked skills directory: $HOME/.gemini/antigravity-cli/skills"
check_refusal antigravity symlinked_agents_md \
  "error: refusing to replace non-regular AGENTS.md: $HOME/.gemini/AGENTS.md"
# A skills directory, or a path between it and the home, that is not a directory: a file, or a symlink
# to nothing. Setup would fail on it only when it installs the skill, after changing other settings.
file_cursor_skills() { mkdir -p "$HOME/.cursor"; printf 'user file\n' > "$HOME/.cursor/skills"; }
dangling_cursor_dir() { ln -s "$TEST_ROOT/user/missing" "$HOME/.cursor"; }
file_antigravity_cli() { mkdir -p "$HOME/.gemini"; printf 'user file\n' > "$HOME/.gemini/antigravity-cli"; }
dangling_antigravity_cli() {
  mkdir -p "$HOME/.gemini"
  ln -s "$TEST_ROOT/user/missing" "$HOME/.gemini/antigravity-cli"
}
check_refusal cursor file_cursor_skills \
  "error: refusing to use non-directory $HOME/.cursor/skills for the ralph-run-cursor skill"
check_refusal cursor dangling_cursor_dir \
  "error: refusing to use non-directory $HOME/.cursor for the ralph-run-cursor skill"
check_refusal antigravity file_antigravity_cli \
  "error: refusing to use non-directory $HOME/.gemini/antigravity-cli for the ralph-run skill"
check_refusal antigravity dangling_antigravity_cli \
  "error: refusing to use non-directory $HOME/.gemini/antigravity-cli for the ralph-run skill"
# The preflights run the installers' settings checks, which compose no guidance into TMPDIR.
check_refusal cursor cursor_hooks_without_version \
  "error: refusing to replace Cursor hooks file without \"version\": 1: $HOME/.cursor/hooks.json"
check_refusal antigravity invalid_antigravity_mcp \
  "error: refusing to replace invalid Antigravity MCP config $HOME/.gemini/config/mcp_config.json:"

# A settings file that turns invalid after the preflight passed makes install-cursor.py fail inside
# install_cursor_environment, which exits 1 and removes the guidance it composed into TMPDIR.
reset_case
expect_success preflight_cursor_environment
mkdir -p "$HOME/.cursor"
printf '{broken\n' > "$HOME/.cursor/hooks.json"
expect_refusal "error: refusing to replace invalid Cursor hooks file $HOME/.cursor/hooks.json:" \
  install_cursor_environment

# install_guidance_block keeps the user's text around the managed block, and refuses markers that
# do not pair up, since its filter would drop the text after them.
reset_case
agents="$HOME/.gemini/AGENTS.md"
begin='<!-- BEGIN codex-workstation-bootstrap -->'
end='<!-- END codex-workstation-bootstrap -->'
printf '%s\n' "$begin" 'new guidance' "$end" > "$TEST_ROOT/user/guidance.md"
mkdir -p "$HOME/.gemini"
printf '%s\n' 'user notes' "$begin" 'old guidance' "$end" 'more notes' > "$agents"
expect_success install_guidance_block "$agents" "$TEST_ROOT/user/guidance.md" Antigravity
for line in 'user notes' 'more notes' 'new guidance'; do
  grep -Fxq "$line" "$agents" || fail "the updated AGENTS.md lost: $line"
done
if grep -Fxq 'old guidance' "$agents"; then fail 'the old managed block was kept'; fi

# install_guidance_block does not grow AGENTS.md. install_twice TEXT runs it twice on the AGENTS.md
# prepared before; after either run the file holds exactly TEXT and then the managed block (the
# guidance and one more newline). So the block follows all of the user's text after one blank line,
# the blank lines an earlier run left around the block are dropped, and a second run changes nothing.
install_twice() {
  local expected="$TEST_ROOT/expected-AGENTS.md" run
  { printf '%s' "$1"; cat "$TEST_ROOT/user/guidance.md"; printf '\n'; } > "$expected"
  for run in first second; do
    expect_success install_guidance_block "$agents" "$TEST_ROOT/user/guidance.md" Antigravity
    cmp -s "$expected" "$agents" ||
      fail "the $run run wrote an unexpected AGENTS.md: $(diff <(cat -A "$expected") <(cat -A "$agents") || true)"
  done
}
rm "$agents"
install_twice ''
printf '%s\n' 'user notes' > "$agents"
install_twice $'user notes\n\n'
printf '%s\n' 'user notes' '' '' '' '' "$begin" 'old guidance' "$end" '' '' > "$agents"
install_twice $'user notes\n\n'
printf '%s\n' '' '' '' "$begin" 'old guidance' "$end" '' > "$agents"
install_twice ''
# Text the user wrote below the block stays, and the block moves after it.
printf '%s\n' 'user notes' "$begin" 'old guidance' "$end" 'more notes' > "$agents"
install_twice $'user notes\nmore notes\n\n'

for markers in begin-only end-only nested; do
  case "$markers" in
    begin-only) printf '%s\n' 'user notes' "$begin" 'old guidance' 'more notes' > "$agents" ;;
    end-only) printf '%s\n' 'user notes' 'more notes' "$end" > "$agents" ;;
    nested) printf '%s\n' "$begin" "$begin" 'old guidance' "$end" 'more notes' > "$agents" ;;
  esac
  expect_exit_1 'markers do not pair up' install_guidance_block "$agents" "$TEST_ROOT/user/guidance.md" Antigravity
  expect_home_unchanged
  expect_exit_1 'markers do not pair up' preflight_antigravity_environment
  expect_home_unchanged
  # Both check the markers in a dry run too.
  DRY_RUN=1 expect_refusal 'markers do not pair up' \
    install_guidance_block "$agents" "$TEST_ROOT/user/guidance.md" Antigravity
  DRY_RUN=1 expect_refusal 'markers do not pair up' preflight_antigravity_environment
done

# install_guidance_block checks its target before its dry-run return, so a dry run refuses a
# symlinked or non-regular AGENTS.md as well.
directory_agents_md() { mkdir -p "$HOME/.gemini/AGENTS.md"; }
for fixture in symlinked_agents_md directory_agents_md; do
  for dry_run in 0 1; do
    reset_case
    "$fixture"
    printf '%s\n' "$begin" 'new guidance' "$end" > "$TEST_ROOT/user/guidance.md"
    DRY_RUN="$dry_run" expect_refusal "error: refusing to replace non-regular AGENTS.md: $agents" \
      install_guidance_block "$agents" "$TEST_ROOT/user/guidance.md" Antigravity
  done
done

# install_guidance_block writes the new AGENTS.md into a temporary file next to it and moves that into
# place. An existing AGENTS.md keeps its mode and a new one gets the mode the umask gives; nothing else
# is left in the directory.
# with_umask MASK COMMAND...: run COMMAND under MASK (capture runs it in a subshell).
with_umask() { umask "$1"; shift; "$@"; }
# expect_agents_md MODE: AGENTS.md has MODE and is the only file in its directory.
expect_agents_md() {
  local mode others
  mode="$(stat -c '%a' "$agents")"
  [[ "$mode" == "$1" ]] || fail "AGENTS.md has mode $mode instead of $1"
  others="$(find "$(dirname "$agents")" -mindepth 1 ! -path "$agents")"
  [[ -z "$others" ]] || fail "install_guidance_block left files next to AGENTS.md: $others"
}
for mode in 600 640; do
  reset_case
  mkdir -p "$HOME/.gemini"
  printf '%s\n' "$begin" 'new guidance' "$end" > "$TEST_ROOT/user/guidance.md"
  printf '%s\n' 'user notes' "$begin" 'old guidance' "$end" > "$agents"
  chmod "$mode" "$agents"
  expect_success with_umask 022 install_guidance_block "$agents" "$TEST_ROOT/user/guidance.md" Antigravity
  expect_agents_md "$mode"
done
for umask_and_mode in '022 644' '027 640'; do
  read -r mask mode <<< "$umask_and_mode"
  reset_case
  printf '%s\n' "$begin" 'new guidance' "$end" > "$TEST_ROOT/user/guidance.md"
  expect_success with_umask "$mask" install_guidance_block "$agents" "$TEST_ROOT/user/guidance.md" Antigravity
  expect_agents_md "$mode"
done

# When the new AGENTS.md cannot be written (here its guidance cannot be read), the user's AGENTS.md is
# left exactly as it was, a missing one is not created, and neither the partial copy next to it nor
# any other temporary file is left behind.
for existing in yes no; do
  reset_case
  mkdir -p "$HOME/.gemini"
  if [[ "$existing" == yes ]]; then
    printf '%s\n' 'user notes' "$begin" 'old guidance' "$end" 'more notes' > "$agents"
    chmod 640 "$agents"
    cp -p "$agents" "$TEST_ROOT/AGENTS.md.before"
  fi
  capture install_guidance_block "$agents" "$TEST_ROOT/user/missing-guidance.md" Antigravity
  [[ "$status" -eq 1 ]] || fail "install_guidance_block exited $status without its guidance"
  [[ "$out" == *"error: could not write $agents"* ]] || fail 'a failed write did not name AGENTS.md'
  if [[ "$existing" == yes ]]; then
    cmp -s "$TEST_ROOT/AGENTS.md.before" "$agents" ||
      fail "a failed write changed AGENTS.md: $(diff "$TEST_ROOT/AGENTS.md.before" "$agents" || true)"
    [[ "$(stat -c '%a' "$agents")" == 640 ]] || fail "a failed write changed the mode of AGENTS.md"
  elif [[ -e "$agents" || -L "$agents" ]]; then
    fail 'a failed write created AGENTS.md'
  fi
  others="$(find "$HOME/.gemini" -mindepth 1 ! -path "$agents")"
  [[ -z "$others" ]] || fail "a failed write left files next to AGENTS.md: $others"
  leftovers="$(find "$TMPDIR" -mindepth 1)"
  [[ -z "$leftovers" ]] || fail "a failed write left temporary files behind: $leftovers"
done

leftovers="$(find "$TMPDIR" -mindepth 1)"
[[ -z "$leftovers" ]] || fail "temporary files were left behind: $leftovers"
printf 'PASS: Cursor CLI and Antigravity CLI install, update and setup refusal checks.\n'
