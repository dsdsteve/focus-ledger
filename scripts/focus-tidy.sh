#!/bin/bash
# Report or apply format-v1 cleanup. Report mode is strictly read-only. Apply
# re-derives under the shared ledger lock/write gate, stages same-filesystem
# replacements, verifies raw-line multisets, and rolls both files back on error.
set -u
LC_ALL=C
export LC_ALL

TAB=$(printf '\t')
NEWLINE='
'
case ${HOME:-} in
  *"$TAB"*|*"$NEWLINE"*)
    printf 'focus-tidy: HOME must not contain tab or newline characters\n' >&2
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
  printf 'focus-tidy: shared library is unavailable\n' >&2
  exit 2
fi
. "$FOCUS_LIB_DIR/focus-lib.sh" || {
  printf 'focus-tidy: shared library failed to load\n' >&2
  exit 2
}

mode=report
case ${1:-} in
  '') ;;
  --apply) mode=apply ;;
  *) printf 'usage: focus-tidy.sh [--apply]\n' >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { printf 'usage: focus-tidy.sh [--apply]\n' >&2; exit 2; }

ARCHIVE="$HOME/.claude/focus-ledger-archive.md"
SNOOZE="$HOME/.claude/.focus-snooze"
LAST_NUDGE="$HOME/.claude/.focus-last-nudge"
TEMP_STALE_SECONDS=86400
archive_days=$(focus_archive_threshold)

report_records=
archive_count=0
promote_count=0
rehome_count=0
remove_count=0
skip_count=0
block_count=0
remove_snooze=0
remove_last_nudge=0
remove_temp_paths=
calendar_today=
today_days=
now_epoch=

ledger_backup=
ledger_backup_owned=0
archive_backup=
archive_existed=0
archive_pre_cksum=
archive_lock="$ARCHIVE.lock"
archive_lock_token="archive.$$"
archive_locked=0
archive_stage=
archive_expected=
archive_lines=
ledger_expected=
pre_open=
post_open=
pre_near=
post_near=
pre_retained=
post_all=
raw_capture=
quarantine_pairs=
quarantine_count=0
inflight_original=
inflight_quarantine=
inflight_copy=
tidy_marker_lock_path=
tidy_marker_lock_token=
tidy_marker_lock_held=0
archive_published=0
ledger_published=0
ledger_change_count=0
retained_artifacts=

emit() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6"
}

append_record() {
  append_line=$(printf '%s\t%s\t%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4" "$5" "$6")
  if [ -z "$report_records" ]; then
    report_records=$append_line
  else
    report_records="$report_records
$append_line"
  fi
}

append_temp_path() {
  if [ -z "$remove_temp_paths" ]; then
    remove_temp_paths=$1
  else
    remove_temp_paths="$remove_temp_paths
$1"
  fi
}

count_records() {
  archive_count=$(printf '%s\n' "$report_records" | awk -F '\t' '$1 == "ARCHIVE" { n++ } END { print n + 0 }')
  promote_count=$(printf '%s\n' "$report_records" | awk -F '\t' '$1 == "PROMOTE" { n++ } END { print n + 0 }')
  rehome_count=$(printf '%s\n' "$report_records" | awk -F '\t' '$1 == "REHOME" { n++ } END { print n + 0 }')
  remove_count=$(printf '%s\n' "$report_records" | awk -F '\t' '$1 == "REMOVE" { n++ } END { print n + 0 }')
  skip_count=$(printf '%s\n' "$report_records" | awk -F '\t' '$1 == "SKIP" { n++ } END { print n + 0 }')
  block_count=$(printf '%s\n' "$report_records" | awk -F '\t' '$1 == "BLOCK" { n++ } END { print n + 0 }')
}

inspect_cleanup_marker() {
  cleanup_marker_path=$1
  cleanup_marker_code=$2
  cleanup_marker_result=$(focus_marker_status "$cleanup_marker_path" "$now_epoch")
  cleanup_marker_state=${cleanup_marker_result%%"$TAB"*}
  cleanup_marker_value=${cleanup_marker_result#*"$TAB"}
  case $cleanup_marker_state in
    missing|active) ;;
    expired)
      append_record REMOVE "$cleanup_marker_code-expired" "$cleanup_marker_path" - \
        'remove expired numeric marker after core publication verifies' \
        "marker epoch $cleanup_marker_value is not later than current epoch $now_epoch"
      case $cleanup_marker_code in
        snooze) remove_snooze=1 ;;
        last-nudge) remove_last_nudge=1 ;;
      esac
      ;;
    malformed)
      append_record SKIP "$cleanup_marker_code-malformed" "$cleanup_marker_path" - \
        'run doctor; malformed markers are never auto-removed' \
        'marker is not exactly one supported decimal epoch line'
      ;;
    unsafe)
      append_record BLOCK "$cleanup_marker_code-unsafe" "$cleanup_marker_path" - \
        'replace or remove the unsafe path manually before apply' \
        'tidy never follows marker symlinks or touches non-regular paths'
      ;;
    unreadable|*)
      append_record BLOCK "$cleanup_marker_code-unreadable" "$cleanup_marker_path" - \
        'restore read permission before apply' \
        'marker could not be classified safely'
      ;;
  esac
}

inspect_cleanup_temps() {
  for cleanup_temp in "$FOCUS_LEDGER".*; do
    [ -e "$cleanup_temp" ] || [ -L "$cleanup_temp" ] || continue
    focus_is_tidy_temp_path "$cleanup_temp" || continue
    if [ -L "$cleanup_temp" ] || [ ! -f "$cleanup_temp" ]; then
      append_record BLOCK temp-unsafe "$cleanup_temp" - \
        'remove the unsafe path manually before apply' \
        'tidy removes stale regular rewrite temps only'
      continue
    fi
    if ! cleanup_mtime=$(focus_file_mtime_epoch "$cleanup_temp"); then
      append_record BLOCK temp-unreadable "$cleanup_temp" - \
        'restore metadata access or inspect the path manually' \
        'temp age could not be classified safely'
      continue
    fi
    if [ "$cleanup_mtime" -le $((now_epoch - TEMP_STALE_SECONDS)) ] 2>/dev/null; then
      append_record REMOVE temp-stale "$cleanup_temp" - \
        'remove safe stale regular temp after core publication verifies' \
        "temp mtime $cleanup_mtime is at least $TEMP_STALE_SECONDS seconds old"
      append_temp_path "$cleanup_temp"
    fi
  done
}

