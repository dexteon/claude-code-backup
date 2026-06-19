# claude-code-backup

Windows-first backup for your Claude Code and OpenClaude configs, agents, hooks, MCP servers, skills, and conversation history — synced to two **private** GitHub repositories.

Adapted from [jtklinger/claude-code-backup-guide](https://github.com/jtklinger/claude-code-backup-guide). Rebuilt for Windows (Git Bash + Task Scheduler, no cron) and extended to back up **both** `~/.claude` (Claude Code) and `~/.openclaude` (OpenClaude) into separate repos.

---

## Why two repos?

Your `~/.claude` and `~/.openclaude` directories contain:
- OAuth tokens and API keys (`.credentials.json`, `.mcp.json`)
- Local-only secrets (`settings.local.json`)
- Conversation history (`history.jsonl`, `projects/`)
- Custom agents, hooks, skills, commands
- Plugin caches and MCP server configs

**These MUST be private.** This tooling splits them across two private repos so you can rotate one without touching the other, and so OpenClaude history never collides with Claude Code history.

This scripts repo (`claude-code-backup`) is the only thing that is **public** — the scripts themselves contain no secrets.

---

## What gets backed up

| Source dir             | Default target repo              | Visibility |
|------------------------|----------------------------------|------------|
| `~/.claude`            | `<you>/claude-config-backup`     | Private    |
| `~/.openclaude`        | `<you>/openclaude-config-backup` | Private    |

Excluded by default (regenerated or volatile):
- `cache/`, `logs/`, `backups/`, `paste-cache/`, `sessions/`, `projects/`
- `.git/`, `node_modules/`, `*.log`, `*.tmp`, `*.lock`, `.last-cleanup`
- Browser-style cache dirs (`Code Cache`, `GPUCache`, `Service Worker`)

> **Note on `projects/`:** The default exclude keeps history.jsonl but skips per-project conversation caches. If you want full conversation history backed up, edit `excludes=()` in `backup.sh`.

---

## Requirements

- Windows 10/11 (or any OS with Git Bash + bash)
- [Git for Windows](https://git-scm.com/download/win) — provides `bash.exe`, `git.exe`, `robocopy` is native
- [GitHub CLI](https://cli.github.com/) (`gh`) — authenticated with `repo`, `gist`, `workflow` scopes
- PowerShell 5.1+ (for Task Scheduler; not needed for manual runs)

Check auth:
```powershell
gh auth status
```
Token scopes must include at least `repo`. If not:
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

`setup.sh` will:
1. Verify `gh auth` and read your GitHub username.
2. Create `claude-config-backup` and `openclaude-config-backup` as **private** repos (or reuse if they already exist).
3. Write a local `.env` (git-ignored, `chmod 600`) with the repo names and paths.
4. Run `backup.sh` once to seed both repos.

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

Output goes through `robocopy /MIR` on Windows (with `rsync` or `cp -r` fallbacks on other platforms). Git add/commit/push is per-repo; commits are timestamped `backup <UTC ISO>`.

---

## Scheduling automatic backups (Windows Task Scheduler)

`schedule.ps1` registers a per-user scheduled task (no admin elevation needed).

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

What it does:
- Finds `bash.exe` (Git for Windows)
- Builds a `New-ScheduledTaskAction` that runs `bash ./backup.sh >> backup.log 2>&1`
- Registers under your user account with `LogonType Interactive` (no password storage, runs only when you're logged in)
- Task settings: `-StartWhenAvailable` (catches up after sleep/shutdown), 30 min execution time limit

Manual triggers after install:
```powershell
Start-ScheduledTask -TaskName 'ClaudeCodeBackup'
Get-ScheduledTask -TaskName 'ClaudeCodeBackup' | Get-ScheduledTaskInfo
```

Logs land in `backup.log` next to the scripts.

### Alternative: cron (WSL / Linux / macOS)

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

`restore.sh` is non-destructive: if the live target dir is non-empty, it renames it to `~/.claude.pre-restore.<timestamp>` before copying the repo over.

---

## What if I want different paths or repo names?

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
| `setup.sh`     | One-shot: creates private repos, writes `.env`, runs first backup |
| `backup.sh`    | Sync both source dirs into the two repos, commit, push            |
| `restore.sh`   | Pull both repos, mirror into the live dirs (non-destructive)      |
| `schedule.ps1` | Register/unregister Windows Scheduled Task                        |
| `.env`         | Generated by `setup.sh` — git-ignored, holds repo paths           |
| `.gitignore`   | Keeps `.env`, logs, and temp files out of the scripts repo        |

---

## Security model

- **Scripts repo (this one): public.** No secrets in scripts, README, or commit history.
- **Data repos (`*-config-backup`): private.** Created automatically with `--private`.
- `.env` is git-ignored at the scripts-repo level. Never commit it.
- If a token in a data repo leaks, treat it as a credential compromise: rotate the OAuth token, the MCP API keys, and any `*.local.json` secrets. GitHub's secret scanning will also catch common token formats if you enable push protection on the data repos.

---

## Differences from `jtklinger/claude-code-backup-guide`

- **Two source dirs, two repos.** Original backs up `~/.claude` only; this one also covers `~/.openclaude`.
- **Windows-native.** Uses `robocopy` instead of `rsync`, Git Bash instead of WSL, and Task Scheduler instead of `launchd`/`cron`.
- **Non-interactive setup.** `setup.sh` accepts repo names as args so it can run inside an installer.
- **Non-destructive restore.** `restore.sh` preserves the live dir with a timestamped `.pre-restore` rename.
- **No bundled pre-commit hooks.** Keeps the surface small; add your own if you want to redact secrets before push.

---

## License

MIT — see [LICENSE](LICENSE).
