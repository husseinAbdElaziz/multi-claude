# mcc — Multi-Claude CLI

Run multiple [Claude Code](https://claude.ai/code) CLI profiles on one device. Every profile shares the same config, plugins, skills, settings and memory as the default by default, but is a separate runnable instance (e.g., a different account, with its own sessions). Full isolation is opt-in.

Built in **Zig 0.16.0** — no external dependencies, single static binary.

## Quick Start

```bash
# Build from source
zig build -Doptimize=ReleaseSafe

# Install
cp zig-out/bin/mcc /usr/local/bin/

# Create a shared profile (inherits settings, plugins, skills from ~/.claude)
mcc new personal

# Run claude with that profile
mcc personal

# Create a fully isolated profile (nothing shared)
mcc new work --no-share
```

## Commands

| Command | Description |
|---------|-------------|
| `mcc` | Run Claude with the **default** profile (identical to `claude`) |
| `mcc <profile>` | Run Claude with the specified profile |
| `mcc new <profile>` | Create a new shared profile |
| `mcc new <profile> --no-share` | Create a fully isolated profile |
| `mcc delete <profile>` | Delete a profile (never touches default) |
| `mcc ls` | List all profiles |
| `mcc which <profile>` | Show the CLAUDE_CONFIG_DIR for a profile |
| `mcc doctor` | Verify environment configuration |

### Extra Arguments

Pass arguments through to Claude using `--`:

```bash
mcc personal -- --resume
```

### Options

| Flag | Description |
|------|-------------|
| `--help`, `-h` | Show help |
| `--version`, `-v` | Show version |
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
