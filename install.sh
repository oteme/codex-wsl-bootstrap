#!/usr/bin/env bash
set -euo pipefail

readonly GSTACK_REPO="https://github.com/garrytan/gstack.git"
readonly GSTACK_REF_DEFAULT="85fd9db554ae4aaaa6d356d2daf873121ee85bdd"
readonly RALPH_REPO="https://github.com/snarktank/ralph.git"
readonly RALPH_REF_DEFAULT="6c53cb0b831ebe8739c6a003e22af14902d8b0b5"
readonly RTK_VERSION_DEFAULT="0.46.0"
readonly RTK_X86_64_SHA256="79aa5b89c69566bbfeceb66c8a27cfbe52237fc7ee3e683115f43745a3262d21"
readonly RTK_AARCH64_SHA256="e8c2e1787f46017ea7c5a711b2bc6a7f7cf61c7ad69385b4c1e4daff1135dcd1"
readonly MANAGED_MARKER=".codex-workstation-bootstrap-managed"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/agent-cli.sh
source "$SCRIPT_DIR/scripts/agent-cli.sh"
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
SKILLS_DIR="$CODEX_DIR/skills"
BOOTSTRAP_STATE_DIR="${BOOTSTRAP_STATE_DIR:-$HOME/.local/share/codex-workstation-bootstrap}"
GSTACK_DIR="${GSTACK_INSTALL_DIR:-$BOOTSTRAP_STATE_DIR/gstack}"
RALPH_SOURCE_DIR="${RALPH_SOURCE_DIR:-$BOOTSTRAP_STATE_DIR/ralph}"
GSTACK_REF="${GSTACK_REF:-$GSTACK_REF_DEFAULT}"
RALPH_REF="${RALPH_REF:-$RALPH_REF_DEFAULT}"
RTK_VERSION="$RTK_VERSION_DEFAULT"
DRY_RUN=0
CODEX_APP_DIR=""

# Non-interactive WSL launches do not necessarily load shell profile PATH entries.
export PATH="$HOME/.local/bin:$HOME/.codex/bin:$HOME/.bun/bin:$PATH"

usage() {
  cat <<'EOF'
Usage: ./install.sh [--dry-run]

Installs Codex CLI, RTK Safe Hook, Bun, gstack, Ralph skills, and shared AGENTS.md guidance
for an existing Ubuntu/WSL2 environment, then sets up Cursor CLI and Antigravity CLI with the
same guidance, skills, Chrome MCP servers, RTK Safe Hook and Ralph runner.

Environment overrides:
  CODEX_HOME          Codex data directory; must resolve to ~/.codex, because Cursor loads
                      Codex skills only from there (another value stops setup before any change)
  CODEX_APP_HOME      Codex App data directory exposed to WSL (optional)
  BOOTSTRAP_STATE_DIR Bootstrap-managed source checkouts
                      (default: ~/.local/share/codex-workstation-bootstrap)
  GSTACK_INSTALL_DIR  gstack checkout (default: <bootstrap state>/gstack)
  GSTACK_REF          gstack git ref/commit
  RALPH_SOURCE_DIR    Ralph source checkout
  RALPH_REF           Ralph git ref/commit
EOF
}

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

log() {
  printf '\n==> %s\n' "$*"
}

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '+ '
    printf '%q ' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

ensure_ubuntu_wsl() {
  if [[ ! -r /etc/os-release ]]; then
    echo "error: /etc/os-release was not found; this installer targets Ubuntu/WSL2" >&2
    exit 1
  fi

  # shellcheck disable=SC1091
  source /etc/os-release
  if [[ "${ID:-}" != "ubuntu" ]]; then
    echo "error: unsupported Linux distribution: ${ID:-unknown} (expected Ubuntu)" >&2
    exit 1
  fi
}

