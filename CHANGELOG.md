# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project follows semantic versioning.

## [Unreleased]

### Added

- Nix flake and lock file for the Zig 0.17.1 development shell, Nix formatting
  check, musl shell, and zon2nix.
- Shared `.envrc` matching the zslay and uWebZockets direnv setup.
- Pre-commit configuration for Zig formatting, generic repository hygiene, and
  zon2nix-generated dependency views.
- Repository guides for architecture, coding style, contribution, CI/CD,
  security, agent workflow, skills, and third-party attribution.
- Shared skill pack for Zig 0.17.1, TigerStyle, testing, Nix, architecture,
  review, `untangle-codebase`, agents, and graphify, pinned by
  `skills-lock.json`.
- Graphify integration for OpenCode and Codex, including skill copies, the
  OpenCode plugin, and the Codex hook.
- `.github` contribution metadata: pull request template, commit convention,
  code of conduct, issue forms, and funding configuration.
- `CLAUDE.md` entry point that imports the canonical `AGENTS.md` rules.
- Architecture guidance that transport uses Zig 0.17.1 `std.Io` async I/O
  instead of libxev.
- README banner at the top of the page, matching the zslay and uWebZockets
  layout.
- Matching architect, developer, reviewer, integrator, and specialist agent
  definitions for agy, OpenCode, and Codex.
- `.codex/TEAM_WORKFLOW.md` with the shared handoff procedure.

### Changed

- Dependency metadata now lives in `build.zig.zon`; the flake no longer pins
  zslay directly, and the zon2nix pre-commit hook generates the Nix, JSON, and
  text views.
- Documentation no longer repeats the zslay version.
