---
description: Install (or remove) the "offer to park when I pivot off an unfinished thread" behavior as a managed block in CLAUDE.md. Use when the user says "set up focus-ledger", "turn on the pivot nudge", "offer to park when I change topics", or specifically asks to remove/update that managed block.
argument-hint: [local | global | remove]
allowed-tools: Bash, AskUserQuestion
---

Install the one focus-ledger behavior that can't be a hook: when the user pivots off an unfinished thread, the assistant offers (in one line) to park the old one. It lives as a managed, idempotent block in CLAUDE.md — re-running updates it in place; removing takes it out cleanly.

Requested: $ARGUMENTS

Steps:

1. **If `$ARGUMENTS` already says the scope**, skip the question:
   - contains `remove`/`off` and clearly refers to the pivot/setup block → removal (use the scope word if given, else `local`).
   - contains `global` → install global. contains `local` → install local.
   - bare `uninstall` refers to the plugin, not this managed block. Explain that setup removal only removes the CLAUDE.md pivot instruction; do not silently translate plugin uninstall into `--remove`.

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

   Before creating a parent, target, backup, or staging rewrite, the script validates the existing `<!-- FOCUS-LEDGER:BEGIN ... -->` / `<!-- FOCUS-LEDGER:END -->` structure. Unmatched, nested, unclosed, same-line, or duplicate managed blocks refuse with exit 3 and preserve target existence, bytes, mtime, and existing backups. For an accepted install/update/remove of an existing target, it first creates and byte-verifies a timestamped backup named `<CLAUDE.md>.focus-bak.<epoch>.<suffix>`, then rotates the prior generation and rewrites the target. Removing a missing target is a true no-op. The script does NOT touch hooks or settings; the plugin registers those itself.

4. **Report according to the exit code:**
   - Exit 0: relay both script output lines: the install/remove result and the backup/undo pattern. Do not infer that a backup exists for a missing-target install/remove; only an existing target is backed up. For an install, mention that it applies next session. The block is managed — re-run `/focus-ledger:setup` to update it, or `remove` to take it out.
   - Exit 3: report the refusal and relay the script's recovery guidance. Do not claim a backup, path creation, mtime change, or rewrite occurred.
   - Any other nonzero exit: report that setup failed and do not claim success.
