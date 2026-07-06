#!/bin/bash
# focus-ledger PreToolUse hook — a soft, optional check before a write lands.
# Emits a top-level systemMessage and takes NO permission decision, so the normal
# permission flow still runs and the write is NOT blocked
# (per Claude Code hooks docs: PreToolUse with no permissionDecision = normal flow).
#
#   FOCUS_WRITE_CHECK=off     -> disable entirely
#   FOCUS_WRITE_CHECK=strict  -> return "ask" so each matched write pauses for confirmation
set -eu

check=${FOCUS_WRITE_CHECK:-}
[ "$check" = "off" ] && exit 0

msg="Optional check before this write: is anything stated here confirmed against its source, and does the wording fit where it will actually be read (its audience, not this chat)? Ignore if it already does."

if [ "$check" = "strict" ]; then
  decision="ask"
else
  decision=""   # empty -> omit; normal permission flow, non-blocking
fi

if command -v jq >/dev/null 2>&1; then
  jq -n --arg m "$msg" --arg d "$decision" '
    { systemMessage: $m }
    + ( if $d == "" then {}
        else { hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: $d, permissionDecisionReason: $m } }
        end )'
else
  esc=$(printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g')
  if [ -n "$decision" ]; then
    printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}' "$esc" "$decision" "$esc"
  else
    printf '{"systemMessage":"%s"}' "$esc"
  fi
fi
exit 0