classify_current() {
  report_records=
  remove_snooze=0
  remove_last_nudge=0
  remove_temp_paths=

  calendar_today=$(date +%F 2>/dev/null) || return 2
  now_epoch=$(date +%s 2>/dev/null) || return 2
  focus_is_safe_epoch "$now_epoch" || return 2
  today_days=$(focus_calendar_days "$calendar_today") || return 2

  if ledger_records=$(focus_tidy_ledger_report "$ARCHIVE" "$today_days" "$archive_days"); then
    report_records=$ledger_records
  else
    return 2
  fi
  if printf '%s\n' "$report_records" | awk -F '\t' '$1 == "ARCHIVE" { found=1 } END { exit !found }'; then
    if [ -L "$ARCHIVE" ] || { [ -e "$ARCHIVE" ] && [ ! -f "$ARCHIVE" ]; }; then
      append_record BLOCK archive-unsafe "$ARCHIVE" - \
        'replace or remove the unsafe archive path before apply' \
        'tidy never follows archive symlinks or reads non-regular archive paths'
    elif [ -e "$ARCHIVE" ] && [ ! -r "$ARCHIVE" ]; then
      append_record BLOCK archive-unreadable "$ARCHIVE" - \
        'restore archive read permission before apply' \
        'existing archive could not be copied or verified safely'
    fi
  fi
  inspect_cleanup_marker "$SNOOZE" snooze
  inspect_cleanup_marker "$LAST_NUDGE" last-nudge
  inspect_cleanup_temps
  count_records
}

print_report() {
  emit META report "$FOCUS_LEDGER" - \
    "report-only; archive threshold ${archive_days}d" \
    'no files, locks, or mtimes are changed'
  [ -z "$report_records" ] || printf '%s\n' "$report_records"
  action_total=$((archive_count + promote_count + rehome_count + remove_count))
  if [ "$action_total" -eq 0 ]; then
    emit NOTHING no-actions "$FOCUS_LEDGER" - 'no tidy actions' \
      'missing, empty, already tidy, or doctor-only lines require no automatic change'
  fi
  emit SUMMARY counts "$FOCUS_LEDGER" - \
    "archive=$archive_count;promote=$promote_count;rehome=$rehome_count;remove=$remove_count" \
    "skip=$skip_count;block=$block_count"
}

path_exists() {
  [ -e "$1" ] || [ -L "$1" ]
}

remember_retained_artifact() {
  retained_path=$1
  [ -n "$retained_path" ] || return 0
  path_exists "$retained_path" || return 0
  if [ -z "$retained_artifacts" ]; then
    retained_artifacts=$retained_path
  else
    retained_artifacts="$retained_artifacts
$retained_path"
  fi
}

remove_owned_file() {
  remove_owned_path=$1
  [ -n "$remove_owned_path" ] || return 0
  rm -f "$remove_owned_path" 2>/dev/null || true
  if path_exists "$remove_owned_path"; then
    remember_retained_artifact "$remove_owned_path"
    return 1
  fi
}

verify_owned_lock_released() {
  verify_lock_path=$1
  verify_lock_token=$2
  path_exists "$verify_lock_path" || return 0
  verify_owner=
  if [ -f "$verify_lock_path/owner" ] && [ ! -L "$verify_lock_path/owner" ]; then
    IFS= read -r verify_owner < "$verify_lock_path/owner" || verify_owner=
  fi
  # A different recorded token can be a new cooperative owner that acquired
  # after our release. Only our token or an ownerless leftover is ours to report.
  if [ -z "$verify_owner" ] || [ "$verify_owner" = "$verify_lock_token" ]; then
    remember_retained_artifact "$verify_lock_path"
    return 1
  fi
}

cleanup_work_files() {
  cleanup_work_status=0
  for cleanup_owned in "$archive_stage" "$archive_expected" "$archive_lines" \
    "$ledger_expected" "$pre_open" "$post_open" "$pre_near" "$post_near" \
    "$pre_retained" "$post_all" "$raw_capture" "${FOCUS_TRIM:-}" "${FOCUS_TMP:-}"; do
    [ -z "$cleanup_owned" ] || remove_owned_file "$cleanup_owned" || cleanup_work_status=1
  done
  archive_stage=
  archive_expected=
  archive_lines=
  ledger_expected=
  pre_open=
  post_open=
  pre_near=
  post_near=
  pre_retained=
  post_all=
  raw_capture=
  FOCUS_TRIM=
  FOCUS_TMP=
  return "$cleanup_work_status"
}

tidy_marker_lock_release() {
  if [ "$tidy_marker_lock_held" != 0 ]; then
    tidy_marker_release_path=$tidy_marker_lock_path
    tidy_marker_release_token=$tidy_marker_lock_token
    focus_lock_drop_owned_dir "$tidy_marker_release_path" "$tidy_marker_release_token"
    if ! verify_owned_lock_released "$tidy_marker_release_path" "$tidy_marker_release_token"; then
      # Keep ownership state so finalization/rollback can retry and report it.
      return 1
    fi
    tidy_marker_lock_held=0
  fi
  tidy_marker_lock_path=
  tidy_marker_lock_token=
  return 0
}

