#!/bin/bash
# Read-only format-v1 verifier. This script never acquires a lock, creates a
# scratch file, removes an artifact, or repairs user-owned text.
set -u
LC_ALL=C
export LC_ALL

TAB=$(printf '\t')
NEWLINE='
'
case ${HOME:-} in
  *"$TAB"*|*"$NEWLINE"*)
    printf 'focus-doctor: HOME must not contain tab or newline characters\n' >&2
    exit 2
    ;;
esac
case ${PWD:-} in
  *"$TAB"*|*"$NEWLINE"*)
    printf 'focus-doctor: PWD must not contain tab or newline characters\n' >&2
    exit 2
    ;;
esac

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/scripts/focus-lib.sh" ]; then
  FOCUS_LIB_DIR="${CLAUDE_PLUGIN_ROOT}/scripts"
else
  FOCUS_LIB_DIR=$SCRIPT_DIR
fi
if [ ! -f "$FOCUS_LIB_DIR/focus-lib.sh" ] || [ ! -r "$FOCUS_LIB_DIR/focus-lib.sh" ]; then
  printf 'focus-doctor: shared library is unavailable; diagnosis is incomplete\n' >&2
  exit 2
fi
# A nonzero source result is an operational installation failure, never the
# generic status 1 used for successfully reported findings.
. "$FOCUS_LIB_DIR/focus-lib.sh" || {
  printf 'focus-doctor: shared library failed to load; diagnosis is incomplete\n' >&2
  exit 2
}

findings=0
operational=0
ledger_state=missing
now=
ARCHIVE="$HOME/.claude/focus-ledger-archive.md"
SNOOZE="$HOME/.claude/.focus-snooze"
LAST_NUDGE="$HOME/.claude/.focus-last-nudge"

emit() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6"
}

diagnostic_path_safe() {
  case $1 in
    *"$TAB"*|*"$NEWLINE"*) return 1 ;;
    *) return 0 ;;
  esac
}

reject_unsafe_discovered_path() {
  emit ERROR diagnostic-path-unsupported - - \
    'rename the artifact without tab/newline separators and rerun doctor' \
    'an adjacent filesystem path could not be represented as one safe TSV field'
  operational=1
}

relay_records() {
  relay_payload=$1
  [ -z "$relay_payload" ] && return 0
  if ! relay_count=$(printf '%s\n' "$relay_payload" | awk -F '\t' '
    NF != 6 { invalid=1 }
    $1 == "ERROR" || $1 == "WARN" { count++ }
    END {
      if (invalid) exit 2
      print count + 0
    }
  '); then
    emit ERROR diagnostic-relay-failed - - \
      'restore a working awk command and rerun doctor' \
      'diagnostic records could not be validated or counted operationally'
    operational=1
    return 1
  fi
  case $relay_count in
    ''|*[!0-9]*)
      emit ERROR diagnostic-relay-failed - - \
        'restore a working awk command and rerun doctor' \
        'diagnostic record count was not a supported decimal'
      operational=1
      return 1
      ;;
  esac
  printf '%s\n' "$relay_payload"
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
    relay_records "$marker_output" || true
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
  if focus_lock_pending_claim_alive "$lock_path" "$lock_prefix"; then
    emit WARN "$lock_code-active" "$lock_path" - \
      'wait for the live pending claimant before retrying maintenance' \
      'lock directory ownership publication is still in progress'
    findings=$((findings + 1))
    return
  fi
  if [ -L "$lock_path/owner" ] || { [ -e "$lock_path/owner" ] && [ ! -f "$lock_path/owner" ]; }; then
    emit ERROR "$lock_code-owner-unsafe" "$lock_path/owner" - \
      'inspect owner metadata manually; doctor will not classify this lock as stale' \
      'owner metadata is a symlink or non-regular path'
    findings=$((findings + 1))
  elif [ -e "$lock_path/owner" ] && [ ! -r "$lock_path/owner" ]; then
    emit ERROR "$lock_code-owner-unreadable" "$lock_path/owner" - \
      'restore read permission and rerun doctor' \
      'lock ownership could not be classified operationally'
    operational=1
  elif focus_lock_dir_owner_alive "$lock_path" "$lock_prefix"; then
    lock_token=
    IFS= read -r lock_token < "$lock_path/owner" || lock_token=unknown
    emit WARN "$lock_code-active" "$lock_path" - \
      'wait for the recorded owner before retrying maintenance' \
      "shared owner metadata reports $lock_token as active"
    findings=$((findings + 1))
  else
    emit WARN "$lock_code-stale" "$lock_path" - \
      'inspect the owner metadata, then remove the stale directory manually' \
      'no live shared-library owner was found'
    findings=$((findings + 1))
  fi
}

