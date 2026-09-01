#!/bin/bash
# focus-ledger: deterministically append one parked item to the ledger.
# The append fallback, guarded rewrite, and hardened mkdir mutex preserve the
# established no-loss contract under failures and concurrent sessions.
set -eu

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/scripts/focus-lib.sh" ]; then
  FOCUS_LIB_DIR="${CLAUDE_PLUGIN_ROOT}/scripts"
else
  FOCUS_LIB_DIR=$SCRIPT_DIR
fi
. "$FOCUS_LIB_DIR/focus-lib.sh"

thing=$(focus_normalize_text "$@")
[ -n "$thing" ] || { echo "nothing to park (empty argument)" >&2; exit 2; }
today=$(date +%F)
item="- [ ] ($today) $thing"

if focus_ledger_path_status; then
  :
else
  ledger_path_rc=$?
  if [ "$ledger_path_rc" = 2 ]; then
    printf 'focus-park: unsafe ledger path: %s\n' "$FOCUS_LEDGER" >&2
    exit 1
  fi
fi
mkdir -p "$(dirname "$FOCUS_LEDGER")" || {
  printf 'focus-park: could not create ledger directory\n' >&2
  exit 1
}

# One atomic O_APPEND write is the last-resort path. It may place an item at EOF,
# but it cannot overwrite another session's item. The existing reap token gates
# this append against guarded rename publication, closing the append/mv race.
# Missing-ledger creation uses that same gate and one exclusive skeleton write.
_append_park() {
  focus_write_gate_acquire || return 1

  append_rc=0
  append_created=0
  if focus_ledger_path_status; then
    :
  else
    append_path_rc=$?
    case $append_path_rc in
      1)
        if (set -C; printf '# Focus ledger\n\n%s\n%s\n\n%s\n' \
          "$FOCUS_PARKED_HEAD" "$item" "$FOCUS_SESSION_HEAD" > "$FOCUS_LEDGER") 2>/dev/null; then
          append_created=1
        elif ! focus_ledger_path_status; then
          append_rc=1
        fi
        ;;
      *) append_rc=1 ;;
    esac
  fi

  if [ "$append_rc" = 0 ] && [ "$append_created" = 0 ]; then
    if [ -s "$FOCUS_LEDGER" ] && [ -n "$(tail -c 1 "$FOCUS_LEDGER")" ]; then
      if ! printf '\n' >> "$FOCUS_LEDGER"; then append_rc=1; fi
    fi
    if [ "$append_rc" = 0 ] && ! printf '%s\n' "$item" >> "$FOCUS_LEDGER"; then
      append_rc=1
    fi
  fi
  focus_write_gate_release
  return "$append_rc"
}

_do_park() {
  if focus_ledger_path_status; then
    :
  else
    park_path_rc=$?
    if [ "$park_path_rc" = 1 ]; then
      _append_park
      return
    fi
    return 1
  fi

  # The grep gate intentionally remains a substring check. The exact shared
  # parser match and its nonzero no-insert result protect near-miss headings.
  if grep -qF "$FOCUS_PARKED_HEAD" "$FOCUS_LEDGER" && \
     grep -qF "$FOCUS_SESSION_HEAD" "$FOCUS_LEDGER"; then
    tries=0
    while [ "$tries" -lt 2 ]; do
      tries=$((tries + 1))
      focus_rewrite_begin || { _append_park; return; }
      if ! focus_rewrite_park "$item"; then
        focus_rewrite_discard
        _append_park
        return
      fi
      if ! focus_rewrite_valid_insert; then
        focus_rewrite_discard
        _append_park
        return
      fi
      if focus_rewrite_publish; then
        return
      else
        publish_rc=$?
      fi
      focus_rewrite_discard
      [ "$publish_rc" = 2 ] && continue
      _append_park
      return
    done
    _append_park
  else
    _append_park
  fi
}

# Preserve the bounded 20+10 retry/reap/re-acquire mutex. Only park may use
# the lockless append fallback; every other mutating command fails unchanged.
park_rc=0
if focus_lock_acquire; then
  if ! _do_park; then park_rc=1; fi
  focus_lock_release
else
  if ! _append_park; then park_rc=1; fi
  focus_lock_release
fi

if [ "$park_rc" != 0 ]; then
  printf 'focus-park: could not write %s\n' "$FOCUS_LEDGER" >&2
  exit 1
fi

# Exit zero is a durability claim: require the exact inserted line to be present.
if ! grep -qxF -- "$item" "$FOCUS_LEDGER" 2>/dev/null; then
  printf 'focus-park: write verification failed: item not found in %s\n' "$FOCUS_LEDGER" >&2
  exit 1
fi

printf '%s\n' "$thing"