tidy_marker_lock_acquire() {
  tidy_marker_target=$1
  tidy_marker_lock_path="$tidy_marker_target.lock"
  tidy_marker_lock_token="lock.$$"
  tidy_marker_lock_held=0
  tidy_marker_try=0
  while [ "$tidy_marker_try" -lt 30 ]; do
    tidy_marker_lock_held=maybe
    if focus_lock_claim_dir "$tidy_marker_lock_path" "$tidy_marker_lock_token"; then
      tidy_marker_lock_held=1
      return 0
    fi
    tidy_marker_lock_held=0
    sleep 0.1
    tidy_marker_try=$((tidy_marker_try + 1))
  done
  tidy_marker_lock_path=
  tidy_marker_lock_token=
  return 1
}

tidy_archive_lock_release() {
  tidy_archive_release_status=0
  if [ "$archive_locked" != 0 ]; then
    tidy_archive_release_path=$archive_lock
    tidy_archive_release_token=$archive_lock_token
    focus_lock_drop_owned_dir "$tidy_archive_release_path" "$tidy_archive_release_token"
    verify_owned_lock_released "$tidy_archive_release_path" "$tidy_archive_release_token" ||
      tidy_archive_release_status=1
    archive_locked=0
  fi
  return "$tidy_archive_release_status"
}

release_all() {
  release_status=0
  if [ -n "${focus_pending_claim:-}" ]; then
    pending_release_path=$focus_pending_claim
    pending_release_token=${focus_claim_token:-}
    focus_lock_drop_pending_claim "$pending_release_path" "$pending_release_token"
    if path_exists "$pending_release_path"; then
      remember_retained_artifact "$pending_release_path"
      release_status=1
    fi
    focus_pending_claim=
  fi
  tidy_marker_lock_release || release_status=1
  tidy_archive_lock_release || release_status=1
  if [ -n "${FOCUS_REAPING:-}" ]; then
    release_reap_path=$FOCUS_REAP
    release_reap_token=$FOCUS_REAP_TOKEN
    focus_lock_drop_owned_dir "$release_reap_path" "$release_reap_token"
    verify_owned_lock_released "$release_reap_path" "$release_reap_token" || release_status=1
  fi
  FOCUS_REAPING=
  FOCUS_WRITE_GATE=
  if [ -n "${FOCUS_LOCKED:-}" ]; then
    release_ledger_path=$FOCUS_LOCK
    release_ledger_token=$FOCUS_LOCK_TOKEN
    focus_lock_drop_owned_dir "$release_ledger_path" "$release_ledger_token"
    verify_owned_lock_released "$release_ledger_path" "$release_ledger_token" || release_status=1
  fi
  FOCUS_LOCKED=
  return "$release_status"
}

report_retained_artifacts() {
  [ -z "$retained_artifacts" ] && return 0
  while IFS= read -r retained_path; do
    [ -n "$retained_path" ] && path_exists "$retained_path" || continue
    printf 'focus-tidy: retained recovery artifact: %s\n' "$retained_path" >&2
  done <<EOF_RETAINED
$retained_artifacts
EOF_RETAINED
}

# Tidy owns no stale-lock cleanup policy. It may wait for a cooperative owner
# and remove only lock directories it successfully created itself; pre-existing
# live or stale ledger lock/reap directories are never reaped by tidy.
tidy_ledger_lock_acquire() {
  focus_lock_prepare "$FOCUS_LEDGER"
  focus_try_lock 30
}

tidy_write_gate_acquire() {
  tidy_gate_try=0
  while [ "$tidy_gate_try" -lt 60 ]; do
    FOCUS_REAPING=maybe
    FOCUS_WRITE_GATE=owned
    if focus_lock_claim_dir "$FOCUS_REAP" "$FOCUS_REAP_TOKEN"; then
      FOCUS_REAPING=1
      return 0
    fi
    FOCUS_REAPING=
    FOCUS_WRITE_GATE=
    : "$FOCUS_REAPING" "$FOCUS_WRITE_GATE"
    sleep 0.05
    tidy_gate_try=$((tidy_gate_try + 1))
  done
  return 1
}

tidy_archive_lock_acquire() {
  tidy_archive_try=0
  while [ "$tidy_archive_try" -lt 60 ]; do
    archive_locked=maybe
    if focus_lock_claim_dir "$archive_lock" "$archive_lock_token"; then
      archive_locked=1
      return 0
    fi
    archive_locked=0
    sleep 0.05
    tidy_archive_try=$((tidy_archive_try + 1))
  done
  return 1
}

fail_locked() {
  fail_message=$1
  fail_cleanup_status=0
  cleanup_work_files || fail_cleanup_status=1
  [ -z "$archive_backup" ] || remove_owned_file "$archive_backup" || fail_cleanup_status=1
  if [ "$ledger_backup_owned" = 1 ] && [ "$ledger_published" = 0 ]; then
    remove_owned_file "$ledger_backup" || fail_cleanup_status=1
    [ "$fail_cleanup_status" = 0 ] && ledger_backup_owned=0
  fi
  release_all || fail_cleanup_status=1
  printf 'focus-tidy: %s\n' "$fail_message" >&2
  if [ "$fail_cleanup_status" != 0 ]; then
    report_retained_artifacts
  fi
  exit 2
}

append_quarantine_pair() {
  quarantine_original=$1
  quarantine_path=$2
  quarantine_copy="$quarantine_path.restore"
  if [ -e "$quarantine_copy" ] || [ -L "$quarantine_copy" ]; then
    mv "$quarantine_path" "$quarantine_original" 2>/dev/null || true
    return 1
  fi
  if ! (umask 077; set -C; cat "$quarantine_path" > "$quarantine_copy") 2>/dev/null ||
     ! cmp -s "$quarantine_path" "$quarantine_copy"; then
    # Restore from the quarantine first. Delete the new recovery copy only
    # after the original is back; otherwise leave both sources for rollback.
    if mv "$quarantine_path" "$quarantine_original" 2>/dev/null; then
      rm -f "$quarantine_copy" 2>/dev/null || true
    fi
    return 1
  fi
  quarantine_entry=$(printf '%s\t%s\t%s' "$quarantine_original" "$quarantine_path" "$quarantine_copy")
  if [ -z "$quarantine_pairs" ]; then
    quarantine_pairs=$quarantine_entry
  else
    quarantine_pairs="$quarantine_pairs
$quarantine_entry"
  fi
  quarantine_count=$((quarantine_count + 1))
}

