#!/usr/bin/env bash
# claude-code-backup — backup.sh
# Syncs ~/.claude and ~/.openclaude into two private GitHub repos.
#
# Usage:
#   ./backup.sh            # use config from ./.env
#   ./backup.sh --dry-run  # show what would happen, no commits/pushes
#
# Env (.env in same dir, or real env vars):
#   CLAUDE_BACKUP_REPO        e.g. dexteon/claude-config-backup
#   OPENCLAUDE_BACKUP_REPO    e.g. dexteon/openclaude-config-backup
#   CLAUDE_HOME               default: $HOME/.claude
#   OPENCLAUDE_HOME           default: $HOME/.openclaude
#   BACKUP_WORKDIR            default: $HOME/.claude-backup-work (clone roots)

set -euo pipefail

# --- locate .env -----------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
  set +a
fi

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
fi

# --- required config -------------------------------------------------------
: "${CLAUDE_BACKUP_REPO:?CLAUDE_BACKUP_REPO not set (run ./setup.sh first)}"
: "${OPENCLAUDE_BACKUP_REPO:?OPENCLAUDE_BACKUP_REPO not set (run ./setup.sh first)}"

CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
OPENCLAUDE_HOME="${OPENCLAUDE_HOME:-$HOME/.openclaude}"
BACKUP_WORKDIR="${BACKUP_WORKDIR:-$HOME/.claude-backup-work}"

# --- helpers ---------------------------------------------------------------
log()  { printf '[backup] %s\n' "$*"; }
fail() { printf '[backup][ERROR] %s\n' "$*" >&2; exit 1; }
run()  {
  if (( DRY_RUN )); then
    printf '[dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

command -v git >/dev/null || fail "git not found on PATH"
command -v gh  >/dev/null || fail "gh CLI not found on PATH"
gh auth status >/dev/null 2>&1 || fail "gh not authenticated (run: gh auth login)"

# --- rsync-replacement via robocopy (native, fast on Windows) --------------
# Falls back to cp -r when robocopy missing (WSL/Linux/macOS).
sync_dir() {
  local src="$1" dst="$2" label="$3"
  log "sync $label: $src -> $dst"

  if [[ ! -d "$src" ]]; then
    log "  source missing, skip ($label)"
    return 0
  fi
  mkdir -p "$dst"

  local excludes=(
    ".git" "node_modules" "*.log" "*.tmp"
    "cache" "logs" "Cache" "Code Cache" "GPUCache" "Service Worker"
    "backups" "paste-cache" "sessions" "projects"
    "*.output" "*.lock" ".last-cleanup"
  )

  if command -v robocopy >/dev/null 2>&1; then
    # Convert to robocopy args
    local rob_args=()
    for e in "${excludes[@]}"; do rob_args+=("/XD" "$e" "/XF" "$e"); done
    rob_args+=("/MIR" "/R:1" "/W:1" "/NFL" "/NDL" "/NJH" "/NP")
    if (( DRY_RUN )); then
      rob_args+=("/L")
    fi
    # robocopy exit codes 0-7 are success
    robocopy "$src" "$dst" "${rob_args[@]}" >/dev/null 2>&1 || {
      local rc=$?
      (( rc >= 8 )) && fail "robocopy failed (rc=$rc) for $label"
    }
  else
    # rsync if available
    if command -v rsync >/dev/null 2>&1; then
      local rs_args=( -a --delete )
      for e in "${excludes[@]}"; do rs_args+=( --exclude="$e" ); done
      if (( DRY_RUN )); then rs_args+=( --dry-run ); fi
      rsync "${rs_args[@]}" "$src/" "$dst/"
    else
      # plain cp fallback (no exclusions)
      run cp -rf "$src/." "$dst/"
    fi
  fi
}

push_repo() {
  local workdir="$1" repo="$2" label="$3"
  log "commit+push $label -> $repo"
  (
    cd "$workdir" || fail "workdir missing: $workdir"
    run git add -A
    # only commit if there are staged changes
    if ! run git diff --cached --quiet; then
      run git commit -m "backup $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    else
      log "  no changes ($label)"
    fi
    if (( DRY_RUN )); then
      log "  [dry-run] would push to $repo"
    else
      git push origin HEAD 2>&1 | sed 's/^/[backup]   /' || fail "push failed for $label"
    fi
  )
}

clone_or_pull_repo() {
  local repo="$1" dst="$2" label="$3"
  if [[ -d "$dst/.git" ]]; then
    log "existing clone: $label ($dst)"
    ( cd "$dst" && run git pull --rebase --ff-only 2>&1 | sed 's/^/[backup]   /' ) || true
  else
    log "clone $label -> $dst"
    mkdir -p "$dst"
    rmdir "$dst" 2>/dev/null || true
    if (( DRY_RUN )); then
      log "  [dry-run] would clone $repo"
    else
      git clone "https://github.com/$repo.git" "$dst" 2>&1 | sed 's/^/[backup]   /' \
        || fail "clone failed for $label"
    fi
  fi
}

# --- main ------------------------------------------------------------------
CLAUDE_WORKDIR="$BACKUP_WORKDIR/claude"
OPENCLAUDE_WORKDIR="$BACKUP_WORKDIR/openclaude"

mkdir -p "$BACKUP_WORKDIR"

clone_or_pull_repo "$CLAUDE_BACKUP_REPO"     "$CLAUDE_WORKDIR"     "claude"
clone_or_pull_repo "$OPENCLAUDE_BACKUP_REPO" "$OPENCLAUDE_WORKDIR" "openclaude"

sync_dir "$CLAUDE_HOME"     "$CLAUDE_WORKDIR"     "claude"
sync_dir "$OPENCLAUDE_HOME" "$OPENCLAUDE_WORKDIR" "openclaude"

push_repo "$CLAUDE_WORKDIR"     "$CLAUDE_BACKUP_REPO"     "claude"
push_repo "$OPENCLAUDE_WORKDIR" "$OPENCLAUDE_BACKUP_REPO" "openclaude"

log "done."
