#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

export HOME="$TEST_ROOT/home"
export CODEX_HOME="$HOME/.codex"
mkdir -p "$CODEX_HOME"

# shellcheck source=../install.sh
source "$PROJECT_ROOT/install.sh"

model_config="$CODEX_HOME/config.toml"
cat > "$model_config" <<'EOF'
model = "gpt-test-model"

[desktop]
model = "ignored-nested-model"
EOF

[[ "$(read_top_level_model "$model_config")" == "gpt-test-model" ]]

printf 'model = "gpt-comment-model" # keep this model\n' > "$model_config"
[[ "$(read_top_level_model "$model_config")" == "gpt-comment-model" ]]
printf '[desktop]\nmodel = "nested-only"\n' > "$model_config"
[[ -z "$(read_top_level_model "$model_config")" ]]

valid_app_home="/mnt/c/Users/bootstrap-test/.codex"
[[ "$(validate_codex_app_home "$valid_app_home")" == "$valid_app_home" ]]

set +e
invalid_output="$(validate_codex_app_home "$TEST_ROOT/not-windows/.codex" 2>&1)"
invalid_status=$?
set -e
[[ "$invalid_status" -eq 1 ]]
grep -Fq 'CODEX_APP_HOME must be a Windows user .codex directory' <<< "$invalid_output"

set +e
nested_output="$(validate_codex_app_home '/mnt/c/Users/bootstrap-test/Documents/.codex' 2>&1)"
nested_status=$?
set -e
[[ "$nested_status" -eq 1 ]]
grep -Fq 'CODEX_APP_HOME must be a Windows user .codex directory' <<< "$nested_output"

calls_file="$TEST_ROOT/app-calls.txt"
install_gstack() { printf 'gstack:%s\n' "$1" >> "$calls_file"; }
install_ralph() { printf 'ralph:%s\n' "$1" >> "$calls_file"; }
install_local_skills() { printf 'local-skills:%s\n' "$1" >> "$calls_file"; }
install_agents_guidance() { printf 'agents:%s\n' "$1" >> "$calls_file"; }
install_rtk_hook() { printf 'rtk-hook:%s\n' "$1" >> "$calls_file"; }

app_fixture="$TEST_ROOT/windows-home/.codex"
mkdir -p "$app_fixture"
validate_codex_app_home() { printf '%s\n' "$app_fixture"; }

mkdir -p "$app_fixture/skills/gstack"
printf 'user-owned\n' > "$app_fixture/skills/gstack/SKILL.md"
printf '[desktop]\nrunCodexInWindowsSubsystemForLinux = true\n' > "$app_fixture/config.toml"
set +e
unmanaged_gstack_output="$(CODEX_APP_HOME="$valid_app_home" prepare_codex_app_environment 2>&1)"
unmanaged_gstack_status=$?
set -e
[[ "$unmanaged_gstack_status" -eq 1 ]]
grep -Fq 'refusing to overwrite an unmanaged App gstack directory' <<< "$unmanaged_gstack_output"
touch "$app_fixture/skills/gstack/$MANAGED_MARKER"

printf '[desktop]\nrunCodexInWindowsSubsystemForLinux = false\n' > "$app_fixture/config.toml"
set +e
wsl_mode_output="$(CODEX_APP_HOME="$valid_app_home" prepare_codex_app_environment 2>&1)"
wsl_mode_status=$?
set -e
[[ "$wsl_mode_status" -eq 1 ]]
grep -Fq 'Codex App must use WSL agent execution' <<< "$wsl_mode_output"

rm "$app_fixture/config.toml"
set +e
missing_config_output="$(CODEX_APP_HOME="$valid_app_home" prepare_codex_app_environment 2>&1)"
missing_config_status=$?
set -e
[[ "$missing_config_status" -eq 1 ]]
grep -Fq 'Codex App config was not found' <<< "$missing_config_output"

printf '[desktop]\nrunCodexInWindowsSubsystemForLinux = true\n' > "$app_fixture/config.toml"
DRY_RUN=1
CODEX_APP_HOME="$valid_app_home"
prepare_codex_app_environment
install_codex_app_environment >/dev/null

grep -Fxq "gstack:$app_fixture" "$calls_file"
grep -Fxq "ralph:$app_fixture" "$calls_file"
grep -Fxq "local-skills:$app_fixture" "$calls_file"
grep -Fxq "agents:$app_fixture" "$calls_file"
grep -Fxq "rtk-hook:$app_fixture" "$calls_file"

validate_codex_app_home() { printf '%s\n' ''; }
CODEX_APP_HOME="$valid_app_home"
prepare_codex_app_environment
[[ -z "$CODEX_APP_DIR" ]]

printf 'PASS: Codex App home validation, model reuse, and dual registration.\n'
