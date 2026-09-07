# Codex WSL Workstation Bootstrap

Recreates this Codex CLI environment on another Ubuntu/WSL2 device:

- Codex CLI
- Chrome DevTools MCP for the WSL CLI, connected to `http://127.0.0.1:9222`
- RTK 0.46.0 with a Codex-native, fail-close Safe Hook
- Bun
- Python 3 (used by the Ralph state gate)
- gstack for Codex (`gstack-*` skill names)
- Ralph `prd` and `ralph` skills
- Codex-native `ralph-bootstrap` and `ralph-run` skills
- A lazily loaded `go-backend` skill for Clean Architecture, HTTP API, SQL, and migration rules
- Shared Japanese/gstack/Ralph instructions in `~/.codex/AGENTS.md`
- The same instructions and skills in the Windows Codex App when it is installed
- Fail-close/clean-break requirements in plans and PRDs, plus an independent Ralph diff gate

## RTK Safe Hook

The bootstrap installs a checksum-verified, pinned RTK binary and registers a global Codex
`PreToolUse` hook. The hook rewrites only allowlisted, single-process commands such as
`go test ./...`, `git status`, and `npx eslint .`. Shell control syntax, pipes, redirects,
assignments, substitutions, mutating flags, `find`, and unknown commands remain byte-for-byte
unchanged.

The Codex adapter is separate from RTK's Claude hook. Invalid hook input, a missing or failing
RTK binary, an unexpected rewrite, and invalid rewritten Bash are denied instead of silently
falling back. Existing unrelated entries in `~/.codex/hooks.json` are preserved. Codex requires
reviewing newly installed or changed non-managed hooks with `/hooks` before they run.

Run the permanent regression suite after RTK or Codex upgrades:

```bash
~/.codex/hooks/rtk-safe/test.sh
```

## One-click setup

This assumes WSL2 with Ubuntu is already installed.

