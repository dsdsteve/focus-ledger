#!/usr/bin/env bash
# focus-ledger test suite — dependency-free (no bats/shellcheck needed to run).
# Exercises the three hooks + the park script against fixture ledgers, asserting on
# exit code, clean stderr, and expected output. Runs each case under a chosen shell
# so the bash/dash (Linux /bin/sh) axis is covered.
#
# Usage:  test/run.sh [bash|dash|sh]   (default: bash, then dash if present)
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
FIX="$HERE/fixtures"
TODAY=$(date +%F)   # fixtures use @TODAY@ so "fresh" items never rot into stale
pass=0; fail=0

# Each case runs in an isolated fake HOME with a chosen ledger fixture (or none).
# assert <shell> <name> <fixture-or-EMPTY> <expect-rc> <expect-stderr-empty:1/0> \
#        <hook-relpath> <must-contain> <must-not-contain> [env assignments...]
run_case() {
  sh_bin=$1; name=$2; fixture=$3; exp_rc=$4; exp_clean=$5; hook=$6; want=$7; notwant=$8; shift 8
  home=$(mktemp -d)
  mkdir -p "$home/.claude"
  [ "$fixture" = EMPTY ] || sed "s/@TODAY@/$TODAY/" "$FIX/$fixture" > "$home/.claude/focus-ledger.md"
  out=$(env -i HOME="$home" PATH="$PATH" "$@" "$sh_bin" "$ROOT/$hook" 2>"$home/err"); rc=$?
  err=$(cat "$home/err")
  ok=1; why=""
  [ "$rc" = "$exp_rc" ] || { ok=0; why="rc=$rc want $exp_rc"; }
  if [ "$exp_clean" = 1 ] && [ -n "$err" ]; then ok=0; why="$why; stderr:[$err]"; fi
  if [ -n "$want" ] && ! printf '%s' "$out" | grep -qF "$want"; then ok=0; why="$why; missing '$want'"; fi
  if [ -n "$notwant" ] && printf '%s' "$out" | grep -qF "$notwant"; then ok=0; why="$why; had forbidden '$notwant'"; fi
  if [ "$ok" = 1 ]; then pass=$((pass+1)); printf '  ok   [%s] %s\n' "$sh_bin" "$name"
  else fail=$((fail+1)); printf '  FAIL [%s] %s -- %s\n' "$sh_bin" "$name" "$why"; fi
  rm -rf "$home"
}

run_suite() {
  sh_bin=$1
  command -v "$sh_bin" >/dev/null 2>&1 || { echo "  (skip: $sh_bin not present)"; return; }
  echo "== shell: $sh_bin =="

  # SessionStart: silent on no ledger / empty; frames + lists on populated.
  run_case "$sh_bin" "session-start: no ledger -> silent, rc0"      EMPTY        0 1 hooks/focus-session-start.sh "" ""
  run_case "$sh_bin" "session-start: empty ledger -> silent, rc0"   empty.md     0 1 hooks/focus-session-start.sh "" ""
  run_case "$sh_bin" "session-start: populated -> frames untrusted" populated.md 0 1 hooks/focus-session-start.sh "untrusted" ""
  run_case "$sh_bin" "session-start: populated -> lists the item"   populated.md 0 1 hooks/focus-session-start.sh "recent parked item" ""
  run_case "$sh_bin" "session-start: <!-- --> examples skipped"     commented.md 0 1 hooks/focus-session-start.sh "real fresh item" "commented example"

  # Stop: silent when nothing stale; flags stale; skips malformed/undated; off-switch.
  run_case "$sh_bin" "stop: no ledger -> silent, rc0"               EMPTY        0 1 hooks/focus-stop.sh "" ""
  run_case "$sh_bin" "stop: fresh only -> silent"                   populated.md 0 1 hooks/focus-stop.sh "" "recent parked item"
  run_case "$sh_bin" "stop: stale -> flags old item"                stale.md     0 1 hooks/focus-stop.sh "very old item" ""
  run_case "$sh_bin" "stop: two stale -> '; ' separated"            stale.md     0 1 hooks/focus-stop.sh "very old item; second old item" ""
  run_case "$sh_bin" "stop: <!-- --> stale example -> silent"       commented.md 0 1 hooks/focus-stop.sh "" "commented example"
  run_case "$sh_bin" "stop: future date -> not flagged"             stale.md     0 1 hooks/focus-stop.sh "" "far future item"
  run_case "$sh_bin" "stop: malformed date -> skipped, silent"      malformed.md 0 1 hooks/focus-stop.sh "" "impossible date"
  run_case "$sh_bin" "stop: FOCUS_STOP_NUDGE=off -> silent"         stale.md     0 1 hooks/focus-stop.sh "" "very old item" FOCUS_STOP_NUDGE=off

  # PreToolUse: soft nudge by default; off-switch; strict adds a decision.
  run_case "$sh_bin" "pretooluse: default -> soft nudge"            EMPTY        0 1 hooks/focus-pretooluse.sh "systemMessage" ""
  run_case "$sh_bin" "pretooluse: off -> silent"                    EMPTY        0 1 hooks/focus-pretooluse.sh "" "systemMessage" FOCUS_WRITE_CHECK=off
  run_case "$sh_bin" "pretooluse: strict -> permissionDecision"     EMPTY        0 1 hooks/focus-pretooluse.sh "permissionDecision" "" FOCUS_WRITE_CHECK=strict
}