inspect_lock_claims() {
  claim_base=$1
  claim_prefix=$2
  claim_code=$3
  for claim_path in "$claim_base".claim.*; do
    [ -e "$claim_path" ] || [ -L "$claim_path" ] || continue
    if ! diagnostic_path_safe "$claim_path"; then
      reject_unsafe_discovered_path
      continue
    fi
    if [ -L "$claim_path" ] || [ ! -f "$claim_path" ]; then
      emit ERROR "$claim_code-unsafe" "$claim_path" - \
        'inspect the claim path manually; doctor never removes it' \
        'pending lock claim is a symlink or non-regular path'
      findings=$((findings + 1))
      continue
    fi
    if [ ! -r "$claim_path" ]; then
      emit ERROR "$claim_code-unreadable" "$claim_path" - \
        'restore read permission and rerun doctor' \
        'pending lock claim could not be classified operationally'
      operational=1
      continue
    fi
    claim_token=
    if ! IFS= read -r claim_token < "$claim_path"; then
      [ -e "$claim_path" ] || [ -L "$claim_path" ] || continue
      emit ERROR "$claim_code-unreadable" "$claim_path" - \
        'restore read permission and rerun doctor' \
        'pending lock claim disappeared or could not be read consistently'
      operational=1
      continue
    fi
    case $claim_token in
      "$claim_prefix".*) claim_pid=${claim_token#*.} ;;
      *) claim_pid= ;;
    esac
    claim_positive=$claim_pid
    while [ "${claim_positive#0}" != "$claim_positive" ]; do
      claim_positive=${claim_positive#0}
    done
    claim_valid=1
    case $claim_pid in ''|*[!0-9]*) claim_valid=0 ;; esac
    [ -n "$claim_positive" ] || claim_valid=0
    if [ "$claim_valid" = 0 ]; then
      emit WARN "$claim_code-malformed" "$claim_path" - \
        'inspect the malformed claim manually before removing it' \
        'pending claim does not contain a supported positive owner PID'
    elif kill -0 "$claim_pid" 2>/dev/null; then
      emit WARN "$claim_code-active" "$claim_path" - \
        'wait for the recorded claimant before retrying maintenance' \
        "pending claim records live process $claim_pid"
    else
      emit WARN "$claim_code-stale" "$claim_path" - \
        'inspect the claim, then remove it manually if abandoned' \
        "pending claim records non-running process $claim_pid"
    fi
    findings=$((findings + 1))
  done
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
      case $ledger_state in
        nonempty)
          epoch_action='run focus-tidy if its report classifies this marker for removal'
          ;;
        missing|empty)
          epoch_action='remove this expired marker manually; tidy is a no-op while the ledger is missing or empty'
          ;;
        *)
          epoch_action='repair the unavailable ledger and rerun doctor before changing this marker'
          ;;
      esac
      emit WARN "$epoch_code-expired" "$epoch_path" - \
        "$epoch_action" \
        "marker epoch $marker_value is not later than current epoch $now"
      findings=$((findings + 1))
      ;;
    malformed)
      if [ "$epoch_code" = snooze ]; then
        epoch_action='run focus-snooze to replace this marker, or remove it manually'
      else
        epoch_action='remove this malformed internal cooldown marker manually'
      fi
      emit ERROR "$epoch_code-malformed" "$epoch_path" - \
        "$epoch_action" \
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
    if ! diagnostic_path_safe "$artifact"; then
      reject_unsafe_discovered_path
      continue
    fi
    case $artifact in
      "$FOCUS_LEDGER.lock"|"$FOCUS_LEDGER.lock.reap"|\
      "$FOCUS_LEDGER.lock.claim."*|"$FOCUS_LEDGER.lock.reap.claim."*|\
      "$FOCUS_LEDGER.backup."*) continue ;;
    esac
    if [ -L "$artifact" ]; then
      emit ERROR temp-unsafe "$artifact" - \
        'inspect and remove the symlink manually if it is obsolete' \
        'doctor does not follow temp-path symlinks'
      findings=$((findings + 1))
      continue
    fi
    if [ ! -f "$artifact" ]; then
      emit ERROR temp-unsafe "$artifact" - \
        'inspect and remove the non-regular path manually if it is obsolete' \
        'doctor does not read or remove non-regular temp paths'
      findings=$((findings + 1))
      continue
    fi
    if ! focus_is_tidy_temp_path "$artifact"; then
      emit WARN temp-leftover "$artifact" - \
        'inspect this legacy or manual ledger-adjacent file; tidy will not remove it' \
        'path does not match the PID-bearing rewrite-temp cleanup contract'
      findings=$((findings + 1))
      continue
    fi
    if ! artifact_mtime=$(focus_file_mtime_epoch "$artifact"); then
      emit ERROR temp-unreadable "$artifact" - \
        'restore metadata access and rerun doctor' \
        'eligible temp age could not be classified operationally'
      operational=1
      continue
    fi
    if [ "$artifact_mtime" -le $((now - 86400)) ] 2>/dev/null; then
      emit WARN temp-stale "$artifact" - \
        'run focus-tidy to remove this classified safe stale temp' \
        "eligible regular temp is at least 86400 seconds old (mtime $artifact_mtime)"
    else
      emit WARN temp-leftover "$artifact" - \
        'leave this live-age temp in place or inspect it manually' \
        "eligible rewrite temp is newer than 86400 seconds (mtime $artifact_mtime)"
    fi
    findings=$((findings + 1))
  done
}