restore_inflight_quarantine() {
  [ -n "$inflight_original" ] || return 0
  inflight_status=0
  inflight_source=
  if [ ! -e "$inflight_original" ] && [ ! -L "$inflight_original" ]; then
    if [ -f "$inflight_quarantine" ] && [ ! -L "$inflight_quarantine" ]; then
      inflight_source=$inflight_quarantine
    elif [ -f "$inflight_copy" ] && [ ! -L "$inflight_copy" ]; then
      inflight_source=$inflight_copy
    fi
    if [ -n "$inflight_source" ] && ln "$inflight_source" "$inflight_original" 2>/dev/null; then
      remove_owned_file "$inflight_quarantine" || inflight_status=1
      remove_owned_file "$inflight_copy" || inflight_status=1
    else
      # Failed restoration must preserve every remaining source, especially a
      # .restore file when the quarantine itself has disappeared.
      inflight_status=1
      remember_retained_artifact "$inflight_quarantine"
      remember_retained_artifact "$inflight_copy"
    fi
  else
    # If another path already exists, remove recovery copies only when one
    # proves it has the same bytes. Otherwise preserve them for manual recovery.
    inflight_matching_source=
    if [ -f "$inflight_quarantine" ] && [ ! -L "$inflight_quarantine" ] &&
       cmp -s "$inflight_original" "$inflight_quarantine"; then
      inflight_matching_source=$inflight_quarantine
    elif [ -f "$inflight_copy" ] && [ ! -L "$inflight_copy" ] &&
         cmp -s "$inflight_original" "$inflight_copy"; then
      inflight_matching_source=$inflight_copy
    elif ! path_exists "$inflight_quarantine" && ! path_exists "$inflight_copy"; then
      inflight_matching_source=none
    fi
    if [ -n "$inflight_matching_source" ]; then
      remove_owned_file "$inflight_quarantine" || inflight_status=1
      remove_owned_file "$inflight_copy" || inflight_status=1
    else
      inflight_status=1
      remember_retained_artifact "$inflight_quarantine"
      remember_retained_artifact "$inflight_copy"
    fi
  fi
  if [ "$inflight_status" = 0 ]; then
    inflight_original=
    inflight_quarantine=
    inflight_copy=
  fi
  return "$inflight_status"
}

restore_quarantines() {
  [ -z "$quarantine_pairs" ] && return 0
  restore_quarantine_status=0
  while IFS="$TAB" read -r original_path quarantine_path quarantine_copy; do
    [ -n "$original_path" ] || continue
    restore_marker=0
    case $original_path in "$SNOOZE"|"$LAST_NUDGE") restore_marker=1 ;; esac
    if [ "$restore_marker" = 1 ] && ! tidy_marker_lock_acquire "$original_path"; then
      restore_quarantine_status=1
      continue
    fi

    if [ -e "$original_path" ] || [ -L "$original_path" ]; then
      if [ "$restore_marker" = 1 ]; then
        # A newer marker won the race after quarantine; preserve it rather than
        # replacing it with the expired pre-state.
        remove_owned_file "$quarantine_path" || restore_quarantine_status=1
        remove_owned_file "$quarantine_copy" || restore_quarantine_status=1
      else
        restore_quarantine_status=1
      fi
    else
      restore_source=
      if [ -f "$quarantine_path" ] && [ ! -L "$quarantine_path" ]; then
        restore_source=$quarantine_path
      elif [ -f "$quarantine_copy" ] && [ ! -L "$quarantine_copy" ]; then
        restore_source=$quarantine_copy
      fi
      if [ -n "$restore_source" ] && ln "$restore_source" "$original_path" 2>/dev/null; then
        remove_owned_file "$quarantine_path" || restore_quarantine_status=1
        remove_owned_file "$quarantine_copy" || restore_quarantine_status=1
      elif [ "$restore_marker" = 1 ] && { [ -e "$original_path" ] || [ -L "$original_path" ]; }; then
        remove_owned_file "$quarantine_path" || restore_quarantine_status=1
        remove_owned_file "$quarantine_copy" || restore_quarantine_status=1
      else
        restore_quarantine_status=1
      fi
    fi
    [ "$restore_marker" = 0 ] || tidy_marker_lock_release
  done <<EOF_QUARANTINES
$quarantine_pairs
EOF_QUARANTINES
  return "$restore_quarantine_status"
}

remove_quarantines() {
  [ -z "$quarantine_pairs" ] && return 0
  remove_quarantine_status=0
  while IFS="$TAB" read -r original_path quarantine_path quarantine_copy; do
    : "$original_path"
    # Quarantine renames are the logical deletion commit. Cleanup after this
    # point is best effort: a failed unlink leaves a recovery artifact and must
    # never trigger an impossible rollback after earlier sources were removed.
    if remove_owned_file "$quarantine_path"; then
      remove_owned_file "$quarantine_copy" || remove_quarantine_status=1
    else
      # Keep the verified copy whenever the payload could not be removed; it may
      # be the only trustworthy bytes if the payload path was replaced.
      remember_retained_artifact "$quarantine_copy"
      remove_quarantine_status=1
    fi
  done <<EOF_QUARANTINES
$quarantine_pairs
EOF_QUARANTINES
  return "$remove_quarantine_status"
}

