# Changelog

All notable changes to this project are documented in this file.

## [0.0.1.0] - 2026-08-26

### Fixed

- Isolated Ralph policy reviewers in disposable Git worktrees so coverage and other generated files cannot dirty the main worktree.
- Preserved fail-close behavior with detailed diagnostics for HEAD, staged, tracked, and untracked repository changes.
- Ensured reviewer setup, cleanup, command failures, and main-worktree mutations leave stories unapproved.

### Changed

- Restricted policy reviewers to static diff review; test, build, lint, coverage, and package-manager execution remains the worker and pre-commit hook's responsibility.
