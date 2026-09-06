# Changelog

All notable changes to this project are documented in this file.

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
