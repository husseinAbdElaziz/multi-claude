# mcc — Multi-Claude CLI

Run multiple [Claude Code](https://claude.ai/code) CLI profiles on one device. Every profile shares the same config, plugins, skills, settings and memory as the default by default, but is a separate runnable instance (e.g., a different account, with its own sessions). Full isolation is opt-in.

Built in **Zig 0.16.0** — no external dependencies, single static binary.

## Install

> mcc supports **macOS** and **Linux** (including **WSL**). Native Windows is not supported because profile sharing relies on symlinks.

### Homebrew (macOS / Linux)

```bash
brew tap husseinAbdElaziz/tap
brew install mcc
```

### Install script (macOS / Linux / WSL)

```bash
curl -fsSL https://raw.githubusercontent.com/husseinAbdElaziz/multi-claude/main/install.sh | bash
```

The script downloads the right prebuilt binary for your OS/arch, verifies its checksum, and installs it to `/usr/local/bin` (or `~/.local/bin` if that isn't writable). Override with `MCC_VERSION` or `MCC_INSTALL_DIR`:

```bash
MCC_VERSION=0.1.0 MCC_INSTALL_DIR="$HOME/bin" \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/husseinAbdElaziz/multi-claude/main/install.sh)"
```

### From source

```bash
zig build -Doptimize=ReleaseSafe
cp zig-out/bin/mcc /usr/local/bin/
```

## Update

```bash
mcc update          # no-op if already on the latest release
mcc update --force  # reinstall even if already current
```

Checks the latest GitHub release and, if newer than the installed version, fetches it and replaces the binary in place (reusing the install script for OS/arch detection and checksum verification). If you're already on the latest version it does nothing. If mcc was installed via Homebrew, it defers to `brew update && brew upgrade mcc`. Requires `curl` or `wget`.

## Uninstall

```bash
mcc uninstall          # prompts for confirmation
mcc uninstall --yes    # no prompt
```

This removes mcc's data directory (`~/.multi-claude`, i.e. all profiles) and the `mcc` binary. Your real `~/.claude` is never touched. If mcc was installed via Homebrew, the binary is left in place and you're directed to `brew uninstall mcc`.

## Quick Start

```bash
# Create a shared profile (inherits settings, plugins, skills from ~/.claude)
mcc new personal

# Run claude with that profile
mcc personal

# Create a fully isolated profile (nothing shared)
mcc new work --no-share
```

## Commands

| Command                        | Description                                                     |
| ------------------------------ | --------------------------------------------------------------- |
| `mcc`                          | Run Claude with the **default** profile (identical to `claude`) |
| `mcc <profile>`                | Run Claude with the specified profile                           |
| `mcc new <profile>`            | Create a new shared profile                                     |
| `mcc new <profile> --no-share` | Create a fully isolated profile                                 |
| `mcc delete <profile>`         | Delete a profile (never touches default)                        |
| `mcc ls`                       | List all profiles                                               |
| `mcc which <profile>`          | Show the CLAUDE_CONFIG_DIR for a profile                        |
| `mcc doctor`                   | Verify environment configuration                                |
| `mcc update`                   | Update mcc to the latest release (defers to brew if managed)    |
| `mcc uninstall`                | Remove mcc's data and binary (never touches `~/.claude`)        |

### Extra Arguments

Pass arguments through to Claude using `--`:

```bash
mcc personal -- --resume
```

### Options

| Flag               | Description          |
| ------------------ | -------------------- |
| `--help`, `-h`     | Show help            |
| `--version`, `-v`  | Show version         |
| `--verbose`, `-vv` | Enable debug logging |

## How It Works

The default profile is the real `~/.claude` — untouched by `mcc`. Non-default profiles use `CLAUDE_CONFIG_DIR` to point at a composed config directory under `~/.multi-claude/profiles/<name>/config/`.

### Shared Resources (symlinked to `~/.claude`)

- `settings.json` — user settings
- `CLAUDE.md` — global memory
- `skills/` — global skills
- `plugins/` — marketplaces, cache, data, indices

### Per-Profile Resources (private)

- Auth / account credentials
- `sessions/`, `history.jsonl`, `shell-snapshots/`, `todos/`, `projects/` — live session state

With `--no-share`, nothing is shared — the profile is fully independent.

## Directory Layout

```
~/.claude/                          # DEFAULT profile (untouched)
  settings.json  CLAUDE.md  skills/  plugins/

~/.multi-claude/
  profiles/
    personal/
      manifest.zon                  # profile metadata
      config/                       # composed CLAUDE_CONFIG_DIR
        settings.json  -> ~/.claude/settings.json   (symlink)
        skills/        -> ~/.claude/skills           (symlink)
        plugins/       -> ~/.claude/plugins          (symlink)
        sessions/                          (private dir)
      run.lock                         # advisory lock
```

## Concurrency

- Multiple profiles can run concurrently without clobbering each other
- Per-profile advisory lock (`flock` on `run.lock`) prevents the same profile from running twice
- Shared files are symlinked (read-only during runtime)

## Guardrails

- `default` is a reserved name — `mcc new default` and `mcc delete default` are rejected
- `mcc delete` only removes the profile directory — shared resources in `~/.claude` are never touched
- Running an unknown profile suggests creating it: `mcc new <profile>`

## Building

Requires [Zig 0.16.0](https://ziglang.org/).

```bash
# Debug build
zig build

# Release build
zig build -Doptimize=ReleaseSafe

# Run tests
zig build test
```

## Platform Support

- **macOS**: Supported
- **Linux**: Supported
- **Windows**: Symlink-based sharing is not supported

## License

MIT
