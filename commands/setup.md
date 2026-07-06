---
description: Install (or remove) the "offer to park when I pivot off an unfinished thread" behavior as a managed block in CLAUDE.md. Use when the user says "set up focus-ledger", "turn on the pivot nudge", "offer to park when I change topics", or wants the one focus-ledger behavior that isn't a hook. Also handles removing/updating that block.
argument-hint: [local | global | remove]
allowed-tools: Bash, AskUserQuestion
---

Install the one focus-ledger behavior that can't be a hook: when the user pivots off an unfinished thread, the assistant offers (in one line) to park the old one. It lives as a managed, idempotent block in CLAUDE.md — re-running updates it in place; removing takes it out cleanly.

Requested: $ARGUMENTS

Steps:

1. **If `$ARGUMENTS` already says the scope**, skip the question:
   - contains `remove`/`uninstall`/`off` → removal (use the scope word if given, else `local`).
   - contains `global` → install global. contains `local` → install local.

2. **Otherwise ask once** with AskUserQuestion — this edits the user's CLAUDE.md, so which file is genuinely their call:
   - Question: "Install the focus-ledger pivot-park nudge where?"
   - Options: `Local — this project's CLAUDE.md (recommended)`, `Global — ~/.claude/CLAUDE.md, every project`, `Remove it instead`.

3. **Run the bundled script** with the resolved choice:

   ```bash
   # install:
   "${CLAUDE_PLUGIN_ROOT}/scripts/focus-setup.sh" <local|global>
   # remove:
   "${CLAUDE_PLUGIN_ROOT}/scripts/focus-setup.sh" <local|global> --remove
   ```

   It backs up CLAUDE.md first, then injects/replaces the `<!-- FOCUS-LEDGER -->` block (idempotent — safe to run repeatedly). It does NOT touch hooks or settings; those are registered by the plugin itself.

4. **Report the result in one line** from the script's output (where it wrote, and that it applies next session). Mention the block is managed — re-run `/focus-ledger:setup` to update it, or `remove` to take it out.
