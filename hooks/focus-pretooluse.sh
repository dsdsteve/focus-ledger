#!/bin/bash
# focus-ledger PreToolUse hook — a soft, opt-in check before a write lands.
# Emits a top-level systemMessage and takes NO permission decision for "on", so the
# normal permission flow still runs and the write is NOT blocked
# (per Claude Code hooks docs: PreToolUse with no permissionDecision = normal flow).
#
#   FOCUS_WRITE_CHECK=on      -> emit the soft nudge
#   FOCUS_WRITE_CHECK=strict  -> return "ask" so each matched write pauses for confirmation
#   unset, off, or any other value -> stay silent
set -eu

case ${FOCUS_WRITE_CHECK:-} in
  on)
    printf '%s\n' '{
  "systemMessage": "Optional check before this write: is anything stated here confirmed against its source, and does the wording fit where it will actually be read (its audience, not this chat)? Ignore if it already does."
}'
    ;;
  strict)
    printf '%s\n' '{
  "systemMessage": "Optional check before this write: is anything stated here confirmed against its source, and does the wording fit where it will actually be read (its audience, not this chat)? Ignore if it already does.",
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "ask",
    "permissionDecisionReason": "Optional check before this write: is anything stated here confirmed against its source, and does the wording fit where it will actually be read (its audience, not this chat)? Ignore if it already does."
  }
}'
    ;;
  *)
    ;;
esac
exit 0
