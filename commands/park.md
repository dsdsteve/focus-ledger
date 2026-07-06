---
description: Park a NEW open thread so it survives across sessions — appends it to the durable tier of the focus ledger. Use when the user says "park this", "remember to…", "don't let me forget", "add a todo / note for later", "circle back to…", or flags a fresh loose end to come back to later. This creates a new thread; to bring an already-parked thread back into the active session, use resume.
argument-hint: [thing to come back to]
allowed-tools: Bash
---

Park a durable thread in the focus ledger.

The thing to park: $ARGUMENTS

Steps:
1. If `$ARGUMENTS` is empty, ask what to park (one line) and stop — don't run the script with no argument.
2. Trim the thing to its essence (a short phrase, not a pasted paragraph), then append it by running the bundled script — this is a deterministic insert that can't drop, reorder, or reformat existing items:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/focus-park.sh" "<the trimmed thing>"
   ```

   The script stamps today's date, inserts `- [ ] (YYYY-MM-DD) <thing>` at the end of the Parked section, and creates the ledger (with both sections) if it doesn't exist yet. Do NOT hand-edit the ledger file for a park — always go through the script, so concurrent sessions and existing items stay safe.

Output (answer-first), using the phrase you passed:
- One line, leading with the item: `<thing> — parked. (Carries over to next session; /focus-ledger:resume to pull it back.)`
- No preamble, no commentary on why they're parking it.

**Example:**
Input: `investigate the flaky login test`
Runs: `"${CLAUDE_PLUGIN_ROOT}/scripts/focus-park.sh" "investigate the flaky login test"`
Output: `investigate the flaky login test — parked. (Carries over to next session; /focus-ledger:resume to pull it back.)`
