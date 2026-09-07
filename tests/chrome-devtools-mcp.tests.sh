#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "$ROOT/tests/chrome-devtools-mcp.tests.py"

fixture="$(mktemp -d)"
trap 'rm -r -- "$fixture"' EXIT
# Isolated destinations: the Node installer must never write workstation paths here.
source "$ROOT/scripts/ensure-node.sh"
export NODE_BIN_DIR="$fixture/bin"
export BOOTSTRAP_STATE_DIR="$fixture/state"
mkdir -p "$NODE_BIN_DIR"
DRY_RUN=0
log() { printf '%s\n' "$*"; }

# Invalid runtimes and missing npx must fail without downloading a replacement.
node() { return 1; }
if validate_chrome_node >"$fixture/log" 2>&1; then exit 1; fi
grep -q 'existing Node was not replaced' "$fixture/log"
node() { return 0; }
npx() { return 1; }
if validate_chrome_node >"$fixture/log" 2>&1; then exit 1; fi
grep -q 'npx is missing or unusable' "$fixture/log"
unset -f node npx

# Simulate no Node on PATH without changing HOME or real installations.
command() {
  if [[ "$*" == '-v node' ]]; then return 1; fi
  builtin command "$@"
}
curl() { echo 'unexpected download' >&2; return 99; }
printf 'user data\n' > "$NODE_BIN_DIR/npm"
if ensure_chrome_node >"$fixture/log" 2>&1; then exit 1; fi
grep -q 'refusing to overwrite' "$fixture/log"
[[ "$(cat "$NODE_BIN_DIR/npm")" == 'user data' ]]
rm "$NODE_BIN_DIR/npm"

# A corrupt archive must fail before extraction, destination creation or linking.
curl() {
  local last="${!#}"
  printf 'corrupt archive' > "$last"
}
if ensure_chrome_node >"$fixture/log" 2>&1; then exit 1; fi
grep -q 'Node archive checksum mismatch' "$fixture/log"
[[ ! -e "$BOOTSTRAP_STATE_DIR" && ! -e "$NODE_BIN_DIR/node" ]]
DRY_RUN=1
ensure_chrome_node >"$fixture/log"
[[ ! -e "$BOOTSTRAP_STATE_DIR" ]]
printf 'PASS: Node conflict, runtime, checksum and dry-run guards\n'

# Successful first-install fixture: real extraction and symlinks, synthetic archive.
DRY_RUN=0
case "$(uname -m)" in x86_64) node_arch=x64 ;; aarch64|arm64) node_arch=arm64 ;; *) exit 1 ;; esac
mkdir -p "$fixture/archive/node-v22.23.2-linux-$node_arch/bin"
cat > "$fixture/archive/node-v22.23.2-linux-$node_arch/bin/node" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == --version ]]; then echo v22.23.2; exit 0; fi
[[ "$1" == -e ]]
EOF
for tool in npm npx; do
  printf '#!/usr/bin/env bash\necho 10.9.8\n' > "$fixture/archive/node-v22.23.2-linux-$node_arch/bin/$tool"
done
chmod +x "$fixture/archive/node-v22.23.2-linux-$node_arch/bin/"*
tar -cJf "$fixture/valid.tar.xz" -C "$fixture/archive" "node-v22.23.2-linux-$node_arch"
curl() { cp "$fixture/valid.tar.xz" "${!#}"; }
# Only synthetic fixture bytes bypass real checksum validation; corruption above uses sha256sum.
sha256sum() { [[ "$*" == '--check --status' ]]; cat >/dev/null; }
export PATH="$NODE_BIN_DIR:$PATH"
ensure_chrome_node
[[ "$(readlink "$NODE_BIN_DIR/node")" == "$BOOTSTRAP_STATE_DIR/node-v22.23.2-linux-$node_arch/bin/node" ]]
[[ "$(node --version)" == v22.23.2 ]]
[[ "$(npx --version)" == 10.9.8 ]]
unset -f command
curl() { echo 'unexpected reinstall' >&2; return 99; }
ensure_chrome_node
printf 'PASS: isolated first Node install and idempotent rerun\n'
