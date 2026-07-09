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
