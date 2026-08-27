#!/bin/bash
# Emit deterministic open-item TSV for the presentation-only /focus command.
set -u

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/scripts/focus-lib.sh" ]; then
  FOCUS_LIB_DIR="${CLAUDE_PLUGIN_ROOT}/scripts"
else
  FOCUS_LIB_DIR=$SCRIPT_DIR
fi
. "$FOCUS_LIB_DIR/focus-lib.sh"

focus_list_items
