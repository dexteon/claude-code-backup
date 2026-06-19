# claude-code-backup

Backs up your Claude Code and OpenClaude configs to two private GitHub repositories. Built for Windows (Git Bash and Task Scheduler, no cron), and covers both `~/.claude` and `~/.openclaude` so OpenClaude history never collides with Claude Code history.

Adapted from [jtklinger/claude-code-backup-guide](https://github.com/jtklinger/claude-code-backup-guide).

---

## Why two repos?

Your `~/.claude` and `~/.openclaude` directories contain a lot of sensitive material:

- OAuth tokens and API keys (`.credentials.json`, `.mcp.json`)
- Local-only secrets (`settings.local.json`)
- Conversation history (`history.jsonl`, `projects/`)
- Custom agents, hooks, skills, and commands
- Plugin caches and MCP server configs

All of it has to live in private repos. Splitting it across two of them means you can rotate one side without touching the other, and the two histories stay separate.

The scripts repo (this one) is the only public part. No secrets live in the scripts.

---

## What gets backed up

| Source dir             | Default target repo              | Visibility |
|------------------------|----------------------------------|------------|
| `~/.claude`            | `<you>/claude-config-backup`     | Private    |
| `~/.openclaude`        | `<you>/openclaude-config-backup` | Private    |

Excluded by default because they are regenerated or volatile:

- `cache/`, `logs/`, `backups/`, `paste-cache/`, `sessions/`, `projects/`, `tasks/`, `teams/`, `telemetry/`
- `.git/`, `node_modules/`, `*.log`, `*.tmp`, `*.lock`, `.last-cleanup`
- Browser-style cache dirs (`Code Cache`, `GPUCache`, `Service Worker`)

Note on `projects/`: the default exclude keeps `history.jsonl` but skips per-project conversation caches. If you want full conversation history backed up, edit the `EXCLUDE_DIRS` array in `backup.sh`.

---

## Requirements

- Windows 10/11, or any OS with Git Bash and `bash`
- [Git for Windows](https://git-scm.com/download/win), which provides `bash.exe` and `git.exe` (`robocopy` is native to Windows)
- [GitHub CLI](https://cli.github.com/) (`gh`), authenticated with at least the `repo` scope
- PowerShell 5.1 or newer (only needed for the Task Scheduler step)

Check your auth:

```powershell
gh auth status
```

Token scopes must include `repo`. If they don't:

```powershell
gh auth refresh -s repo,workflow
```

---

## Quick start

```bash
git clone https://github.com/dexteon/claude-code-backup.git
cd claude-code-backup
bash setup.sh
```

`setup.sh` does four things:

1. Verifies `gh auth` and reads your GitHub username.
2. Creates `claude-config-backup` and `openclaude-config-backup` as private repos, or reuses them if they already exist.
3. Writes a local `.env` (git-ignored, `chmod 600`) with the repo names and paths.
4. Runs `backup.sh` once to seed both repos.

You can also pass repo names non-interactively:

```bash
bash setup.sh dexteon/my-claude-backup dexteon/my-openclaude-backup
```

---

## Manual backups

```bash
# from the cloned scripts dir
./backup.sh              # full backup, both repos
./backup.sh --dry-run    # show what would be committed, no push
```

On Windows, files are copied with `robocopy /MIR` (the script falls back to `rsync` or `cp -r` on other platforms). Git add, commit, and push are per-repo. Commits are timestamped `backup <UTC ISO>`.

---

## Scheduling automatic backups (Windows Task Scheduler)

`schedule.ps1` registers a per-user scheduled task. No admin elevation needed.

Open PowerShell in this directory:

```powershell
# Daily at 09:00 (default)
.\schedule.ps1

# Custom time
.\schedule.ps1 -Hour 14 -Minute 30

# Every 6 hours instead of daily
.\schedule.ps1 -IntervalHours 6

# Remove the task
.\schedule.ps1 -Uninstall
```

What the script does:

- Finds `bash.exe` from Git for Windows.
- Builds a `New-ScheduledTaskAction` that runs `bash ./backup.sh >> backup.log 2>&1`.
- Registers the task under your user account with `LogonType Interactive`, so it runs only when you are logged in and never needs to store your password.
- Sets `-StartWhenAvailable` so the task catches up after sleep or shutdown, with a 30-minute execution time limit.

Manual triggers after install:

```powershell
Start-ScheduledTask -TaskName 'ClaudeCodeBackup'
Get-ScheduledTask -TaskName 'ClaudeCodeBackup' | Get-ScheduledTaskInfo
```

Logs land in `backup.log` next to the scripts.

### Alternative: cron (WSL, Linux, macOS)

```cron
# Edit with: crontab -e
0 9 * * * /bin/bash /path/to/claude-code-backup/backup.sh >> /path/to/claude-code-backup/backup.log 2>&1
```

---

## Restoring

```bash
# restore both into ~/.claude and ~/.openclaude
./restore.sh

# only one side
./restore.sh claude
./restore.sh openclaude

# preview without writing
./restore.sh --dry-run
```

`restore.sh` is non-destructive. If the live target directory is non-empty, it renames it to `~/.claude.pre-restore.<timestamp>` before copying the repo over, so you can roll back.

---

## Different paths or repo names?

Edit `.env`:

```bash
CLAUDE_BACKUP_REPO=dexteon/claude-config-backup
OPENCLAUDE_BACKUP_REPO=dexteon/openclaude-config-backup
CLAUDE_HOME=/c/Users/Dex/.claude
OPENCLAUDE_HOME=/c/Users/Dex/.openclaude
BACKUP_WORKDIR=/c/Users/Dex/.claude-backup-work
```

`.env` is read by `backup.sh`, `restore.sh`, and `setup.sh`.

---

## Files

| File           | Purpose                                                          |
|----------------|------------------------------------------------------------------|
| `setup.sh`     | One-shot installer: creates private repos, writes `.env`, runs first backup |
| `backup.sh`    | Syncs both source dirs into the two repos, commits, pushes       |
| `restore.sh`   | Pulls both repos and mirrors them into the live dirs (non-destructive) |
| `schedule.ps1` | Registers or removes a Windows Scheduled Task                    |
| `.env`         | Generated by `setup.sh`; git-ignored; holds repo paths           |
| `.gitignore`   | Keeps `.env`, logs, and temp files out of the scripts repo       |

---

## Security model

The scripts repo (this one) is public. No secrets live in scripts, README, or commit history.

The data repos (`*-config-backup`) are private, created automatically with `--private`. `.env` is git-ignored at the scripts-repo level. Do not commit it.

If a token in a data repo leaks, treat it as a credential compromise: rotate the OAuth token, the MCP API keys, and anything in `*.local.json`. GitHub's secret scanning will also catch common token formats if you enable push protection on the data repos.

---

## Differences from `jtklinger/claude-code-backup-guide`

- Two source dirs, two repos. The original backs up `~/.claude` only; this one also covers `~/.openclaude`.
- Windows-native. Uses `robocopy` instead of `rsync`, Git Bash instead of WSL, and Task Scheduler instead of `launchd` or `cron`.
- Non-interactive setup. `setup.sh` accepts repo names as arguments so it can run inside an installer.
- Non-destructive restore. `restore.sh` preserves the live directory with a timestamped `.pre-restore` rename.
- No bundled pre-commit hooks. The surface is kept small. Add your own if you want to redact secrets before push.

---

## License

MIT. See [LICENSE](LICENSE).