ensure_base_tools() {
  local missing=()
  local tool
  for tool in curl git python3 xz; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  [[ "${#missing[@]}" -eq 0 ]] && return

  log "Installing base packages: ${missing[*]}"
  local sudo_cmd=()
  if [[ "$EUID" -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || {
      echo "error: sudo is required to install: ${missing[*]}" >&2
      exit 1
    }
    sudo_cmd=(sudo)
  fi
  run "${sudo_cmd[@]}" apt-get update
  run "${sudo_cmd[@]}" apt-get install -y ca-certificates curl git python3 xz-utils
}

download_and_run() {
  local url="$1"
  local label="$2"
  local installer
  installer="$(mktemp)"
  trap 'rm -f "${installer:-}"' RETURN
  curl -fsSL "$url" -o "$installer"
  NON_INTERACTIVE=1 bash "$installer" "${@:3}"
  rm -f "$installer"
  trap - RETURN
  log "$label installed"
}

ensure_codex() {
  if command -v codex >/dev/null 2>&1; then
    log "Codex CLI already present: $(codex --version)"
    return
  fi
  [[ "$DRY_RUN" -eq 1 ]] && { log "Would install Codex CLI from the official installer"; return; }
  log "Installing Codex CLI"
  download_and_run "https://chatgpt.com/codex/install.sh" "Codex CLI"
  export PATH="$HOME/.local/bin:$HOME/.codex/bin:$PATH"
  command -v codex >/dev/null 2>&1 || {
    echo "error: Codex installed, but codex is not on PATH; open a new shell and rerun this installer" >&2
    exit 1
  }
}

ensure_bun() {
  if command -v bun >/dev/null 2>&1; then
    log "Bun already present: $(bun --version)"
    return
  fi
  [[ "$DRY_RUN" -eq 1 ]] && { log "Would install Bun"; return; }
  log "Installing Bun"
  download_and_run "https://bun.sh/install" "Bun"
  export PATH="$HOME/.bun/bin:$PATH"
  command -v bun >/dev/null 2>&1 || {
    echo "error: Bun installed, but bun is not on PATH; open a new shell and rerun this installer" >&2
    exit 1
  }
}

ensure_rtk() {
  local current_version=""
  if command -v rtk >/dev/null 2>&1; then
    current_version="$(rtk --version 2>/dev/null | awk '{print $2}')"
  fi
  if [[ "$current_version" == "$RTK_VERSION" ]]; then
    log "RTK already present: rtk $current_version"
    return
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Would install RTK $RTK_VERSION with checksum verification"
    return
  fi

  local architecture asset checksum temporary_dir archive
  architecture="$(uname -m)"
  case "$architecture" in
    x86_64)
      asset="rtk-x86_64-unknown-linux-musl.tar.gz"
      checksum="$RTK_X86_64_SHA256"
      ;;
    aarch64|arm64)
      asset="rtk-aarch64-unknown-linux-gnu.tar.gz"
      checksum="$RTK_AARCH64_SHA256"
      ;;
    *)
      echo "error: unsupported RTK architecture: $architecture" >&2
      exit 1
      ;;
  esac

  temporary_dir="$(mktemp -d)"
  archive="$temporary_dir/$asset"
  cleanup_rtk_download() {
    if [[ -n "$temporary_dir" && -d "$temporary_dir" ]]; then
      rm -r -- "$temporary_dir"
    fi
  }
  trap cleanup_rtk_download RETURN
  log "Installing RTK $RTK_VERSION"
  curl -fsSL "https://github.com/rtk-ai/rtk/releases/download/v$RTK_VERSION/$asset" -o "$archive"
  printf '%s  %s\n' "$checksum" "$archive" | sha256sum --check --status || {
    echo "error: RTK archive checksum mismatch" >&2
    exit 1
  }
  tar -xzf "$archive" -C "$temporary_dir"
  [[ -x "$temporary_dir/rtk" ]] || {
    echo "error: RTK archive did not contain an executable rtk binary" >&2
    exit 1
  }
  run mkdir -p "$HOME/.local/bin"
  run install -m 0755 "$temporary_dir/rtk" "$HOME/.local/bin/rtk"
  rm -r -- "$temporary_dir"
  trap - RETURN
  [[ "$(rtk --version | awk '{print $2}')" == "$RTK_VERSION" ]] || {
    echo "error: installed RTK version does not match $RTK_VERSION" >&2
    exit 1
  }
}

install_rtk_hook() {
  local target_codex_dir="${1:-$CODEX_DIR}"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "+ install Codex RTK Safe Hook -> $target_codex_dir/hooks/rtk-safe"
    echo "+ merge managed PreToolUse entry -> $target_codex_dir/hooks.json"
    return
  fi
  python3 "$SCRIPT_DIR/scripts/install-codex-rtk-hook.py" \
    --codex-dir "$target_codex_dir" \
    --hook-source "$SCRIPT_DIR/hooks/rtk-codex-safe-hook.py" \
    --test-source "$SCRIPT_DIR/hooks/test-rtk-codex-safe-hook.sh" \
    --rtk-version "$RTK_VERSION"
  log "Installed Codex RTK Safe Hook"
}

