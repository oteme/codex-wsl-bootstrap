#!/usr/bin/env bash
set -euo pipefail

readonly GSTACK_REPO="https://github.com/garrytan/gstack.git"
readonly GSTACK_REF_DEFAULT="85fd9db554ae4aaaa6d356d2daf873121ee85bdd"
readonly RALPH_REPO="https://github.com/snarktank/ralph.git"
readonly RALPH_REF_DEFAULT="6c53cb0b831ebe8739c6a003e22af14902d8b0b5"
readonly MANAGED_MARKER=".codex-workstation-bootstrap-managed"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
SKILLS_DIR="$CODEX_DIR/skills"
GSTACK_DIR="${GSTACK_INSTALL_DIR:-$HOME/gstack}"
RALPH_SOURCE_DIR="${RALPH_SOURCE_DIR:-$HOME/.local/share/codex-workstation-bootstrap/ralph}"
GSTACK_REF="${GSTACK_REF:-$GSTACK_REF_DEFAULT}"
RALPH_REF="${RALPH_REF:-$RALPH_REF_DEFAULT}"
DRY_RUN=0

# Non-interactive WSL launches do not necessarily load shell profile PATH entries.
export PATH="$HOME/.local/bin:$HOME/.codex/bin:$HOME/.bun/bin:$PATH"

usage() {
  cat <<'EOF'
Usage: ./install.sh [--dry-run]

Installs Codex CLI, Bun, gstack, Ralph skills, and shared AGENTS.md guidance
for an existing Ubuntu/WSL2 environment.

Environment overrides:
  CODEX_HOME          Codex data directory (default: ~/.codex)
  GSTACK_INSTALL_DIR  gstack checkout (default: ~/gstack)
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
  for tool in curl git python3; do
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
  run "${sudo_cmd[@]}" apt-get install -y ca-certificates curl git python3
}

download_and_run() {
  local url="$1"
  local label="$2"
  local installer
  installer="$(mktemp)"
  trap 'rm -f "${installer:-}"' RETURN
  curl -fsSL "$url" -o "$installer"
  NON_INTERACTIVE=1 bash "$installer"
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
  local instructions_overlay="${3:-}"
  local destination="$SKILLS_DIR/$skill_name"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "+ install skill $skill_name -> $destination"
    return
  fi

  bash "$SCRIPT_DIR/scripts/install-skill.sh" \
    "$source_dir" "$destination" "$MANAGED_MARKER" "$instructions_overlay"
  log "Installed skill: $skill_name"
}

install_gstack() {
  checkout_repo "$GSTACK_REPO" "$GSTACK_REF" "$GSTACK_DIR" "gstack"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "+ (cd $GSTACK_DIR && ./setup --host codex --prefix)"
    return
  fi
  log "Building and registering gstack skills"
  (cd "$GSTACK_DIR" && ./setup --host codex --prefix)
}

install_ralph() {
  checkout_repo "$RALPH_REPO" "$RALPH_REF" "$RALPH_SOURCE_DIR" "Ralph"
  run mkdir -p "$SKILLS_DIR"
  install_skill "$RALPH_SOURCE_DIR/skills/prd" "prd" "$SCRIPT_DIR/config/prd-fail-close-clean-break.md"
  install_skill "$RALPH_SOURCE_DIR/skills/ralph" "ralph" "$SCRIPT_DIR/config/ralph-fail-close-clean-break.md"
  install_skill "$SCRIPT_DIR/skills/ralph-bootstrap" "ralph-bootstrap"
  install_skill "$SCRIPT_DIR/skills/ralph-run" "ralph-run"
}

install_agents_guidance() {
  local agents_file="$CODEX_DIR/AGENTS.md"
  local guidance="$SCRIPT_DIR/config/AGENTS.global.md"
  local filtered

  run mkdir -p "$CODEX_DIR"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "+ update managed block in $agents_file"
    return
  fi

  filtered="$(mktemp)"
  if [[ -f "$agents_file" ]]; then
    awk '
      $0 == "<!-- BEGIN codex-workstation-bootstrap -->" { skip=1; next }
      $0 == "<!-- END codex-workstation-bootstrap -->" { skip=0; next }
      !skip { print }
    ' "$agents_file" > "$filtered"
  fi

  {
    cat "$filtered"
    [[ -s "$filtered" ]] && printf '\n\n'
    cat "$guidance"
    printf '\n'
  } > "$agents_file"
  rm -f "$filtered"
  log "Updated shared Codex guidance: $agents_file"
}

main() {
  ensure_ubuntu_wsl
  ensure_base_tools
  run mkdir -p "$CODEX_DIR"
  ensure_codex
  ensure_bun
  run mkdir -p "$SKILLS_DIR"
  install_gstack
  install_ralph
  install_agents_guidance

  if [[ "$DRY_RUN" -eq 0 ]]; then
    bash "$SCRIPT_DIR/doctor.sh" --skip-login
    if ! codex login status >/dev/null 2>&1; then
      printf '\nCodexへのログインが必要です。次を実行してください:\n  codex login --device-auth\n'
    fi
  fi

  printf '\nSetup complete. Restart Codex CLI to refresh the skill list.\n'
}

main