inspect_archive_artifacts() {
  for artifact in "$ARCHIVE".*; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    if ! diagnostic_path_safe "$artifact"; then
      reject_unsafe_discovered_path
      continue
    fi
    case $artifact in
      "$ARCHIVE.lock"|"$ARCHIVE.lock.reap"|\
      "$ARCHIVE.lock.claim."*|"$ARCHIVE.lock.reap.claim."*) continue ;;
    esac
    if [ -L "$artifact" ] || [ ! -f "$artifact" ]; then
      emit ERROR archive-artifact-unsafe "$artifact" - \
        'inspect this path manually; doctor never follows or removes it' \
        'archive-adjacent transaction artifact is a symlink or non-regular path'
    else
      emit WARN archive-artifact-leftover "$artifact" - \
        'inspect this archive transaction or recovery artifact manually' \
        'doctor reports archive-adjacent leftovers read-only; tidy does not purge them'
    fi
    findings=$((findings + 1))
  done
}

inspect_marker_artifacts() {
  marker_artifact_target=$1
  marker_artifact_code=$2
  for artifact in "$marker_artifact_target".*; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    if ! diagnostic_path_safe "$artifact"; then
      reject_unsafe_discovered_path
      continue
    fi
    case $artifact in
      "$marker_artifact_target.lock"|"$marker_artifact_target.lock.reap"|\
      "$marker_artifact_target.lock.claim."*|"$marker_artifact_target.lock.reap.claim."*) continue ;;
    esac
    if [ -L "$artifact" ] || [ ! -f "$artifact" ]; then
      emit ERROR "$marker_artifact_code-artifact-unsafe" "$artifact" - \
        'inspect this path manually; doctor never follows or removes it' \
        'marker-adjacent stage or recovery artifact is a symlink or non-regular path'
    else
      emit WARN "$marker_artifact_code-artifact-leftover" "$artifact" - \
        'inspect this marker stage or recovery artifact manually' \
        'doctor reports marker-adjacent leftovers read-only; tidy does not purge unknown artifacts'
    fi
    findings=$((findings + 1))
  done
}