checkout_repo() {
  local repo="$1"
  local ref="$2"
  local destination="$3"
  local label="$4"

  if [[ -e "$destination" && ! -d "$destination/.git" ]]; then
    echo "error: $destination exists but is not a git checkout; move it aside and rerun" >&2
    exit 1
  fi

  if [[ ! -d "$destination/.git" ]]; then
    run mkdir -p "$(dirname "$destination")"
    run git clone --filter=blob:none --no-checkout "$repo" "$destination"
  else
    local actual_remote
    actual_remote="$(git -C "$destination" remote get-url origin)"
    if [[ "$actual_remote" != "$repo" && "$actual_remote" != "${repo%.git}" ]]; then
      echo "error: $destination has an unexpected origin: $actual_remote" >&2
      exit 1
    fi
    if [[ -n "$(git -C "$destination" status --porcelain)" ]]; then
      echo "error: $destination contains local changes; commit or move them before rerunning" >&2
      exit 1
    fi
  fi

  log "Checking out $label at $ref"
  run git -C "$destination" fetch --depth 1 origin "$ref"
  run git -C "$destination" checkout --detach FETCH_HEAD
}

install_skill() {
  local source_dir="$1"
  local skill_name="$2"
  local target_skills_dir="${3:-$SKILLS_DIR}"
  local instructions_overlay="${4:-}"
  local destination="$target_skills_dir/$skill_name"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "+ install skill $skill_name -> $destination"
    return
  fi

  bash "$SCRIPT_DIR/scripts/install-skill.sh" \
    "$source_dir" "$destination" "$MANAGED_MARKER" "$instructions_overlay"
  log "Installed skill: $skill_name"
}

read_top_level_model() {
  local config_file="$1"
  [[ -f "$config_file" ]] || return 0
  python3 - "$config_file" <<'PY'
import re
import sys

path = sys.argv[1]
with open(path, "rb") as config:
    raw = config.read()

try:
    import tomllib
except ModuleNotFoundError:
    # Ubuntu 22.04 ships Python 3.10. This fallback recognizes the complete
    # top-level string form Codex uses, including quoted keys and indented
    # table headers, without mistaking a nested model for the root setting.
    text = raw.decode("utf-8")
    key = re.compile(r'''^(?:model|"model"|'model')\s*=\s*(["'])(.*?)\1(?:\s*#.*)?$''')
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("["):
            break
        match = key.match(stripped)
        if match:
            print(match.group(2))
            break
else:
    data = tomllib.loads(raw.decode("utf-8"))
    model = data.get("model")
    if model is not None:
        if not isinstance(model, str):
            raise SystemExit("error: top-level Codex model must be a TOML string")
        print(model)
PY
}

resolve_cli_model() {
  local configured_model
  configured_model="$(read_top_level_model "$CODEX_DIR/config.toml")"
  printf '%s\n' "${configured_model:-gpt}"
}

prepare_sources() {
  checkout_repo "$GSTACK_REPO" "$GSTACK_REF" "$GSTACK_DIR" "gstack"
  checkout_repo "$RALPH_REPO" "$RALPH_REF" "$RALPH_SOURCE_DIR" "Ralph"
}

install_gstack() {
  local target_codex_dir="${1:-$CODEX_DIR}"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "+ (cd $GSTACK_DIR && CODEX_HOME=$target_codex_dir ./setup --host codex --prefix)"
    return
  fi
  log "Building and registering gstack skills"
  local setup_args=(--host codex --prefix)
  local cli_model=""
  if [[ "$target_codex_dir" != "$CODEX_DIR" ]]; then
    cli_model="$(resolve_cli_model)"
    setup_args+=(--model "$cli_model")
  fi
  (cd "$GSTACK_DIR" && CODEX_HOME="$target_codex_dir" ./setup "${setup_args[@]}")
}

install_ralph() {
  local target_codex_dir="${1:-$CODEX_DIR}"
  local target_skills_dir="$target_codex_dir/skills"
  run mkdir -p "$target_skills_dir"
  install_skill "$RALPH_SOURCE_DIR/skills/prd" "prd" "$target_skills_dir" "$SCRIPT_DIR/config/prd-fail-close-clean-break.md"
  install_skill "$RALPH_SOURCE_DIR/skills/ralph" "ralph" "$target_skills_dir" "$SCRIPT_DIR/config/ralph-fail-close-clean-break.md"
  install_skill "$SCRIPT_DIR/skills/ralph-bootstrap" "ralph-bootstrap" "$target_skills_dir"
  install_skill "$SCRIPT_DIR/skills/ralph-run" "ralph-run" "$target_skills_dir"
  run python3 "$SCRIPT_DIR/skills/ralph-run/scripts/ralph_runtime.py" \
    --record "$target_skills_dir/ralph-run/scripts/codex-runtime.json" \
    --codex "$(type -P codex)"
}

