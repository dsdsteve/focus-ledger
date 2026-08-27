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

3. **Run the bundled script** with the resolved choice and retain its exit code and output:

   ```bash
   # install:
   "${CLAUDE_PLUGIN_ROOT}/scripts/focus-setup.sh" <local|global>
   # remove:
   "${CLAUDE_PLUGIN_ROOT}/scripts/focus-setup.sh" <local|global> --remove
   ```

   Before rotating a backup or rewriting content, the script validates the
   `<!-- FOCUS-LEDGER:BEGIN ... -->` / `<!-- FOCUS-LEDGER:END -->` structure.
   Unmatched, nested, or unclosed markers refuse with exit 3, preserve file
   content and existing backups, and print recovery guidance. The script creates
   the parent/target (or touches an existing target) before this scan, so refusal
   can still create the path or update its mtime. For an accepted
   install/update/remove, it backs up `CLAUDE.md`, then injects, replaces, or
   removes the managed block. It does NOT touch hooks or settings; the plugin
   registers those itself.

4. **Report according to the exit code:**
   - Exit 0: relay both script output lines: the install/remove result and the
     backup/undo line. For an install, mention that it applies next session. The
     block is managed — re-run `/focus-ledger:setup` to update it, or `remove` to
     take it out.
   - Exit 3: report the refusal and relay the script's recovery guidance. Do not
     claim a backup or rewrite occurred.
   - Any other nonzero exit: report that setup failed and do not claim success.
