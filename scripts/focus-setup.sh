#!/bin/bash
# focus-ledger: install (or remove) the one behavior that can't be a hook.
#
# The commands and hooks cover the manual and event-driven parts. The remaining
# behavior some people want — "when I pivot off an unfinished thread, offer to
# park the old one" — needs the model's judgment about what a real pivot is, so
# it can't be a hook. It lives as an instruction block in your CLAUDE.md instead.
#
# This writes that block as a MANAGED, idempotent section (bracketed by
# FOCUS-LEDGER markers) so re-running updates it in place rather than duplicating,
# and --remove takes it back out cleanly. Like fablize's block, minus the python.
#
# Usage:  focus-setup.sh [local|global] [--remove]
#   local  (default) -> ./CLAUDE.md in the current project
#   global           -> ~/.claude/CLAUDE.md for every project
set -eu

scope=local
remove=0
for a in "$@"; do
  case "$a" in
    local|global) scope=$a ;;
    --remove)     remove=1 ;;
    *) echo "focus-setup: unknown arg '$a' (want: local|global [--remove])" >&2; exit 2 ;;
  esac
done

case "$scope" in
  global) CLAUDE_MD="$HOME/.claude/CLAUDE.md" ;;
  local)  CLAUDE_MD="$PWD/CLAUDE.md" ;;
esac

# Removing a genuinely absent target is a no-op. In particular, do not create
# its parent, the target itself, or a misleading recovery backup.
if [ "$remove" = 1 ] && [ ! -e "$CLAUDE_MD" ] && [ ! -L "$CLAUDE_MD" ]; then
  echo "focus-ledger: pivot-park block removed from $CLAUDE_MD"
  echo "  backup: $CLAUDE_MD.focus-bak.* · undo: focus-setup.sh $scope --remove"
  exit 0
fi

# Setup never follows a CLAUDE.md symlink. Doctor reports the same topology as
# unsafe; refuse before scanning, backing up, or rewriting through the link.
if [ -L "$CLAUDE_MD" ]; then
  printf 'focus-setup: refusing symlink target %s; replace it with a regular file before retrying.\n' \
    "$CLAUDE_MD" >&2
  exit 3
fi

# A FIFO or device target is not a symlink, so the check above misses it, and
# the snapshot cp below blocks on the open before its own type check can run.
# Refuse a non-regular target here instead of hanging.
if [ -e "$CLAUDE_MD" ] && [ ! -f "$CLAUDE_MD" ]; then
  printf 'focus-setup: refusing non-regular target %s; replace it with a regular file before retrying.\n' \
    "$CLAUDE_MD" >&2
  exit 3
fi

# Capture an existing regular target without following a symlink. All parsing,
# stripping, and backup reads use this private copy; final publication replaces
# the target pathname atomically instead of opening it for redirection.
source_snapshot=
setup_source=
cleanup_source() {
  [ -z "$source_snapshot" ] || rm -f "$source_snapshot" 2>/dev/null || true
}
trap 'cleanup_source; exit 1' INT TERM HUP
if [ -e "$CLAUDE_MD" ]; then
  source_snapshot=$(mktemp "$CLAUDE_MD.focus-source.XXXXXX") || {
    printf 'focus-setup: could not create source snapshot for %s\n' "$CLAUDE_MD" >&2
    exit 1
  }
  # Overwrite the mktemp file in place; do not rm it first. Deleting and
  # recreating the predictable pathname would reopen a symlink-swap window that
  # cp -pP could then write CLAUDE.md's bytes through.
  if ! cp -pP "$CLAUDE_MD" "$source_snapshot" ||
     [ -L "$source_snapshot" ] || [ ! -f "$source_snapshot" ]; then
    cleanup_source
    printf 'focus-setup: refusing unsafe or unstable target %s\n' "$CLAUDE_MD" >&2
    exit 3
  fi
  setup_source=$source_snapshot
fi