restore_regular_from_backup() {
  restore_backup=$1
  restore_target=$2
  restore_tmp=$(mktemp "$restore_target.rollback.XXXXXX" 2>/dev/null) || return 1
  if { [ -e "$restore_target" ] || [ -L "$restore_target" ]; } &&
     { [ -L "$restore_target" ] || [ ! -f "$restore_target" ]; }; then
    rm -f "$restore_tmp" 2>/dev/null || true
    return 1
  fi
  if ! cat "$restore_backup" > "$restore_tmp" ||
     ! cmp -s "$restore_backup" "$restore_tmp" ||
     ! mv -f "$restore_tmp" "$restore_target" ||
     [ -L "$restore_target" ] || [ ! -f "$restore_target" ] ||
     ! cmp -s "$restore_backup" "$restore_target"; then
    rm -f "$restore_tmp" 2>/dev/null || true
    return 1
  fi
}

rollback_and_fail() {
  rollback_reason=$1
  # A second catchable signal cannot interrupt restoration or lock release.
  trap '' INT TERM HUP
  rollback_ok=1
  restore_inflight_quarantine || rollback_ok=0
  tidy_marker_lock_release || rollback_ok=0
  restore_quarantines || rollback_ok=0

  if [ "$ledger_published" = 1 ]; then
    if [ -f "$FOCUS_LEDGER" ] && [ ! -L "$FOCUS_LEDGER" ] &&
       [ -n "$ledger_expected" ] && cmp -s "$FOCUS_LEDGER" "$ledger_expected"; then
      restore_regular_from_backup "$ledger_backup" "$FOCUS_LEDGER" || rollback_ok=0
    elif [ -f "$FOCUS_LEDGER" ] && [ ! -L "$FOCUS_LEDGER" ] &&
         cmp -s "$FOCUS_LEDGER" "$ledger_backup"; then
      :
    else
      rollback_ok=0
    fi
  elif [ "$ledger_published" = maybe ]; then
    if [ -f "$FOCUS_LEDGER" ] && [ ! -L "$FOCUS_LEDGER" ] &&
       [ -n "$ledger_expected" ] && cmp -s "$FOCUS_LEDGER" "$ledger_expected"; then
      restore_regular_from_backup "$ledger_backup" "$FOCUS_LEDGER" || rollback_ok=0
    elif [ -f "$FOCUS_LEDGER" ] && [ ! -L "$FOCUS_LEDGER" ] &&
         cmp -s "$FOCUS_LEDGER" "$ledger_backup"; then
      :
    else
      # Unknown bytes belong to a non-cooperative writer; never overwrite them.
      rollback_ok=0
    fi
  fi

  if [ "$archive_published" != 0 ]; then
    if [ "$archive_existed" = 1 ]; then
      if [ -f "$ARCHIVE" ] && [ ! -L "$ARCHIVE" ] &&
         [ -n "$archive_expected" ] && cmp -s "$ARCHIVE" "$archive_expected"; then
        restore_regular_from_backup "$archive_backup" "$ARCHIVE" || rollback_ok=0
      elif [ -f "$ARCHIVE" ] && [ ! -L "$ARCHIVE" ] && cmp -s "$ARCHIVE" "$archive_backup"; then
        :
      else
        rollback_ok=0
      fi
    elif [ ! -e "$ARCHIVE" ] && [ ! -L "$ARCHIVE" ]; then
      [ "$archive_published" = maybe ] || rollback_ok=0
    elif [ -f "$ARCHIVE" ] && [ ! -L "$ARCHIVE" ] &&
         [ -n "$archive_expected" ] && cmp -s "$ARCHIVE" "$archive_expected"; then
      remove_owned_file "$ARCHIVE" || rollback_ok=0
    else
      rollback_ok=0
    fi
  fi

  cleanup_work_files || rollback_ok=0
  release_all || rollback_ok=0

  if [ "$rollback_ok" = 1 ]; then
    [ -z "$archive_backup" ] || remove_owned_file "$archive_backup" || rollback_ok=0
    if [ "$ledger_published" = 0 ] && [ "$ledger_backup_owned" = 1 ]; then
      remove_owned_file "$ledger_backup" || rollback_ok=0
      [ "$rollback_ok" = 0 ] || ledger_backup_owned=0
    fi
  fi

  if [ "$rollback_ok" != 1 ]; then
    remember_retained_artifact "$ledger_backup"
    remember_retained_artifact "$archive_backup"
    remember_retained_artifact "$inflight_quarantine"
    remember_retained_artifact "$inflight_copy"
    if [ -n "$quarantine_pairs" ]; then
      while IFS="$TAB" read -r recovery_original recovery_quarantine recovery_copy; do
        : "$recovery_original"
        remember_retained_artifact "$recovery_quarantine"
        remember_retained_artifact "$recovery_copy"
      done <<EOF_RECOVERY
$quarantine_pairs
EOF_RECOVERY
    fi
  fi

  if [ "$rollback_ok" = 1 ]; then
    if [ "$ledger_published" = 0 ] && [ "$archive_published" = 0 ]; then
      printf 'focus-tidy: apply failed (%s); cleanup targets restored; no ledger or archive publication occurred\n' "$rollback_reason" >&2
    else
      printf 'focus-tidy: apply failed (%s); ledger and archive restored from backups; markers and temps left unchanged\n' "$rollback_reason" >&2
    fi
  else
    printf 'focus-tidy: apply failed (%s); rollback or artifact cleanup was incomplete; surviving recovery paths follow\n' "$rollback_reason" >&2
    report_retained_artifacts
  fi
  exit 2
}

quarantine_marker_if_expired() {
  marker_target=$1
  if ! tidy_marker_lock_acquire "$marker_target"; then return 1; fi
  marker_recheck=$(focus_marker_status "$marker_target" "$now_epoch")
  marker_recheck_state=${marker_recheck%%"$TAB"*}
  if [ "$marker_recheck_state" = expired ]; then
    marker_quarantine="$marker_target.tidy-delete.$$"
    if [ -e "$marker_quarantine" ] || [ -L "$marker_quarantine" ] ||
       [ -L "$marker_target" ] || [ ! -f "$marker_target" ]; then
      tidy_marker_lock_release
      return 1
    fi
    inflight_original=$marker_target
    inflight_quarantine=$marker_quarantine
    inflight_copy="$marker_quarantine.restore"
    if ! mv "$marker_target" "$marker_quarantine" ||
       ! append_quarantine_pair "$marker_target" "$marker_quarantine"; then
      restore_inflight_quarantine || :
      tidy_marker_lock_release
      return 1
    fi
    inflight_original=
    inflight_quarantine=
    inflight_copy=
    tidy_marker_lock_release || return 1
    return 0
  fi
  case $marker_recheck_state in
    missing|active) tidy_marker_lock_release || return 1; return 0 ;;
    *) tidy_marker_lock_release || true; return 1 ;;
  esac
}

