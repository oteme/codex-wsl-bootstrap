# Changelog

All notable changes to this project are documented in this file.

## [0.6.1.0] - 2026-09-23

### Fixed

- The Ralph worker protocol now ships with the `ralph-run` skill (`assets/worker-protocol.md`), and the runner puts it in every worker prompt. Before, it lived only in the project's `scripts/ralph/CLAUDE.md`, which the runner called the worker's complete and authoritative specification. On 2026-09-23 the `ralph` conversion of a new plan replaced that file, dropped the rules that let a story pass with unverified items recorded, and added "leave `passes:false` until the runtime decision exists". The run then spent 39 of its 76 iterations on that one story without changing code.
- Where `CLAUDE.md`, the PRD, or `prd.json` conflicts with the protocol about when to stop or when a story passes, the protocol wins. Workers again decide details the PRD leaves open within its goals and Non-Goals and record the decision. They do not keep `passes: false` while waiting for an outside decision, record, approval, credential, measurement, or live verification. Product failure behavior, such as returning an error when a required record is missing, is still implemented.
- The `ralph` overlay again forbids criteria and instructions that keep `passes` false until an outside item exists, and ordering gates. It settles open implementation choices before writing `prd.json` and no longer replaces, archives, or rewrites `CLAUDE.md`; only `prd.json` and `progress.txt` are archived. 0.4.3.0 removed the gating rule as a mere counter to the old stop rules, but the stop pattern returned without them.
- The `prd` overlay and the shared AGENTS guidance settle implementation choices (runtime, service, library, format, method) in the plan or PRD. They no longer turn an open choice into a spike, release blocker, or pre-run prerequisite, and no story may depend on a pre-run checklist item.

### Changed

- `ralph-bootstrap` generates `CLAUDE.md` as project notes with only an `Authorized actions` list. An existing `CLAUDE.md` from an older bootstrap keeps working; the protocol takes precedence over it about when to stop or when a story passes.
- The runner fails before the first iteration when the worker protocol is missing, and Doctor checks that it is installed.

## [0.6.0.0] - 2026-09-23

### Added

- Add Orca's `orca-cli` and `computer-use` discovery skills to the bootstrap-managed Codex CLI
  and Windows Codex App homes. Each stub loads the version-matched guide from the selected Orca
  executable at use time.
- Verify both Orca skills in Doctor and cover their installation and unmanaged App collision
  behavior in regression tests.

### Unchanged

- The bootstrap does not install Orca itself and does not modify the shared `~/.agents/skills`
  source or Claude symlinks. Missing or incompatible Orca executables fail explicitly without a
  fallback runtime.

## [0.5.0.0] - 2026-09-22

### Changed

- The Ralph runner no longer stops for an incomplete or rejected story. The rejection, no-progress, and incomplete circuit breakers and their `RALPH_MAX_CONSECUTIVE_*` settings are removed; an iteration that completes no story, a rejected story, and a failing pre-commit hook all leave the work in the working tree and the next iteration continues from it.
- The run ends when every story passes or the iteration budget is used up. An omitted or zero budget now means twice the number of pending stories, at least 10, and the runner prints it; the result is `limit_reached` when the budget runs out.
- `prd.json` edits are sanitized instead of rejected: `ralph-state.py apply-transition` keeps only story `passes` and `notes` changes from the worker's file, discards metadata, specification, and added/removed-story edits with a warning, and accepts one or more stories completed in one iteration (`validate-transition` is replaced).
- Uncommitted changes outside `scripts/ralph` no longer block a run. They are listed, the worker is told to keep them, and they enter the next approved story commit; `scripts/ralph/logs/leftover.txt` and the resume matching are removed.
- The supervisor no longer reports a `blocked` status.
- The generated Ralph instructions tell the worker to set `passes: true` when the project's checks pass and to record anything it could not verify or do (a live service, a device, an account, an approval) in `progress.txt`, instead of leaving `passes: false`; one story is one iteration, as in the Claude loop.

### Unchanged

- The independent policy review, the exact-tree commit, the worker-commit and review-integrity checks, and the hard errors for a failed or silent `codex exec`.

## [0.4.3.0] - 2026-09-22

### Changed

