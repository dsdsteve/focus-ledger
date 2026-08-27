#!/bin/bash
# Validate a portable duration, publish its future epoch safely, and print one
# platform-independent confirmation line.
set -u

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/scripts/focus-lib.sh" ]; then
  FOCUS_LIB_DIR="${CLAUDE_PLUGIN_ROOT}/scripts"
else
  FOCUS_LIB_DIR=$SCRIPT_DIR
fi
. "$FOCUS_LIB_DIR/focus-lib.sh"

usage() {
  printf 'usage: focus-snooze.sh [Nd|Nh|Nm]\n' >&2
  exit 2
}

duration=$(focus_normalize_text "$@")
[ -n "$duration" ] || duration=1d
number=${duration%?}
unit=${duration#"$number"}
case $number in
  ''|*[!0-9]*) usage ;;
esac
number=$(printf '%s' "$number" | sed 's/^0*//')
[ -n "$number" ] || usage

# Conservative per-unit maxima keep multiplication and addition below the
# bounded 18-digit epoch accepted by the Stop hook and below signed 64-bit range.
case $unit in
  d) factor=86400; max_number=11574000000000 ;;
  h) factor=3600; max_number=277777000000000 ;;
  m) factor=60; max_number=16666666000000000 ;;
  *) usage ;;
esac
focus_decimal_le "$number" "$max_number" || usage

now=$(date +%s) || { printf 'focus-snooze: could not read current time\n' >&2; exit 1; }
focus_is_safe_epoch "$now" || { printf 'focus-snooze: current time is outside the supported range\n' >&2; exit 1; }
seconds=$((number * factor))
until_ts=$((now + seconds))
focus_is_safe_epoch "$until_ts" || usage
[ "$until_ts" -gt "$now" ] 2>/dev/null || usage
focus_decimal_le "$until_ts" 999999999999999999 || usage

if until_text=$(focus_format_epoch "$until_ts"); then
  :
elif focus_format_epoch "$now" >/dev/null 2>&1; then
  # The platform can format ordinary epochs, so this target exceeded its range.
  usage
else
  printf 'focus-snooze: this date implementation cannot format epochs\n' >&2
  exit 1
fi
mkdir -p "$HOME/.claude" || {
  printf 'focus-snooze: could not create marker directory\n' >&2
  exit 1
}
SNOOZE="$HOME/.claude/.focus-snooze"
if ! focus_lock_acquire "$SNOOZE"; then
  focus_lock_release
  printf 'focus-snooze: could not acquire marker lock\n' >&2
  exit 1
fi
if ! focus_write_marker "$SNOOZE" "$until_ts"; then
  focus_lock_release
  printf 'focus-snooze: could not write %s\n' "$SNOOZE" >&2
  exit 1
fi
focus_lock_release

printf 'Nudge snoozed until %s.\n' "$until_text"