quarantine_temp_if_stale() {
  temp_target=$1
  if [ ! -e "$temp_target" ] && [ ! -L "$temp_target" ]; then return 0; fi
  focus_is_tidy_temp_path "$temp_target" || return 1
  if [ -L "$temp_target" ] || [ ! -f "$temp_target" ]; then return 1; fi
  temp_recheck_mtime=$(focus_file_mtime_epoch "$temp_target") || return 1
  [ "$temp_recheck_mtime" -le $((now_epoch - TEMP_STALE_SECONDS)) ] 2>/dev/null || return 0
  temp_quarantine="$temp_target.tidy-delete.$$"
  [ ! -e "$temp_quarantine" ] && [ ! -L "$temp_quarantine" ] || return 1
  inflight_original=$temp_target
  inflight_quarantine=$temp_quarantine
  inflight_copy="$temp_quarantine.restore"
  if ! mv "$temp_target" "$temp_quarantine" ||
     ! append_quarantine_pair "$temp_target" "$temp_quarantine"; then
    restore_inflight_quarantine || :
    return 1
  fi
  inflight_original=
  inflight_quarantine=
  inflight_copy=
}

tidy_test_rollback_after_quarantine() {
  if [ "${FOCUS_TIDY_TEST_FAIL:-}" = rollback-after-first-quarantine ] &&
     [ "$quarantine_count" -gt 0 ]; then
    rollback_and_fail 'test-only rollback after first quarantine'
  fi
}

capture_sorted_records() {
  capture_kind=$1
  capture_source=$2
  capture_output=$3
  raw_capture=$(mktemp "$FOCUS_LEDGER.verify-raw.XXXXXX" 2>/dev/null) || return 1
  case $capture_kind in
    open) focus_raw_open_lines "$capture_source" > "$raw_capture" || return 1 ;;
    near) focus_raw_near_lines "$capture_source" > "$raw_capture" || return 1 ;;
    retained) focus_raw_retained_lines "$capture_source" "$today_days" "$archive_days" > "$raw_capture" || return 1 ;;
    all) cat "$capture_source" > "$raw_capture" || return 1 ;;
    *) return 1 ;;
  esac
  if ! sort "$raw_capture" > "$capture_output"; then return 1; fi
  rm -f "$raw_capture" 2>/dev/null || return 1
  raw_capture=
}

# Missing and empty ledgers are explicit no-op states. Do not even create a lock.
# Test symlink identity first because a dangling symlink makes `test -e` false.
if [ -L "$FOCUS_LEDGER" ]; then
  printf 'focus-tidy: refusing unsafe or unreadable ledger %s\n' "$FOCUS_LEDGER" >&2
  exit 2
fi
if [ ! -e "$FOCUS_LEDGER" ]; then
  if [ "$mode" = report ]; then
    report_records=
    count_records
    print_report
  else
    emit APPLY no-op "$FOCUS_LEDGER" - 'no mutation performed' \
      'ledger is missing; no backup or other file was created'
  fi
  exit 0
fi
if [ -L "$FOCUS_LEDGER" ] || [ ! -f "$FOCUS_LEDGER" ] || [ ! -r "$FOCUS_LEDGER" ]; then
  printf 'focus-tidy: refusing unsafe or unreadable ledger %s\n' "$FOCUS_LEDGER" >&2
  exit 2
fi
if [ ! -s "$FOCUS_LEDGER" ]; then
  if [ "$mode" = report ]; then
    report_records=
    count_records
    print_report
  else
    emit APPLY no-op "$FOCUS_LEDGER" - 'no mutation performed' \
      'ledger is empty; no backup or other file was created'
  fi
  exit 0
fi

if [ "$mode" = report ]; then
  classify_current || {
    printf 'focus-tidy: classification failed operationally\n' >&2
    exit 2
  }
  print_report
  exit 0
fi

# Apply always serializes first and then derives from the protected current state.
# Unlike ordinary mutators, tidy never reaps someone else's stale lock artifacts.
if ! tidy_ledger_lock_acquire; then
  focus_lock_release
  printf 'focus-tidy: could not acquire ledger lock without reaping an existing owner\n' >&2
  exit 2
fi
if ! tidy_write_gate_acquire; then
  focus_lock_release
  printf 'focus-tidy: could not acquire ledger publication gate without reaping it\n' >&2
  exit 2
fi
if ! classify_current; then
  fail_locked 'classification failed operationally'
fi
action_total=$((archive_count + promote_count + rehome_count + remove_count))
if [ "$block_count" -gt 0 ]; then
  fail_locked 'unsafe paths or ledger structure block apply; run report and doctor'
fi
if [ "$action_total" -eq 0 ]; then
  if ! release_all; then
    report_retained_artifacts
    emit APPLY verified-with-artifacts "$FOCUS_LEDGER" - 'no mutation performed' \
      'fresh derivation found no actions, but owned lock cleanup was incomplete'
    exit 2
  fi
  emit APPLY no-op "$FOCUS_LEDGER" - 'no mutation performed' \
    'fresh in-lock derivation found no actions; no backup was created'
  exit 0
fi

# From this point forward, a signal must unwind every lock and any published
# transaction state rather than using focus-lib's generic single-lock trap.
trap 'rollback_and_fail "interrupted by signal"' INT TERM HUP

