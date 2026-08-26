# Codex WSL Workstation Bootstrap

Recreates this Codex CLI environment on another Ubuntu/WSL2 device:

- Codex CLI
- Bun
- Python 3 (used by the Ralph state gate)
- gstack for Codex (`gstack-*` skill names)
- Ralph `prd` and `ralph` skills
- Codex-native `ralph-bootstrap` and `ralph-run` skills
- A lazily loaded `go-backend` skill for Clean Architecture, HTTP API, SQL, and migration rules
- Shared Japanese/gstack/Ralph instructions in `~/.codex/AGENTS.md`
- Fail-close/clean-break requirements in plans and PRDs, plus an independent Ralph diff gate

## One-click setup

This assumes WSL2 with Ubuntu is already installed.

1. Download [`setup-wsl.cmd`](https://github.com/oteme/codex-wsl-bootstrap/raw/main/setup-wsl.cmd)
   once on the new Windows device.
2. Double-click `setup-wsl.cmd`.
3. If prompted, complete the Ubuntu password and Codex sign-in steps.

The CMD downloads the latest PowerShell launcher, which then uses Git installed inside WSL.
It checks out the latest version at `~/.local/share/codex-wsl-bootstrap` and runs its
installer. Windows Git is not required.

To install directly from an Ubuntu/WSL terminal, run:

```bash
git clone https://github.com/oteme/codex-wsl-bootstrap.git \
  ~/.local/share/codex-wsl-bootstrap
bash ~/.local/share/codex-wsl-bootstrap/install.sh
```

The installer is safe to rerun. It preserves unrelated content in
`~/.codex/AGENTS.md` and refuses to overwrite unmanaged skill folders or modified source
checkouts.

## Ralph policy gate

`ralph-bootstrap` generates project instructions that forbid speculative fallbacks and
compatibility paths. The installed `prd` and `ralph` skills require explicit failure behavior,
compatibility decisions, and deletion criteria.

During `ralph-run`, workers leave each story uncommitted. A fresh Codex process statically reviews
the exact staged diff in a disposable detached Git worktree for swallowed failures, unrequested
fallback/legacy paths, weakened tests, and unmet acceptance criteria. Reviewer-created files are
discarded with that worktree. Only an approved diff is committed and allowed to count as passing.
A rejected story returns to `passes: false` and is repaired in the next iteration. The runner also
refuses to start if unrelated files outside `scripts/ralph` are already dirty.

## Verify

```bash
./doctor.sh
```

If Codex is not signed in yet:

```bash
codex login --device-auth
```

Then restart Codex CLI so it reloads the installed skills.

## Update an existing device

Double-click the same `setup-wsl.cmd` again. The CMD refreshes its PowerShell launcher, then
fetches the latest version with Git inside WSL and updates bootstrap-managed skills while
preserving unrelated Codex configuration. There is no ZIP to replace or extract. Restart
Codex CLI after setup completes.

## Update pinned versions

The default gstack and Ralph commits are pinned in `install.sh` for reproducible setup.
You can test newer revisions without editing the file:

```bash
GSTACK_REF=<commit> RALPH_REF=<commit> ./install.sh
```

After verification, update the two default commit constants in `install.sh`.

## Security boundary

Authentication files, API keys, browser cookies, shell history, and existing Codex
session data are never copied. Each device performs its own Codex login.

Local `.gstack/` runtime state is excluded by `.gitignore`; do not remove that rule when
publishing this bundle.
