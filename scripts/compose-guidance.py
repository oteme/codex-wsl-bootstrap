#!/usr/bin/env python3
"""Compose Cursor or Antigravity guidance from AGENTS.global.md with agent-specific gstack and Ralph sections."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import stat
import tempfile


BEGIN = "<!-- BEGIN codex-workstation-bootstrap -->"
END = "<!-- END codex-workstation-bootstrap -->"
SECTIONS = (
    "Workstation setup updates",
    "gstack",
    "Ralph",
    "Open implementation choices",
    "Go backend",
    "Fail-close and clean-break",
)
# Section title -> fragment suffix; <guidance-dir>/<agent>-<suffix>.md replaces the Codex wording.
AGENT_SECTIONS = {"gstack": "gstack", "Ralph": "ralph"}


def read_text(path: Path, label: str) -> str:
    if not path.is_file():
        raise SystemExit(f"error: {label} is missing: {path}")
    try:
        return path.read_bytes().decode("utf-8")
    except (OSError, UnicodeDecodeError) as error:
        raise SystemExit(f"error: cannot read {label} {path}: {error}")


def split_lines(text: str) -> list[str]:
    # Each line keeps its newline so unchanged sections are copied byte for byte.
    lines = text.split("\n")
    return [line + "\n" for line in lines[:-1]] + ([lines[-1]] if lines[-1] else [])


def is_marker(line: str) -> bool:
    return line.rstrip("\n") in (BEGIN, END)


def parse_global(path: Path) -> tuple[str, list[tuple[str, str]], str]:
    lines = split_lines(read_text(path, "global guidance"))
    if len(lines) < 2 or lines[0].rstrip("\n") != BEGIN or lines[-1].rstrip("\n") != END:
        raise SystemExit(f"error: {path} must start with {BEGIN} and end with {END}")
    if any(is_marker(line) for line in lines[1:-1]):
        raise SystemExit(f"error: unexpected bootstrap marker inside {path}")
    preamble: list[str] = []
    sections: list[tuple[str, list[str]]] = []
    for line in lines[1:-1]:
        if line.startswith("## "):
            sections.append((line.rstrip("\n")[3:], [line]))
        elif sections:
            sections[-1][1].append(line)
        else:
            preamble.append(line)
    titles = [title for title, _ in sections]
    for title in titles:
        if title not in SECTIONS:
            raise SystemExit(f'error: unknown section "## {title}" in {path}')
    for title in SECTIONS:
        if title not in titles:
            raise SystemExit(f'error: missing section "## {title}" in {path}')
        if titles.count(title) > 1:
            raise SystemExit(f'error: duplicate section "## {title}" in {path}')
    if titles != list(SECTIONS):
        raise SystemExit(f"error: sections are out of order in {path}; expected: {', '.join(SECTIONS)}")
    head = lines[0] + "".join(preamble)
    return head, [(title, "".join(body)) for title, body in sections], lines[-1]


def read_fragment(path: Path, title: str) -> str:
    lines = split_lines(read_text(path, "guidance fragment"))
    if not lines or lines[0].rstrip("\n") != f"## {title}":
        raise SystemExit(f'error: guidance fragment must start with "## {title}": {path}')
    if any(line.startswith("## ") or is_marker(line) for line in lines[1:]):
        raise SystemExit(f'error: guidance fragment must hold only the "## {title}" section: {path}')
    return "".join(lines)


def compose(head: str, sections: list[tuple[str, str]], tail: str, fragments: dict[str, str]) -> str:
    parts = [head]
    for title, body in sections:
        if title in fragments:
            # Keep the global file's blank lines after the section, whatever the fragment ends with.
            content = body.rstrip("\n")
            parts.append(fragments[title].rstrip("\n") + body[len(content):])
        else:
            parts.append(body)
    parts.append(tail)
    return "".join(parts)


def atomic_write(destination: Path, content: bytes, mode: int) -> None:
    if (
        not destination.is_symlink()
        and destination.is_file()
        and stat.S_IMODE(destination.stat().st_mode) == mode
        and destination.read_bytes() == content
    ):
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    descriptor, name = tempfile.mkstemp(prefix=f".{destination.name}.", dir=destination.parent)
    temporary_path = Path(name)
    try:
        with os.fdopen(descriptor, "wb") as temporary:
            temporary.write(content)
        os.chmod(temporary_path, mode)
        os.replace(temporary_path, destination)
    finally:
        temporary_path.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--agent", required=True, choices=("cursor", "antigravity"))
    parser.add_argument("--global-guidance", required=True, type=Path)
    parser.add_argument("--guidance-dir", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    head, sections, tail = parse_global(args.global_guidance)
    sources = {
        title: args.guidance_dir / f"{args.agent}-{suffix}.md" for title, suffix in AGENT_SECTIONS.items()
    }
    fragments = {title: read_fragment(path, title) for title, path in sources.items()}
    output = args.output
    if output.is_symlink():
        raise SystemExit(f"error: refusing to replace symlinked output: {output}")
    if output.exists():
        if not output.is_file():
            raise SystemExit(f"error: refusing to replace non-regular output: {output}")
        if any(output.samefile(path) for path in [args.global_guidance, *sources.values()]):
            raise SystemExit(f"error: refusing to overwrite an input file: {output}")
    atomic_write(output, compose(head, sections, tail, fragments).encode("utf-8"), 0o644)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except OSError as error:
        raise SystemExit(f"error: {error}")