if [ "$archive_count" -gt 0 ]; then
  if ! tidy_archive_lock_acquire; then
    fail_locked "could not acquire archive lock without reaping $archive_lock"
  fi
  if [ -L "$ARCHIVE" ] || { [ -e "$ARCHIVE" ] && [ ! -f "$ARCHIVE" ]; }; then
    fail_locked "refusing unsafe archive path $ARCHIVE"
  fi
  if [ -e "$ARCHIVE" ] && [ ! -r "$ARCHIVE" ]; then
    fail_locked "refusing unreadable archive path $ARCHIVE"
  fi
  if [ -e "$ARCHIVE" ]; then
    archive_pre_cksum=$(cksum < "$ARCHIVE") || fail_locked 'could not snapshot archive identity'
  else
    archive_pre_cksum=missing
  fi
fi

ledger_change_count=$((archive_count + promote_count + rehome_count))
if [ "$ledger_change_count" -gt 0 ]; then
  timestamp=$(date '+%Y%m%dT%H%M%S' 2>/dev/null) || fail_locked 'could not create backup timestamp'
  ledger_backup=$(mktemp "$FOCUS_LEDGER.backup.$timestamp.XXXXXX" 2>/dev/null) ||
    fail_locked 'could not create same-directory ledger backup'
  if [ -L "$ledger_backup" ] || [ ! -f "$ledger_backup" ]; then
    fail_locked 'ledger backup path is not a safe regular file'
  fi
  ledger_backup_owned=1
  if ! cat "$FOCUS_LEDGER" > "$ledger_backup" ||
     ! cmp -s "$FOCUS_LEDGER" "$ledger_backup"; then
    fail_locked 'ledger backup verification failed'
  fi

  if [ "$archive_count" -gt 0 ] && [ -e "$ARCHIVE" ]; then
    archive_existed=1
    archive_backup=$(mktemp "$ARCHIVE.backup.$timestamp.XXXXXX" 2>/dev/null) ||
      fail_locked 'could not create same-directory archive backup'
    if [ -L "$archive_backup" ] || [ ! -f "$archive_backup" ] ||
       ! cat "$ARCHIVE" > "$archive_backup" ||
       ! cmp -s "$ARCHIVE" "$archive_backup"; then
      fail_locked 'archive backup verification failed'
    fi
  fi
fi

if [ "$ledger_change_count" -gt 0 ]; then
  focus_rewrite_begin || fail_locked 'could not create same-directory ledger stage'
  if ! focus_tidy_rewrite "$today_days" "$archive_days" > "$FOCUS_TMP" ||
     ! focus_rewrite_preserve_eof ||
     ! focus_rewrite_source_unchanged ||
     ! focus_structure_valid "$FOCUS_TMP"; then
    fail_locked 'guarded ledger rewrite validation failed'
  fi
  ledger_expected=$(mktemp "$FOCUS_LEDGER.verify.XXXXXX" 2>/dev/null) ||
    fail_locked 'could not create ledger verification snapshot'
  cat "$FOCUS_TMP" > "$ledger_expected" || fail_locked 'could not snapshot expected ledger'
fi

if [ "$ledger_change_count" -gt 0 ]; then
  pre_open=$(mktemp "$FOCUS_LEDGER.verify-open.XXXXXX" 2>/dev/null) || fail_locked 'could not create open-line verification file'
  pre_near=$(mktemp "$FOCUS_LEDGER.verify-near.XXXXXX" 2>/dev/null) || fail_locked 'could not create near-miss verification file'
  pre_retained=$(mktemp "$FOCUS_LEDGER.verify-retained.XXXXXX" 2>/dev/null) || fail_locked 'could not create retained-record verification file'
  capture_sorted_records open "$FOCUS_LEDGER" "$pre_open" || fail_locked 'could not capture open-line multiset'
  capture_sorted_records near "$FOCUS_LEDGER" "$pre_near" || fail_locked 'could not capture near-miss multiset'
  capture_sorted_records retained "$FOCUS_LEDGER" "$pre_retained" || fail_locked 'could not capture retained-record multiset'
fi

if [ "$archive_count" -gt 0 ]; then
  archive_lines=$(mktemp "$FOCUS_LEDGER.archive-lines.XXXXXX" 2>/dev/null) ||
    fail_locked 'could not create archived-line verification file'
  focus_tidy_archive_lines "$today_days" "$archive_days" > "$archive_lines" ||
    fail_locked 'could not derive archive lines'
  [ "$(wc -l < "$archive_lines")" -eq "$archive_count" ] ||
    fail_locked 'archive candidate count changed during staging'
  archive_stage=$(mktemp "$ARCHIVE.tmp.XXXXXX" 2>/dev/null) ||
    fail_locked 'could not create same-directory archive stage'
  (
    if [ "$archive_existed" = 1 ] && [ -s "$archive_backup" ]; then
      cat "$archive_backup" || exit 1
      archive_last_byte=$(tail -c 1 "$archive_backup") || exit 1
      if [ -n "$archive_last_byte" ]; then printf '\n'; fi
      printf '\n'
    else
      printf '# Focus ledger archive\n\n'
    fi
    printf '## Archived by focus-ledger tidy on %s (epoch %s)\n\n' "$calendar_today" "$now_epoch"
    cat "$archive_lines"
  ) > "$archive_stage" || fail_locked 'could not stage archive'
  archive_expected=$(mktemp "$ARCHIVE.verify.XXXXXX" 2>/dev/null) ||
    fail_locked 'could not create archive verification snapshot'
  cat "$archive_stage" > "$archive_expected" || fail_locked 'could not snapshot expected archive'
fi

# Once publication can begin, signals use the same two-file rollback path as
# explicit failures rather than the generic lock cleanup trap from focus-lib.
trap 'rollback_and_fail "interrupted by signal"' INT TERM HUP