install_local_skills() {
  local target_codex_dir="${1:-$CODEX_DIR}"
  local target_skills_dir="$target_codex_dir/skills"
  run mkdir -p "$target_skills_dir"
  install_skill "$SCRIPT_DIR/skills/go-backend" "go-backend" "$target_skills_dir"
  install_skill "$SCRIPT_DIR/skills/orca-cli" "orca-cli" "$target_skills_dir"
  install_skill "$SCRIPT_DIR/skills/computer-use" "computer-use" "$target_skills_dir"
}

install_agents_guidance() {
  local target_codex_dir="${1:-$CODEX_DIR}"
  install_guidance_block "$target_codex_dir/AGENTS.md" "$SCRIPT_DIR/config/AGENTS.global.md" "Codex"
}

# An instructions file setup would refuse: a symlink or other non-regular file, or managed-block
# markers that do not pair up. The filter in install_guidance_block drops everything from a BEGIN
# marker to its END marker, so an unpaired marker would silently drop the text the user wrote after
# it. main() and the preflights call this before anything changes.
check_guidance_target() {
  local agents_file="$1"
  if [[ -L "$agents_file" ]] || [[ -e "$agents_file" && ! -f "$agents_file" ]]; then
    echo "error: refusing to replace non-regular $(basename "$agents_file"): $agents_file" >&2
    exit 1
  fi
  [[ -f "$agents_file" ]] || return 0
  if ! awk '
    $0 == "<!-- BEGIN codex-workstation-bootstrap -->" { if (open) { bad = 1; exit } open = 1; next }
    $0 == "<!-- END codex-workstation-bootstrap -->" { if (!open) { bad = 1; exit } open = 0 }
    END { exit (bad || open) ? 1 : 0 }
  ' "$agents_file"; then
    echo "error: refusing to update $agents_file: its codex-workstation-bootstrap BEGIN and END markers do not pair up" >&2
    exit 1
  fi
}

# Replace the bootstrap-managed block in an instructions file, keeping everything else the user wrote.
install_guidance_block() {
  local agents_file="$1"
  local guidance="$2"
  local label="$3"
  local filtered replacement

  check_guidance_target "$agents_file"
  run mkdir -p "$(dirname "$agents_file")"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "+ update managed block in $agents_file"
    return
  fi

  filtered="$(mktemp)"
  if [[ -f "$agents_file" ]]; then
    # Drop the managed block, and hold blank lines back until more text follows: the blank lines an
    # earlier run left around the block are not kept, so the file does not grow with every run.
    awk '
      $0 == "<!-- BEGIN codex-workstation-bootstrap -->" { skip = 1; next }
      $0 == "<!-- END codex-workstation-bootstrap -->" { skip = 0; next }
      skip { next }
      $0 == "" { blank++; next }
      { for (; blank > 0; blank--) print ""; print }
    ' "$agents_file" > "$filtered"
  fi

  # Write next to the file and move it into place, so that a failed write (a full disk) leaves the
  # user's file as it was. Each step is chained explicitly, so a failure also removes the partial
  # copy instead of leaving it next to the user's file.
  replacement="$(mktemp "$(dirname "$agents_file")/.$(basename "$agents_file").XXXXXX")"
  if ! {
    cat "$filtered" &&
      { [[ ! -s "$filtered" ]] || printf '\n'; } &&
      cat "$guidance" &&
      printf '\n'
  } > "$replacement" ||
    ! if [[ -f "$agents_file" ]]; then
      chmod --reference="$agents_file" "$replacement"
    else
      chmod "$(printf '%04o' $((0666 & ~$(umask))))" "$replacement"
    fi ||
    ! mv -f -- "$replacement" "$agents_file"; then
    rm -f -- "$replacement" "$filtered"
    echo "error: could not write $agents_file" >&2
    exit 1
  fi
  rm -f "$filtered"
  log "Updated shared $label guidance: $agents_file"
}

