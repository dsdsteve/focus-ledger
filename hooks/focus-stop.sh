#!/bin/bash
# focus-ledger Stop hook — the naggiest surface, gated hardest.
# Speaks ONLY when an open ledger item is stale (older than threshold). Silent otherwise.
# Emits systemMessage on exit 0: a quiet note to the USER. Never blocks, never forces
# the assistant to keep working (per Claude Code hooks docs: Stop exit 0 + systemMessage).
#
# Opt-outs (soft by design):
#   FOCUS_STOP_NUDGE=off      -> disable entirely
#   FOCUS_STALE_DAYS=<n>      -> staleness threshold in days (default 7)
#   ~/.claude/.focus-snooze   -> if it holds a future epoch, stay silent until then
set -u

[ "${FOCUS_STOP_NUDGE:-}" = "off" ] && exit 0

LEDGER="$HOME/.claude/focus-ledger.md"
[ -f "$LEDGER" ] || exit 0

# Snooze: silent while the snooze epoch is in the future.
SNOOZE="$HOME/.claude/.focus-snooze"
now=$(date +%s)
if [ -f "$SNOOZE" ]; then
  until_ts=$(head -1 "$SNOOZE" 2>/dev/null | tr -dc '0-9')
  [ -n "$until_ts" ] && [ "$now" -lt "$until_ts" ] && exit 0
fi

threshold=${FOCUS_STALE_DAYS:-7}
today_days=$(( now / 86400 ))   # whole days since epoch, UTC

# Collect open "- [ ]" items whose (YYYY-MM-DD) date is >= threshold days old.
# The date is parsed and compared ENTIRELY inside awk with integer arithmetic
# (Hinnant days-from-civil) — no shell-out, no date(1) fork, no getline. This is
# both safe (no ledger text ever reaches a shell) and portable (works on BSD awk,
# which lacks mktime()). Only the strict 4-2-2 digit groups are read.
stale=$(awk -v today="$today_days" -v thr="$threshold" '
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
        print lbl
      }
    }
  }
' "$LEDGER")

[ -z "$stale" ] && exit 0

# Compact message: up to 3 items, then "+N more".
n=$(printf '%s\n' "$stale" | grep -c .)
head3=$(printf '%s\n' "$stale" | head -3 | paste -sd '; ' -)
if [ "$n" -gt 3 ]; then head3="$head3; +$((n-3)) more"; fi

msg="Open a while: $head3. Run /focus-ledger:focus to view, or /focus-ledger:snooze to hide. (Only shows when something's been sitting past $threshold days.)"

# Emit as JSON systemMessage. jq handles all escaping; the fallback strips control
# chars first (a raw tab/newline in item text would otherwise make invalid JSON).
if command -v jq >/dev/null 2>&1; then
  printf '%s' "$msg" | jq -R -s '{systemMessage: .}'
else
  esc=$(printf '%s' "$msg" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '{"systemMessage": "%s"}' "$esc"
fi
exit 0