# --- security: the stop hook must NOT execute text embedded in the ledger ---
run_injection_check() {
  sh_bin=$1
  command -v "$sh_bin" >/dev/null 2>&1 || return
  home=$(mktemp -d); mkdir -p "$home/.claude"
  cp "$FIX/injection.md" "$home/.claude/focus-ledger.md"
  canary="$home/focus_pwned"
  # point the payload's target into the sandbox by editing the fixture copy in place
  sed "s#/tmp/focus_pwned#$canary#" "$FIX/injection.md" > "$home/.claude/focus-ledger.md"
  env -i HOME="$home" PATH="$PATH" "$sh_bin" "$ROOT/hooks/focus-stop.sh" >/dev/null 2>&1
  if [ -e "$canary" ]; then fail=$((fail+1)); printf '  FAIL [%s] SECURITY: ledger text executed (canary created)\n' "$sh_bin"
  else pass=$((pass+1)); printf '  ok   [%s] security: ledger text not executed\n' "$sh_bin"; fi
  rm -rf "$home"
}

# --- park: deterministic append, existing items preserved ---
run_park_check() {
  sh_bin=$1
  command -v "$sh_bin" >/dev/null 2>&1 || return
  home=$(mktemp -d); mkdir -p "$home/.claude"
  cp "$FIX/populated.md" "$home/.claude/focus-ledger.md"
  out=$(env -i HOME="$home" PATH="$PATH" "$sh_bin" "$ROOT/scripts/focus-park.sh" "newly parked" 2>/dev/null); rc=$?
  led=$(cat "$home/.claude/focus-ledger.md")
  # Durability contract (story 1.2): rc 0 must coincide with stdout being exactly
  # the item text AND the exact `- [ ] (date) text` line present. The date is
  # matched structurally so a midnight rollover between suite start and this park
  # cannot flake the test.
  if [ "$rc" = 0 ] && [ "$out" = "newly parked" ] && printf '%s' "$led" | grep -qF "recent parked item" \
     && grep -q '^- \[ \] ([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}) newly parked$' "$home/.claude/focus-ledger.md"; then
    pass=$((pass+1)); printf '  ok   [%s] park: appends and preserves existing item\n' "$sh_bin"
  else fail=$((fail+1)); printf '  FAIL [%s] park: lost an item (rc=%s)\n' "$sh_bin" "$rc"; fi

  # Backslashes in item text stay literal on one line (awk -v would eat \n).
  env -i HOME="$home" PATH="$PATH" "$sh_bin" "$ROOT/scripts/focus-park.sh" 'fix the \n handling' >/dev/null 2>&1; rc=$?
  if [ "$rc" = 0 ] && grep -qF 'fix the \n handling' "$home/.claude/focus-ledger.md"; then
    pass=$((pass+1)); printf '  ok   [%s] park: backslash item stays literal, one line\n' "$sh_bin"
  else fail=$((fail+1)); printf '  FAIL [%s] park: backslash item mangled\n' "$sh_bin"; fi

  # A stale lock left by a dead park must be reaped, not waited on forever.
  mkdir "$home/.claude/focus-ledger.md.lock"
  env -i HOME="$home" PATH="$PATH" "$sh_bin" "$ROOT/scripts/focus-park.sh" "after stale lock" >/dev/null 2>&1
  if grep -qF "after stale lock" "$home/.claude/focus-ledger.md" && [ ! -d "$home/.claude/focus-ledger.md.lock" ]; then
    pass=$((pass+1)); printf '  ok   [%s] park: reaps stale lock and proceeds\n' "$sh_bin"
  else fail=$((fail+1)); printf '  FAIL [%s] park: stale lock not reaped\n' "$sh_bin"; fi

  # Regression (story 1.1): a lock held past every wait window while two parks race.
  # Both time out together, reap, and must serialize — afterwards both new items AND
  # the pre-existing one are present, both parks exit 0, at least one raced item sits
  # INSIDE the Parked section (proving reap + re-acquire + rewrite actually ran, not
  # just the append fallback), and nothing is left behind: no lock, no reap token, no
  # mktemp litter (anything focus-ledger.md.*).
  # Timing is coupled to the script's wait windows (20+10 tries at 0.1s ≈ 2s+1s):
  # the holder's 3s must outlast the primary window; retune them together.
  lockdir="$home/.claude/focus-ledger.md.lock"
  mkdir "$lockdir"
  ( sleep 3; rmdir "$lockdir" 2>/dev/null ) &
  holder=$!
  env -i HOME="$home" PATH="$PATH" "$sh_bin" "$ROOT/scripts/focus-park.sh" "race item alpha" >/dev/null 2>&1 &
  ra=$!
  env -i HOME="$home" PATH="$PATH" "$sh_bin" "$ROOT/scripts/focus-park.sh" "race item bravo" >/dev/null 2>&1 &
  rb=$!
  wait "$ra"; rca=$?
  wait "$rb"; rcb=$?
  wait "$holder"
  led=$(cat "$home/.claude/focus-ledger.md")
  ok=1; why=""
  for want in "race item alpha" "race item bravo" "recent parked item"; do
    printf '%s' "$led" | grep -qF "$want" || { ok=0; why="$why; missing '$want'"; }
  done
  [ "$rca" = 0 ] || { ok=0; why="$why; alpha rc=$rca"; }
  [ "$rcb" = 0 ] || { ok=0; why="$why; bravo rc=$rcb"; }
  if ! awk '/^## This session/{exit} /race item (alpha|bravo)/{found=1} END{exit !found}' "$home/.claude/focus-ledger.md"; then
    ok=0; why="$why; no raced item inside Parked"
  fi
  set -- "$home/.claude/focus-ledger.md."*
  if [ -e "$1" ]; then ok=0; why="$why; leftover: $*"; fi
  if [ "$ok" = 1 ]; then pass=$((pass+1)); printf '  ok   [%s] park: race on held lock keeps every item, no litter\n' "$sh_bin"
  else fail=$((fail+1)); printf '  FAIL [%s] park: race on held lock -- %s\n' "$sh_bin" "$why"; fi

  # Matrix: brief live contention -> acquires within the primary window, normal
  # insert into the Parked section (not the EOF-append fallback).
  mkdir "$home/.claude/focus-ledger.md.lock"
  ( sleep 0.4; rmdir "$home/.claude/focus-ledger.md.lock" 2>/dev/null ) &
  bh=$!
  env -i HOME="$home" PATH="$PATH" "$sh_bin" "$ROOT/scripts/focus-park.sh" "brief contention item" >/dev/null 2>&1
  wait "$bh"
  if awk '/^## This session/{exit} /brief contention item/{found=1} END{exit !found}' "$home/.claude/focus-ledger.md"; then
    pass=$((pass+1)); printf '  ok   [%s] park: brief contention -> primary-window acquire, normal insert\n' "$sh_bin"
  else fail=$((fail+1)); printf '  FAIL [%s] park: brief contention item missing from Parked section\n' "$sh_bin"; fi

  # Matrix: lock unacquirable for the entire window (reap token held too, so the
  # reap is skipped) -> degrade to the atomic EOF append; rc 0; stdout intact.
  mkdir "$home/.claude/focus-ledger.md.lock" "$home/.claude/focus-ledger.md.lock.reap"
  out=$(env -i HOME="$home" PATH="$PATH" "$sh_bin" "$ROOT/scripts/focus-park.sh" "unacquirable window item" 2>/dev/null); rc=$?
  last=$(tail -1 "$home/.claude/focus-ledger.md")
  rmdir "$home/.claude/focus-ledger.md.lock" "$home/.claude/focus-ledger.md.lock.reap"
  case $last in *"unacquirable window item") lastok=1 ;; *) lastok=0 ;; esac
  if [ "$rc" = 0 ] && [ "$out" = "unacquirable window item" ] && [ "$lastok" = 1 ]; then
    pass=$((pass+1)); printf '  ok   [%s] park: unacquirable lock -> EOF append, rc 0\n' "$sh_bin"
  else fail=$((fail+1)); printf '  FAIL [%s] park: unacquirable lock (rc=%s, last=[%s])\n' "$sh_bin" "$rc" "$last"; fi

  # Matrix: empty argument -> rc 2, "nothing to park" on stderr, ledger untouched.
  before=$(cat "$home/.claude/focus-ledger.md")
  env -i HOME="$home" PATH="$PATH" "$sh_bin" "$ROOT/scripts/focus-park.sh" "" >/dev/null 2>"$home/err2"; rc=$?
  after=$(cat "$home/.claude/focus-ledger.md")
  if [ "$rc" = 2 ] && grep -q "nothing to park" "$home/err2" && [ "$before" = "$after" ]; then
    pass=$((pass+1)); printf '  ok   [%s] park: empty argument -> rc 2, ledger untouched\n' "$sh_bin"
  else fail=$((fail+1)); printf '  FAIL [%s] park: empty argument (rc=%s)\n' "$sh_bin" "$rc"; fi

  # Rewrite-failure fallback: awk dying mid-rewrite must degrade to the append —
  # item kept, rc 0, stdout intact, no temp litter. (Stub awk shadows the real
  # one through PATH; every other tool the script uses stays real.)
  stub=$(mktemp -d)
  printf '#!/bin/sh\nexit 1\n' > "$stub/awk"; chmod +x "$stub/awk"
  out=$(env -i HOME="$home" PATH="$stub:$PATH" "$sh_bin" "$ROOT/scripts/focus-park.sh" "awk failed item" 2>/dev/null); rc=$?
  set -- "$home/.claude/focus-ledger.md."*
  if [ "$rc" = 0 ] && [ "$out" = "awk failed item" ] && grep -qF "awk failed item" "$home/.claude/focus-ledger.md" && [ ! -e "$1" ]; then
    pass=$((pass+1)); printf '  ok   [%s] park: awk failure -> append fallback, no litter\n' "$sh_bin"
  else fail=$((fail+1)); printf '  FAIL [%s] park: awk failure fallback (rc=%s)\n' "$sh_bin" "$rc"; fi

  # Truncation guard: an awk that exits 0 but writes nothing (short-write/ENOSPC
  # shape) must NOT have its empty temp installed over the ledger — existing items
  # survive and the new item degrades to the append.
  printf '#!/bin/sh\nexit 0\n' > "$stub/awk"
  env -i HOME="$home" PATH="$stub:$PATH" "$sh_bin" "$ROOT/scripts/focus-park.sh" "silent truncation item" >/dev/null 2>&1; rc=$?
  set -- "$home/.claude/focus-ledger.md."*
  if [ "$rc" = 0 ] && grep -qF "silent truncation item" "$home/.claude/focus-ledger.md" && grep -qF "recent parked item" "$home/.claude/focus-ledger.md" && [ ! -e "$1" ]; then
    pass=$((pass+1)); printf '  ok   [%s] park: truncated rewrite blocked, ledger preserved\n' "$sh_bin"
  else fail=$((fail+1)); printf '  FAIL [%s] park: truncation guard (rc=%s)\n' "$sh_bin" "$rc"; fi
  rm -rf "$stub"

  # Near-miss heading (trailing space): the substring grep gate passes but the
  # exact-match awk cannot insert — the park must detect the non-insert and
  # degrade to the append instead of installing a rewrite missing the item.
  printf '# Focus ledger\n\n## Parked (durable — carries across sessions) \n- [ ] (2026-01-01) preexisting near item\n\n## This session (volatile — clear whenever)\n' > "$home/.claude/focus-ledger.md"
  out=$(env -i HOME="$home" PATH="$PATH" "$sh_bin" "$ROOT/scripts/focus-park.sh" "near miss heading item" 2>/dev/null); rc=$?
  if [ "$rc" = 0 ] && grep -qF "near miss heading item" "$home/.claude/focus-ledger.md" && grep -qF "preexisting near item" "$home/.claude/focus-ledger.md"; then
    pass=$((pass+1)); printf '  ok   [%s] park: near-miss heading -> append, item never dropped\n' "$sh_bin"
  else fail=$((fail+1)); printf '  FAIL [%s] park: near-miss heading (rc=%s)\n' "$sh_bin" "$rc"; fi

  # Append onto a ledger with no final newline (hand-edit): the guard must restore
  # the newline so the old last line and the new item stay separate lines.
  printf '## Parked (durable — carries across sessions)\n- [ ] (2026-01-01) tail item' > "$home/.claude/focus-ledger.md"
  env -i HOME="$home" PATH="$PATH" "$sh_bin" "$ROOT/scripts/focus-park.sh" "newline guard item" >/dev/null 2>&1
  if grep -q '^- \[ \] (2026-01-01) tail item$' "$home/.claude/focus-ledger.md" && grep -q '^- \[ \] (....-..-..) newline guard item$' "$home/.claude/focus-ledger.md"; then
    pass=$((pass+1)); printf '  ok   [%s] park: no-final-newline ledger -> lines kept separate\n' "$sh_bin"
  else fail=$((fail+1)); printf '  FAIL [%s] park: no-final-newline append glued lines\n' "$sh_bin"; fi

  # First-ever park under an unacquirable lock must still create the section
  # skeleton, so later (unlocked) parks return to the structured insert instead
  # of degrading to plain appends forever.
  rm -f "$home/.claude/focus-ledger.md"
  mkdir "$home/.claude/focus-ledger.md.lock" "$home/.claude/focus-ledger.md.lock.reap"
  env -i HOME="$home" PATH="$PATH" "$sh_bin" "$ROOT/scripts/focus-park.sh" "skeleton first item" >/dev/null 2>&1
  rmdir "$home/.claude/focus-ledger.md.lock" "$home/.claude/focus-ledger.md.lock.reap"
  env -i HOME="$home" PATH="$PATH" "$sh_bin" "$ROOT/scripts/focus-park.sh" "structured second item" >/dev/null 2>&1
  ok=1
  grep -qF "## Parked" "$home/.claude/focus-ledger.md" || ok=0
  grep -qF "skeleton first item" "$home/.claude/focus-ledger.md" || ok=0
  awk '/^## This session/{exit} /structured second item/{found=1} END{exit !found}' "$home/.claude/focus-ledger.md" || ok=0
  if [ "$ok" = 1 ]; then
    pass=$((pass+1)); printf '  ok   [%s] park: lockless first park writes skeleton, next park structured\n' "$sh_bin"
  else fail=$((fail+1)); printf '  FAIL [%s] park: lockless first park left ledger headingless\n' "$sh_bin"; fi

  # Failure path (story 1.2): an unwritable ~/.claude means nothing can land, so the
  # park must exit non-zero with NO success text on stdout and an error on stderr
  # (the pre-1.2 failure mode exited 0 after losing the item). Fresh sandbox HOME so
  # the read-only dir can't leak into other cases; permissions restored before
  # cleanup so rm -rf works. (~3s: the lock retry windows all fail on EACCES first.)
  if [ "$(id -u)" = 0 ]; then
    printf '  (skip [%s] park: unwritable-dir case needs non-root — chmod cannot stop uid 0)\n' "$sh_bin"
  else
    home2=$(mktemp -d); mkdir -p "$home2/.claude"
    chmod 500 "$home2/.claude"
    out=$(env -i HOME="$home2" PATH="$PATH" "$sh_bin" "$ROOT/scripts/focus-park.sh" "doomed item" 2>"$home2/err3"); rc=$?
    chmod 700 "$home2/.claude"
    if [ "$rc" != 0 ] && [ -z "$out" ] && grep -qi -e "denied" -e "focus-park" "$home2/err3"; then
      pass=$((pass+1)); printf '  ok   [%s] park: unwritable dir -> non-zero rc, no success output\n' "$sh_bin"
    else fail=$((fail+1)); printf '  FAIL [%s] park: unwritable dir (rc=%s, out=[%s])\n' "$sh_bin" "$rc" "$out"; fi
    rm -rf "$home2"
  fi

  # Durability gate failure arm (story 1.2): when the post-write verification cannot
  # confirm the item (grep stubbed to always fail — deliberately intercepting EVERY
  # grep call site, which also routes the write to the append path), the park must
  # withhold the success claim: empty stdout, error on stderr, non-zero rc — while
  # the exact item line is still safely in the file.
  stub3=$(mktemp -d)
  printf '#!/bin/sh\nexit 1\n' > "$stub3/grep"; chmod +x "$stub3/grep"
  out=$(env -i HOME="$home" PATH="$stub3:$PATH" "$sh_bin" "$ROOT/scripts/focus-park.sh" "unverifiable item" 2>"$home/err4"); rc=$?
  if [ "$rc" != 0 ] && [ -z "$out" ] && grep -q "verification failed" "$home/err4" \
     && grep -q '^- \[ \] ([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}) unverifiable item$' "$home/.claude/focus-ledger.md"; then
    pass=$((pass+1)); printf '  ok   [%s] park: failed verification -> no success claim, item kept\n' "$sh_bin"
  else fail=$((fail+1)); printf '  FAIL [%s] park: failed verification arm (rc=%s, out=[%s])\n' "$sh_bin" "$rc" "$out"; fi
  rm -rf "$stub3"

  # Gate predicate (story 1.2): the gate must discriminate with a REAL grep. A
  # rewrite whose mv silently does nothing (stub exits 0 without moving) leaves the
  # exact new line absent while a decoy line carries the raw text as a substring —
  # a weakened needle (substring match, missing -x, wrong variable) would accept
  # the decoy and this case would FAIL. The stranded temp is the lying stub's
  # artifact; the sandbox teardown sweeps it.
  home4=$(mktemp -d); mkdir -p "$home4/.claude"
  cp "$FIX/populated.md" "$home4/.claude/focus-ledger.md"
  printf '%s\n' "- [x] (2020-01-01) note: mv stub item" >> "$home4/.claude/focus-ledger.md"
  stub4=$(mktemp -d)
  printf '#!/bin/sh\nexit 0\n' > "$stub4/mv"; chmod +x "$stub4/mv"
  out=$(env -i HOME="$home4" PATH="$stub4:$PATH" "$sh_bin" "$ROOT/scripts/focus-park.sh" "mv stub item" 2>"$home4/err5"); rc=$?
  if [ "$rc" != 0 ] && [ -z "$out" ] && grep -q "verification failed" "$home4/err5"; then
    pass=$((pass+1)); printf '  ok   [%s] park: gate predicate needs the exact line, real grep\n' "$sh_bin"
  else fail=$((fail+1)); printf '  FAIL [%s] park: gate predicate (rc=%s, out=[%s])\n' "$sh_bin" "$rc" "$out"; fi
  rm -rf "$home4" "$stub4"
  rm -rf "$home"
}