validate_codex_app_home() {
  local candidate="$1"
  local normalized
  normalized="$(realpath -m "$candidate")"

  if [[ ! "$normalized" =~ ^/mnt/[[:alpha:]]/Users/[^/]+/\.codex$ ]]; then
    echo "error: CODEX_APP_HOME must be a Windows user .codex directory exposed under /mnt/<drive>/Users: $candidate" >&2
    exit 1
  fi

  if [[ "$normalized" == "$(realpath -m "$CODEX_DIR")" ]]; then
    printf '%s\n' ""
  else
    printf '%s\n' "$normalized"
  fi
}

validate_app_gstack_target() {
  local target_codex_dir="$1"
  local target="$target_codex_dir/skills/gstack"
  [[ -e "$target" || -L "$target" ]] || return 0
  [[ -f "$target/$MANAGED_MARKER" ]] && return 0

  if [[ -L "$target" ]] && \
    [[ "$(realpath -m "$target")" == "$(realpath -m "$GSTACK_DIR")" ]]; then
    return 0
  fi

  if [[ -d "$target" && -L "$target/SKILL.md" && -L "$target/bin" ]] && \
    [[ "$(realpath -m "$target/SKILL.md")" == "$(realpath -m "$GSTACK_DIR/.agents/skills/gstack/SKILL.md")" ]] && \
    [[ "$(realpath -m "$target/bin")" == "$(realpath -m "$GSTACK_DIR/bin")" ]]; then
    return 0
  fi

  echo "error: refusing to overwrite an unmanaged App gstack directory: $target" >&2
  exit 1
}

validate_app_managed_skill_target() {
  local target_codex_dir="$1"
  local skill_name="$2"
  local target="$target_codex_dir/skills/$skill_name"
  [[ -e "$target" || -L "$target" ]] || return 0
  [[ ! -L "$target" && -f "$target/$MANAGED_MARKER" ]] && return 0

  echo "error: refusing to overwrite an unmanaged App skill: $target" >&2
  exit 1
}

validate_app_gstack_skill_targets() {
  local target_codex_dir="$1"
  local source target skill_name
  [[ "$DRY_RUN" -eq 0 ]] || return 0

  for source in "$GSTACK_DIR"/.agents/skills/gstack*/; do
    [[ -f "$source/SKILL.md" ]] || continue
    skill_name="$(basename "$source")"
    [[ "$skill_name" != "gstack" ]] || continue
    target="$target_codex_dir/skills/$skill_name"
    [[ -e "$target" || -L "$target" ]] || continue
    if [[ -L "$target" ]] && \
      [[ "$(realpath -m "$target")" == "$(realpath -m "$source")" ]]; then
      continue
    fi
    echo "error: refusing to retain an unmanaged App gstack skill: $target" >&2
    exit 1
  done
}

validate_app_install_targets() {
  local target_codex_dir="$1"
  local skill_name
  if [[ -L "$target_codex_dir/skills" ]]; then
    echo "error: refusing to use symlinked App skills directory: $target_codex_dir/skills" >&2
    exit 1
  fi
  validate_app_gstack_target "$target_codex_dir"
  validate_app_gstack_skill_targets "$target_codex_dir"
  for skill_name in prd ralph ralph-bootstrap ralph-run go-backend orca-cli computer-use; do
    validate_app_managed_skill_target "$target_codex_dir" "$skill_name"
  done
  check_guidance_target "$target_codex_dir/AGENTS.md"
  python3 "$SCRIPT_DIR/scripts/install-codex-rtk-hook.py" \
    --codex-dir "$target_codex_dir" \
    --hook-source "$SCRIPT_DIR/hooks/rtk-codex-safe-hook.py" \
    --test-source "$SCRIPT_DIR/hooks/test-rtk-codex-safe-hook.sh" \
    --rtk-version "$RTK_VERSION" \
    --check-only
}

install_codex_app_environment() {
  [[ -n "$CODEX_APP_DIR" ]] || {
    if [[ -n "${CODEX_APP_HOME:-}" ]]; then
      log "Codex App already uses the CLI CODEX_HOME"
    else
      log "Codex App environment not requested; CLI bootstrap only"
    fi
    return
  }

  log "Installing shared bootstrap into Codex App: $CODEX_APP_DIR"
  run mkdir -p "$CODEX_APP_DIR/skills"
  install_gstack "$CODEX_APP_DIR"
  run touch "$CODEX_APP_DIR/skills/gstack/$MANAGED_MARKER"
  install_ralph "$CODEX_APP_DIR"
  install_local_skills "$CODEX_APP_DIR"
  install_agents_guidance "$CODEX_APP_DIR"
  install_rtk_hook "$CODEX_APP_DIR"
  install_chrome_mcp "$CODEX_APP_DIR" --app
}

