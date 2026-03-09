---
name: scriptoria
description: >
  Manage automation scripts with Scriptoria. Use when the user requests
  script management actions like "add a script", "run my backup", "schedule
  a task every hour", "list my scripts", or "set up a cron job".
metadata:
  author: scriptoria
  version: "0.1.0"
---

# Scriptoria — Automation Script Manager

Manage, run, and schedule shell scripts on macOS via the `scriptoria` CLI.
Scriptoria stores scripts in a local SQLite database and uses macOS launchd for scheduling.

## Step 1: Check Environment

Run these checks before taking action:

```bash
# 1. Is the CLI installed?
which scriptoria

# 2. Show current config (data directory, db path)
scriptoria config show

# 3. List existing scripts
scriptoria list
```

- If `which scriptoria` fails → the CLI is not installed. See [Installation](#installation).
- If `scriptoria config show` works → the CLI is ready to use.

## Installation

The CLI binary must be symlinked to `/usr/local/bin/scriptoria`.

### From source (development)

```bash
cd /path/to/Scriptoria
swift build
sudo ln -sf "$(pwd)/.build/debug/scriptoria" /usr/local/bin/scriptoria
```

### From the GUI app

Open Scriptoria.app → Settings → General → Shell Command → click **Install**.

## Step 2: Choose an Action

### Add a script

Register an existing script file with Scriptoria.

```bash
# Basic — title is inferred from filename
scriptoria add ./backup.sh

# Full options
scriptoria add ~/scripts/deploy.sh \
  --title "Deploy Production" \
  --description "Deploy app to production server" \
  --interpreter bash \
  --tags "deploy,prod,ci"
```

**Options:**

| Flag | Short | Description |
|------|-------|-------------|
| `--title` | `-t` | Display name (defaults to filename without extension) |
| `--description` | `-d` | Description text |
| `--interpreter` | `-i` | `auto`, `bash`, `zsh`, `sh`, `node`, `python3`, `ruby`, `osascript`, `binary` |
| `--tags` | | Comma-separated tags |

The script file must exist at the given path. Relative paths are resolved from the current directory.

### Run a script

```bash
# By title
scriptoria run "Deploy Production"

# By UUID (full or prefix from `scriptoria list`)
scriptoria run 3A1F2B4C-XXXX-XXXX-XXXX-XXXXXXXXXXXX

# With macOS notification on completion
scriptoria run "Backup" --notify
```

Exit code matches the script's exit code. Run history (stdout, stderr, duration, status) is saved to the database.

### List scripts

```bash
scriptoria list                 # All scripts
scriptoria list --tag backup    # Filter by tag
scriptoria list --favorites     # Favorites only
scriptoria list --recent        # Recently run
```

### Search scripts

```bash
scriptoria search "backup"     # Matches title, description, tags
```

### Remove a script

```bash
scriptoria remove "Deploy Production"   # By title
scriptoria remove 3A1F2B4C              # By UUID or prefix
```

This removes the script from Scriptoria's database only. The script file on disk is not deleted.

### List tags

```bash
scriptoria tags                # Shows all tags with script counts
```

## Step 3: Schedule a Script

Scriptoria uses macOS launchd agents for persistent scheduling that survives reboots.

### Add a schedule

Three schedule types are available:

```bash
# Interval — run every N minutes
scriptoria schedule add "Health Check" --every 10

# Daily — run at a specific time
scriptoria schedule add "Daily Report" --daily 09:00

# Weekly — run on specific days at a time
scriptoria schedule add "Weekly Backup" --weekly "mon,wed,fri@09:00"
```

**Weekly day names:** `sun`, `mon`, `tue`, `wed`, `thu`, `fri`, `sat`

### List schedules

```bash
scriptoria schedule list       # Shows all schedules, status, next run time
```

### Enable / Disable / Remove

```bash
# Use schedule ID prefix from `scriptoria schedule list`
scriptoria schedule enable 3A1F2B4C
scriptoria schedule disable 3A1F2B4C
scriptoria schedule remove 3A1F2B4C
```

## Step 4: Configure

```bash
# Show current configuration
scriptoria config show

# Change data directory
scriptoria config set-dir ~/my-scriptoria-data

# Use iCloud Drive (syncs across Macs)
scriptoria config use-icloud
```

Data is stored at `~/.scriptoria/` by default:
- `db/scriptoria.db` — SQLite database (scripts, run history, schedules)
- `scripts/` — Optional script storage

## Agent-Specific Notes

### Claude Code / terminal-based agents

- All commands work directly via `bash`. No interactive prompts.
- After `scriptoria add`, the returned UUID can be used for subsequent `run` / `schedule` commands.
- Chain commands for a complete workflow:

```bash
# Write → Add → Test → Schedule in one flow
cat > /tmp/check.sh << 'SCRIPT'
#!/bin/bash
curl -sf https://example.com/health && echo "OK" || exit 1
SCRIPT
chmod +x /tmp/check.sh
scriptoria add /tmp/check.sh --title "Health Check" --tags "monitoring"
scriptoria run "Health Check"
scriptoria schedule add "Health Check" --every 15
```

### Sandboxed environments

If the agent cannot execute shell commands directly, instruct the user to:
1. Open Scriptoria.app
2. Use the GUI to add scripts, run them, and configure schedules

## Output

On success, all commands print a confirmation with relevant details (script ID, schedule ID, next run time). On failure, commands exit with code 1 and print an error message prefixed with `❌`.

## Troubleshooting

### CLI not found

```bash
# Check if binary exists
ls -la /usr/local/bin/scriptoria

# If broken symlink, rebuild and re-link
swift build && sudo ln -sf "$(pwd)/.build/debug/scriptoria" /usr/local/bin/scriptoria
```

### Script not found

- Verify the script title matches exactly (case-sensitive): `scriptoria search "<keyword>"`
- Use UUID instead of title: `scriptoria list` → copy the 8-char ID prefix

### Schedule not activating

```bash
# Check launchd status
scriptoria schedule list
# Look for "launchd: installed" vs "not installed"

# Re-enable if needed
scriptoria schedule disable <id>
scriptoria schedule enable <id>
```
