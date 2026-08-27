#!/bin/bash
# focus-ledger Stop hook — emit a soft note only when an open item is stale.
set -u

[ "${FOCUS_STOP_NUDGE:-}" = "off" ] && exit 0

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/scripts/focus-lib.sh" ]; then
  FOCUS_LIB_DIR="${CLAUDE_PLUGIN_ROOT}/scripts"
else
  FOCUS_LIB_DIR="$SCRIPT_DIR/../scripts"
fi
[ -r "$FOCUS_LIB_DIR/focus-lib.sh" ] || exit 0
. "$FOCUS_LIB_DIR/focus-lib.sh" || exit 0

[ -f "$FOCUS_LEDGER" ] || exit 0
now=$(date +%s) || exit 0
focus_is_safe_epoch "$now" || exit 0

# Snooze markers are advisory. A valid future epoch suppresses the hook; an
# expired numeric marker is removed before ordinary stale-item evaluation.
SNOOZE="$HOME/.claude/.focus-snooze"
if ! focus_lock_acquire "$SNOOZE"; then
  focus_lock_release
  exit 0
fi
if [ -f "$SNOOZE" ]; then
  until_ts=
  IFS= read -r until_ts 2>/dev/null < "$SNOOZE" || :
  if focus_is_safe_epoch "$until_ts"; then
    if [ "$now" -lt "$until_ts" ] 2>/dev/null; then
      focus_lock_release
      exit 0
    fi
    rm -f "$SNOOZE" 2>/dev/null || :
  fi
fi
focus_lock_release

# Invalid, negative, leading-zero, or impractically large cooldowns retain the
# historical four-hour fallback. Zero deliberately disables suppression.
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
  if focus_is_safe_epoch "$next_nudge" && [ "$now" -lt "$next_nudge" ] 2>/dev/null; then
    exit 0
  fi
fi

threshold=$(focus_stale_threshold) || exit 0
today_days=$(focus_today_days) || exit 0
stale=$(focus_parse_stale "$today_days" "$threshold")
[ -z "$stale" ] && exit 0

msg="Open a while: $stale. Run /focus-ledger:focus to view, or /focus-ledger:snooze to hide. (Only shows when something's been sitting past $threshold days.)"

# Marker writes fail open. The shared primitive replaces symlinks/FIFOs rather
# than following them and publishes through a private same-directory file.
write_nudge_marker() {
  focus_write_marker "$LAST_NUDGE" "$1" || :
  return 0
}

# jq handles escaping when available. The fallback strips controls before manual
# JSON escaping. Only successful serialization consumes the cooldown window.
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
