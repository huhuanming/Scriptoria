# Scriptoria

A macOS automation script workshop — manage, run, and schedule shell scripts from both a native menu bar app and a powerful CLI.

Built with Swift, SwiftUI, SQLite ([GRDB](https://github.com/groue/GRDB.swift)), and macOS launchd.

## Features

### Native macOS App

- **Menu bar access** — Quick-launch scripts from the menu bar without switching windows
- **Script management** — Add, edit, organize, tag, and favorite your scripts
- **Run with live output** — Execute scripts and see stdout/stderr in real time
- **Run history** — Full execution history with output, exit codes, and duration
- **Schedule tasks** — Set up interval, daily, or weekly schedules backed by macOS launchd (persists across reboots)
- **Onboarding** — First-launch wizard to choose storage location
- **CLI installer** — One-click install of the `scriptoria` command from Settings

### CLI (`scriptoria`)

A full-featured command-line tool for terminal workflows and automation:

```bash
scriptoria add ./backup.sh --title "Backup" --tags "daily,infra"
scriptoria list --tag daily
scriptoria run "Backup" --notify
scriptoria schedule add "Backup" --daily 09:00
scriptoria search "deploy"
scriptoria tags
scriptoria config show
```

| Command | Description |
|---------|-------------|
| `add <path>` | Register a script (with title, description, interpreter, tags) |
| `list` | List scripts (filter by `--tag`, `--favorites`, `--recent`) |
| `run <title-or-id>` | Execute a script, save run history |
| `search <query>` | Search by title, description, or tags |
| `remove <title-or-id>` | Remove a script from the database |
| `tags` | List all tags with script counts |
| `schedule list` | Show all schedules with status and next run time |
| `schedule add` | Create interval (`--every`), daily (`--daily`), or weekly (`--weekly`) schedules |
| `schedule enable/disable/remove` | Manage existing schedules |
| `config show` | Show current configuration |
| `config set-dir <path>` | Change data directory |

### AI Agent Friendly

Scriptoria is designed to work seamlessly with AI coding agents like [Claude Code](https://claude.ai/claude-code).

**Claude Code Skill** — The project includes a [skill](skills/scriptoria/SKILL.md) that teaches Claude Code how to use Scriptoria. When the skill is active, Claude can:

- Write shell scripts and register them with `scriptoria add`
- Run scripts and inspect output via `scriptoria run`
- Set up automated schedules with `scriptoria schedule add`
- Search and manage your script library

Example agent workflow:
```bash
# Claude can do this entire flow autonomously:
cat > /tmp/health-check.sh << 'EOF'
#!/bin/bash
curl -sf https://example.com/health && echo "OK" || echo "FAIL"
EOF
chmod +x /tmp/health-check.sh

scriptoria add /tmp/health-check.sh --title "Health Check" --tags "monitoring"
scriptoria run "Health Check"
scriptoria schedule add "Health Check" --every 10
```

**Why it works well with agents:**

- All CLI commands are non-interactive — no prompts, no TTY required
- Structured output with clear success/error indicators
- UUID-based script references for unambiguous identification
- Full CRUD via CLI — agents never need the GUI
- Chainable commands for end-to-end automation in a single flow

## Architecture

```
Scriptoria/
├── Sources/
│   ├── ScriptoriaApp/       # SwiftUI macOS app (menu bar + main window)
│   ├── ScriptoriaCLI/       # CLI tool (swift-argument-parser)
│   └── ScriptoriaCore/      # Shared library (models, storage, execution, scheduling)
├── Tests/
├── skills/scriptoria/       # Claude Code skill definition
├── CLAUDE.md                # AI agent project context
└── Package.swift
```

**Data directory layout** (default `~/.scriptoria/`, configurable):

```
~/.scriptoria/
├── pointer.json             # Points to the active data directory
├── db/
│   └── scriptoria.db        # SQLite database (scripts, schedules, run history, config)
└── scripts/
    └── hello-world.sh       # Script files
```

## Requirements

- macOS 15.0+
- Swift 6.0+
- Xcode 16+

## Build & Run

```bash
# Build all targets
swift build

# Run CLI
swift run scriptoria --help

# Run tests
swift test
```

### Install the CLI

```bash
# Option 1: From source
swift build
sudo ln -sf "$(pwd)/.build/debug/scriptoria" /usr/local/bin/scriptoria

# Option 2: From the app
# Settings > General > Shell Command > Install
```

## License

MIT
