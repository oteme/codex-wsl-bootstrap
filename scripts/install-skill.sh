#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -lt 3 || "$#" -gt 4 ]]; then
  echo "Usage: install-skill.sh <source-dir> <destination> <managed-marker> [instructions-overlay]" >&2
  exit 2
fi

source_dir="$1"
destination="$2"
managed_marker="$3"
instructions_overlay="${4:-}"
skills_dir="$(dirname "$destination")"
skill_name="$(basename "$destination")"
stage="$skills_dir/.${skill_name}.stage.$$"

[[ -f "$source_dir/SKILL.md" ]] || {
  echo "error: invalid skill source: $source_dir" >&2
  exit 1
}

if [[ -n "$instructions_overlay" && ! -f "$instructions_overlay" ]]; then
  echo "error: skill overlay not found: $instructions_overlay" >&2
  exit 1
fi

if [[ -e "$destination" || -L "$destination" ]]; then
  if [[ -L "$destination" ]]; then
    echo "error: refusing to replace symlinked skill: $destination" >&2
    exit 1
  fi
  if [[ ! -f "$destination/$managed_marker" ]]; then
    if ! diff -qr --exclude="$managed_marker" "$source_dir" "$destination" >/dev/null 2>&1; then
      echo "error: refusing to overwrite an unmanaged skill: $destination" >&2
      exit 1
    fi
  fi
fi

rm -rf "$stage"
trap 'rm -rf "$stage"' EXIT
cp -a "$source_dir" "$stage"
if [[ -n "$instructions_overlay" ]]; then
  cat "$instructions_overlay" >> "$stage/SKILL.md"
fi
touch "$stage/$managed_marker"
if [[ -e "$destination" ]]; then
  rm -rf "$destination"
fi
mv "$stage" "$destination"
trap - EXIT
