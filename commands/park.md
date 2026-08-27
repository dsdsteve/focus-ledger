---
description: Park a NEW open thread so it survives across sessions — appends it to the durable tier of the focus ledger. Use when the user says "park this", "remember to…", "don't let me forget", "add a todo / note for later", "circle back to…", or flags a fresh loose end to come back to later. This creates a new thread; to bring an already-parked thread back into the active session, use resume.
argument-hint: [thing to come back to]
allowed-tools: Bash
---

Park a durable thread in the focus ledger.

The thing to park: $ARGUMENTS

Steps:
1. If `$ARGUMENTS` is empty, ask what to park (one line) and stop — don't run the script with no argument.
2. Trim the thing to its essence (a short phrase, not a pasted paragraph), then run the bundled writer and retain its exit code and stdout:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/focus-park.sh" "<the trimmed thing>"
   ```

   The script stamps today's date, inserts `- [ ] (YYYY-MM-DD) <thing>` in the Parked section when guarded rewriting is available, and creates the ledger with both sections if it does not exist. Its no-loss fallback can append at EOF when safe structured publication cannot be proven. Do NOT hand-edit the ledger for a park.
3. Report according to the exit code:
   - Exit 0: stdout is the normalized item. Answer with `<stdout> — parked. (Carries over to next session; /focus-ledger:resume to pull it back.)`
   - Exit 1: say the write could not be verified and do not claim the item was parked. An identical line may already be present, so suggest checking `/focus-ledger:focus` or `/focus-ledger:doctor` before retrying.
   - Exit 2: ask for a non-empty item and do not claim success.
   - Any other nonzero exit: report that parking failed and do not claim success.

Use no preamble on success and do not add commentary about why the user is parking it.

**Example:**
Input: `investigate the flaky login test`
Runs: `"${CLAUDE_PLUGIN_ROOT}/scripts/focus-park.sh" "investigate the flaky login test"`
Exit 0 output: `investigate the flaky login test — parked. (Carries over to next session; /focus-ledger:resume to pull it back.)`