- Fail-close and clean-break are stated as properties of the code being built, not of the work process. The shared AGENTS guidance, the `prd` and `ralph` overlays, and the generated Ralph instructions keep only the code rules (no silent fallback, no compatibility path the story does not require, obsolete paths removed, no weakened tests) and say so explicitly.
- Removed the rules that only existed to counter the earlier stop rules: decide-within-confirmed-decisions-and-continue, the confirmed-decisions table, the ID-reference rule for acceptance criteria, the "do not add gating criteria" rule, and the "still create `prd.json`" rule. The `prd` overlay no longer restricts clarifying questions.
- The `go-backend` skill no longer tells the agent to stop or surface a decision when rules conflict or a contract condition is missing; the conflict or gap is recorded and not filled with a fallback.
- The pre-run checklist for work only a person can do stays, under its own heading in the `prd` overlay, and the `ralph` overlay keeps the `description` and human-only-work constraints under a `Runner constraints` heading. The runner itself (review, single-story validation, breakers, dirty-tree check) is unchanged.

### Added

- Regression: the shared policy texts, the generated Ralph instructions, and the `go-backend` skill contain no stop, surface, or refuse-to-convert rule.

## [0.4.2.0] - 2026-09-09

### Changed

- Workers are told to complete the selected story within their turn. The runner prompt and the generated Ralph instructions no longer present handing unfinished work to a later iteration as a normal path; the leftover record stays as a safety net for interrupted runs.
- The no-progress breaker now counts iterations that leave the working tree unchanged outside `scripts/ralph` and `docs/`, not iterations without a completed story. A separate cap, `RALPH_MAX_CONSECUTIVE_INCOMPLETE` (default 10), bounds consecutive incomplete iterations on one story.

### Added

- Regression for a worker that keeps changing files without completing the story: it is not stopped by the no-progress breaker and is stopped by the incomplete cap.

## [0.4.1.0] - 2026-09-08

### Fixed

- Record the worker's uncommitted work in `scripts/ralph/logs/leftover.txt` when a `prd.json` validation fails (metadata or story-specification edits, wrong story), so the next run resumes instead of refusing to start; `prd.json` is still restored.
- Tell workers, in the runner prompt and the generated instructions, to change only the completed story's `passes` and `notes` in `prd.json`; the `ralph` overlay keeps `description` free of progress state because any later edit to it is rejected.
- Regression: a worker that edits `description` fails closed, leaves resumable work, and the following run completes.

## [0.4.0.0] - 2026-09-08

### Changed

- Replaced the "stop as blocked" rule in the shared AGENTS guidance and the generated Ralph instructions: a decision the PRD does not settle is made within its confirmed design decisions and recorded in `progress.txt`, and the generated instructions carry an `Authorized actions` list for external resources.
- The Ralph runner no longer fails a run when an iteration completes no story: the uncommitted work stays in place, the next iteration continues from it, and three consecutive no-progress iterations on the same story stop the run as blocked (`RALPH_MAX_CONSECUTIVE_NO_PROGRESS`).
- The runner records uncommitted work in `scripts/ralph/logs/leftover.txt` after no-progress iterations, policy rejections, and worker failures, and a later run resumes only when the working tree matches that record exactly.
- The `prd` overlay requires a confirmed-decisions table and a pre-run checklist for work only a person can do; the `ralph` overlay references decisions by ID instead of copying policy text and serial gates into every story, and no longer refuses to create `prd.json` for open decisions.
- The shared gstack guidance asks Codex to present one review section's findings in a single question call, and the global workstation-update note is reduced to the direct-install prohibition.

### Added

- `ralph-state.py next-story` and a distinct exit status 3 for a validated no-transition result.
- Regressions for no-progress continuation, the no-progress breaker, the already-complete PRD, leftover resume and mismatch, and the rewritten policy texts.

## [0.3.0.0] - 2026-09-07

### Added

- Register Chrome DevTools MCP in the WSL CLI and WSL-backed App with separate localhost ports 9222 and 9223, preserving identical registrations and rejecting conflicts.
- Prepare Node.js/npx, installing checksum-verified Node 22.23.2 only when Node is absent; reject incompatible user runtimes and occupied targets.
- Add a Windows Chrome launcher with separate profiles for 9222/9223 and per-port live connection verification in doctor.
- Pin the App MCP executable path and Node PATH to setup-resolved WSL tools, avoiding the App server's missing interactive shell PATH.
- Cover MCP configuration preservation, invalid configuration diagnostics, Node installation guards and isolated first-install/reinstall fixtures.

### Changed

