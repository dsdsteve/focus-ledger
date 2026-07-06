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
pass=0; fail=0

# Each case runs in an isolated fake HOME with a chosen ledger fixture (or none).
# assert <shell> <name> <fixture-or-EMPTY> <expect-rc> <expect-stderr-empty:1/0> \
#        <hook-relpath> <must-contain> <must-not-contain> [env assignments...]
run_case() {
  sh_bin=$1; name=$2; fixture=$3; exp_rc=$4; exp_clean=$5; hook=$6; want=$7; notwant=$8; shift 8
  home=$(mktemp -d)
  mkdir -p "$home/.claude"
  [ "$fixture" = EMPTY ] || cp "$FIX/$fixture" "$home/.claude/focus-ledger.md"
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

  # Stop: silent when nothing stale; flags stale; skips malformed/undated; off-switch.
  run_case "$sh_bin" "stop: no ledger -> silent, rc0"               EMPTY        0 1 hooks/focus-stop.sh "" ""
  run_case "$sh_bin" "stop: fresh only -> silent"                   populated.md 0 1 hooks/focus-stop.sh "" "recent parked item"
  run_case "$sh_bin" "stop: stale -> flags old item"                stale.md     0 1 hooks/focus-stop.sh "very old item" ""
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
  env -i HOME="$home" PATH="$PATH" "$sh_bin" "$ROOT/scripts/focus-park.sh" "newly parked" >/dev/null 2>&1
  led=$(cat "$home/.claude/focus-ledger.md")
  if printf '%s' "$led" | grep -qF "recent parked item" && printf '%s' "$led" | grep -qF "newly parked"; then
    pass=$((pass+1)); printf '  ok   [%s] park: appends and preserves existing item\n' "$sh_bin"
  else fail=$((fail+1)); printf '  FAIL [%s] park: lost an item\n' "$sh_bin"; fi
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
