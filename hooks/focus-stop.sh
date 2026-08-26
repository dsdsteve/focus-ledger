#!/bin/bash
# focus-ledger Stop hook — the naggiest surface, gated hardest.
# Speaks ONLY when an open ledger item is stale (older than threshold). Silent otherwise.
# Emits systemMessage on exit 0: a quiet note to the USER. Never blocks, never forces
# the assistant to keep working (per Claude Code hooks docs: Stop exit 0 + systemMessage).
#
# Opt-outs (soft by design):
#   FOCUS_STOP_NUDGE=off       -> disable entirely
#   FOCUS_STALE_DAYS=<n>       -> staleness threshold in days (default 7)
#   FOCUS_NUDGE_COOLDOWN=<n>   -> seconds between nudges (default 14400; 0 disables)
#   ~/.claude/.focus-snooze    -> if it holds a future epoch, stay silent until then
#   ~/.claude/.focus-last-nudge -> if it holds a future epoch, cooldown is active
set -u

[ "${FOCUS_STOP_NUDGE:-}" = "off" ] && exit 0

LEDGER="$HOME/.claude/focus-ledger.md"
[ -f "$LEDGER" ] || exit 0

# Epoch files are advisory. Accept only bounded, non-negative decimal text so a
# malformed marker can never make a soft hook fail with an integer-expression error.
is_safe_epoch() {
  epoch_value=$1
  case $epoch_value in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "${#epoch_value}" -le 18 ]
}

now=$(date +%s)

# Snooze: silent while the snooze epoch is in the future. Remove an expired
# numeric marker before evaluating the ordinary stale-item nudge.
SNOOZE="$HOME/.claude/.focus-snooze"
if [ -f "$SNOOZE" ]; then
  until_ts=
  IFS= read -r until_ts 2>/dev/null < "$SNOOZE" || :
  if is_safe_epoch "$until_ts"; then
    [ "$now" -lt "$until_ts" ] 2>/dev/null && exit 0
    rm -f "$SNOOZE" 2>/dev/null || :
  fi
fi

# Invalid, negative, leading-zero, or impractically large values safely fall
# back to four hours. Keeping the accepted value to nine digits also keeps the
# addition below the integer range used by the supported shells.
cooldown=${FOCUS_NUDGE_COOLDOWN:-14400}
case $cooldown in
  0) ;;
  ''|*[!0-9]*|0*) cooldown=14400 ;;
  *) [ "${#cooldown}" -le 9 ] || cooldown=14400 ;;
esac

LAST_NUDGE="$HOME/.claude/.focus-last-nudge"
if [ "$cooldown" -gt 0 ] && [ -f "$LAST_NUDGE" ]; then
  next_nudge=
  IFS= read -r next_nudge 2>/dev/null < "$LAST_NUDGE" || :
  if is_safe_epoch "$next_nudge" && [ "$now" -lt "$next_nudge" ] 2>/dev/null; then
    exit 0
  fi
fi

threshold=${FOCUS_STALE_DAYS:-7}
today_days=$(( now / 86400 ))   # whole days since epoch, UTC

# Collect open "- [ ]" items whose (YYYY-MM-DD) date is >= threshold days old.
# The date is parsed and compared ENTIRELY inside awk with integer arithmetic
# (Hinnant days-from-civil) — no shell-out, no date(1) fork, no getline. This is
# both safe (no ledger text ever reaches a shell) and portable (works on BSD awk,
# which lacks mktime()). Only the strict 4-2-2 digit groups are read. The same
# pass counts matches and joins the first three labels for the final message.
stale=$(awk -v today="$today_days" -v thr="$threshold" '
  # Lines inside <!-- --> blocks are format examples, not items (format v1) — skip.
  incom { if (index($0, "-->")) incom=0; next }
  index($0, "<!--") == 1 { if (!index($0, "-->")) incom=1; next }
  function days(y,m,d,   era,yoe,doy,doe){
    if (m <= 2) { y--; m += 12 }
    era = int((y>=0?y:y-399)/400); yoe = y - era*400
    doy = int((153*(m-3)+2)/5) + d - 1
    doe = yoe*365 + int(yoe/4) - int(yoe/100) + doy
    return era*146097 + doe - 719468
  }
  /^- \[ \]/ {
    if (match($0, /\([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\)/)) {
      ds = substr($0, RSTART+1, 10)
      y = substr(ds,1,4) + 0; m = substr(ds,6,2) + 0; d = substr(ds,9,2) + 0
      if (m < 1 || m > 12 || d < 1 || d > 31) next   # garbage date -> skip, never misfire
      age = today - days(y,m,d)
      if (age >= thr) {
        lbl = $0
        sub(/^- \[ \] \([0-9-]+\) /, "", lbl)
        count++
        if (count <= 3) {
          if (count > 1) summary = summary "; "
          summary = summary lbl
        }
      }
    }
  }
  END {
    if (count > 3) summary = summary "; +" (count - 3) " more"
    if (count > 0) print summary
  }
' "$LEDGER")

[ -z "$stale" ] && exit 0

msg="Open a while: $stale. Run /focus-ledger:focus to view, or /focus-ledger:snooze to hide. (Only shows when something's been sitting past $threshold days.)"

# Write the advisory epoch through a private same-directory file. Removing the
# destination before the rename avoids following a symlink or blocking on a FIFO;
# any failure simply leaves the hook fail-open for a later nudge.
write_nudge_marker() {
  marker_value=$1
  marker_tmp="${LAST_NUDGE}.tmp.$$"
  if (umask 077; set -C; printf '%s\n' "$marker_value" > "$marker_tmp") 2>/dev/null; then
    if rm -f "$LAST_NUDGE" 2>/dev/null && mv -f "$marker_tmp" "$LAST_NUDGE" 2>/dev/null; then
      return 0
    fi
    rm -f "$marker_tmp" 2>/dev/null || :
  fi
  return 0
}

# Emit as JSON systemMessage. jq handles all escaping; the fallback strips control
# chars first (a raw tab/newline in item text would otherwise make invalid JSON).
# Only a successful serializer consumes the cooldown window.
emitted=0
if command -v jq >/dev/null 2>&1; then
  if printf '%s' "$msg" | jq -R -s '{systemMessage: .}'; then emitted=1; fi
else
  if esc=$(printf '%s' "$msg" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g'); then
    if printf '{"systemMessage": "%s"}' "$esc"; then emitted=1; fi
  fi
fi
[ "$emitted" = 1 ] || exit 0

next_nudge=$((now + cooldown))
write_nudge_marker "$next_nudge"
exit 0
