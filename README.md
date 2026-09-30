# Codex WSL Workstation Bootstrap

Recreates this Codex CLI environment on another Ubuntu/WSL2 device:

- Codex CLI
- Chrome DevTools MCP for the WSL CLI and WSL-backed App, with separate ports 9222 and 9223
- RTK 0.46.0 with a Codex-native, fail-close Safe Hook
- Bun
- Python 3 (used by the Ralph state gate)
- gstack for Codex (`gstack-*` skill names)
- Ralph `prd` and `ralph` skills
- Codex-native `ralph-bootstrap` and `ralph-run` skills
- A lazily loaded `go-backend` skill for Clean Architecture, HTTP API, SQL, and migration rules
- Orca's version-matched `orca-cli` and `computer-use` discovery skills for embedded browser,
  worktree, terminal, and visible GUI control
- Shared Japanese/gstack/Ralph instructions in `~/.codex/AGENTS.md`
- The same instructions and skills in the Windows Codex App when it is installed
- Fail-close/clean-break rules for the code being built, stated in plans and PRDs and checked by an
  independent Ralph diff review
- Cursor CLI (`agent`) and Antigravity CLI (`agy`), set up after Codex with the same guidance,
  skills, Chrome MCP servers, RTK Safe Hook and a Ralph runner of their own (see
  [Cursor CLI](#cursor-cli) and [Antigravity CLI](#antigravity-cli))

## RTK Safe Hook

The bootstrap installs a checksum-verified, pinned RTK binary and registers a global Codex
`PreToolUse` hook. The hook rewrites only allowlisted, single-process commands such as
`go test ./...`, `git status`, and `npx eslint .`. `git diff`, `git show` and `git log` are not
rewritten: RTK cuts each file's diff to 100 lines and a log to 10 commits without saying so,
which would hide part of a change or a history from a review.
Neither are `head` and `tail` (RTK printed a single line for `head -2`) nor commands spaced
other than with single spaces (RTK misread `head  -n 3`). `grep` and `rg` are rewritten; RTK
shortens long results but says so and names the file that holds the rest. Shell
control syntax, pipes, redirects,
assignments, substitutions, mutating flags, `find`, and unknown commands remain byte-for-byte
unchanged. An allowlisted command that RTK has no rewrite for, such as `npm test`, also runs
unchanged: RTK 0.46 reports it with exit status 1 and `No rewrite for: <command>`, sometimes after
its own `[rtk]` notice lines. Of RTK's failures, only that exact report counts as "no rewrite";
any other failure is still denied.

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

Bootstrap-managed guidance and skills are distributed to both homes (gstack skills link
to the same source). This does not symlink the complete `config.toml`, authentication or
sessions; managed Chrome MCP entries are now registered in each config separately.

Apply repository changes only after creating and merging a PR, then rerun the Windows
`Downloads/setup-wsl.cmd` launcher.

The installer is safe to rerun. It preserves unrelated content in
`~/.codex/AGENTS.md` and refuses to overwrite unmanaged skill folders or modified source
checkouts.

The Orca skills are discovery stubs, not a bundled Orca runtime. They select the session's
`orca`, `orca-ide`, or `orca-dev` executable and load its matching guide at use time. If that
executable is missing or incompatible, the skill reports the exact error instead of trying a
different runtime. Existing shared `~/.agents/skills` and Claude symlinks are left untouched;
the bootstrap manages only its Codex CLI and Codex App copies.

## Chrome DevTools MCP (WSL CLI and App)

Setup registers two independent servers in the CLI's `CODEX_HOME` and the detected
Windows App home (when configured to run agents in WSL):

| MCP name | Chrome port |
| --- | --- |
| `chrome-devtools` | 9222 |
| `chrome-devtools-9223` | 9223 |

The first server preserves the originally requested CLI command:

```bash
codex mcp add chrome-devtools -- \
  npx -y chrome-devtools-mcp@latest \
  --browser-url=http://127.0.0.1:9222
```

An identical registration is preserved. A disabled or differently configured server with
that name, invalid Codex configuration, or a non-regular config file stops setup without
replacing it. Both names in both homes are checked before registration begins. Other MCP
servers and settings are preserved. The App registration uses the absolute WSL npx path
and an explicit Node/npx PATH because the App server does not inherit the interactive
shell environment. If CLI and App share a single home, the common registration uses
this same App-safe runtime configuration. If runtime locations change, setup stops on
the conflicting registration; review and resolve it explicitly before rerunning setup.
The requested `@latest` is retained, so MCP package updates follow npm rather than the
bootstrap release. There is no legacy MCP configuration or compatibility shim to retain. The unreleased
single-port doctor flag is replaced by explicit port selection.

Setup uses an existing working Node runtime (20.19+, 22.12+, or 23+) and npx.
If Node is absent, it installs checksum-verified Node 22.23.2 for Linux x64/arm64 and
links node/npm/npx into `~/.local/bin`. An incompatible existing runtime, broken npx,
or an occupied installation target fails explicitly; setup does not replace user runtimes.
Ensure `~/.local/bin` is on PATH when starting Codex from a new shell.

To start the browser on Windows:

1. Install Google Chrome and enable `networkingMode=mirrored` in the `[wsl2]` section
   of `%USERPROFILE%\.wslconfig`. Apply WSL changes by restarting WSL after saving work.
2. Download [start-chrome-devtools.cmd](https://github.com/oteme/codex-wsl-bootstrap/raw/main/start-chrome-devtools.cmd)
   to Downloads. Double-click it for 9222, or run `start-chrome-devtools.cmd 9223`
   from a Windows terminal for the second profile. They use separate
   `%LOCALAPPDATA%\CodexChromeDevTools-9222` and `CodexChromeDevTools-9223` directories.
   Ports other than 9222/9223 are rejected. Setup does not change WSL networking or
   launch Chrome automatically.
3. In WSL, run `bash ~/.local/share/codex-wsl-bootstrap/doctor.sh --check-browser=9222`
   (or `--check-browser=9223` to check the second browser).
   Connection refusal, malformed responses and unexpected endpoints fail; no alternate
   browser or address is tried.
4. Restart Codex CLI and reload MCP servers in Codex App (or restart the App). Ask it
   to list pages using `chrome-devtools` or `chrome-devtools-9223` as appropriate.

The default setup doctor checks registration and runtime only. Passing setup does not mean
Chrome is running; `--check-browser=9222` / `--check-browser=9223` verifies only the selected live endpoint.
Either browser can be closed when not in use; a tool call to its server then fails explicitly
instead of connecting to the other profile. Add `CODEX_APP_HOME=/mnt/c/Users/<user>/.codex`
when running doctor manually to include App registration checks.
Chrome pages in this dedicated profile are accessible to the agent through MCP.

References: [Codex MCP](https://developers.openai.com/codex/mcp),
[Chrome MCP WSL guidance](https://github.com/ChromeDevTools/chrome-devtools-mcp/blob/main/docs/troubleshooting.md).

## Ralph policy gate

`ralph-run` gives every worker the Ralph worker protocol that ships with the skill
(`skills/ralph-run/assets/worker-protocol.md`). It sets how an iteration runs and when a story
passes: the story passes when the project's checks pass, a detail the PRD leaves open is decided
within the PRD and recorded, and anything that could not be verified or done (a live service, a
device, an account, an approval, an outside decision or record) is recorded in `progress.txt`
instead of keeping `passes: false`. Its fail-close and clean-break rules describe the code the
worker writes: no speculative fallback, no compatibility path the story does not require, obsolete
paths removed, no weakened tests. Where the project's `scripts/ralph/CLAUDE.md`, the PRD, or
`prd.json` conflicts with the protocol about when to stop or when a story passes, the protocol
wins, and a project cannot edit it. `ralph-bootstrap` generates `CLAUDE.md` as project notes with
an `Authorized actions` list for external resources.

The installed `prd` skill requires explicit failure behavior and compatibility decisions, settles
open implementation choices in the PRD instead of turning them into spikes or prerequisites, and
keeps a pre-run checklist for work only a person can do that no story may depend on. The `ralph`
skill carries those decisions into acceptance criteria only where a story implements them, writes
no criterion or instruction that keeps `passes` false for an outside decision or verification,
and leaves `CLAUDE.md` unchanged when converting a PRD.

During `ralph-run`, workers leave each story uncommitted. A fresh Codex process statically reviews
the exact staged diff in a disposable detached Git worktree for swallowed failures, unrequested
fallback/legacy paths, and weakened tests. Acceptance criteria are consulted only for explicit
policy exceptions; the reviewer does not grade general story correctness or completeness.
Reviewer-created files are discarded with that worktree. Only an approved diff is committed and
allowed to count as passing. A rejected story returns to `passes: false` and is repaired in the
next iteration. Workers are told to finish the selected story within their turn. Nothing stops the
run because a story is incomplete or rejected: the work stays in the working tree and the next
iteration continues from it, until every story passes or the iteration budget (the given number,
or twice the pending stories, at least 10) is used up. The runner keeps only story `passes` and
`notes` changes from the worker's `prd.json` and discards other edits with a warning. Uncommitted
changes present before a run are kept and enter the next approved story commit.

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

## Cursor CLI

Setup installs Cursor CLI with the official installer (`https://cursor.com/install`, which does not
edit shell profiles) when `agent` is missing, and runs `agent update` when it is older than
`2026.09.28`, the version verified on 2026-09-29. Sign in once per device with `agent login`.

Cursor loads `~/.codex/skills`, `~/.claude/skills` and the Claude Code hooks in
`~/.claude/settings.json` by itself (Cursor Settings > Agents > Third-Party Imports, on by default;
`cli-config.json` has no setting for it). The bootstrap therefore copies no skills into Cursor, and it
refuses a `CODEX_HOME` that does not resolve to `~/.codex`: the whole setup, Codex included, stops
before it changes any Codex, Cursor or Antigravity setting (only the gstack and Ralph source
checkouts come first), in a dry run too. The same holds for the other Cursor and Antigravity file
checks and for an `AGENTS.md` whose managed-block markers do not pair up. On a machine that also
has Claude Code,
skills with the same name appear once, and the Claude copy is the one Cursor lists; Cursor names
skills by their folder, so Codex's gstack skills keep their `gstack-*` names. The Claude Code hooks
run in Cursor next to the Safe Hook, so a Claude-side RTK hook can still rewrite a command that the
Safe Hook leaves unchanged.

| What | Where |
| --- | --- |
| Shared guidance | A `sessionStart` hook returns it as `additional_context`, because Cursor has no user-level instructions file. The managed copy is `~/.cursor/hooks/codex-workstation-bootstrap/guidance.md`. |
| RTK Safe Hook | A `preToolUse` adapter for `Shell`, registered with `failClosed`: it returns only `updated_input` for an allowlisted rewrite, `{}` otherwise, and an explicit deny for invalid input. It reuses the Codex hook rules. |
| Chrome DevTools MCP | `chrome-devtools` (9222) and `chrome-devtools-9223` in `~/.cursor/mcp.json`. Servers there need no per-project approval. |
| Ralph | `ralph-run-cursor` in `~/.cursor/skills`. In Cursor, a skill named `ralph-run` is Codex's or Claude's. A `beforeSubmitPrompt` hook adds a finished run's result to the next message of the conversation that started it. |

## Antigravity CLI

Setup installs Antigravity CLI with the official installer
(`https://antigravity.google/cli/install.sh --skip-path --skip-aliases`, so shell profiles stay
untouched) when `agy` is missing, and runs `agy update` when it is older than `1.2.13`. Sign in once
per device by running `agy` and following the prompt.

Antigravity reads no other tool's configuration, so everything is registered explicitly:

| What | Where |
| --- | --- |
| Shared guidance | A managed block in `~/.gemini/AGENTS.md` (Gemini CLI reads `GEMINI.md`, so it is unaffected). |
| Skills | `~/.gemini/config/skills.json` lists Antigravity's own `~/.gemini/antigravity-cli/skills` (with its `ralph-run`) first, then `~/.codex/skills` with `"exclude": ["ralph-run"]`. Antigravity shows the model only as many skill descriptions as its budget allows; with the Codex skills registered, the skills in its own directory were left out until that directory was listed first. Skills in `~/.gemini/skills` and some built-in skills can still be left out. `exclude` matches exact folder names. Antigravity lists skills by their frontmatter names, so gstack skills appear without the `gstack-` prefix. |
| RTK Safe Hook | A `PreToolUse` adapter for `run_command` named `codex-workstation-bootstrap-rtk` in `~/.gemini/config/hooks.json`. It answers `{"decision":"ask"}` and rewrites through `overwrite.CommandLine`. agy blocks the command whenever a hook fails. |
| Chrome DevTools MCP | `chrome-devtools` (9222) and `chrome-devtools-9223` in `~/.gemini/config/mcp_config.json`. The 0-byte file agy creates on first run means no servers; any other file that is not plain JSON (agy also accepts comments) is refused. |
| Ralph | `ralph-run` in `~/.gemini/antigravity-cli/skills`. A `PreInvocation` hook in the same named entry, `codex-workstation-bootstrap-rtk`, adds a finished run's result to the conversation that started it when it next goes to the model. |

Other entries in these files, such as Orca's `orca-status` hook, are preserved.

## Ralph from Cursor and Antigravity

`ralph-run-cursor` and the Antigravity `ralph-run` run the same loop as Codex (`ralph-loop.sh`),
with the same worker protocol, policy review, exact-tree commit and iteration budget:

- Workers and the reviewer run headless: `agent -p --force --trust --sandbox disabled` and
  `agy --dangerously-skip-permissions`.
- The reviewer must report the `git write-tree` of the staged snapshot it reviewed. A review
  without that exact tree is invalid output, so a reviewer that could not run commands in the
  review worktree cannot approve. agy constrains the review with `--json-schema`; Cursor has no
  such option and receives the schema in the prompt. The Cursor reviewer is told to read the diff
  through `| cat`, because the Claude Code RTK hook that Cursor also runs cuts a plain `git diff`.
- A Cursor run that does not end with a successful `result` event, and an agy run whose status is
  not `SUCCESS`, whose `denied_actions` is not empty or whose stderr reports an auto-denied tool,
  is a hard error. agy exits 0 in these cases.
- The launcher reads the initiating conversation from `CURSOR_CONVERSATION_ID` or
  `ANTIGRAVITY_CONVERSATION_ID`. Neither CLI has a message queue, so when the run ends the
  supervisor leaves the result in an inbox named by that conversation
  (`~/.cursor/ralph-inbox/<conversation>/` or `~/.gemini/antigravity-cli/ralph-inbox/<conversation>/`)
  and records `notification=queued`. The result hook adds it to the conversation's next message
  (Cursor: `beforeSubmitPrompt` context; agy: a `PreInvocation` user message at the first model call
  of the next turn), whether the conversation is open in an interactive session or resumed later,
  and records `notification=delivered` once it has handed the result to the CLI. A session that was
  already running when setup installed the hook gets results only after it is restarted.

## Ralph models

Each agent's Ralph runs with that CLI's default model unless Ralph has its own. Saved Ralph defaults
live in a per-agent file that setup never rewrites:

| Agent | Settings file |
| --- | --- |
| Codex | `$CODEX_HOME/ralph.json` (normally `~/.codex/ralph.json`; the App home has its own) |
| Cursor | `~/.cursor/ralph.json` |
| Antigravity | `~/.gemini/antigravity-cli/ralph.json` |

```json
{"model": "claude-opus-5-thinking-high", "review_model": "gpt-5.3-codex-high"}
```

Both keys are optional. Ask for a model when starting a run ("run ralph with <model>"), and the
skill passes `--model` (workers) or `--review-model` (policy reviewer) to the launcher for that run
only. Each role uses the run value, then the saved value; the reviewer then falls back to the
worker's model; with no model anywhere the CLI default is used, exactly as before. Cursor and agy
check the names against `agent models` and `agy models` before a run starts; Cursor's parameterized
names such as `claude-opus-4-8[effort=high]` are not listed there, so they are left to Cursor, which
rejects an invalid one in the first iteration. An empty run model is refused. Codex has no model
list, so an unknown name fails the first `codex exec`. An invalid settings file stops every run of
that agent, and Doctor reports it.

## Verify

```bash
./doctor.sh
```

If Codex, Cursor CLI or Antigravity CLI is not signed in yet:

```bash
codex login --device-auth
agent login
agy    # follow the sign-in prompt once
```

Doctor also checks Cursor CLI and Antigravity CLI: their versions, hooks, guidance, Chrome MCP
servers, the Antigravity skills registration and both Ralph runtime records. Without
`--skip-login` it checks all three sign-ins.

To verify both Codex homes again later, pass the App home to Doctor explicitly:

```bash
CODEX_APP_HOME=/mnt/c/Users/<user>/.codex ./doctor.sh
```

Then restart Codex CLI and Codex App so they reload the installed skills. Open `/hooks` in each
and trust the reviewed RTK Safe Hook definition; the bootstrap intentionally does not bypass
Codex hook trust. Codex trusts the hook definition in `hooks.json`, so an update that changes only
the hook script does not ask again.

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
plugins remain separate; bootstrap-managed guidance, skills, hooks and Chrome MCP entries are installed in both.

The internal PowerShell launcher supports `-CodexAppHome`, and its WSL installer receives
`CODEX_APP_HOME`. These are also exercised in isolated regression fixtures. For workstation
setup, use `Downloads/setup-wsl.cmd` so App detection and path conversion run together.

Invalid App paths and unmanaged skill collisions fail closed. The installer does not add a
Windows-native fallback: App sharing requires its WSL execution mode.

The bootstrap keeps its pinned gstack checkout under
`~/.local/share/codex-workstation-bootstrap/gstack`. A separate `~/gstack` checkout is left
untouched, including the generated `gstack-*` skill-name patches that gstack may keep there.

The internal installer supports `BOOTSTRAP_STATE_DIR` for the shared source directory;
`GSTACK_INSTALL_DIR` and `RALPH_SOURCE_DIR` override their individual checkout locations.
Regression fixtures exercise these overrides in temporary directories. Workstation changes
must be delivered through a merged PR and `Downloads/setup-wsl.cmd`.

## Update pinned versions

The default gstack and Ralph commits and the RTK release/checksums are pinned in `install.sh`
for reproducible setup. Node's release and checksums are pinned in `scripts/ensure-node.sh`.
Test proposed pins using isolated regression fixtures, then update the corresponding constants
and checksums in a PR. After merging, apply them with `Downloads/setup-wsl.cmd`.

## Security boundary

Authentication files, API keys, browser cookies, shell history, and existing Codex
session data are never copied. Each device performs its own Codex, Cursor and Antigravity sign-in.

Local `.gstack/` runtime state is excluded by `.gitignore`; do not remove that rule when
publishing this bundle.
