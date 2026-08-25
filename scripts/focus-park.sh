#!/bin/bash
# focus-ledger: deterministically append ONE parked item to the ledger.
# Called by the /focus-ledger:park command instead of an LLM freehand rewrite, so a
# park can never drop, reorder, or reformat existing items, and concurrent parks from
# two sessions don't clobber each other (portable mkdir mutex).
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

# Last-resort write path: one atomic O_APPEND write, no read-rewrite-mv, so it can
# interleave with nothing and overwrite nothing. The item may land at EOF instead of
# inside the Parked section (a later tidy verb can re-home it), but it is never lost.
_append_park() {
  printf '%s\n' "$item" >> "$LEDGER"
}

_do_park() {
  if [ ! -f "$LEDGER" ]; then
    printf '# Focus ledger\n\n%s\n%s\n\n%s\n' "$PARKED_HEAD" "$item" "$SESSION_HEAD" > "$LEDGER"
    return
  fi
  # Insert the item as the last line of the Parked section. If either heading is
  # missing (hand-edited ledger), fall back to a plain append so nothing is lost.
  if grep -qF "$PARKED_HEAD" "$LEDGER" && grep -qF "$SESSION_HEAD" "$LEDGER"; then
    # Rewrite through a per-process temp file in the ledger's own directory: mktemp
    # keeps concurrent parks off each other's output (the old fixed ".tmp" name was
    # a collision), and staying in the same directory keeps the mv an atomic
    # same-filesystem rename. On any failure, remove the temp and degrade to the
    # append so the item is never lost and no litter remains.
    tmp=$(mktemp "$LEDGER.XXXXXX" 2>/dev/null) || { _append_park; return; }
    # Insert as the last line of the Parked block: emit the new item right before the
    # trailing blank line(s) that precede "## This session", so the section stays tight
    # (no accumulating blank lines) and existing items are byte-for-byte untouched.
    # Item and headings ride in via ENVIRON, not -v: awk -v interprets backslash
    # escapes, so parking text with a literal \n would split into two lines.
    if ITEM="$item" PH="$PARKED_HEAD" SH="$SESSION_HEAD" awk '
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
    ' "$LEDGER" > "$tmp"; then
      mv "$tmp" "$LEDGER" || { rm -f "$tmp"; _append_park; }
    else
      rm -f "$tmp"
      _append_park
    fi
  else
    _append_park
  fi
}

# Serialize concurrent parks with a portable mkdir-mutex (atomic on any POSIX FS;
# flock is Linux-only and absent on macOS, so we don't rely on it). A parallel park
# queues through a bounded primary window; if that times out, the holder is presumed
# dead (a park killed between mkdir and rmdir), the stale lock is reaped, and we try
# to re-acquire through a second bounded window. The rewrite path is unreachable
# without owning the lock: if the lock still cannot be owned, the atomic append
# above takes over — a misplaced item is acceptable, a lost one is not.
# ponytail: mkdir-lock with a bounded ~2s+1s wait — fine for a single-user tool; if
# you ever drive it from many concurrent sessions, move to a real lock daemon.
LOCK="$LEDGER.lock"
REAP="$LOCK.reap"
locked=""
reaping=""

# Bounded lock attempt: poll mkdir every 0.1s for $1 tries; locked=1 on success.
_try_lock() {
  i=0
  while [ "$i" -lt "$1" ]; do
    if mkdir "$LOCK" 2>/dev/null; then locked=1; return 0; fi
    sleep 0.1
    i=$((i+1))
  done
  return 1
}

if ! _try_lock 20; then
  # Timed out: reap the stale lock, then re-acquire. The reap is serialized through
  # a token dir held until the reaper has fully finished (lock released again):
  # without it, two parks timing out together can interleave as rmdir(A) mkdir(A)
  # rmdir(B) — B reaping A's FRESH lock — and both would rewrite at once, the exact
  # lost-update this script exists to prevent. A racer that cannot take the token
  # skips reaping and just queues on the lock; mkdir stays the only arbiter.
  if mkdir "$REAP" 2>/dev/null; then
    reaping=1
    rmdir "$LOCK" 2>/dev/null || true
  fi
  _try_lock 10 || true
fi

if [ -n "$locked" ]; then
  _do_park
  # Release only what we acquired (best-effort; ignore any error). Written as a real
  # if/then rather than `A && B || C`, which shellcheck flags (SC2015) and which would
  # also run the fallback when the test fails, not only when B fails.
  rmdir "$LOCK" 2>/dev/null || true
else
  # Never rewrite unlocked — degrade to the append that cannot clobber anyone.
  _append_park
fi
# Hand the reap token back only after the lock is released: "token free" must imply
# "no reap-cycle still holds the lock", so a late racer can never mistake our fresh
# lock for the stale one it timed out on.
if [ -n "$reaping" ]; then
  rmdir "$REAP" 2>/dev/null || true
fi

printf '%s\n' "$thing"