prepare_codex_app_environment() {
  [[ -n "${CODEX_APP_HOME:-}" ]] || return 0
  CODEX_APP_DIR="$(validate_codex_app_home "$CODEX_APP_HOME")"
  [[ -n "$CODEX_APP_DIR" ]] || return 0

  local app_config="$CODEX_APP_DIR/config.toml"
  if [[ ! -f "$app_config" ]]; then
    echo "error: Codex App config was not found: $app_config; open the App, enable WSL agent execution, then rerun" >&2
    exit 1
  fi
  if ! grep -Eq '^[[:space:]]*runCodexInWindowsSubsystemForLinux[[:space:]]*=[[:space:]]*true([[:space:]]*(#.*)?)?$' "$app_config"; then
    echo "error: Codex App must use WSL agent execution; enable it in the App, then rerun" >&2
    exit 1
  fi
}

preflight_codex_app_environment() {
  [[ -n "$CODEX_APP_DIR" ]] || return 0
  validate_app_install_targets "$CODEX_APP_DIR"
}

install_chrome_mcp() {
  local target_codex_dir="${1:-$CODEX_DIR}"
  local mode="${2:-}"
  if [[ -n "${CODEX_APP_HOME:-}" && "$(realpath -m "$target_codex_dir")" == "$(realpath -m "$CODEX_APP_HOME")" ]]; then
    mode=--app
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Would register Chrome MCP ports 9222 + 9223: $target_codex_dir"
    return
  fi
  local args=(--codex-home "$target_codex_dir" --install)
  [[ -z "$mode" ]] || args+=("$mode")
  python3 "$SCRIPT_DIR/scripts/chrome-devtools-mcp.py" "${args[@]}"
}

preflight_chrome_mcp() {
  [[ "$DRY_RUN" -eq 0 ]] || return 0
  local args=(--codex-home "$CODEX_DIR" --preflight)
  if [[ -n "${CODEX_APP_HOME:-}" && "$(realpath -m "$CODEX_DIR")" == "$(realpath -m "$CODEX_APP_HOME")" ]]; then
    args+=(--app)
  fi
  python3 "$SCRIPT_DIR/scripts/chrome-devtools-mcp.py" "${args[@]}"
  if [[ -n "$CODEX_APP_DIR" ]]; then
    python3 "$SCRIPT_DIR/scripts/chrome-devtools-mcp.py" --codex-home "$CODEX_APP_DIR" --app --preflight
  fi
}

# Cursor CLI and Antigravity CLI are set up after the Codex setup is complete and reuse its skills:
# Cursor loads ~/.codex/skills by itself, and Antigravity registers that directory in skills.json.
# Each gets its own guidance, hooks, Chrome MCP servers and Ralph runner.

# ensure_agent_cli LABEL COMMAND VERSION_FUNCTION MINIMUM INSTALLER_URL [INSTALLER_ARGS...]
ensure_agent_cli() {
  local label="$1" command_name="$2" version_function="$3" minimum="$4" url="$5"
  local installer_args=("${@:6}")
  local version=""

  if command -v "$command_name" >/dev/null 2>&1; then
    if ! version="$("$version_function")"; then
      echo "error: unrecognized $label version: $("$command_name" --version 2>&1 | head -n 1)" >&2
      exit 1
    fi
    if version_at_least "$version" "$minimum"; then
      log "$label already present: $version"
      return
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "Would update $label $version to at least $minimum"
      return
    fi
    log "Updating $label $version to at least $minimum"
    "$command_name" update < /dev/null
  else
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "Would install $label from the official installer"
      return
    fi
    log "Installing $label"
    download_and_run "$url" "$label" "${installer_args[@]}"
    command -v "$command_name" >/dev/null 2>&1 || {
      echo "error: $label installed, but $command_name is not on PATH; open a new shell and rerun this installer" >&2
      exit 1
    }
  fi
  if ! version="$("$version_function")" || ! version_at_least "$version" "$minimum"; then
    echo "error: $label ${version:-with an unrecognized version} is older than the verified minimum $minimum" >&2
    exit 1
  fi
}

ensure_cursor_cli() {
  ensure_agent_cli "Cursor CLI" agent cursor_version "$CURSOR_MIN_VERSION" "https://cursor.com/install"
}

