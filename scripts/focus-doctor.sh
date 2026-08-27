#!/bin/bash
# Read-only format-v1 verifier. This script never acquires a lock, creates a
# scratch file, removes an artifact, or repairs user-owned text.
set -u
LC_ALL=C
export LC_ALL

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/scripts/focus-lib.sh" ]; then
  FOCUS_LIB_DIR="${CLAUDE_PLUGIN_ROOT}/scripts"
else
  FOCUS_LIB_DIR=$SCRIPT_DIR
fi
. "$FOCUS_LIB_DIR/focus-lib.sh"

TAB=$(printf '\t')
findings=0
operational=0
ledger_present=0
now=

emit() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6"
}

relay_records() {
  relay_payload=$1
  [ -z "$relay_payload" ] || printf '%s\n' "$relay_payload"
  relay_count=$(printf '%s\n' "$relay_payload" | awk -F '\t' '
    $1 == "ERROR" || $1 == "WARN" { count++ }
    END { print count + 0 }
  ')
  findings=$((findings + relay_count))
}

inspect_managed_markers() {
  marker_file=$1
  if [ -L "$marker_file" ]; then
    emit ERROR marker-unsafe "$marker_file" - \
      'replace the symlink with a regular file before checking markers' \
      'doctor does not follow symlinks'
    findings=$((findings + 1))
    return
  fi
  [ -e "$marker_file" ] || return
  if [ ! -f "$marker_file" ]; then
    emit ERROR marker-unsafe "$marker_file" - \
      'replace the non-regular path before checking markers' \
      'doctor reads regular CLAUDE.md files only'
    findings=$((findings + 1))
    return
  fi
  if [ ! -r "$marker_file" ]; then
    emit ERROR marker-unreadable "$marker_file" - \
      'restore read permission and rerun doctor' \
      'managed-block markers could not be inspected'
    operational=1
    return
  fi
  if marker_output=$(focus_scan_markers "$marker_file"); then
    relay_records "$marker_output"
  else
    emit ERROR marker-parser-failed "$marker_file" - \
      'rerun after restoring the shared parser' \
      'managed-block marker scan failed operationally'
    operational=1
  fi
}

inspect_lock_dir() {
  lock_path=$1
  lock_prefix=$2
  lock_code=$3
  if [ -L "$lock_path" ]; then
    emit ERROR "$lock_code-unsafe" "$lock_path" - \
      'remove only after confirming no command owns this path' \
      'lock path is a symlink; doctor did not follow it'
    findings=$((findings + 1))
    return
  fi
  [ -e "$lock_path" ] || return
  if [ ! -d "$lock_path" ]; then
    emit ERROR "$lock_code-unsafe" "$lock_path" - \
      'remove only after confirming no command owns this path' \
      'lock path exists but is not a directory'
    findings=$((findings + 1))
    return
  fi
  if focus_lock_dir_owner_alive "$lock_path" "$lock_prefix"; then
    lock_token=
    IFS= read -r lock_token < "$lock_path/owner" || lock_token=unknown
    emit WARN "$lock_code-active" "$lock_path" - \
      'wait for the recorded owner before retrying maintenance' \
      "shared owner metadata reports $lock_token as active"
  else
    emit WARN "$lock_code-stale" "$lock_path" - \
      'inspect the owner metadata, then remove the stale directory manually' \
      'no live shared-library owner was found'
  fi
  findings=$((findings + 1))
}

inspect_epoch_marker() {
  epoch_path=$1
  epoch_code=$2
  marker_result=$(focus_marker_status "$epoch_path" "$now")
  marker_state=${marker_result%%"$TAB"*}
  marker_value=${marker_result#*"$TAB"}
  case $marker_state in
    missing|active) ;;
    expired)
      if [ "$ledger_present" = 1 ]; then
        epoch_action='run focus-tidy to remove this expired numeric marker'
      else
        epoch_action='remove this expired marker manually; tidy is a no-op while the ledger is missing'
      fi
      emit WARN "$epoch_code-expired" "$epoch_path" - \
        "$epoch_action" \
        "marker epoch $marker_value is not later than current epoch $now"
      findings=$((findings + 1))
      ;;
    malformed)
      emit ERROR "$epoch_code-malformed" "$epoch_path" - \
        'replace with one future decimal epoch or remove it by hand' \
        'marker is not exactly one supported decimal epoch line'
      findings=$((findings + 1))
      ;;
    unsafe)
      emit ERROR "$epoch_code-unsafe" "$epoch_path" - \
        'replace the unsafe path with a regular marker or remove it manually' \
        'doctor does not follow marker symlinks or read non-regular paths'
      findings=$((findings + 1))
      ;;
    unreadable|*)
      emit ERROR "$epoch_code-unreadable" "$epoch_path" - \
        'restore read permission and rerun doctor' \
        'marker could not be inspected operationally'
      operational=1
      ;;
  esac
}