# Scan existing bytes before mkdir, touch, backup rotation, or any rewrite.
# Besides ordinary imbalance, reject same-line markers and multiple sequential
# blocks because neither has one unambiguous canonical replacement range.
managed_blocks=0
if [ -n "$setup_source" ]; then
  scan_result=$(awk '
    {
      has_begin = index($0, "<!-- FOCUS-LEDGER:BEGIN")
      has_end = index($0, "FOCUS-LEDGER:END -->")
      if (has_begin && has_end) {
        nb++; ne++
        if (!why) why="BEGIN and END markers appear on the same line"
        next
      }
      if (has_begin) {
        nb++; depth++
        if (depth > 1 && !why) why="nested BEGIN markers"
      }
      if (has_end) {
        ne++
        if (depth == 0) {
          if (!why) why="END marker with no BEGIN open before it"
        } else {
          depth--
          if (depth == 0) blocks++
        }
      }
    }
    END {
      if (!why && depth != 0) why="BEGIN marker never closed by an END"
      if (!why && blocks > 1) why="multiple managed blocks"
      if (why) {
        printf "error:%s (found %d BEGIN, %d END)", why, nb+0, ne+0
      } else {
        printf "blocks:%d", blocks+0
      }
    }
  ' "$setup_source") || {
    cleanup_source
    trap - INT TERM HUP
    printf 'focus-setup: marker scan failed for %s; refusing to continue.\n' "$CLAUDE_MD" >&2
    exit 3
  }
  case $scan_result in
    blocks:0) managed_blocks=0; mangled= ;;
    blocks:1) managed_blocks=1; mangled= ;;
    error:*) mangled=${scan_result#error:} ;;
    *)
      cleanup_source
      trap - INT TERM HUP
      printf 'focus-setup: marker scan failed for %s; refusing to continue.\n' "$CLAUDE_MD" >&2
      exit 3
      ;;
  esac
else
  mangled=
fi
if [ -n "$mangled" ]; then
  {
    printf 'focus-setup: refusing to rewrite %s — FOCUS-LEDGER block is mangled: %s.\n' "$CLAUDE_MD" "$mangled"
    if ls "$CLAUDE_MD".focus-bak.* >/dev/null 2>&1; then
      printf '  Nothing was written. To recover: restore the latest %s.focus-bak.* over it,\n' "$CLAUDE_MD"
      printf '  or hand-delete the partial FOCUS-LEDGER block, then re-run.\n'
    else
      printf '  Nothing was written. To recover: hand-delete the partial FOCUS-LEDGER block, then re-run.\n'
    fi
  } >&2
  cleanup_source
  trap - INT TERM HUP
  exit 3
fi

# Removing from an existing marker-free file is also a strict no-op. Preserve
# every byte, metadata field, and prior recovery generation.
if [ "$remove" = 1 ] && [ "$managed_blocks" = 0 ]; then
  echo "focus-ledger: pivot-park block removed from $CLAUDE_MD"
  echo "  backup: $CLAUDE_MD.focus-bak.* · undo: focus-setup.sh $scope --remove"
  cleanup_source
  trap - INT TERM HUP
  exit 0
fi

strip_tmp=$(mktemp) || {
  cleanup_source
  trap - INT TERM HUP
  printf 'focus-setup: could not create rewrite staging file\n' >&2
  exit 1
}
output_tmp=
backup_new=
cleanup_setup() {
  rm -f "$strip_tmp" "$output_tmp" 2>/dev/null || true
  cleanup_source
  [ -z "$backup_new" ] || rm -f "$backup_new" 2>/dev/null || true
}
trap 'cleanup_setup; exit 1' INT TERM HUP

# Strip the one validated managed block from the private source snapshot, then
# drop trailing blank lines.
if [ -n "$setup_source" ]; then
  if ! awk '
    /<!-- FOCUS-LEDGER:BEGIN/ { skip=1 }
    skip==0 { buf[n++]=$0 }
    /FOCUS-LEDGER:END -->/ { skip=0 }
    END {
      last=-1
      for (i=0; i<n; i++) if (buf[i] ~ /[^[:space:]]/) last=i
      for (i=0; i<=last; i++) print buf[i]
    }
  ' "$setup_source" > "$strip_tmp"; then
    cleanup_setup
    printf 'focus-setup: could not prepare rewrite for %s\n' "$CLAUDE_MD" >&2
    exit 1
  fi
else
  : > "$strip_tmp"
fi

mkdir -p "$(dirname "$CLAUDE_MD")" || {
  cleanup_setup
  printf 'focus-setup: could not create target directory for %s\n' "$CLAUDE_MD" >&2
  exit 1
}
output_tmp=$(mktemp "$CLAUDE_MD.focus-stage.XXXXXX") || {
  cleanup_setup
  printf 'focus-setup: could not create same-directory output stage for %s\n' "$CLAUDE_MD" >&2
  exit 1
}
if [ -n "$setup_source" ] && ! cp -p "$setup_source" "$output_tmp"; then
  cleanup_setup
  printf 'focus-setup: could not preserve target mode for %s\n' "$CLAUDE_MD" >&2
  exit 1
