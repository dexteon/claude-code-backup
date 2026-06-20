#!/usr/bin/env bash
# claude-code-backup — backup.sh
# Syncs ~/.claude and ~/.openclaude into two private GitHub repos.
#
# Usage:
#   ./backup.sh            # use config from ./.env
#   ./backup.sh --dry-run  # show what would happen, no commits/pushes
#
# Env (.env in same dir; .env takes precedence over shell env, like dotenv):
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
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "unknown arg: $arg (try --help)" >&2; exit 2 ;;
  esac
done

# --- required config -------------------------------------------------------
: "${CLAUDE_BACKUP_REPO:?CLAUDE_BACKUP_REPO not set (run ./setup.sh first)}"
: "${OPENCLAUDE_BACKUP_REPO:?OPENCLAUDE_BACKUP_REPO not set (run ./setup.sh first)}"

CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
OPENCLAUDE_HOME="${OPENCLAUDE_HOME:-$HOME/.openclaude}"
BACKUP_WORKDIR="${BACKUP_WORKDIR:-$HOME/.claude-backup-work}"

# --- helpers ---------------------------------------------------------------
# Convert bash path (/c/Users/Dex/.claude) to Windows path (C:\Users\Dex\.claude)
to_win_path() {
  local p="$1"
  # drive letter: /c/... -> C:\...
  if [[ "$p" =~ ^/([a-zA-Z])/(.*)$ ]]; then
    local drive="${BASH_REMATCH[1]}"
    local rest="${BASH_REMATCH[2]}"
    rest="${rest//\//\\}"
    printf '%s:\\%s\n' "${drive^}" "$rest"
  else
    p="${p//\//\\}"
    printf '%s\n' "$p"
  fi
}

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
# Excludes split: directory names go to /XD, file globs to /XF.
#   robocopy is buggy with mixed args, so we build /XD and /XF separately.
EXCLUDE_DIRS=(
  ".git" "node_modules" "cache" "logs" "Cache" "Code Cache" "GPUCache"
  "Service Worker" "backups" "paste-cache" "sessions" "projects"
  "ShaderCache" "GrShaderCache"
  "tasks" "teams" "telemetry"
)
EXCLUDE_FILES=(
  "*.log" "*.tmp" "*.output" "*.lock" ".last-cleanup"
)

sync_dir() {
  local src="$1" dst="$2" label="$3"
  log "sync $label: $src -> $dst"

  if [[ ! -d "$src" ]]; then
    log "  source missing, skip ($label)"
    return 0
  fi
  mkdir -p "$dst"

  if command -v robocopy >/dev/null 2>&1; then
    local win_src win_dst
    win_src="$(to_win_path "$src")"
    win_dst="$(to_win_path "$dst")"
    local rob_args=( /MIR /R:1 /W:1 /NFL /NDL /NJH /NP )
    rob_args+=( /XD "${EXCLUDE_DIRS[@]}" )
    rob_args+=( /XF "${EXCLUDE_FILES[@]}" )
    if (( DRY_RUN )); then rob_args+=( /L ); fi
    # MSYS_NO_PATHCONV=1 stops Git Bash from mangling /MIR -> C:\...\MIR
    # robocopy rc 0-7 = clean success; 8 = files FAILED (real error);
    # 9-15 = copied with warnings (locked files, mismatches) — acceptable for backup
    MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' \
      robocopy "$win_src" "$win_dst" "${rob_args[@]}" >/dev/null 2>&1 || {
        local rc=$?
        (( rc == 8 )) && fail "robocopy failed (rc=$rc) for $label — files could not be copied"
        (( rc >= 16 )) && fail "robocopy serious error (rc=$rc) for $label"
        log "  robocopy rc=$rc ($label, copied with warnings — likely locked files)"
      }
  elif command -v rsync >/dev/null 2>&1; then
    local rs_args=( -a --delete )
    local e
    for e in "${EXCLUDE_DIRS[@]}" "${EXCLUDE_FILES[@]}"; do
      rs_args+=( --exclude="$e" )
    done
    if (( DRY_RUN )); then rs_args+=( --dry-run ); fi
    rsync "${rs_args[@]}" "$src/" "$dst/"
  else
    run cp -rf "$src/." "$dst/"
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

# Force-remove a workdir using PowerShell on Windows (rm -rf fails on locked .git/objects)
rm_workdir_force() {
  local p="$1"
  if [[ -d "$p" ]]; then
    local win_p; win_p="$(to_win_path "$p")"
    powershell.exe -NoProfile -Command \
      "Remove-Item -LiteralPath '$win_p' -Recurse -Force -ErrorAction SilentlyContinue" \
      2>/dev/null || true
    # also try rm -rf as best effort
    rm -rf "$p" 2>/dev/null || true
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
