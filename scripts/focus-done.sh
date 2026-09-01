#!/bin/bash
# Mark one uniquely matched open item done under the shared ledger lock.
set -u

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/scripts/focus-lib.sh" ]; then
  FOCUS_LIB_DIR="${CLAUDE_PLUGIN_ROOT}/scripts"
else
  FOCUS_LIB_DIR=$SCRIPT_DIR
fi
. "$FOCUS_LIB_DIR/focus-lib.sh"

query=$(focus_normalize_text "$@")
if [ -z "$query" ]; then
  printf 'usage: focus-done.sh <rank-or-words>\n' >&2
  exit 2
fi
if focus_ledger_path_status; then
  :
else
  ledger_path_rc=$?
  [ "$ledger_path_rc" = 1 ] && exit 1
  printf 'focus-done: unsafe ledger path: %s\n' "$FOCUS_LEDGER" >&2
  exit 4
fi

if ! focus_lock_acquire; then
  focus_lock_release
  printf 'focus-done: could not acquire ledger lock\n' >&2
  exit 4
fi

attempt=0
while [ "$attempt" -lt 2 ]; do
  attempt=$((attempt + 1))
  if ! focus_rewrite_begin; then
    focus_lock_release
    printf 'focus-done: could not create guarded rewrite\n' >&2
    exit 4
  fi

  match_output=
  if match_output=$(focus_match "$query" all); then
    match_rc=0
  else
    match_rc=$?
  fi
  case $match_rc in
    0) ;;
    1|3)
      if ! focus_rewrite_source_unchanged; then
        focus_rewrite_discard
        continue
      fi
      focus_rewrite_discard
      [ -z "$match_output" ] || printf '%s\n' "$match_output"
      focus_lock_release
      exit "$match_rc"
      ;;
    *)
      focus_rewrite_discard
      focus_lock_release
      printf 'focus-done: failed to match ledger items\n' >&2
      exit 4
      ;;
  esac

  source_line=$(printf '%s\n' "$match_output" | awk -F '\t' 'NR == 1 { print $3 }')
  if ! focus_rewrite_done "$source_line"; then
    if ! focus_rewrite_source_unchanged; then
      focus_rewrite_discard
      continue
    fi
    focus_rewrite_discard
    focus_lock_release
    printf 'focus-done: matched item changed before rewrite\n' >&2
    exit 4
  fi

  if ! focus_rewrite_preserve_eof; then
    focus_rewrite_discard
    focus_lock_release
    printf 'focus-done: could not preserve ledger terminator\n' >&2
    exit 4
  fi
  if ! focus_rewrite_source_unchanged; then
    focus_rewrite_discard
    continue
  fi
  if ! focus_rewrite_valid_mutation; then
    focus_rewrite_discard
    focus_lock_release
    printf 'focus-done: guarded rewrite validation failed\n' >&2
    exit 4
  fi
  if focus_rewrite_publish; then
    focus_lock_release
    printf '%s\n' "$match_output"
    exit 0
  else
    publish_rc=$?
  fi
  focus_rewrite_discard
  [ "$publish_rc" = 2 ] && continue
  focus_lock_release
  printf 'focus-done: atomic publish failed\n' >&2
  exit 4
done

focus_lock_release
printf 'focus-done: ledger changed during both rewrite attempts\n' >&2
exit 4