fi
if [ -z "$setup_source" ]; then
  # Fresh target: mktemp forced 0600 and the publishing mv preserves the stage's
  # mode, so match the umask-based mode a plain create would have produced. A
  # hardcoded 644 would ignore a restrictive umask, so derive 0666 & ~umask.
  if ! chmod "$(printf '%o' "$(( 0666 & ~0$(umask) ))")" "$output_tmp"; then
    cleanup_setup
    printf 'focus-setup: could not set staged output mode for %s\n' "$CLAUDE_MD" >&2
    exit 1
  fi
fi

# Build the complete canonical output in a same-directory stage before touching
# the target or its backups.
{
  if [ -s "$strip_tmp" ]; then cat "$strip_tmp"; [ "$remove" = 1 ] || printf '\n'; fi
  if [ "$remove" = 0 ]; then
    cat <<'BLOCK'
<!-- FOCUS-LEDGER:BEGIN — offer to park on pivot. Update or remove: /focus-ledger:setup -->
## Focus ledger — offer to park on pivot

When I pivot off an unfinished thread to a new topic, answer the new thing and
then offer in one line to park the old one (e.g. "want me to park <old thing>?").
Offer, don't auto-park. One line, not a paragraph. Only on a real pivot off
something unfinished — not every topic change.
<!-- FOCUS-LEDGER:END -->
BLOCK
  fi
} > "$output_tmp"

# Publish and verify a new recovery copy before deleting any older generation.
# A failed or partial copy leaves both the target and every prior backup intact.
if [ -n "$setup_source" ]; then
  if [ -L "$CLAUDE_MD" ] || [ ! -f "$CLAUDE_MD" ] ||
     ! cmp -s "$CLAUDE_MD" "$setup_source"; then
    cleanup_setup
    printf 'focus-setup: target changed or became unsafe before backup for %s\n' "$CLAUDE_MD" >&2
    exit 1
  fi
  backup_epoch=$(date +%s 2>/dev/null) || {
    cleanup_setup
    printf 'focus-setup: could not create recovery backup timestamp for %s\n' "$CLAUDE_MD" >&2
    exit 1
  }
  case $backup_epoch in
    ''|*[!0-9]*)
      cleanup_setup
      printf 'focus-setup: invalid recovery backup timestamp for %s\n' "$CLAUDE_MD" >&2
      exit 1
      ;;
  esac
  backup_new=$(mktemp "$CLAUDE_MD.focus-bak.$backup_epoch.XXXXXX") || {
    cleanup_setup
    printf 'focus-setup: could not create recovery backup for %s\n' "$CLAUDE_MD" >&2
    exit 1
  }
  if ! cp "$setup_source" "$backup_new" || ! cmp -s "$setup_source" "$backup_new"; then
    cleanup_setup
    printf 'focus-setup: could not verify recovery backup for %s\n' "$CLAUDE_MD" >&2
    exit 1
  fi
  if [ -L "$CLAUDE_MD" ] || [ ! -f "$CLAUDE_MD" ] ||
     ! cmp -s "$CLAUDE_MD" "$setup_source"; then
    cleanup_setup
    printf 'focus-setup: target changed or became unsafe before publication for %s\n' "$CLAUDE_MD" >&2
    exit 1
  fi
  for old_backup in "$CLAUDE_MD".focus-bak.*; do
    [ -e "$old_backup" ] || [ -L "$old_backup" ] || continue
    [ "$old_backup" = "$backup_new" ] || rm -f "$old_backup" || {
      cleanup_setup
      printf 'focus-setup: could not replace prior recovery backup for %s\n' "$CLAUDE_MD" >&2
      exit 1
    }
  done
  # From this point the verified new generation is the recovery backup, even if
  # the later target write fails.
  backup_new=
fi

focus_setup_publish() {
  if mv --version >/dev/null 2>&1; then
    mv -fT "$1" "$2"
  else
    mv -fh "$1" "$2"
  fi
}

if ! focus_setup_publish "$output_tmp" "$CLAUDE_MD"; then
  cleanup_setup
  printf 'focus-setup: could not atomically rewrite %s\n' "$CLAUDE_MD" >&2
  exit 1
fi
output_tmp=
backup_new=
cleanup_setup
trap - INT TERM HUP

if [ "$remove" = 1 ]; then
  echo "focus-ledger: pivot-park block removed from $CLAUDE_MD"
else
  echo "focus-ledger: pivot-park block installed in $CLAUDE_MD ($scope) — applies from your next session."
fi
echo "  backup: $CLAUDE_MD.focus-bak.* · undo: focus-setup.sh $scope --remove"
