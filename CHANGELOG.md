# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - 2026-06-05

### Added

- Custom provider support via `provider.json` per profile: set a custom `api_url`, `api_key`, and `model`.
- `openai_compat` provider type: routes requests through a local proxy that translates between Anthropic and OpenAI Chat Completions APIs, enabling LM Studio, vLLM, and compatible endpoints.
- `anthropic_compat` provider type: direct base URL and API key override, no proxy required.
- `mcc web <profile>` command: local web UI for managing provider configuration.

## [0.2.0]

### Added

- `mcc update` command to update an installer-based install to the latest release in place (reuses `install.sh` for OS/arch detection and checksum verification). Compares the installed version against the latest GitHub release and skips the download when already current (`--force` to reinstall anyway). Detects Homebrew-managed installs and defers to `brew upgrade mcc`.
- `mcc uninstall` command to remove mcc's data directory (`~/.multi-claude`) and the binary, with a confirmation prompt (`--yes`/`-y` to skip). Detects Homebrew-managed installs and defers to `brew uninstall`; never touches `~/.claude`.

## [0.1.0] - 2026-06-01

Initial release.

### Added

- `mcc` CLI for running multiple Claude Code profiles on one device, built in Zig 0.16.0 as a single dependency-free binary.
- Default profile passthrough: bare `mcc` runs `claude` against the real `~/.claude`, untouched.
- Profile commands: `mcc <profile>`, `mcc new <profile>`, `mcc delete <profile>`, `mcc ls`, `mcc which <profile>`, and `mcc doctor`.
- Share-everything model: profiles symlink `settings.json`, `CLAUDE.md`, `skills/`, and `plugins/` to `~/.claude` while keeping auth and live session state private.
- `--no-share` flag to create fully isolated profiles.
- Per-profile advisory locking (`flock` on `run.lock`) to guard against running the same profile twice.
- Guardrails: reserved `default` profile name, unknown-profile suggestions (Levenshtein), and delete that never touches shared data.
- Pass-through of extra arguments to `claude` via `--`.
- Homebrew formula (`Formula/mcc.rb`) and tap-based installation.
- `install.sh` installer for macOS, Linux, and WSL with OS/arch detection and checksum verification.
- Release automation (`.github/workflows/release.yml`): cross-compiled static binaries for `macos-arm64`, `macos-x64`, `linux-x64`, and `linux-arm64`, published to GitHub Releases with `SHA256SUMS`.
- Build-time version injection via `-Dversion` so `mcc --version` matches the released tag.

### Platform support

- macOS and Linux (including WSL). Native Windows is not supported because profile sharing relies on symlinks.

[Unreleased]: https://github.com/husseinAbdElaziz/multi-claude/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/husseinAbdElaziz/multi-claude/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/husseinAbdElaziz/multi-claude/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/husseinAbdElaziz/multi-claude/releases/tag/v0.1.0