# --- setup: idempotent CLAUDE.md block; preserves existing content; clean remove ---
run_setup_check() {
  sh_bin=$1
  command -v "$sh_bin" >/dev/null 2>&1 || return
  home=$(mktemp -d)
  md="$home/CLAUDE.md"
  printf '# My rules\n\nkeep this line.\n' > "$md"
  # Three installs must leave exactly one block and preserve the original line.
  ( cd "$home" && env -i HOME="$home" PATH="$PATH" "$sh_bin" "$ROOT/scripts/focus-setup.sh" local >/dev/null 2>&1 )
  ( cd "$home" && env -i HOME="$home" PATH="$PATH" "$sh_bin" "$ROOT/scripts/focus-setup.sh" local >/dev/null 2>&1 )
  ( cd "$home" && env -i HOME="$home" PATH="$PATH" "$sh_bin" "$ROOT/scripts/focus-setup.sh" local >/dev/null 2>&1 )
  n=$(grep -c 'FOCUS-LEDGER:BEGIN' "$md")
  kept=$(grep -c 'keep this line' "$md")
  if [ "$n" = 1 ] && [ "$kept" = 1 ]; then
    pass=$((pass+1)); printf '  ok   [%s] setup: idempotent single block, preserves content\n' "$sh_bin"
  else fail=$((fail+1)); printf '  FAIL [%s] setup: blocks=%s kept=%s (want 1/1)\n' "$sh_bin" "$n" "$kept"; fi
  # Repeated runs keep only the latest backup, not one per run.
  nbak=$(ls "$md".focus-bak.* 2>/dev/null | wc -l | tr -d ' ')
  if [ "$nbak" = 1 ]; then
    pass=$((pass+1)); printf '  ok   [%s] setup: single backup kept across runs\n' "$sh_bin"
  else fail=$((fail+1)); printf '  FAIL [%s] setup: %s backups (want 1)\n' "$sh_bin" "$nbak"; fi
  # Remove must drop the block but keep the original line.
  ( cd "$home" && env -i HOME="$home" PATH="$PATH" "$sh_bin" "$ROOT/scripts/focus-setup.sh" local --remove >/dev/null 2>&1 )
  n2=$(grep -c 'FOCUS-LEDGER:BEGIN' "$md")
  kept2=$(grep -c 'keep this line' "$md")
  if [ "$n2" = 0 ] && [ "$kept2" = 1 ]; then
    pass=$((pass+1)); printf '  ok   [%s] setup: --remove clears block, keeps content\n' "$sh_bin"
  else fail=$((fail+1)); printf '  FAIL [%s] setup: after remove blocks=%s kept=%s (want 0/1)\n' "$sh_bin" "$n2" "$kept2"; fi
  rm -rf "$home"
}

main() {
  shells=${1:-}
  if [ -n "$shells" ]; then set -- "$shells"; else set -- bash dash; fi
  for s in "$@"; do
    run_suite "$s"
    run_injection_check "$s"
    run_park_check "$s"
    run_setup_check "$s"
  done
  echo
  echo "TOTAL: $pass passed, $fail failed"
  [ "$fail" = 0 ]
}
main "$@"