- Document the Chrome startup requirements and distinguish installation checks from live browser connectivity.
- Remove direct-install instructions in favor of the required merge-then-Windows-launcher route.

## [0.2.2.0] - 2026-09-07

### Fixed

- Made Ralph's worker, reviewer and completion notification use the absolute Codex CLI path recorded by setup, preventing desktop app PATH ordering from selecting an older CLI.
- Fail before work when the installed runtime record or executable is unavailable; preserve the initiating app's CODEX_HOME and configured model.
- Added regressions for a shadowing incompatible CLI, both installed skill homes, reinstall, invalid records and failed CLI version probes.

## [0.2.1.0] - 2026-09-07

### Fixed

- Replaced Ralph's parent-model polling with a detached supervisor that queues one terminal result to the initiating Codex thread.
- Kept worker and reviewer output in log files, preserved independent review and exact-tree commit gates, and added repository-wide protection against duplicate runners.
- Prevented worker/reviewer background processes from retaining the runner lock after completion.

### Added

- Added durable run results, separate notification-failure reporting, interruption handling, and process-identity checks for lost supervision.
- Added notification process and runner integration regressions, plus Linux and Windows CI checks.
- Recorded the required setup route in repository and distributed AGENTS guidance: merge changes first, then use Downloads/setup-wsl.cmd; do not directly copy or install skills.

### Changed

- Documented verified WSL CLI and Windows App queue/resume behavior and the limits of notification delivery.

## [0.2.0.0] - 2026-08-31

### Added

- Enabled the Windows Codex App to receive the same bootstrap-managed skills, shared guidance, and RTK Safe Hook as Codex CLI when agents run in WSL.
- Added automatic App detection to the Windows launcher and an explicit `CODEX_APP_HOME` path for direct WSL installs.
- Added regression coverage for App home validation, model reuse, dual-home doctor checks, and launcher behavior.

### Changed

- Kept App-specific configuration, authentication, sessions, and plugins separate while reusing the CLI model profile for generated App skills.
- Required the App's WSL execution mode and a Windows user `.codex` path, failing closed before either Codex home is modified when the setup is invalid.

## [0.1.2.0] - 2026-08-29

### Fixed

- Kept bootstrap's pinned gstack checkout separate from a user's `~/gstack`, so generated skill-name changes no longer block setup reruns.
- Preserved explicit gstack and Ralph checkout overrides while sharing a dedicated bootstrap state directory by default.

### Added

- Added regression coverage proving a dirty legacy `~/gstack` remains untouched and all checkout-path overrides retain precedence.

## [0.1.1.0] - 2026-08-29

### Changed

- Restored Ralph's independent reviewer to its original fail-close and clean-break policy scope, so unrelated acceptance criteria no longer block otherwise valid iterations.
- Limited policy findings to fallback and swallowed-error behavior, compatibility or retained legacy paths, required removals, and weakened tests.

### Removed

- Removed the catch-all acceptance finding category and its general story-completeness review path.

### Added

- Documented why the reviewer became broader during its initial implementation and added regression coverage that keeps the policy-only boundary intact.

## [0.1.0.2] - 2026-08-27

### Fixed

- Made the permanent RTK Safe Hook regression test independent of the caller's working directory, preventing Windows-mounted Downloads I/O errors during WSL setup.

## [0.1.0.1] - 2026-08-27

### Fixed

- Preserved RTK Safe Hook regression output when Doctor reports a failure, so cross-device setup errors show the actionable cause.

## [0.1.0.0] - 2026-08-27

### Added

- Installed pinned, checksum-verified RTK releases through the workstation bootstrap.
- Added a Codex-native Safe Hook that rewrites only allowlisted simple Bash commands and fails closed on invalid hook or RTK state.
- Added idempotent `hooks.json` merging, permanent RTK hook regression tests, and doctor checks.

## [0.0.1.0] - 2026-08-26

### Fixed

- Isolated Ralph policy reviewers in disposable Git worktrees so coverage and other generated files cannot dirty the main worktree.
- Preserved fail-close behavior with detailed diagnostics for HEAD, staged, tracked, and untracked repository changes.
- Ensured reviewer setup, cleanup, command failures, and main-worktree mutations leave stories unapproved.

### Changed

- Restricted policy reviewers to static diff review; test, build, lint, coverage, and package-manager execution remains the worker and pre-commit hook's responsibility.
