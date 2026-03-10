---
name: scriptoria
description: >
  Manage automation scripts with Scriptoria. Use when the user requests
  script management actions like "add a script", "run my backup", "schedule
  a task every hour", "list my scripts", or "set up a cron job".
metadata:
  author: scriptoria
  version: "0.1.2"
---

# Scriptoria — Automation Script Manager

Manage, run, and schedule shell scripts on macOS via the `scriptoria` CLI.

## Scheduling Policy

- For any request to create/update/enable/disable/remove a schedule, prefer `scriptoria schedule ...` commands.
- Do not default to direct `launchd` or `cron` file edits; only use them when the user explicitly requests low-level setup or when Scriptoria CLI cannot represent the requested schedule.

## Supported Coding Agents

- Codex (native app-server mode)
- Claude (via local adapter exposing the same app-server JSON-RPC contract)
- Kimi (via local adapter exposing the same app-server JSON-RPC contract)

## File Conventions

When creating new scripts or skill files, always place them under the Scriptoria config directory:

- **Scripts** → `~/.scriptoria/scripts/` (e.g. `~/.scriptoria/scripts/my-task.sh`)
- **Skills** → `~/.scriptoria/skills/<name>/SKILL.md` (e.g. `~/.scriptoria/skills/my-skill/SKILL.md`)

**IMPORTANT: All scripts and skill files MUST be written under `~/.scriptoria/`. Never write to `/tmp`, project directories, or any other location.** Keeping everything in `~/.scriptoria/` ensures easy backup, migration, and prevents files from being lost.

## Quick Start: Creating a Task (Full Example)

Here's how to create, register, test, and schedule a script — end to end:

```bash
# 1. Write the script
mkdir -p ~/.scriptoria/scripts
cat > ~/.scriptoria/scripts/disk-usage-alert.sh << 'SCRIPT'
#!/bin/bash
# Alert if disk usage exceeds 80%
USAGE=$(df -h / | awk 'NR==2 {gsub(/%/,""); print $5}')
echo "Disk usage: ${USAGE}%"
if [ "$USAGE" -gt 80 ]; then
  echo "⚠️  WARNING: Disk usage is above 80%!"
  exit 1
fi
echo "Disk usage is normal."
SCRIPT
chmod +x ~/.scriptoria/scripts/disk-usage-alert.sh

# 2. Add to Scriptoria
scriptoria add ~/.scriptoria/scripts/disk-usage-alert.sh \
  --title "Disk Usage Alert" \
  --description "Check if root disk usage exceeds 80%" \
  --interpreter bash \
  --tags "monitoring,disk"

# 3. Test run
scriptoria run "Disk Usage Alert"

# 4. Schedule to run every 30 minutes
scriptoria schedule add "Disk Usage Alert" --every 30

# 5. Verify everything
scriptoria list
scriptoria schedule list
```

## Pre-flight Check

Before taking action, verify the CLI is available:

```bash
which scriptoria && scriptoria config show
```

If `which scriptoria` fails, install the CLI:

```bash
cd /path/to/Scriptoria
swift build
sudo ln -sf "$(pwd)/.build/debug/scriptoria" /usr/local/bin/scriptoria
```

## Commands Reference

### Add a script

```bash
scriptoria add <path> [options]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--title` | `-t` | Display name (defaults to filename) |
| `--description` | `-d` | Description text |
| `--interpreter` | `-i` | `auto`, `bash`, `zsh`, `sh`, `node`, `python3`, `ruby`, `osascript`, `binary` |
| `--tags` | | Comma-separated tags |
| `--skill` | | Path to a skill file for AI agents |
| `--task-name` | | Task name for post-script agent runs and memory |
| `--default-model` | | Default model used by post-script agent |

### Run a script

```bash
scriptoria run "Title"              # By title
scriptoria run 3A1F2B4C             # By UUID prefix
scriptoria run --id "3A1F2B4C-..."  # By explicit UUID
scriptoria run "Title" --model gpt-5.3-codex --no-steer
scriptoria run "Title" --agent-prompt "Focus on failing logs first"
scriptoria run "Title" --command "Please continue with tests" --command "/interrupt"
```

Common run flags:
- `--no-notify`: suppress completion notification
- `--scheduled`: scheduled mode (less output)
- `--model`: override post-script agent model
- `--agent-prompt`: append extra user instruction for agent stage
- `--skip-agent`: skip post-script agent stage
- `--no-steer`: disable interactive steering input
- `--command`: scripted steer/interrupt commands (repeatable, supports `/interrupt`)

### List / Search / Remove

```bash
scriptoria list                     # All scripts
scriptoria list --tag monitoring    # Filter by tag
scriptoria list --favorites         # Favorites only
scriptoria list --recent            # Recently run

scriptoria search "backup"          # Search title, description, tags
scriptoria tags                     # List all tags with counts

scriptoria remove "Title"           # Remove by title or UUID
```

### Schedule

```bash
# Add schedules (3 types)
scriptoria schedule add "Title" --every 10              # Every 10 minutes
scriptoria schedule add "Title" --daily 09:00            # Daily at 09:00
scriptoria schedule add "Title" --weekly "mon,fri@09:00" # Weekly

# Manage schedules
scriptoria schedule list
scriptoria schedule enable <id>
scriptoria schedule disable <id>
scriptoria schedule remove <id>
```

Weekly day names: `sun`, `mon`, `tue`, `wed`, `thu`, `fri`, `sat`

### Config

```bash
scriptoria config show              # Show current config
scriptoria config set-dir ~/data    # Change data directory
```

## Agent Workflow Tips

- After `scriptoria add`, the printed UUID can be used for `run` / `schedule` commands.
- For non-interactive automation, provide `--model` and `--no-steer` (or use `--scheduled`).
- Exit code of `scriptoria run` matches the script's exit code.
- Run history (stdout, stderr, exit code) is saved to the database.
- Chain commands for a complete workflow:

```bash
# Write → Add → Test → Schedule
cat > ~/.scriptoria/scripts/check.sh << 'SCRIPT'
#!/bin/bash
curl -sf https://example.com/health && echo "OK" || exit 1
SCRIPT
chmod +x ~/.scriptoria/scripts/check.sh
scriptoria add ~/.scriptoria/scripts/check.sh --title "Health Check" --tags "monitoring"
scriptoria run "Health Check"
scriptoria schedule add "Health Check" --every 15
```

## Pre-script Gate (Agent Trigger)

When GUI `Agent Trigger` is set to `Only when pre-script is true`, Scriptoria evaluates the script output gate before running agent stage.

Gate parser contract:
- Scriptoria reads the **last non-empty line of STDOUT**.
- Accepted values:
  - `true` / `1` / `yes` / `on` -> run post-script agent stage
  - `false` / `0` / `no` / `off` -> skip post-script agent stage
- If the last non-empty line is not parseable (or JSON with a recognized boolean field), trigger check is invalid and run is marked with trigger error.

Recommended gate-script pattern:
```bash
# keep logs above...
echo "true"   # or "false" as the final non-empty stdout line
```

## Troubleshooting

- **CLI not found**: Rebuild and re-link: `swift build && sudo ln -sf "$(pwd)/.build/debug/scriptoria" /usr/local/bin/scriptoria`
- **Script not found**: Use `scriptoria search "<keyword>"` to check the exact title, or use UUID from `scriptoria list`
- **Schedule not activating**: Run `scriptoria schedule list` to check status, then `scriptoria schedule disable <id>` + `scriptoria schedule enable <id>` to reset
