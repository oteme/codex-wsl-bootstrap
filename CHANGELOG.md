# Changelog

All notable changes to this project are documented in this file.

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
