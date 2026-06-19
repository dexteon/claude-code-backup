#!/usr/bin/env bash
# claude-code-backup — restore.sh
# Pulls the two private data repos and copies them back over the live dirs.
#
# Usage:
#   ./restore.sh                   # restore both
#   ./restore.sh claude            # only ~/.claude
#   ./restore.sh openclaude        # only ~/.openclaude
#   ./restore.sh --dry-run

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  set -a; source "$SCRIPT_DIR/.env"; set +a
fi

DRY_RUN=0
TARGET="both"
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    claude) TARGET="claude" ;;
    openclaude) TARGET="openclaude" ;;
    *) printf 'unknown arg: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

: "${CLAUDE_BACKUP_REPO:?CLAUDE_BACKUP_REPO not set (run ./setup.sh)}"
: "${OPENCLAUDE_BACKUP_REPO:?OPENCLAUDE_BACKUP_REPO not set}"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
OPENCLAUDE_HOME="${OPENCLAUDE_HOME:-$HOME/.openclaude}"
BACKUP_WORKDIR="${BACKUP_WORKDIR:-$HOME/.claude-backup-work}"

log()  { printf '[restore] %s\n' "$*"; }
fail() { printf '[restore][ERROR] %s\n' "$*" >&2; exit 1; }
run()  { if (( DRY_RUN )); then printf '[dry-run] %s\n' "$*"; else "$@"; fi; }

restore_one() {
  local repo="$1" label="$2" target_dir="$3"
  local workdir="$BACKUP_WORKDIR/$label"

  log "restore $label from $repo -> $target_dir"
  if [[ -d "$workdir/.git" ]]; then
    ( cd "$workdir" && run git pull --rebase --ff-only ) || fail "pull failed: $label"
  else
    mkdir -p "$workdir"; rmdir "$workdir" 2>/dev/null || true
    run git clone "https://github.com/$repo.git" "$workdir" || fail "clone failed: $label"
  fi

  # backup current live dir if it exists and is non-empty
  if [[ -d "$target_dir" && -n "$(ls -A "$target_dir" 2>/dev/null)" ]]; then
    local stamp="$(date +%Y%m%d-%H%M%S)"
    local bak="$target_dir.pre-restore.$stamp"
    log "  backing up live $label -> $bak"
    run mv "$target_dir" "$bak"
  fi
  run mkdir -p "$target_dir"

  if command -v robocopy >/dev/null 2>&1; then
    run robocopy "$workdir" "$target_dir" /MIR /R:1 /W:1 /NFL /NDL /NJH /NP \
      >/dev/null 2>&1 || true
  elif command -v rsync >/dev/null 2>&1; then
    run rsync -a --delete "$workdir/" "$target_dir/"
  else
    run cp -rf "$workdir/." "$target_dir/"
  fi
  log "  $label restored."
}

case "$TARGET" in
  claude)     restore_one "$CLAUDE_BACKUP_REPO"     "claude"     "$CLAUDE_HOME" ;;
  openclaude) restore_one "$OPENCLAUDE_BACKUP_REPO" "openclaude" "$OPENCLAUDE_HOME" ;;
  both)
    restore_one "$CLAUDE_BACKUP_REPO"     "claude"     "$CLAUDE_HOME"
    restore_one "$OPENCLAUDE_BACKUP_REPO" "openclaude" "$OPENCLAUDE_HOME"
    ;;
esac

log "done."
