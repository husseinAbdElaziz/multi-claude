# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.5.1] - 2026-06-07

### Fixed

- Custom models with a provider-routing prefix now work. Claude Code prepends segments to the model id (e.g. `anthropic/lmstudio/cyankiwi/Qwen3.6-27B-AWQ-INT4`); the proxy now matches the configured id as a suffix at a `/` boundary and rewrites the outbound request to the bare id, so the provider no longer returns `404 model does not exist`. Exact ids, globs, and `*` wildcards are unchanged.
- `mcc` (the default profile) now honors a globally-configured provider (`~/.multi-claude/provider.json`): it routes through the proxy and forces the configured model via `--model`, the same as a named profile — no profile creation required. With no provider configured it still launches `claude` directly.

## [0.5.0] - 2026-06-07

### Added

- Provider config UI now has an **API Format** dropdown (OpenAI-compatible vs Anthropic-compatible), so the endpoint's protocol is chosen explicitly instead of always defaulting to Anthropic. New providers default to OpenAI-compatible (Ollama, LM Studio, OpenAI, OpenRouter, vLLM).
- Provider config UI now has a **model dropdown** with a **Fetch Models** button that queries the provider's `/models` endpoint (`GET /api/fetch-models`) and lists available models. Selecting a model is now required before saving when an API URL is set.

### Fixed

- Custom (non-`claude-*`) models now route correctly: the launcher routes both `openai_compat` and `anthropic_compat` providers through the local proxy, so requests reach the configured endpoint instead of falling back to Anthropic.
- `anthropic_compat` providers no longer trigger Claude Code's "Detected a custom API key" prompt — routing through the proxy keeps `ANTHROPIC_API_KEY` out of Claude Code's environment.
- Model fetch (UI and proxy auto-discovery) no longer panics on `GET /models`: send a bodiless request instead of a zero-length body (which tripped a `requestHasBody()` assertion), and request `identity` encoding so responses aren't gzipped.

## [0.4.0] - 2026-06-07

### Added

- Update check on launch: when running a profile (`mcc` / `mcc <profile>`), mcc checks GitHub for a newer release and, on an interactive terminal, asks whether to update now (`y` runs `mcc update`; `n` continues). Never updates automatically. The check is throttled to at most once per 24h (cached in `~/.multi-claude/.update_check`) and bounded by a short network timeout; non-interactive shells (pipes/CI) print a one-line notice instead of prompting and never block.

### Security

- Proxy now requires a per-run secret on every request, passed via a custom header (`X-Mcc-Proxy-Secret`) so no other local process or browser page can drive the proxy with the user's real credential. Claude Code's own Anthropic auth flows through untouched for `claude-*` passthrough; the gate header is stripped before forwarding upstream.
- Provider config UI (`/api/`) now rejects cross-site requests (CSRF) via `Sec-Fetch-Site`/`Origin` checks, and validates profile names against an allowlist to block path traversal.
- Config files holding API keys are written `0600` (owner-only).
- UI escapes interpolated profile names to prevent XSS.

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

[Unreleased]: https://github.com/husseinAbdElaziz/multi-claude/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/husseinAbdElaziz/multi-claude/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/husseinAbdElaziz/multi-claude/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/husseinAbdElaziz/multi-claude/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/husseinAbdElaziz/multi-claude/releases/tag/v0.1.0
