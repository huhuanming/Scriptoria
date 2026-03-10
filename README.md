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
scriptoria add ./backup.sh --title "Backup" --task-name "Daily Backup" --default-model gpt-5.3-codex --tags "daily,infra"
scriptoria list --tag daily
scriptoria run "Backup" --model gpt-5.3-codex --no-steer
scriptoria schedule add "Backup" --daily 09:00
scriptoria search "deploy"
scriptoria tags
scriptoria config show
```

| Command | Description |
|---------|-------------|
| `add <path>` | Register a script (title/description/interpreter/tags/agent task/model defaults) |
| `list` | List scripts (filter by `--tag`, `--favorites`, `--recent`) |
| `run <title-or-id>` | Execute a script, optional post-script agent stage (`--model`, `--agent-prompt`, `--command`, `--skip-agent`) |
| `search <query>` | Search by title, description, or tags |
| `remove <title-or-id>` | Remove a script from the database |
| `tags` | List all tags with script counts |
| `schedule list` | Show all schedules with status and next run time |
| `schedule add` | Create interval (`--every`), daily (`--daily`), or weekly (`--weekly`) schedules |
| `schedule enable/disable/remove` | Manage existing schedules |
| `config show` | Show current configuration |
| `config set-dir <path>` | Change data directory |

### AI Agent Friendly

Scriptoria includes a reusable [skill](skills/scriptoria/SKILL.md) and a provider-agnostic agent runtime, so coding agents can manage scripts end to end.

#### Install the Scriptoria Skill (Codex)

```bash
# Install from local repo (recommended during development)
mkdir -p ~/.codex/skills/scriptoria
ln -sfn "$(pwd)/skills/scriptoria/SKILL.md" ~/.codex/skills/scriptoria/SKILL.md

# Or install from a GitHub repo path
python3 ~/.codex/skills/.system/skill-installer/scripts/install-skill-from-github.py \
  --repo <owner>/<repo> \
  --path skills/scriptoria \
  --ref main
```

After installation, restart Codex so the new skill is loaded.

#### Best-fit Tasks for This Skill

- Create/register scripts: `scriptoria add ...`
- Run scripts and inspect output/errors: `scriptoria run ...`, `scriptoria logs ...`
- Configure recurring jobs: `scriptoria schedule add|list|enable|disable|remove ...`
- Search, classify, and clean up script inventory: `scriptoria search|tags|remove ...`
- Memory-oriented post-script workflows (task/workspace summaries): `scriptoria memory ...`

This skill should prefer Scriptoria CLI scheduling commands over direct `launchd` or `cron` edits.

#### Supported Coding Agents

- **Codex (native)**: direct support via `codex app-server`
- **Claude (adapter mode)**: supported through a local adapter that exposes the same app-server JSON-RPC protocol
- **Kimi (adapter mode)**: supported through a local adapter with the same contract

Runtime provider selection is done by executable path (`SCRIPTORIA_CODEX_EXECUTABLE`), keeping `ScriptoriaCore` provider-agnostic.

Example agent workflow:

```bash
cat > /tmp/health-check.sh << 'EOF'
#!/bin/bash
curl -sf https://example.com/health && echo "OK" || echo "FAIL"
EOF
chmod +x /tmp/health-check.sh

scriptoria add /tmp/health-check.sh --title "Health Check" --tags "monitoring"
scriptoria run "Health Check" --model gpt-5.3-codex --no-steer
scriptoria schedule add "Health Check" --every 10
```

Why it works well with agents:

- CLI flows are automation-friendly and mostly non-interactive
- Structured status and stored run history simplify agent follow-up
- UUID-based references reduce ambiguity
- Full lifecycle coverage is available from CLI (create, run, schedule, inspect, clean up)

## Architecture

```
Scriptoria/
├── Sources/
│   ├── ScriptoriaApp/       # SwiftUI macOS app (menu bar + main window)
│   ├── ScriptoriaCLI/       # CLI tool (swift-argument-parser)
│   └── ScriptoriaCore/      # Shared library (models, storage, execution, scheduling)
├── Tests/
├── skills/scriptoria/       # Scriptoria skill definition
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
