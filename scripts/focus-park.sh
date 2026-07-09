#!/bin/bash
# focus-ledger: deterministically append ONE parked item to the ledger.
# Called by the /focus-ledger:park command instead of an LLM freehand rewrite, so a
# park can never drop, reorder, or reformat existing items, and concurrent parks from
# two sessions don't clobber each other (flock when available).
#
# Usage:  focus-park.sh "the thing to park"
# Inserts `- [ ] (YYYY-MM-DD) <thing>` at the END of the "## Parked" section (before
# the "## This session" heading), creating the ledger with both sections if absent.
# Prints the one-line item text on success.
set -eu

# Fixed path so the scripts and the /focus, /resume, /snooze command prompts (which
# reference this literal path) always agree on one ledger. Not env-overridable: a shell
# var wouldn't reach the LLM-driven command prompts, which would split-brain the ledger.
LEDGER="$HOME/.claude/focus-ledger.md"
PARKED_HEAD="## Parked (durable — carries across sessions)"
SESSION_HEAD="## This session (volatile — clear whenever)"

# Collapse whitespace to single spaces so one item is exactly one line; then a
# POSIX-clean emptiness check (no bashism like ${var//}, which dash rejects).
thing=$(printf '%s' "$*" | tr '\n\t' '  ' | sed 's/  */ /g; s/^ //; s/ $//')
[ -n "$thing" ] || { echo "nothing to park (empty argument)" >&2; exit 2; }
today=$(date +%F)
item="- [ ] ($today) $thing"

mkdir -p "$(dirname "$LEDGER")"

_do_park() {
  if [ ! -f "$LEDGER" ]; then
    printf '# Focus ledger\n\n%s\n%s\n\n%s\n' "$PARKED_HEAD" "$item" "$SESSION_HEAD" > "$LEDGER"
    return
  fi
  # Insert the item as the last line of the Parked section. If either heading is
  # missing (hand-edited ledger), fall back to a plain append so nothing is lost.
  if grep -qF "$PARKED_HEAD" "$LEDGER" && grep -qF "$SESSION_HEAD" "$LEDGER"; then
    # Insert as the last line of the Parked block: emit the new item right before the
    # trailing blank line(s) that precede "## This session", so the section stays tight
    # (no accumulating blank lines) and existing items are byte-for-byte untouched.
    # Item and headings ride in via ENVIRON, not -v: awk -v interprets backslash
    # escapes, so parking text with a literal \n would split into two lines.
    ITEM="$item" PH="$PARKED_HEAD" SH="$SESSION_HEAD" awk '
      BEGIN { item=ENVIRON["ITEM"]; ph=ENVIRON["PH"]; sh=ENVIRON["SH"] }
      $0 == ph { inpk=1 }
      inpk && $0 == sh && !done {
        # peel back any blank lines we already buffered, print item, then restore them
        print item
        for (k=1; k<=nb; k++) print ""
        nb=0; inpk=0; done=1; print; next
      }
      inpk && $0 == "" { nb++; next }        # buffer blank lines inside Parked
      { for (k=1; k<=nb; k++) print ""; nb=0; print }
      END { for (k=1; k<=nb; k++) print "" }
    ' "$LEDGER" > "$LEDGER.tmp" && mv "$LEDGER.tmp" "$LEDGER"
  else
    printf '%s\n' "$item" >> "$LEDGER"
  fi
}

# Serialize concurrent parks with a portable mkdir-mutex (atomic on any POSIX FS;
# flock is Linux-only and absent on macOS, so we don't rely on it). Retry briefly so
# a parallel park queues instead of clobbering, then proceed anyway rather than lose
# the item. ponytail: mkdir-lock with a ~2s bounded wait — fine for a single-user
# tool; if you ever drive it from many concurrent sessions, move to a real lock daemon.
LOCK="$LEDGER.lock"
locked=""
i=0
while [ "$i" -lt 20 ]; do
  if mkdir "$LOCK" 2>/dev/null; then locked=1; break; fi
  sleep 0.1
  i=$((i+1))
done
# Waited out the whole window: the holder is presumed dead (a park killed between
# mkdir and rmdir). Reap the stale lock so future parks don't also eat the full wait.
if [ -z "$locked" ]; then
  rmdir "$LOCK" 2>/dev/null || true
fi
_do_park
# Release the lock if we took it (best-effort; ignore any error). Written as a real
# if/then rather than `A && B || C`, which shellcheck flags (SC2015) and which would
# also run the fallback when the test fails, not only when B fails.
if [ -n "$locked" ]; then
  rmdir "$LOCK" 2>/dev/null || true
fi

printf '%s\n' "$thing"
