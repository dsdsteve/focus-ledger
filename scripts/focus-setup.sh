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

mkdir -p "$(dirname "$CLAUDE_MD")"
touch "$CLAUDE_MD"

# Refuse-before-write guard: with a mangled managed block (say, the END marker
# hand-deleted), the strip below would set skip=1 at BEGIN and never clear it —
# silently deleting every user line after the marker. Depth-walk the markers
# first (same regexes the strip uses): BEGIN opens, END closes; an END with
# nothing open, nested BEGINs, or an unclosed BEGIN at EOF refuses with rc 3
# (bad args stay rc 2) and writes NOTHING. This sits before the backup rotation
# so the refused path can't evict the last good backup either.
mangled=$(awk '
  /<!-- FOCUS-LEDGER:BEGIN/ { nb++; depth++; if (depth > 1 && !why) why="nested BEGIN markers" }
  /FOCUS-LEDGER:END -->/    { ne++; depth--; if (depth < 0 && !why) why="END marker with no BEGIN open before it" }
  END {
    if (!why && depth != 0) why="BEGIN marker never closed by an END"
    if (why) printf "%s (found %d BEGIN, %d END)", why, nb+0, ne+0
  }
' "$CLAUDE_MD") || {
  # Fail CLOSED with a clear message: an unverified file must never reach the strip.
  printf 'focus-setup: marker scan failed for %s; refusing to continue.\n' "$CLAUDE_MD" >&2
  exit 3
}
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
  exit 3
fi

# Keep only the latest backup — repeated runs would otherwise pile up
# CLAUDE.md.focus-bak.* files in the project root (easy to commit by accident).
rm -f "$CLAUDE_MD".focus-bak.* 2>/dev/null || true
cp "$CLAUDE_MD" "$CLAUDE_MD.focus-bak.$(date +%s)"

# Strip any existing FOCUS-LEDGER block, then drop trailing blank lines. Buffering
# in awk (no python, no fragile sed range) keeps the plugin's zero-extra-deps promise.
tmp=$(mktemp)
awk '
  /<!-- FOCUS-LEDGER:BEGIN/ { skip=1 }
  skip==0 { buf[n++]=$0 }
  /FOCUS-LEDGER:END -->/ { skip=0 }
  END {
    last=-1
    for (i=0; i<n; i++) if (buf[i] ~ /[^[:space:]]/) last=i
    for (i=0; i<=last; i++) print buf[i]
  }
' "$CLAUDE_MD" > "$tmp"

# Rewrite: kept content, then (unless removing) a blank separator + the fresh block.
{
  if [ -s "$tmp" ]; then cat "$tmp"; [ "$remove" = 1 ] || printf '\n'; fi
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
} > "$CLAUDE_MD"
rm -f "$tmp"

if [ "$remove" = 1 ]; then
  echo "focus-ledger: pivot-park block removed from $CLAUDE_MD"
else
  echo "focus-ledger: pivot-park block installed in $CLAUDE_MD ($scope) — applies from your next session."
fi
echo "  backup: $CLAUDE_MD.focus-bak.* · undo: focus-setup.sh $scope --remove"