1. Download [`setup-wsl.cmd`](https://github.com/oteme/codex-wsl-bootstrap/raw/main/setup-wsl.cmd)
   once on the new Windows device.
2. Double-click `setup-wsl.cmd`.
3. If prompted, complete the Ubuntu password and Codex sign-in steps.
4. Restart Codex, open `/hooks`, and trust the reviewed RTK Safe Hook definition.

The CMD downloads the latest PowerShell launcher, which then uses Git installed inside WSL.
It checks out the latest version at `~/.local/share/codex-wsl-bootstrap` and runs its
installer. Windows Git is not required. When the Windows Codex App package is present, the
launcher also registers the bootstrap-managed guidance and skills in
`C:\Users\<user>\.codex`, which is the App's `CODEX_HOME` even when agents execute in WSL.

Apply repository changes only after creating and merging a PR, then rerun the Windows
`Downloads/setup-wsl.cmd` launcher.

The installer is safe to rerun. It preserves unrelated content in
`~/.codex/AGENTS.md` and refuses to overwrite unmanaged skill folders or modified source
checkouts.

## Chrome DevTools MCP (WSL CLI)

Setup registers the requested command in the CLI's `CODEX_HOME`:

```bash
codex mcp add chrome-devtools -- \
  npx -y chrome-devtools-mcp@latest \
  --browser-url=http://127.0.0.1:9222
```

An identical registration is preserved. A disabled or differently configured server with
that name, invalid Codex configuration, or a non-regular config file stops setup without
replacing it. Other MCP servers and settings are preserved. This addition targets the WSL
CLI; it does not register the server in the separate Windows App configuration.
The requested `@latest` is retained, so MCP package updates follow npm rather than the
bootstrap release. There is no legacy MCP configuration or compatibility shim to retain.

Setup uses an existing working Node runtime (20.19+, 22.12+, or 23+) and npx.
If Node is absent, it installs checksum-verified Node 22.23.2 for Linux x64/arm64 and
links node/npm/npx into `~/.local/bin`. An incompatible existing runtime, broken npx,
or an occupied installation target fails explicitly; setup does not replace user runtimes.
Ensure `~/.local/bin` is on PATH when starting Codex from a new shell.

To start the browser on Windows:

1. Install Google Chrome and enable `networkingMode=mirrored` in the `[wsl2]` section
   of `%USERPROFILE%\.wslconfig`. Apply WSL changes by restarting WSL after saving work.
2. Download [start-chrome-devtools.cmd](https://github.com/oteme/codex-wsl-bootstrap/raw/main/start-chrome-devtools.cmd)
   to Downloads and run it. It uses a dedicated `%LOCALAPPDATA%\CodexChromeDevTools`
   profile and port 9222. Setup does not change WSL networking or launch Chrome automatically.
3. In WSL, run `bash ~/.local/share/codex-wsl-bootstrap/doctor.sh --check-browser`.
   Connection refusal, malformed responses and unexpected endpoints fail; no alternate
   browser or address is tried.
4. Restart Codex CLI and ask it to list the open Chrome pages.

The default setup doctor checks registration and runtime only. Passing setup does not mean
Chrome is running; `--check-browser` separately verifies the live DevTools endpoint.
Chrome pages in this dedicated profile are accessible to the agent through MCP.

References: [Codex MCP](https://developers.openai.com/codex/mcp),
[Chrome MCP WSL guidance](https://github.com/ChromeDevTools/chrome-devtools-mcp/blob/main/docs/troubleshooting.md).

## Ralph policy gate

`ralph-bootstrap` generates project instructions that forbid speculative fallbacks and
compatibility paths. The installed `prd` and `ralph` skills require explicit failure behavior,
compatibility decisions, and deletion criteria.

During `ralph-run`, workers leave each story uncommitted. A fresh Codex process statically reviews
the exact staged diff in a disposable detached Git worktree for swallowed failures, unrequested
fallback/legacy paths, and weakened tests. Acceptance criteria are consulted only for explicit
policy exceptions; the reviewer does not grade general story correctness or completeness.
Reviewer-created files are discarded with that worktree. Only an approved diff is committed and
allowed to count as passing. A rejected story returns to `passes: false` and is repaired in the
next iteration. The runner also refuses to start if unrelated files outside `scripts/ralph` are
already dirty.

## Ralph completion notifications

On the WSL Codex CLI and the Windows App executing in WSL, `ralph-run` starts a detached Python
supervisor and ends the parent turn.
The supervisor waits for the existing implementation/review loop, saves detailed logs, and queues
one terminal result to the initiating thread with `codex queue`. There is no periodic parent-model
polling. Run IDs and durable results live in `scripts/ralph/logs/runs/<run-id>/result.json`.

Setup records its verified Codex CLI's absolute path in each installed Ralph skill's
`scripts/codex-runtime.json`. Workers, reviewers and notifications use that executable even
when the desktop app's PATH puts an older CLI first. To apply this update on an existing
device, rerun `Downloads/setup-wsl.cmd`. A missing or invalid runtime record or executable
stops Ralph before work; rerun the same CMD to repair it. The initiating `CODEX_HOME` and
configured model are preserved.

This requires `codex queue --thread`, the initiating `CODEX_THREAD_ID`, Python 3 and `flock`.
The Windows App queue-and-resume route was verified in-App on 2026-09-07 using the App
`CODEX_HOME` and initiating thread ID unchanged. The full supervisor/runner fixture was tested
on the WSL CLI; native PowerShell execution is not covered. Missing queue support fails before
work starts.
Notification failures are recorded separately from execution results and are not retried.
An OS shutdown or forced supervisor kill can prevent delivery; saved running state is not proof
of liveness. Inspect the result and logs when recovering. Never start a second run to recover a
notification. Existing PRD formats and policy gates are preserved; the old attached polling
workflow and worker/reviewer console streaming have been removed.

## Verify

```bash
./doctor.sh
```

If Codex is not signed in yet:

```bash
codex login --device-auth
```

To verify both Codex homes again later, pass the App home to Doctor explicitly:

```bash
CODEX_APP_HOME=/mnt/c/Users/<user>/.codex ./doctor.sh
```

Then restart Codex CLI and Codex App so they reload the installed skills. Open `/hooks` in each
and trust the reviewed RTK Safe Hook definition; the bootstrap intentionally does not bypass
Codex hook trust.

## Update an existing device

Double-click the same `setup-wsl.cmd` again. The CMD refreshes its PowerShell launcher, then
fetches the latest version with Git inside WSL and updates bootstrap-managed skills while
preserving unrelated Codex configuration. There is no ZIP to replace or extract. Restart
Codex CLI and Codex App after setup completes.

## Codex App and WSL

Windows and WSL have different home directories. Installing only from a WSL terminal writes
to `/home/<user>/.codex`; the Windows App normally uses `C:\Users\<user>\.codex` while its
agent process runs inside WSL. The one-click Windows launcher detects the installed App and
updates both locations. App-specific configuration, authentication, sessions, and built-in
plugins remain separate; only bootstrap-managed guidance and skills are installed in both.

If you run the PowerShell launcher directly and need to override App detection, pass the Windows
profile path explicitly:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\setup-wsl.ps1 `
  -CodexAppHome 'C:\Users\<user>\.codex'
```

Direct WSL installs cannot reliably detect whether the Windows App package is installed. To
target it explicitly, pass its Windows profile directory as a WSL path:

```bash
CODEX_APP_HOME=/mnt/c/Users/<user>/.codex ./install.sh
```

Invalid App paths and unmanaged skill collisions fail closed. The installer does not add a
Windows-native fallback: App sharing requires its WSL execution mode.

The bootstrap keeps its pinned gstack checkout under
`~/.local/share/codex-workstation-bootstrap/gstack`. A separate `~/gstack` checkout is left
untouched, including the generated `gstack-*` skill-name patches that gstack may keep there.

To relocate both bootstrap-managed source checkouts, set the shared state directory:

```bash
BOOTSTRAP_STATE_DIR=/path/to/bootstrap-state ./install.sh
```

`GSTACK_INSTALL_DIR` and `RALPH_SOURCE_DIR` still override their individual checkout locations.

## Update pinned versions

The default gstack and Ralph commits and the RTK release/checksums are pinned in `install.sh`
for reproducible setup.
You can test newer revisions without editing the file:

```bash
GSTACK_REF=<commit> RALPH_REF=<commit> ./install.sh
```

After verification, update the corresponding pinned constants and RTK checksums in `install.sh`.

## Security boundary

Authentication files, API keys, browser cookies, shell history, and existing Codex
session data are never copied. Each device performs its own Codex login.

Local `.gstack/` runtime state is excluded by `.gitignore`; do not remove that rule when
publishing this bundle.
