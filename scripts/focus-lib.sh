#!/bin/sh
# Shared, source-safe primitives for focus-ledger scripts and hooks.
# Consumers set FOCUS_LIB_DIR to this directory before sourcing this file.

FOCUS_LEDGER="$HOME/.claude/focus-ledger.md"
FOCUS_PARKED_HEAD='## Parked (durable — carries across sessions)'
FOCUS_SESSION_HEAD='## This session (volatile — clear whenever)'

if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/scripts/focus-parse.awk" ]; then
  FOCUS_PARSE_AWK="${CLAUDE_PLUGIN_ROOT}/scripts/focus-parse.awk"
elif [ -n "${FOCUS_LIB_DIR:-}" ]; then
  FOCUS_PARSE_AWK="${FOCUS_LIB_DIR}/focus-parse.awk"
else
  FOCUS_PARSE_AWK=
fi

focus_normalize_text() {
  printf '%s' "$*" | tr '\n\t' '  ' | sed 's/  */ /g; s/^ //; s/ $//'
}

focus_is_safe_epoch() {
  focus_epoch_value=$1
  case $focus_epoch_value in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "${#focus_epoch_value}" -le 18 ]
}

focus_stale_threshold() {
  focus_threshold_value=${FOCUS_STALE_DAYS:-7}
  case $focus_threshold_value in
    ''|*[!0-9]*) focus_threshold_value=7 ;;
    *) [ "${#focus_threshold_value}" -le 9 ] || focus_threshold_value=7 ;;
  esac
  printf '%s\n' "$focus_threshold_value"
}

focus_parser_ready() {
  [ -n "$FOCUS_PARSE_AWK" ] && [ -f "$FOCUS_PARSE_AWK" ]
}

# Convert the local calendar date used by focus-park into the shared civil-day
# number. Using date +%F rather than epoch/86400 avoids UTC/local midnight drift.
focus_today_days() {
  focus_parser_ready || return 2
  focus_calendar_today=$(date +%F) || return 2
  FOCUS_PARSE_MODE=date-days \
  FOCUS_CALENDAR_DATE=$focus_calendar_today \
    awk -f "$FOCUS_PARSE_AWK" </dev/null
}

focus_parse_session_start() {
  focus_parser_ready || return 2
  FOCUS_PARSE_MODE=session-start \
  FOCUS_PARKED_HEAD="$FOCUS_PARKED_HEAD" \
  FOCUS_SESSION_HEAD="$FOCUS_SESSION_HEAD" \
  FOCUS_DISPLAY_LEDGER=$1 \
    awk -f "$FOCUS_PARSE_AWK" "$1"
}

focus_parse_stale() {
  focus_parser_ready || return 2
  FOCUS_PARSE_MODE=stale \
  FOCUS_PARKED_HEAD="$FOCUS_PARKED_HEAD" \
  FOCUS_SESSION_HEAD="$FOCUS_SESSION_HEAD" \
  FOCUS_TODAY_DAYS=$1 \
  FOCUS_STALE_THRESHOLD=$2 \
    awk -f "$FOCUS_PARSE_AWK" "$FOCUS_LEDGER"
}

focus_list_items() {
  [ -f "$FOCUS_LEDGER" ] || return 0
  focus_parser_ready || return 2
  focus_list_today=$(focus_today_days) || return 2
  focus_list_threshold=$(focus_stale_threshold)
  FOCUS_PARSE_MODE=list \
  FOCUS_PARKED_HEAD="$FOCUS_PARKED_HEAD" \
  FOCUS_SESSION_HEAD="$FOCUS_SESSION_HEAD" \
  FOCUS_TODAY_DAYS=$focus_list_today \
  FOCUS_STALE_THRESHOLD=$focus_list_threshold \
    awk -f "$FOCUS_PARSE_AWK" "$FOCUS_LEDGER"
}