ensure_antigravity_cli() {
  # The flags keep the installer from editing shell profiles; ~/.local/bin is already required on PATH.
  ensure_agent_cli "Antigravity CLI" agy antigravity_version "$ANTIGRAVITY_MIN_VERSION" \
    "https://antigravity.google/cli/install.sh" --skip-path --skip-aliases
}

compose_guidance() {
  local agent="$1"
  local output="$2"
  python3 "$SCRIPT_DIR/scripts/compose-guidance.py" --agent "$agent" \
    --global-guidance "$SCRIPT_DIR/config/AGENTS.global.md" \
    --guidance-dir "$SCRIPT_DIR/config/guidance" --output "$output"
}

# An agent's Ralph skill: its own SKILL.md, runner and assets plus the loop files shared with Codex.
stage_agent_ralph_skill() {
  local agent="$1"
  local stage="$2"
  local shared="$SCRIPT_DIR/skills/ralph-run"
  mkdir -p "$stage/scripts" "$stage/assets"
  (cd "$SCRIPT_DIR/skills/ralph-run-$agent" && tar --exclude='__pycache__' -cf - .) \
    | (cd "$stage" && tar -xf -)
  cp -p "$shared/scripts/ralph-loop.sh" "$shared/scripts/ralph-notify.py" \
    "$shared/scripts/ralph-state.py" "$shared/scripts/ralph_runtime.py" \
    "$shared/scripts/ralph_models.py" "$stage/scripts/"
  cp -p "$shared/assets/worker-protocol.md" "$shared/assets/policy-review.schema.json" "$stage/assets/"
}

validate_agent_skill_target() {
  local skills_dir="$1"
  local skill_name="$2"
  local target="$skills_dir/$skill_name"
  local path="$skills_dir"
  if [[ -L "$skills_dir" ]]; then
    echo "error: refusing to use symlinked skills directory: $skills_dir" >&2
    exit 1
  fi
  # A file (or a dangling link) on the way would stop the skill install only after setup has changed
  # other settings.
  while [[ "$path" != "$HOME" && "$path" != / && "$path" != . ]]; do
    if [[ -e "$path" && ! -d "$path" ]] || [[ -L "$path" && ! -e "$path" ]]; then
      echo "error: refusing to use non-directory $path for the $skill_name skill" >&2
      exit 1
    fi
    path="$(dirname "$path")"
  done
  [[ -e "$target" || -L "$target" ]] || return 0
  [[ ! -L "$target" && -f "$target/$MANAGED_MARKER" ]] && return 0
  echo "error: refusing to overwrite an unmanaged skill: $target" >&2
  exit 1
}

install_agent_ralph_skill() {
  local agent="$1" skill_name="$2" skills_dir="$3" command_name="$4"
  local stage
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "+ install skill $skill_name -> $skills_dir/$skill_name"
    return
  fi
  stage="$(mktemp -d)"
  stage_agent_ralph_skill "$agent" "$stage/$skill_name"
  mkdir -p "$skills_dir"
  install_skill "$stage/$skill_name" "$skill_name" "$skills_dir"
  rm -r -- "$stage"
  python3 "$skills_dir/$skill_name/scripts/ralph_runtime.py" \
    --record "$skills_dir/$skill_name/scripts/$agent-runtime.json" "--$agent" "$(type -P "$command_name")"
}

preflight_cursor_environment() {
  if [[ "$(realpath -m "$CODEX_DIR")" != "$(realpath -m "$HOME/.codex")" ]]; then
    echo "error: Cursor loads Codex skills only from ~/.codex/skills; CODEX_HOME=$CODEX_DIR is not supported" >&2
    exit 1
  fi
  validate_agent_skill_target "$HOME/.cursor/skills" ralph-run-cursor
  python3 "$SCRIPT_DIR/scripts/install-cursor.py" --cursor-dir "$HOME/.cursor" \
    --hook-source-dir "$SCRIPT_DIR/hooks" --check-only
}

install_cursor_environment() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "+ register Cursor hooks, guidance and Chrome MCP servers -> $HOME/.cursor"
    install_agent_ralph_skill cursor ralph-run-cursor "$HOME/.cursor/skills" agent
    return
  fi
  local guidance
  guidance="$(mktemp)"
  # errexit would skip the rm below, so a failed step removes the temporary file itself.
  compose_guidance cursor "$guidance" || { rm -f "$guidance"; exit 1; }
  python3 "$SCRIPT_DIR/scripts/install-cursor.py" --cursor-dir "$HOME/.cursor" \
    --hook-source-dir "$SCRIPT_DIR/hooks" --guidance-file "$guidance" || { rm -f "$guidance"; exit 1; }
  rm -f "$guidance"
  log "Installed Cursor hooks, guidance and Chrome MCP servers"
  install_agent_ralph_skill cursor ralph-run-cursor "$HOME/.cursor/skills" agent
}

