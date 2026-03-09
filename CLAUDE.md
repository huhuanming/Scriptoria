# Scriptoria

Scriptoria is a macOS automation script manager — a menu bar app + CLI tool for organizing, running, and scheduling shell scripts.

## Architecture

- **ScriptoriaApp** — SwiftUI macOS app (menu bar + main window)
- **ScriptoriaCLI** — Command-line tool (`scriptoria`)
- **ScriptoriaCore** — Shared library (models, storage, execution)
- Storage: SQLite via GRDB at `~/.scriptoria/` (configurable, supports iCloud)
- Scheduling: macOS launchd agents

## Build & Run

```bash
swift build                          # Build all targets
swift run scriptoria --help          # Run CLI
swift test                           # Run tests
```

## CLI Installation

The CLI binary is at `.build/debug/scriptoria` after building. To install system-wide:

```bash
# Option 1: Symlink (recommended for development)
sudo ln -sf "$(pwd)/.build/debug/scriptoria" /usr/local/bin/scriptoria

# Option 2: Via the GUI app
# Settings > General > Shell Command > Install
```

## CLI Reference

### `scriptoria add <path>` — Add a script

```bash
scriptoria add ./backup.sh
scriptoria add ~/scripts/deploy.sh --title "Deploy" --description "Deploy to prod" --interpreter bash --tags "deploy,prod"
```

Options:
- `-t, --title` — Display name (defaults to filename)
- `-d, --description` — Description text
- `-i, --interpreter` — One of: `auto`, `bash`, `zsh`, `sh`, `node`, `python3`, `ruby`, `osascript`, `binary`
- `--tags` — Comma-separated tags (e.g. `"backup,daily"`)

### `scriptoria list` — List scripts

```bash
scriptoria list                 # All scripts
scriptoria list --tag backup    # Filter by tag
scriptoria list --favorites     # Only favorites
scriptoria list --recent        # Recently run
```

Output shows: status icon, title, ID prefix, interpreter, tags, run count.

### `scriptoria run <title-or-id>` — Run a script

```bash
scriptoria run "Deploy"                           # By title
scriptoria run 3A1F2B4C-...                       # By full UUID
scriptoria run deploy --notify                    # Send macOS notification on finish
scriptoria run deploy --scheduled                 # Scheduled mode (auto-notify, less output)
scriptoria run --id "3A1F2B4C-..."                # Explicit --id flag
```

Exit code matches the script's exit code. Run history is saved to the database.

### `scriptoria search <query>` — Search scripts

```bash
scriptoria search backup        # Search title, description, tags
```

### `scriptoria remove <title-or-id>` — Remove a script

```bash
scriptoria remove "Deploy"
scriptoria remove 3A1F2B4C
```

### `scriptoria tags` — List all tags

```bash
scriptoria tags                 # Shows all tags with script counts
```

### `scriptoria schedule` — Manage scheduled tasks

#### List schedules

```bash
scriptoria schedule list        # Shows all schedules with status, next run time
scriptoria schedule             # Same (list is default)
```

#### Add a schedule

```bash
# Run every 30 minutes
scriptoria schedule add "Backup" --every 30

# Run daily at 09:00
scriptoria schedule add "Report" --daily 09:00

# Run on specific weekdays at a time
scriptoria schedule add "Deploy" --weekly "mon,wed,fri@09:00"
```

Schedule types:
- `--every <minutes>` — Interval-based (e.g. every 30 minutes)
- `--daily HH:MM` — Daily at a specific time
- `--weekly "days@HH:MM"` — Weekly on specific days. Days: `sun`, `mon`, `tue`, `wed`, `thu`, `fri`, `sat`

Schedules are backed by macOS launchd agents and persist across reboots.

#### Enable / Disable / Remove a schedule

```bash
scriptoria schedule enable <schedule-id>    # ID prefix works (e.g. "3A1F2B4C")
scriptoria schedule disable <schedule-id>
scriptoria schedule remove <schedule-id>
```

### `scriptoria config` — Configuration

```bash
scriptoria config show                      # Show current config
scriptoria config set-dir ~/my-data         # Set data directory
scriptoria config use-icloud                # Store data in iCloud Drive
```

## Typical AI Workflow

A complete example of adding a script, scheduling it, and verifying:

```bash
# 1. Write a script
cat > /tmp/health-check.sh << 'EOF'
#!/bin/bash
curl -sf https://example.com/health && echo "OK" || echo "FAIL"
EOF
chmod +x /tmp/health-check.sh

# 2. Add to Scriptoria
scriptoria add /tmp/health-check.sh --title "Health Check" --description "Check service health" --tags "monitoring,health"

# 3. Test run
scriptoria run "Health Check"

# 4. Schedule every 10 minutes
scriptoria schedule add "Health Check" --every 10

# 5. Verify
scriptoria list
scriptoria schedule list
```

## Key File Paths

- CLI entry: `Sources/ScriptoriaCLI/CLI.swift`
- Commands: `Sources/ScriptoriaCLI/Commands/`
- Models: `Sources/ScriptoriaCore/Models/` (Script, ScriptRun, Schedule)
- Storage: `Sources/ScriptoriaCore/Storage/` (ScriptStore, DatabaseManager, Config)
- Execution: `Sources/ScriptoriaCore/Execution/ScriptRunner.swift`
- Scheduling: `Sources/ScriptoriaCore/Scheduling/` (ScheduleStore, LaunchdHelper)
- App views: `Sources/ScriptoriaApp/Views/`
- App state: `Sources/ScriptoriaApp/AppState.swift`
- Theme: `Sources/ScriptoriaApp/Styles/Theme.swift`