# Print rank<TAB>section<TAB>source-line<TAB>escaped-raw-item for every match.
# Return 0 for one match, 1 for none, and 3 for ambiguity.
focus_match() {
  focus_match_query=$(focus_normalize_text "$1")
  focus_match_eligible=${2:-all}
  [ -n "$focus_match_query" ] || return 1
  [ -f "$FOCUS_LEDGER" ] || return 1
  focus_parser_ready || return 2
  focus_match_today=$(focus_today_days) || return 2
  focus_match_threshold=$(focus_stale_threshold)
  FOCUS_PARSE_MODE=match \
  FOCUS_PARKED_HEAD="$FOCUS_PARKED_HEAD" \
  FOCUS_SESSION_HEAD="$FOCUS_SESSION_HEAD" \
  FOCUS_TODAY_DAYS=$focus_match_today \
  FOCUS_STALE_THRESHOLD=$focus_match_threshold \
  FOCUS_MATCH_QUERY=$focus_match_query \
  FOCUS_MATCH_ELIGIBLE=$focus_match_eligible \
    awk -f "$FOCUS_PARSE_AWK" "$FOCUS_LEDGER"
}

# Decimal comparison without numeric conversion, so boundary-sized durations do
# not lose precision in awk or overflow the shell before they are rejected.
focus_decimal_le() {
  focus_dec_left=$1
  focus_dec_right=$2
  while [ "${focus_dec_left#0}" != "$focus_dec_left" ]; do
    focus_dec_left=${focus_dec_left#0}
  done
  [ -n "$focus_dec_left" ] || focus_dec_left=0
  while [ "${focus_dec_right#0}" != "$focus_dec_right" ]; do
    focus_dec_right=${focus_dec_right#0}
  done
  [ -n "$focus_dec_right" ] || focus_dec_right=0
  [ "${#focus_dec_left}" -lt "${#focus_dec_right}" ] && return 0
  [ "${#focus_dec_left}" -gt "${#focus_dec_right}" ] && return 1
  [ "$focus_dec_left" = "$focus_dec_right" ] && return 0
  focus_dec_first=$(printf '%s\n%s\n' "$focus_dec_left" "$focus_dec_right" | LC_ALL=C sort | sed -n '1p')
  [ "$focus_dec_first" = "$focus_dec_left" ]
}

focus_format_epoch() {
  focus_format_value=$1
  # GNU date exposes --version and uses -d @epoch. BSD date rejects --version
  # and uses -r epoch. Detect the implementation before formatting so GNU's
  # unrelated `-r reference-file` option can never select a file timestamp.
  if date --version >/dev/null 2>&1; then
    focus_format_result=$(date -d "@$focus_format_value" '+%Y-%m-%d %H:%M' 2>/dev/null) || return 1
  else
    focus_format_result=$(date -r "$focus_format_value" '+%Y-%m-%d %H:%M' 2>/dev/null) || return 1
  fi
  printf '%s\n' "$focus_format_result"
}

# Replace a marker without following a destination symlink or writing into a FIFO.
# A regular marker is replaced with one rename so a failed publish leaves its prior
# value intact. Unsafe destination types are removed before rename as before.
focus_write_marker() {
  focus_marker_path=$1
  focus_marker_value=$2
  focus_marker_tmp="${focus_marker_path}.tmp.$$"
  if (umask 077; set -C; printf '%s\n' "$focus_marker_value" > "$focus_marker_tmp") 2>/dev/null; then
    if [ -f "$focus_marker_path" ] && [ ! -L "$focus_marker_path" ]; then
      if mv -f "$focus_marker_tmp" "$focus_marker_path" 2>/dev/null; then return 0; fi
    elif rm -f "$focus_marker_path" 2>/dev/null && mv -f "$focus_marker_tmp" "$focus_marker_path" 2>/dev/null; then
      return 0
    fi
    rm -f "$focus_marker_tmp" 2>/dev/null || :
  fi
  return 1
}

FOCUS_LOCK=
FOCUS_REAP=
FOCUS_LOCK_TOKEN=
FOCUS_REAP_TOKEN=
FOCUS_LOCKED=
FOCUS_REAPING=
FOCUS_WRITE_GATE=
FOCUS_TMP=
FOCUS_TRIM=
FOCUS_PRE_BYTES=
FOCUS_PRE_LINES=
FOCUS_PRE_CKSUM=
FOCUS_PRE_FINAL_NEWLINE=

focus_lock_dir_owned() {
  focus_owned_dir=$1
  focus_owned_token=$2
  focus_recorded_token=
  [ -f "$focus_owned_dir/owner" ] && [ ! -L "$focus_owned_dir/owner" ] || return 1
  IFS= read -r focus_recorded_token < "$focus_owned_dir/owner" || return 1
  [ "$focus_recorded_token" = "$focus_owned_token" ]
}

focus_lock_claim_dir() {
  focus_claim_dir=$1
  focus_claim_token=$2
  mkdir "$focus_claim_dir" 2>/dev/null || return 1
  if (umask 077; printf '%s\n' "$focus_claim_token" > "$focus_claim_dir/owner") 2>/dev/null; then
    return 0
  fi
  rm -f "$focus_claim_dir/owner" 2>/dev/null || true
  rmdir "$focus_claim_dir" 2>/dev/null || true
  return 1
}

focus_lock_drop_owned_dir() {
  focus_drop_dir=$1
  focus_drop_token=$2
  focus_lock_dir_owned "$focus_drop_dir" "$focus_drop_token" || return 0
  rm -f "$focus_drop_dir/owner" 2>/dev/null || true
  rmdir "$focus_drop_dir" 2>/dev/null || true
}

focus_lock_reap_dir() {
  focus_stale_dir=$1
  rm -f "$focus_stale_dir/owner" 2>/dev/null || true
  rmdir "$focus_stale_dir" 2>/dev/null || true
}

focus_lock_cleanup() {
  if [ -n "${FOCUS_TRIM:-}" ]; then rm -f "$FOCUS_TRIM" 2>/dev/null || true; fi
  if [ -n "${FOCUS_TMP:-}" ]; then rm -f "$FOCUS_TMP" 2>/dev/null || true; fi
  if [ -n "${FOCUS_LOCKED:-}" ]; then
    focus_lock_drop_owned_dir "$FOCUS_LOCK" "$FOCUS_LOCK_TOKEN"
  fi
  if [ -n "${FOCUS_REAPING:-}" ]; then
    focus_lock_drop_owned_dir "$FOCUS_REAP" "$FOCUS_REAP_TOKEN"
  fi
  FOCUS_TRIM=
  FOCUS_TMP=
  FOCUS_LOCKED=
  FOCUS_REAPING=
  FOCUS_WRITE_GATE=
}

focus_lock_prepare() {
  focus_lock_target=${1:-$FOCUS_LEDGER}
  FOCUS_LOCK="$focus_lock_target.lock"
  FOCUS_REAP="$FOCUS_LOCK.reap"
  FOCUS_LOCK_TOKEN="lock.$$"
  FOCUS_REAP_TOKEN="reap.$$"
  FOCUS_LOCKED=
  FOCUS_REAPING=
  FOCUS_WRITE_GATE=
  FOCUS_TMP=
  FOCUS_TRIM=
  trap 'focus_lock_cleanup; exit 1' INT TERM HUP
}

# Poll mkdir every 0.1s for the requested number of attempts.
focus_try_lock() {
  focus_lock_i=0
  while [ "$focus_lock_i" -lt "$1" ]; do
    if focus_lock_claim_dir "$FOCUS_LOCK" "$FOCUS_LOCK_TOKEN"; then
      FOCUS_LOCKED=1
      return 0
    fi
    sleep 0.1
    focus_lock_i=$((focus_lock_i + 1))
  done
  return 1
}

# Return success only when a library-owned directory records a live PID.
focus_lock_dir_owner_alive() {
  focus_owner_dir=$1
  focus_owner_prefix=$2
  focus_owner_token=
  [ -f "$focus_owner_dir/owner" ] && [ ! -L "$focus_owner_dir/owner" ] || return 1
  IFS= read -r focus_owner_token < "$focus_owner_dir/owner" || return 1
  case $focus_owner_token in
    "$focus_owner_prefix".*) focus_owner_pid=${focus_owner_token#*.} ;;
    *) return 1 ;;
  esac
  case $focus_owner_pid in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$focus_owner_pid" 2>/dev/null
}

# A lock created by this library records its shell PID. Cooperative live owners
# are never reaped; legacy/empty locks and owners whose process exited remain stale.
focus_lock_owner_alive() {
  focus_lock_dir_owner_alive "$FOCUS_LOCK" lock
}

# Preserve park's hardened mutex: primary bounded wait, serialized stale-lock
# reap, then a second bounded re-acquire window. Ownership tokens ensure a slow
# live owner is not reaped and can never remove a successor during late cleanup.
focus_lock_acquire() {
  focus_lock_prepare "${1:-$FOCUS_LEDGER}"
  if focus_try_lock 20; then return 0; fi
  if ! focus_lock_owner_alive && focus_lock_claim_dir "$FOCUS_REAP" "$FOCUS_REAP_TOKEN"; then
    FOCUS_REAPING=1
    # Re-check after serializing reapers; an owner may have changed while waiting.
    if ! focus_lock_owner_alive; then focus_lock_reap_dir "$FOCUS_LOCK"; fi
  fi
  focus_try_lock 10 || true
  [ -n "$FOCUS_LOCKED" ]
}

focus_lock_release() {
  if [ -n "${FOCUS_LOCKED:-}" ]; then
    focus_lock_drop_owned_dir "$FOCUS_LOCK" "$FOCUS_LOCK_TOKEN"
    FOCUS_LOCKED=
  fi
  if [ -n "${FOCUS_REAPING:-}" ]; then
    focus_lock_drop_owned_dir "$FOCUS_REAP" "$FOCUS_REAP_TOKEN"
    FOCUS_REAPING=
    FOCUS_WRITE_GATE=
  fi
}

# The existing reap token doubles as a publication gate. This serializes the
# lockless park fallback with the checksum+rename step used by guarded rewrites:
# append-before-publish forces a retry; publish-before-append targets the new file.
focus_write_gate_acquire() {
  FOCUS_WRITE_GATE=
  if [ -n "${FOCUS_REAPING:-}" ] &&
     focus_lock_dir_owned "$FOCUS_REAP" "$FOCUS_REAP_TOKEN"; then
    FOCUS_WRITE_GATE=borrowed
    return 0
  fi

  while :; do
    if focus_lock_claim_dir "$FOCUS_REAP" "$FOCUS_REAP_TOKEN"; then
      FOCUS_REAPING=1
      FOCUS_WRITE_GATE=owned
      return 0
    fi
    if [ ! -f "$FOCUS_REAP/owner" ] || [ -L "$FOCUS_REAP/owner" ]; then
      # An unmanaged reap token blocks all cooperative publishers. Callers may
      # use the append-only path, but guarded renames must fail unchanged.
      return 2
    fi
    if focus_lock_dir_owner_alive "$FOCUS_REAP" reap; then
      sleep 0.05
      continue
    fi
    focus_lock_reap_dir "$FOCUS_REAP"
  done
}

focus_write_gate_release() {
  if [ "${FOCUS_WRITE_GATE:-}" = owned ]; then
    focus_lock_drop_owned_dir "$FOCUS_REAP" "$FOCUS_REAP_TOKEN"
    FOCUS_REAPING=
  fi
  FOCUS_WRITE_GATE=
}

focus_rewrite_begin() {
  FOCUS_PRE_BYTES=$(wc -c < "$FOCUS_LEDGER") || return 1
  FOCUS_PRE_LINES=$(wc -l < "$FOCUS_LEDGER") || return 1
  FOCUS_PRE_CKSUM=$(cksum < "$FOCUS_LEDGER") || return 1
  if [ -s "$FOCUS_LEDGER" ] && [ -n "$(tail -c 1 "$FOCUS_LEDGER")" ]; then
    FOCUS_PRE_FINAL_NEWLINE=0
  else
    FOCUS_PRE_FINAL_NEWLINE=1
  fi
  FOCUS_TMP=$(mktemp "$FOCUS_LEDGER.XXXXXX" 2>/dev/null) || return 1
}

focus_rewrite_discard() {
  if [ -n "${FOCUS_TRIM:-}" ]; then rm -f "$FOCUS_TRIM" 2>/dev/null || true; fi
  if [ -n "${FOCUS_TMP:-}" ]; then rm -f "$FOCUS_TMP" 2>/dev/null || true; fi
  FOCUS_TRIM=
  FOCUS_TMP=
}

focus_rewrite_park() {
  focus_parser_ready || return 2
  FOCUS_PARSE_MODE=park-insert \
  FOCUS_PARKED_HEAD="$FOCUS_PARKED_HEAD" \
  FOCUS_SESSION_HEAD="$FOCUS_SESSION_HEAD" \
  FOCUS_REWRITE_ITEM=$1 \
    awk -f "$FOCUS_PARSE_AWK" "$FOCUS_LEDGER" > "$FOCUS_TMP"
}

focus_rewrite_resume() {
  focus_parser_ready || return 2
  FOCUS_PARSE_MODE=resume-move \
  FOCUS_PARKED_HEAD="$FOCUS_PARKED_HEAD" \
  FOCUS_SESSION_HEAD="$FOCUS_SESSION_HEAD" \
  FOCUS_TARGET_LINE=$1 \
    awk -f "$FOCUS_PARSE_AWK" "$FOCUS_LEDGER" > "$FOCUS_TMP"
}

focus_rewrite_done() {
  focus_parser_ready || return 2
  FOCUS_PARSE_MODE=done-mutate \
  FOCUS_PARKED_HEAD="$FOCUS_PARKED_HEAD" \
  FOCUS_SESSION_HEAD="$FOCUS_SESSION_HEAD" \
  FOCUS_TARGET_LINE=$1 \
    awk -f "$FOCUS_PARSE_AWK" "$FOCUS_LEDGER" > "$FOCUS_TMP"
}

# Awk always terminates its final record. Remove only that generated terminator
# when the source lacked one so a valid hand-edited ledger remains byte-shaped.
focus_rewrite_preserve_eof() {
  [ "$FOCUS_PRE_FINAL_NEWLINE" = 0 ] || return 0
  focus_rewrite_bytes=$(wc -c < "$FOCUS_TMP") || return 1
  [ "$focus_rewrite_bytes" -gt 0 ] || return 1
  FOCUS_TRIM="${FOCUS_TMP}.trim"
  if ! (umask 077; dd if="$FOCUS_TMP" of="$FOCUS_TRIM" bs=1 count=$((focus_rewrite_bytes - 1))) 2>/dev/null; then
    return 1
  fi
  if ! mv -f "$FOCUS_TRIM" "$FOCUS_TMP"; then return 1; fi
  FOCUS_TRIM=
}

focus_rewrite_source_unchanged() {
  [ "$(cksum < "$FOCUS_LEDGER")" = "$FOCUS_PRE_CKSUM" ]
}

focus_rewrite_valid_insert() {
  [ "$(wc -l < "$FOCUS_TMP")" -gt "$FOCUS_PRE_LINES" ]
}

focus_rewrite_valid_mutation() {
  [ "$(wc -l < "$FOCUS_TMP")" -eq "$FOCUS_PRE_LINES" ] &&
    [ "$(wc -c < "$FOCUS_TMP")" -eq "$FOCUS_PRE_BYTES" ] &&
    ! cmp -s "$FOCUS_TMP" "$FOCUS_LEDGER"
}

focus_rewrite_publish() {
  focus_write_gate_acquire || return 1
  # Re-check while fallback appends are excluded; callers retry on status 2.
  if ! focus_rewrite_source_unchanged; then
    focus_write_gate_release
    return 2
  fi
  if mv "$FOCUS_TMP" "$FOCUS_LEDGER"; then
    FOCUS_TMP=
    focus_write_gate_release
    return 0
  fi
  focus_write_gate_release
  return 1
}