preflight_antigravity_environment() {
  check_guidance_target "$HOME/.gemini/AGENTS.md"
  validate_agent_skill_target "$HOME/.gemini/antigravity-cli/skills" ralph-run
  python3 "$SCRIPT_DIR/scripts/install-antigravity.py" --gemini-dir "$HOME/.gemini" \
    --codex-skills-dir "$(realpath -m "$SKILLS_DIR")" --hook-source-dir "$SCRIPT_DIR/hooks" --check-only
}

install_antigravity_environment() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    install_guidance_block "$HOME/.gemini/AGENTS.md" /dev/null "Antigravity"
    echo "+ register Antigravity hooks, skills.json and Chrome MCP servers -> $HOME/.gemini/config"
    install_agent_ralph_skill antigravity ralph-run "$HOME/.gemini/antigravity-cli/skills" agy
    return
  fi
  local guidance
  check_guidance_target "$HOME/.gemini/AGENTS.md"
  guidance="$(mktemp)"
  # errexit would skip the rm below, so a failed step removes the temporary file itself.
  compose_guidance antigravity "$guidance" || { rm -f "$guidance"; exit 1; }
  install_guidance_block "$HOME/.gemini/AGENTS.md" "$guidance" "Antigravity"
  rm -f "$guidance"
  python3 "$SCRIPT_DIR/scripts/install-antigravity.py" --gemini-dir "$HOME/.gemini" \
    --codex-skills-dir "$(realpath -m "$SKILLS_DIR")" --hook-source-dir "$SCRIPT_DIR/hooks"
  log "Installed Antigravity hooks, skills.json and Chrome MCP servers"
  install_agent_ralph_skill antigravity ralph-run "$HOME/.gemini/antigravity-cli/skills" agy
}

setup_cursor() {
  log "Setting up Cursor CLI"
  preflight_cursor_environment
  ensure_cursor_cli
  install_cursor_environment
}

setup_antigravity() {
  log "Setting up Antigravity CLI"
  preflight_antigravity_environment
  ensure_antigravity_cli
  install_antigravity_environment
}

main() {
  ensure_ubuntu_wsl
  prepare_codex_app_environment
  ensure_base_tools
  prepare_sources
  preflight_codex_app_environment
  # A file setup would refuse stops the run here, before any Codex, Cursor or Antigravity setting
  # changes. Cursor and Antigravity are set up after Codex.
  check_guidance_target "$CODEX_DIR/AGENTS.md"
  preflight_cursor_environment
  preflight_antigravity_environment
  run mkdir -p "$CODEX_DIR"
  ensure_codex
  ensure_rtk
  ensure_bun
  source "$SCRIPT_DIR/scripts/ensure-node.sh"
  ensure_chrome_node
  preflight_chrome_mcp
  install_chrome_mcp
  run mkdir -p "$SKILLS_DIR"
  install_gstack
  install_ralph
  install_local_skills
  install_agents_guidance
  install_rtk_hook
  install_codex_app_environment
  setup_cursor
  setup_antigravity

  if [[ "$DRY_RUN" -eq 0 ]]; then
    CODEX_APP_HOME="${CODEX_APP_HOME:-}" bash "$SCRIPT_DIR/doctor.sh" --skip-login
    if ! codex login status >/dev/null 2>&1; then
      printf '\nCodexへのログインが必要です。次を実行してください:\n  codex login --device-auth\n'
    fi
    if ! cursor_logged_in; then
      printf '\nCursor CLIへのログインが必要です。次を実行してください:\n  agent login\n'
    fi
    printf '\nAntigravity CLIのサインインを確認しています（未サインインのときは最大%s秒かかります）...\n' \
      "$AGENT_SIGN_IN_TIMEOUT"
    if ! antigravity_logged_in; then
      printf '\nAntigravity CLIへのサインインが必要です。次を実行して、表示される案内に従ってください:\n  agy\n'
    fi
  fi

  printf '\nSetup complete. Restart Codex CLI and Codex App, then open /hooks in each and trust the reviewed RTK Safe Hook.\n'
  printf 'Cursor CLI and Antigravity CLI load their new hooks, guidance and skills when they next start.\n'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
