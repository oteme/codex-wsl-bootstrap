#!/usr/bin/env bash
# Sourced by install.sh. Install only when Node is absent; do not replace user runtimes.
validate_chrome_node() {
  node -e 'const [major, minor] = process.versions.node.split(".").map(Number); if (!((major === 20 && minor >= 19) || (major === 22 && minor >= 12) || major >= 23)) process.exit(1)' || {
    echo 'error: Chrome MCP requires Node 20.19+, 22.12+, or 23+; existing Node was not replaced' >&2
    return 1
  }
  command -v npx >/dev/null && npx --version >/dev/null || {
    echo 'error: npx is missing or unusable; existing Node was not replaced' >&2
    return 1
  }
}

ensure_chrome_node() {
  if command -v node >/dev/null 2>&1; then
    validate_chrome_node
    return
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log 'Would install checksum-verified Node.js 22.23.2 and npx'
    return
  fi
  local arch checksum destination archive_dir tool
  local node_bin_dir="${NODE_BIN_DIR:-$HOME/.local/bin}"
  case "$(uname -m)" in
    x86_64) arch=x64; checksum=d60acfe00a2932254bb0ad20e01b0d74397a0875595de719654b214f4b03f307 ;;
    aarch64|arm64) arch=arm64; checksum=fff4078c5def658577f92c88db7db3bc0072924bfb93fe52c1e744a54e94abb8 ;;
    *) echo 'error: unsupported Node architecture' >&2; return 1 ;;
  esac
  destination="$BOOTSTRAP_STATE_DIR/node-v22.23.2-linux-$arch"
  for tool in node npm npx; do
    if [[ -e "$node_bin_dir/$tool" || -L "$node_bin_dir/$tool" ]]; then
      echo "error: refusing to overwrite $node_bin_dir/$tool" >&2
      return 1
    fi
  done
  if [[ -e "$destination" || -L "$destination" ]]; then
    echo "error: Node destination already exists: $destination" >&2
    return 1
  fi
  archive_dir="$(mktemp -d)"
  # Keep a failed download/extraction for diagnosis; do not treat it as installed.
  curl -fsSL "https://nodejs.org/dist/v22.23.2/node-v22.23.2-linux-$arch.tar.xz" -o "$archive_dir/node.tar.xz"
  printf '%s  %s\n' "$checksum" "$archive_dir/node.tar.xz" | sha256sum --check --status || {
    echo 'error: Node archive checksum mismatch' >&2
    return 1
  }
  tar -xJf "$archive_dir/node.tar.xz" -C "$archive_dir"
  [[ "$("$archive_dir/node-v22.23.2-linux-$arch/bin/node" --version)" == v22.23.2 ]]
  mkdir -p "$BOOTSTRAP_STATE_DIR" "$node_bin_dir"
  mv "$archive_dir/node-v22.23.2-linux-$arch" "$destination"
  for tool in node npm npx; do
    ln -s "$destination/bin/$tool" "$node_bin_dir/$tool"
  done
  rm -r -- "$archive_dir"
  validate_chrome_node
}