emit META doctor "$FOCUS_LEDGER" - 'read-only format-v1 diagnostics' 'output fields: level, code, path, line, action, detail'

if ! command -v awk >/dev/null 2>&1 || ! awk 'BEGIN { exit 0 }' </dev/null >/dev/null 2>&1; then
  emit ERROR awk-unavailable - - \
    'restore a working awk command and rerun doctor' \
    'ledger, marker, and diagnostic record parsing is unavailable'
  operational=1
elif [ -L "$FOCUS_LEDGER" ]; then
  ledger_state=unavailable
  emit ERROR ledger-unsafe "$FOCUS_LEDGER" - \
    'replace the symlink with a regular ledger before running commands' \
    'doctor does not follow a ledger symlink'
  operational=1
elif [ ! -e "$FOCUS_LEDGER" ]; then
  ledger_state=missing
  emit INFO ledger-missing "$FOCUS_LEDGER" - \
    'no action needed; focus-park will create it when required' \
    'missing ledger is a clean informational state'
elif [ ! -f "$FOCUS_LEDGER" ] || [ ! -r "$FOCUS_LEDGER" ]; then
  ledger_state=unavailable
  emit ERROR ledger-unreadable "$FOCUS_LEDGER" - \
    'restore a readable regular ledger and rerun doctor' \
    'ledger could not be parsed operationally'
  operational=1
else
  if [ -s "$FOCUS_LEDGER" ]; then ledger_state=nonempty; else ledger_state=empty; fi
  if ledger_output=$(focus_doctor_ledger); then
    relay_records "$ledger_output" || true
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
inspect_lock_claims "$FOCUS_LEDGER.lock" lock ledger-lock-claim
inspect_lock_claims "$FOCUS_LEDGER.lock.reap" reap ledger-reap-claim
inspect_lock_dir "$ARCHIVE.lock" archive archive-lock
inspect_lock_dir "$ARCHIVE.lock.reap" reap archive-reap
inspect_lock_claims "$ARCHIVE.lock" archive archive-lock-claim
inspect_lock_claims "$ARCHIVE.lock.reap" reap archive-reap-claim
for marker_target in "$SNOOZE" "$LAST_NUDGE"; do
  case $marker_target in "$SNOOZE") marker_code=snooze ;; *) marker_code=last-nudge ;; esac
  inspect_lock_dir "$marker_target.lock" lock "$marker_code-lock"
  inspect_lock_dir "$marker_target.lock.reap" reap "$marker_code-reap"
  inspect_lock_claims "$marker_target.lock" lock "$marker_code-lock-claim"
  inspect_lock_claims "$marker_target.lock.reap" reap "$marker_code-reap-claim"
done
inspect_marker_artifacts "$SNOOZE" snooze
inspect_marker_artifacts "$LAST_NUDGE" last-nudge
inspect_archive_artifacts

if now=$(date +%s 2>/dev/null) && focus_is_safe_epoch "$now"; then
  inspect_epoch_marker "$SNOOZE" snooze
  inspect_epoch_marker "$LAST_NUDGE" last-nudge
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
if [ "$ledger_state" = nonempty ] || [ "$ledger_state" = empty ]; then
  emit OK all-clean "$FOCUS_LEDGER" - 'no action needed' 'all checked ledger and setup contracts are clean'
fi
exit 0