if [ "$archive_count" -gt 0 ]; then
  if [ "$archive_pre_cksum" = missing ]; then
    if [ -e "$ARCHIVE" ] || [ -L "$ARCHIVE" ]; then
      rollback_and_fail 'archive appeared after staging'
    fi
  elif [ -L "$ARCHIVE" ] || [ ! -f "$ARCHIVE" ] ||
       [ "$(cksum < "$ARCHIVE" 2>/dev/null)" != "$archive_pre_cksum" ]; then
    rollback_and_fail 'archive changed after staging'
  fi
  archive_published=maybe
  if ! mv -f "$archive_stage" "$ARCHIVE"; then
    rollback_and_fail 'archive atomic publish failed'
  fi
  archive_stage=
  archive_published=1
fi

if [ "$ledger_change_count" -gt 0 ]; then
  if ! focus_rewrite_source_unchanged; then
    # Publication was never attempted. Keep the concurrent ledger bytes and
    # restore only any archive version owned by this transaction.
    ledger_published=0
    rollback_and_fail 'ledger changed before atomic publish'
  fi
  ledger_published=maybe
  if ! mv -f "$FOCUS_TMP" "$FOCUS_LEDGER"; then
    rollback_and_fail 'ledger atomic publish failed'
  fi
  FOCUS_TMP=
  ledger_published=1
fi

# Test-only rollback seam. It exercises the real owned-publication rollback
# path without corrupting or otherwise mutating unowned live bytes. Cleanup-only
# applies have no owned ledger/archive publication and deliberately ignore it.
if [ "${FOCUS_TIDY_TEST_FAIL:-}" = rollback-after-publish ] &&
   { [ "$ledger_published" != 0 ] || [ "$archive_published" != 0 ]; }; then
  rollback_and_fail 'test-only rollback after owned publication'
fi

if [ "$ledger_change_count" -gt 0 ]; then
  post_open=$(mktemp "$FOCUS_LEDGER.verify-open-post.XXXXXX" 2>/dev/null) ||
    rollback_and_fail 'could not create post-verify open-line file'
  post_near=$(mktemp "$FOCUS_LEDGER.verify-near-post.XXXXXX" 2>/dev/null) ||
    rollback_and_fail 'could not create post-verify near-miss file'
  post_all=$(mktemp "$FOCUS_LEDGER.verify-all-post.XXXXXX" 2>/dev/null) ||
    rollback_and_fail 'could not create post-verify retained-record file'
  capture_sorted_records open "$FOCUS_LEDGER" "$post_open" ||
    rollback_and_fail 'could not read post-state open lines'
  capture_sorted_records near "$FOCUS_LEDGER" "$post_near" ||
    rollback_and_fail 'could not read post-state near-miss lines'
  capture_sorted_records all "$FOCUS_LEDGER" "$post_all" ||
    rollback_and_fail 'could not read post-state retained records'

  if ! focus_structure_valid "$FOCUS_LEDGER" ||
     ! focus_tidy_sections_valid "$FOCUS_LEDGER" ||
     ! cmp -s "$pre_open" "$post_open" ||
     ! cmp -s "$pre_near" "$post_near" ||
     ! cmp -s "$pre_retained" "$post_all"; then
    rollback_and_fail 'post-verify heading, section/action, or raw-record multiset invariant failed'
  fi
  if ! cmp -s "$FOCUS_LEDGER" "$ledger_expected"; then
    rollback_and_fail 'post-verify untouched-ledger bytes differ from the staged result'
  fi
fi
if [ "$archive_count" -gt 0 ] && ! cmp -s "$ARCHIVE" "$archive_expected"; then
  rollback_and_fail 'post-verify archive multiplicity differs from the staged result'
fi

# Volatile cleanup begins only after both published files and every invariant
# verify. Targets are first renamed to same-directory quarantine names; if any
# rename fails, all prior targets can be restored before core rollback.
if [ "$remove_snooze" = 1 ]; then
  quarantine_marker_if_expired "$SNOOZE" ||
    rollback_and_fail 'snooze cleanup could not be quarantined safely'
  tidy_test_rollback_after_quarantine
fi
if [ "$remove_last_nudge" = 1 ]; then
  quarantine_marker_if_expired "$LAST_NUDGE" ||
    rollback_and_fail 'last-nudge cleanup could not be quarantined safely'
  tidy_test_rollback_after_quarantine
fi
if [ -n "$remove_temp_paths" ]; then
  while IFS= read -r cleanup_target; do
    if [ -n "$cleanup_target" ]; then
      quarantine_temp_if_stale "$cleanup_target" ||
        rollback_and_fail 'temp cleanup could not be quarantined safely'
      tidy_test_rollback_after_quarantine
    fi
  done <<EOF_TEMPS
$remove_temp_paths
EOF_TEMPS
fi
# Quarantine renames are now the logical deletion commit. From here onward,
# catchable signals are deferred until owned locks are released. Unlink failures
# retain truthful recovery artifacts and never attempt an impossible rollback.
trap '' INT TERM HUP
finalize_status=0
remove_quarantines || finalize_status=1
cleanup_work_files || finalize_status=1
[ -z "$archive_backup" ] || remove_owned_file "$archive_backup" || finalize_status=1
release_all || finalize_status=1
trap - INT TERM HUP

if [ -n "$ledger_backup" ]; then
  verification_detail="post-verify passed with exact open/near-miss/retained-record multisets and section/action placement; recovery backup=$ledger_backup"
else
  verification_detail='post-verify passed; ledger bytes and mtime were not mutated and no recovery backup was created'
fi
if [ "$finalize_status" != 0 ]; then
  report_retained_artifacts
  emit APPLY verified-with-artifacts "$FOCUS_LEDGER" - \
    "archive=$archive_count;promote=$promote_count;rehome=$rehome_count;remove=$quarantine_count" \
    "$verification_detail; automatic artifact cleanup was incomplete"
  exit 2
fi
emit APPLY verified "$FOCUS_LEDGER" - \
  "archive=$archive_count;promote=$promote_count;rehome=$rehome_count;remove=$quarantine_count" \
  "$verification_detail"
exit 0