inspect_ledger_artifacts() {
  for artifact in "$FOCUS_LEDGER".*; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    case $artifact in
      "$FOCUS_LEDGER.lock"|"$FOCUS_LEDGER.lock.reap"|"$FOCUS_LEDGER.backup."*) continue ;;
    esac
    if [ -L "$artifact" ]; then
      emit ERROR temp-unsafe "$artifact" - \
        'inspect and remove the symlink manually if it is obsolete' \
        'doctor does not follow temp-path symlinks'
    elif [ -f "$artifact" ]; then
      if artifact_mtime=$(focus_file_mtime_epoch "$artifact") &&
         [ "$artifact_mtime" -le $((now - 86400)) ] 2>/dev/null; then
        artifact_code=temp-stale
        artifact_detail="regular temp is at least 86400 seconds old (mtime $artifact_mtime)"
      else
        artifact_code=temp-leftover
        artifact_detail='regular ledger-adjacent temp or unknown artifact remains'
      fi
      emit WARN "$artifact_code" "$artifact" - \
        'run focus-tidy only for classified safe stale temps; otherwise inspect manually' \
        "$artifact_detail"
    else
      emit ERROR temp-unsafe "$artifact" - \
        'inspect and remove the non-regular path manually if it is obsolete' \
        'doctor does not read or remove non-regular temp paths'
    fi
    findings=$((findings + 1))
  done
}

emit META doctor "$FOCUS_LEDGER" - 'read-only format-v1 diagnostics' 'output fields: level, code, path, line, action, detail'

if [ -L "$FOCUS_LEDGER" ]; then
  emit ERROR ledger-unsafe "$FOCUS_LEDGER" - \
    'replace the symlink with a regular ledger before running commands' \
    'doctor does not follow a ledger symlink'
  operational=1
elif [ ! -e "$FOCUS_LEDGER" ]; then
  emit INFO ledger-missing "$FOCUS_LEDGER" - \
    'no action needed; focus-park will create it when required' \
    'missing ledger is a clean informational state'
elif [ ! -f "$FOCUS_LEDGER" ] || [ ! -r "$FOCUS_LEDGER" ]; then
  emit ERROR ledger-unreadable "$FOCUS_LEDGER" - \
    'restore a readable regular ledger and rerun doctor' \
    'ledger could not be parsed operationally'
  operational=1
else
  ledger_present=1
  if ledger_output=$(focus_doctor_ledger); then
    relay_records "$ledger_output"
  else
    emit ERROR ledger-parser-failed "$FOCUS_LEDGER" - \
      'restore the shared parser and rerun doctor' \
      'ledger parser failed operationally'
    operational=1
  fi
fi

inspect_managed_markers "$PWD/CLAUDE.md"
inspect_managed_markers "$HOME/.claude/CLAUDE.md"
inspect_lock_dir "$FOCUS_LEDGER.lock" lock ledger-lock
inspect_lock_dir "$FOCUS_LEDGER.lock.reap" reap ledger-reap

if now=$(date +%s 2>/dev/null) && focus_is_safe_epoch "$now"; then
  inspect_epoch_marker "$HOME/.claude/.focus-snooze" snooze
  inspect_epoch_marker "$HOME/.claude/.focus-last-nudge" last-nudge
  inspect_ledger_artifacts
else
  emit ERROR clock-unavailable - - \
    'restore a working date command and rerun doctor' \
    'marker expiry and temp age could not be checked'
  operational=1
fi

if command -v jq >/dev/null 2>&1; then
  emit INFO jq - - 'no action needed' 'jq is available (optional)'
else
  emit INFO jq - - 'no action needed' 'jq is unavailable; built-in fallbacks remain supported'
fi

if [ "$operational" = 1 ]; then exit 2; fi
if [ "$findings" -gt 0 ]; then exit 1; fi
if [ "$ledger_present" = 1 ]; then
  emit OK all-clean "$FOCUS_LEDGER" - 'no action needed' 'all checked ledger and setup contracts are clean'
fi
exit 0
