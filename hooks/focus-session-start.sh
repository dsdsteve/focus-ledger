#!/bin/bash
# focus-ledger SessionStart hook — replay open parked threads as untrusted data.
# Soft only: never blocks and stays silent when nothing is parked.
set -eu

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/scripts/focus-lib.sh" ]; then
  FOCUS_LIB_DIR="${CLAUDE_PLUGIN_ROOT}/scripts"
else
  FOCUS_LIB_DIR="$SCRIPT_DIR/../scripts"
fi
[ -r "$FOCUS_LIB_DIR/focus-lib.sh" ] || exit 0
. "$FOCUS_LIB_DIR/focus-lib.sh" || exit 0

[ -f "$FOCUS_LEDGER" ] || exit 0
focus_parse_session_start "$FOCUS_LEDGER" || exit 0
exit 0
